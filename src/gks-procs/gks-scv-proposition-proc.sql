CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_scv_proposition_proc`(start_with DATE)
BEGIN
  FOR rec IN (select s.schema_name FROM clinvar_ingest.schema_on(start_with) as s)
  DO
    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_scv_proposition`
      AS
        WITH normalized_single_gene_variation AS (
          SELECT DISTINCT
            sgv.gene_id,
            'gene' as conceptType,
            g.symbol as name,
            STRUCT(
              g.id as code,
              g.symbol as name,
              'https://www.ncbi.nlm.nih.gov/gene/' as system,
              [
                  FORMAT('https://identifiers.org/ncbigene:%%s',g.id),
                  FORMAT('https://www.ncbi.nlm.nih.gov/gene/%%s', g.id)
              ] as iris
            ) as primaryCoding,
            [
              STRUCT(
                STRUCT(
                  REGEXP_EXTRACT(g.hgnc_id, r'\\d+') as code,
                  'https://www.genenames.org' as system,
                  [
                      FORMAT('https://identifiers.org/hgnc:%%s',REGEXP_EXTRACT(g.hgnc_id, r'\\d+')),
                      FORMAT(
                        'https://www.genenames.org/data/gene-symbol-report/#!/hgnc_id/%%s', 
                        REGEXP_EXTRACT(g.hgnc_id, r'\\d+')
                      )
                  ] as iris
                ) as coding,
                'exactMatch' as relation
              )
            ] as mappings
          from `%s.single_gene_variation` sgv
          join `%s.gene` g
          on
            g.id = sgv.gene_id
        )
        ,
        scv_submitted_genes AS (
          SELECT 
            cav.clinical_assertion_id,
            ARRAY_AGG(DISTINCT gene_symbol) as submitted_gene_symbols
          FROM `%s.clinical_assertion_variation` cav
          CROSS JOIN UNNEST(clinvar_ingest.parseGeneLists(cav.content)) as g
          CROSS JOIN UNNEST(SPLIT(g.symbol)) as gene_symbol
          GROUP BY 
            cav.clinical_assertion_id
        ),
        scv_gene_context_qualifiers AS (
          SELECT
            scv.id as scv_id,
            nsgv.conceptType,
            nsgv.name,
            nsgv.primaryCoding,
            nsgv.mappings,
            IF(
              ssg.submitted_gene_symbols is null OR ARRAY_LENGTH(ssg.submitted_gene_symbols) = 0, 
              null,
              [
                STRUCT(
                  'submitted gene symbols' as name,
                  ssg.submitted_gene_symbols as value_string,
                  null as value_object
                )
              ]
            ) as extensions
          from `%s.gks_scv` scv
          join `%s.single_gene_variation` sgv
          on
            sgv.variation_id = scv.variation_id
          join normalized_single_gene_variation nsgv
          on
            nsgv.gene_id = sgv.gene_id
          left join scv_submitted_genes ssg
          on
            ssg.clinical_assertion_id = scv.id
          UNION ALL
          SELECT
            scv.id as scv_id,
            'gene' as conceptType,
            'submitted genes were not normalized' as name,
            null as primaryCoding,
            null as mappings,
            [
              STRUCT(
                'submitted gene symbols' as name,
                ssg.submitted_gene_symbols as value_string,
                null as value_object
              )
            ]  as extensions
          from `%s.gks_scv` scv
          join scv_submitted_genes ssg
          on
            ssg.clinical_assertion_id = scv.id
          left join `%s.single_gene_variation` sgv
          on
            sgv.variation_id = scv.variation_id
          left join normalized_single_gene_variation nsgv
          on
            nsgv.gene_id = sgv.gene_id
          where 
            nsgv.gene_id is null
        ),
        scv_moi_qualifiers AS (
          SELECT
            scv.id as scv_id,
            'modeOfInheritance' as conceptType,
            a.attribute.value as name,
            IF(
              hpo.id is null, 
              null,
              STRUCT(
                hpo.id as code,
                hpo.lbl as name,
                'https://hpo.jax.org/' as system,
                [
                    FORMAT('https://identifiers.org/%%s',hpo.id),
                    FORMAT('https://hpo.jax.org/browse/term/%%s', hpo.id)
                ] as iris       
              )
            ) as primaryCoding,
            [
              STRUCT(
                'submitted mode of inheritance' as name,
                a.attribute.value as value_string,
                null as value_object
              )
            ] as extensions
          from `%s.gks_scv` scv
          CROSS JOIN UNNEST(scv.attribs) as a
          LEFT JOIN `clingen-dev.clinvar_ingest.hpo_terms` hpo
          ON
            LOWER(hpo.lbl) = LOWER(a.attribute.value)
          WHERE 
            a.attribute.type = 'ModeOfInheritance'
        ),
        scv_penetrance_qualifiers AS (
          SELECT
            scv.id as scv_id,
            'penetrance' as conceptType,
            IF(scv.classif_type IN ('p-lp','lp-lp'), 'low', 'risk') as name,
            [
              STRUCT(
                'submitted classification' as name,
                scv.submitted_classification as value_string,
                null as value_object
              )
            ] as extensions
          from `%s.gks_scv` scv
          WHERE 
            scv.classif_type in ('p-lp', 'lp-lp', 'era', 'lra','ura')
        ),
        scv_drugs AS (
          SELECT
            scv_id,
            ARRAY_AGG(STRUCT(drug.name, 'Drug' as conceptType)) as therapies,
            STRUCT(CAST(null as string) as name, CAST(null as string) as conceptType) as therapy
          FROM (
            SELECT 
              scv.id as scv_id,
              drug as name
            FROM `%s.gks_scv` scv
            CROSS JOIN UNNEST(scv.drugTherapy) as drug
          ) drug
          GROUP BY
            scv_id
          HAVING COUNT(*) > 1
          UNION ALL
          SELECT 
            scv.id as scv_id,
            [STRUCT(CAST(null as string) as name, CAST(null as string) as conceptType)] as therapies,
            STRUCT(
              ARRAY_AGG(drug)[SAFE_OFFSET(0)] as name,
              'Drug' as conceptType
            ) as therapy
          FROM `%s.gks_scv` scv
          CROSS JOIN UNNEST(scv.drugTherapy) as drug
          GROUP BY
            scv.id
          HAVING COUNT(*) = 1
        )
        SELECT 
          scv.id,
          scv.proposition.type as type,
          scv.variation_id as subjectVariation,  
          scv.proposition.pred as predicate,
          IF(
            ARRAY_LENGTH(sd.therapies) > 0, 
            STRUCT(sd.therapies, 'AND' as membershipOperator), 
            null
          ) as objectTherapeutic_compound,
          IF(
            sd.therapies IS NULL OR ARRAY_LENGTH(sd.therapies)=0,
            sd.therapy,
            null
          ) as objectTherpeutic_simple,
          IF(
            scv.proposition.type not in ('VariantOncogenicityProposition','VariantTherapeuticResponseProposition'), 
            scs.condition, 
            null
          ) as objectCondition_single,
          IF(
            scv.proposition.type not in ('VariantOncogenicityProposition','VariantTherapeuticResponseProposition'), 
            scs.conditionSet, 
            null
          ) as objectCondition_compound,
          IF(
            scv.proposition.type = 'VariantOncogenicityProposition', 
            scs.condition, 
            null
          ) as objectTumorType_single,
          IF(
            scv.proposition.type = 'VariantOncogenicityProposition', 
            scs.conditionSet, 
            null
          ) as objectTumorType_compound,
          IF(
            scv.proposition.type = 'VariantTherapeuticResponseProposition', 
            scs.condition, 
            null
          ) as conditionQualifier_single,
          IF(
            scv.proposition.type = 'VariantTherapeuticResponseProposition', 
            scs.conditionSet, 
            null
          ) as conditionQualifier_compound,
          (SELECT AS STRUCT sgq.* EXCEPT(scv_id)) as geneContextQualifier,
          (SELECT AS STRUCT smq.* EXCEPT(scv_id)) as modeOfInheritanceQualifier,
          (SELECT AS STRUCT spq.* EXCEPT(scv_id)) as penetranceQualifier
        FROM `%s.gks_scv` scv
        LEFT JOIN scv_gene_context_qualifiers sgq
        ON
          sgq.scv_id = scv.id
        LEFT JOIN scv_moi_qualifiers smq
        ON
          smq.scv_id = scv.id
        LEFT JOIN scv_penetrance_qualifiers spq
        ON
          spq.scv_id = scv.id
        LEFT JOIN `%s.gks_scv_condition_sets` scs
        ON
          scs.scv_id = scv.id
        LEFT JOIN scv_drugs sd
        ON
          sd.scv_id = scv.id
  """, 
  rec.schema_name, 
  rec.schema_name, 
  rec.schema_name, 
  rec.schema_name, 
  rec.schema_name, 
  rec.schema_name, 
  rec.schema_name, 
  rec.schema_name, 
  rec.schema_name, 
  rec.schema_name, 
  rec.schema_name, 
  rec.schema_name, 
  rec.schema_name, 
  rec.schema_name
  );

  END FOR;
END;

