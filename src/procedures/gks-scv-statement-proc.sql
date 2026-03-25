CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_scv_statement_proc`(on_date DATE, debug BOOL)
BEGIN

  DECLARE query_scv_records STRING;
  DECLARE query_gene_context_qualifiers STRING;
  DECLARE query_moi_qualifiers STRING;
  DECLARE query_penetrance_qualifiers STRING;
  DECLARE query_scv_proposition STRING;
  DECLARE query_scv_target_proposition STRING;
  DECLARE query_statement_scv_pre STRING;
  DECLARE temp_create STRING;
  DECLARE temp_prefix STRING;

  IF debug THEN
    SET temp_create = 'CREATE OR REPLACE TABLE';
  ELSE
    SET temp_create = 'CREATE TEMP TABLE';
  END IF;

  FOR rec IN (select s.schema_name FROM clinvar_ingest.schema_on(on_date) as s)
  DO

    -- Clean up any persistent temp tables from a prior debug run
    IF NOT debug THEN
      CALL `clinvar_ingest.cleanup_temp_tables`(rec.schema_name, [
        'temp_gks_scv', 'temp_gene_context_qualifiers', 'temp_moi_qualifiers',
        'temp_penetrance_qualifiers', 'temp_gks_scv_proposition', 'temp_gks_scv_target_proposition'
      ]);
    END IF;

    ---------------------------------------------------------------------------
    -- Step 1: Create GKS SCV table (temp)
    ---------------------------------------------------------------------------
    SET query_scv_records = REPLACE("""
      {CT} {P}.temp_gks_scv
      AS
        SELECT
          scv.id,
          scv.version,
          IF(
            cct.final_proposition_type IS NOT NULL,
            STRUCT(cct.final_proposition_type as type, cct.final_predicate as pred),
            STRUCT('ClinvarUndefinedProposition' as type, 'isClinvarUndefinedAssociationFor' as pred)
          ) as proposition,

          CASE scv.clinical_impact_assertion_type
            WHEN 'prognostic' THEN
              CASE scv.clinical_impact_clinical_significance
                WHEN 'better outcome' THEN
                  STRUCT('VariantPrognosticProposition' as type, 'associatedWithBetterOutcomeFor' as pred)
                WHEN 'poor outcome' THEN
                  STRUCT('VariantPrognosticProposition' as type, 'associatedWithWorseOutcomeFor' as pred)
                ELSE
                  -- should never occur
                  STRUCT('VariantPrognosticProposition' as type, 'associatedWithUndefinedOutcomeFor' as pred)
              END
            WHEN 'diagnostic' THEN
              CASE scv.clinical_impact_clinical_significance
                WHEN 'supports diagnosis' THEN
                  STRUCT('VariantDiagnosticProposition' as type, 'isDiagnosticInclusionCriterionFor' as pred)
                WHEN 'excludes diagnosis' THEN
                  STRUCT('VariantDiagnosticProposition' as type, 'isDiagnosticExclusionCriterionFor' as pred)
                ELSE
                  -- should never occur
                  STRUCT('VariantDiagnosticProposition' as type, 'isDiagnosticUndefinedCriterionFor' as pred)
              END
            WHEN 'therapeutic' THEN
              CASE scv.clinical_impact_clinical_significance
                WHEN 'sensitivity/response' THEN
                  STRUCT('VariantTherapeuticResponseProposition' as type, 'predictsSensitivityTo' as pred)
                WHEN 'resistance' THEN
                  STRUCT('VariantTherapeuticResponseProposition' as type, 'predictsResistanceTo' as pred)
                WHEN 'reduced sensitivity' THEN
                  -- AHW is looking into whether this should be allowed
                  STRUCT('VariantTherapeuticResponseProposition' as type, 'predictsReducedSensitivtyTo' as pred)
                ELSE
                  -- should never occur
                  STRUCT('VariantTherapeuticResponseProposition' as type, 'predictsUndefinedResponseTo' as pred)
              END
          END as evidence_line_target_proposition,

          scv.date_created,
          scv.date_last_updated,
          scv.local_key,
          scv.last_evaluated,
          cct.direction,
          scv.variation_id,
          scv.review_status,
          scv.submitted_classification,
          cct.label as classification_name,
          cct.classification_code,
          cct.strength_label as strength_name,
          cct.strength_code,
          cct.code_system as classif_and_strength_code_system,
          scv.method_type,
          scv.origin,
          scv.classif_type,
          scv.statement_type,
          scv.clinical_impact_assertion_type,
          scv.clinical_impact_clinical_significance,
          scv.classification_comment,
          -- -- ideally we'd move the drugTherapy extraction to the scv_summary table - future improvement.
          SPLIT(
            JSON_EXTRACT_SCALAR(
              ca.content,
              "$.Classification.SomaticClinicalImpact['@DrugForTherapeuticAssertion']"
            ),
            ';'
          ) as drugTherapy,
          `clinvar_ingest.parseAttributeSet`(ca.content) as attribs,
          (
            SELECT ARRAY_AGG(s)
            FROM (
              SELECT DISTINCT s
              FROM UNNEST(
                ARRAY_CONCAT(
                  `clinvar_ingest.parseCitations`(JSON_EXTRACT(ca.content,'$')),
                  `clinvar_ingest.parseCitations`(JSON_EXTRACT(ca.content,'$.Classification'))
                )
              ) AS s
            )
          ) as scvCitations,
          STRUCT (
            FORMAT('clinvar.submitter:%s',scv.submitter_id) as id,
            'Agent' as type,
            scv.submitter_name as name
          ) as submitter

        FROM `{S}.clinical_assertion` ca
        JOIN `{S}.scv_summary` scv
        ON
          scv.id = ca.id
        LEFT JOIN `clinvar_ingest.clinvar_clinsig_types` cct
          ON
            cct.code = scv.classif_type
            AND
            cct.statement_type = scv.statement_type
    """, '{S}', rec.schema_name);
    SET query_scv_records = REPLACE(query_scv_records, '{CT}', temp_create);
    SET query_scv_records = REPLACE(query_scv_records, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_scv_records;

    ---------------------------------------------------------------------------
    -- Step 2: Create temp gene context qualifiers
    ---------------------------------------------------------------------------
    SET query_gene_context_qualifiers = REPLACE("""
      {CT} {P}.temp_gene_context_qualifiers
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
                  FORMAT('https://identifiers.org/ncbigene:%s',g.id),
                  FORMAT('https://www.ncbi.nlm.nih.gov/gene/%s', g.id)
              ] as iris
            ) as primaryCoding,
            [
              STRUCT(
                STRUCT(
                  REGEXP_EXTRACT(g.hgnc_id, r'\\d+') as code,
                  'https://www.genenames.org' as system,
                  [
                      FORMAT('https://identifiers.org/hgnc:%s',REGEXP_EXTRACT(g.hgnc_id, r'\\d+')),
                      FORMAT(
                        'https://www.genenames.org/data/gene-symbol-report/#!/hgnc_id/%s',
                        REGEXP_EXTRACT(g.hgnc_id, r'\\d+')
                      )
                  ] as iris
                ) as coding,
                'exactMatch' as relation
              )
            ] as mappings
          from `{S}.single_gene_variation` sgv
          join `{S}.gene` g
          on
            g.id = sgv.gene_id
        ),
        scv_submitted_genes AS (
          SELECT
            cav.clinical_assertion_id,
            ARRAY_AGG(DISTINCT gene_symbol) as submitted_gene_symbols
          FROM `{S}.clinical_assertion_variation` cav
          CROSS JOIN UNNEST(clinvar_ingest.parseGeneLists(cav.content)) as g
          CROSS JOIN UNNEST(SPLIT(g.symbol)) as gene_symbol
          GROUP BY
            cav.clinical_assertion_id
        )
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
                'submittedGeneSymbols' as name,
                ssg.submitted_gene_symbols as value_string,
                null as value_object
              )
            ]
          ) as extensions
        from {P}.temp_gks_scv scv
        join `{S}.single_gene_variation` sgv
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
              'submittedGeneSymbols' as name,
              ssg.submitted_gene_symbols as value_string,
              null as value_object
            )
          ]  as extensions
        from {P}.temp_gks_scv scv
        join scv_submitted_genes ssg
        on
          ssg.clinical_assertion_id = scv.id
        left join `{S}.single_gene_variation` sgv
        on
          sgv.variation_id = scv.variation_id
        left join normalized_single_gene_variation nsgv
        on
          nsgv.gene_id = sgv.gene_id
        where
          nsgv.gene_id is null
    """, '{S}', rec.schema_name);
    SET query_gene_context_qualifiers = REPLACE(query_gene_context_qualifiers, '{CT}', temp_create);
    SET query_gene_context_qualifiers = REPLACE(query_gene_context_qualifiers, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_gene_context_qualifiers;

    ---------------------------------------------------------------------------
    -- Step 3: Create temp mode of inheritance qualifiers
    ---------------------------------------------------------------------------
    SET query_moi_qualifiers = REPLACE("""
      {CT} {P}.temp_moi_qualifiers
      AS
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
                  FORMAT('https://identifiers.org/%s',hpo.id),
                  FORMAT('https://hpo.jax.org/browse/term/%s', hpo.id)
              ] as iris
            )
          ) as primaryCoding,
          [
            STRUCT(
              'submittedModeOfInheritance' as name,
              a.attribute.value as value_string,
              null as value_object
            )
          ] as extensions
        from {P}.temp_gks_scv scv
        CROSS JOIN UNNEST(scv.attribs) as a
        LEFT JOIN `clinvar_ingest.hpo_terms` hpo
        ON
          LOWER(hpo.lbl) = LOWER(a.attribute.value)
        WHERE
          a.attribute.type = 'ModeOfInheritance'
    """, '{S}', rec.schema_name);
    SET query_moi_qualifiers = REPLACE(query_moi_qualifiers, '{CT}', temp_create);
    SET query_moi_qualifiers = REPLACE(query_moi_qualifiers, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_moi_qualifiers;

    ---------------------------------------------------------------------------
    -- Step 4: Create temp penetrance qualifiers
    ---------------------------------------------------------------------------
    SET query_penetrance_qualifiers = REPLACE("""
      {CT} {P}.temp_penetrance_qualifiers
      AS
        SELECT
          scv.id as scv_id,
          'penetrance' as conceptType,
          IF(scv.classif_type IN ('p-lp','lp-lp'), 'low', 'risk') as name,
          [
            STRUCT(
              'submittedClassification' as name,
              scv.submitted_classification as value_string,
              null as value_object
            )
          ] as extensions
        FROM {P}.temp_gks_scv scv
        WHERE
          scv.classif_type in ('p-lp', 'lp-lp', 'era', 'lra','ura')
    """, '{S}', rec.schema_name);
    SET query_penetrance_qualifiers = REPLACE(query_penetrance_qualifiers, '{CT}', temp_create);
    SET query_penetrance_qualifiers = REPLACE(query_penetrance_qualifiers, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_penetrance_qualifiers;

    ---------------------------------------------------------------------------
    -- Step 5: Create SCV proposition table (temp)
    ---------------------------------------------------------------------------
    SET query_scv_proposition = REPLACE("""
      {CT} {P}.temp_gks_scv_proposition
      AS
        SELECT
          scv.id,
          scv.proposition.type as type,
          FORMAT('clinvar:%s', scv.variation_id) as subjectVariation,
          scv.proposition.pred as predicate,
          scs.condition as objectCondition_single,
          scs.conditionSet as objectCondition_compound,
          (SELECT AS STRUCT sgq.* EXCEPT(scv_id)) as geneContextQualifier,
          (SELECT AS STRUCT smq.* EXCEPT(scv_id)) as modeOfInheritanceQualifier,
          (SELECT AS STRUCT spq.* EXCEPT(scv_id)) as penetranceQualifier
        FROM {P}.temp_gks_scv scv
        LEFT JOIN {P}.temp_gene_context_qualifiers sgq
        ON
          sgq.scv_id = scv.id
        LEFT JOIN {P}.temp_moi_qualifiers smq
        ON
          smq.scv_id = scv.id
        LEFT JOIN {P}.temp_penetrance_qualifiers spq
        ON
          spq.scv_id = scv.id
        LEFT JOIN `{S}.gks_scv_condition_sets` scs
        ON
          scs.scv_id = scv.id
    """, '{S}', rec.schema_name);
    SET query_scv_proposition = REPLACE(query_scv_proposition, '{CT}', temp_create);
    SET query_scv_proposition = REPLACE(query_scv_proposition, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_scv_proposition;

    ---------------------------------------------------------------------------
    -- Step 6: Create SCV target proposition table (temp)
    ---------------------------------------------------------------------------
    SET query_scv_target_proposition = REPLACE("""
      {CT} {P}.temp_gks_scv_target_proposition
      AS
        WITH scv_drugs AS (
          SELECT
            scv_id,
            ARRAY_AGG(STRUCT(drug.name, 'Drug' as conceptType)) as therapies,
            STRUCT(CAST(null as string) as name, CAST(null as string) as conceptType) as therapy
          FROM (
            SELECT
              scv.id as scv_id,
              drug as name
            FROM {P}.temp_gks_scv scv
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
          FROM {P}.temp_gks_scv scv
          CROSS JOIN UNNEST(scv.drugTherapy) as drug
          GROUP BY
            scv.id
          HAVING COUNT(*) = 1
        )
        SELECT
          scv.id,
          scv.evidence_line_target_proposition.type as type,
          '4/proposition/subjectVariation' as subjectVariation,
          scv.evidence_line_target_proposition.pred as predicate,
          IF(
            scv.clinical_impact_assertion_type IS DISTINCT FROM 'therapeutic',
            scs.condition,
            null
          ) as objectCondition_single,
          IF(
            scv.clinical_impact_assertion_type IS DISTINCT FROM 'therapeutic',
            scs.conditionSet,
            null
          ) as objectCondition_compound,
          IF(
            ARRAY_LENGTH(sd.therapies) > 1,
            STRUCT(sd.therapies, 'AND' as membershipOperator),
            null
          ) as objectTherapy_compound,
          sd.therapy as objectTherapy_single,
          IF(
            scv.clinical_impact_assertion_type IS NOT DISTINCT FROM 'therapeutic',
            scs.condition,
            null
          ) as conditionQualifier_single,
          IF(
            scv.clinical_impact_assertion_type IS NOT DISTINCT FROM 'therapeutic',
            scs.conditionSet,
            null
          ) as conditionQualifier_compound,
          (SELECT AS STRUCT sgq.* EXCEPT(scv_id)) as geneContextQualifier,
          (SELECT AS STRUCT smq.* EXCEPT(scv_id)) as modeOfInheritanceQualifier,
          (SELECT AS STRUCT spq.* EXCEPT(scv_id)) as penetranceQualifier
        FROM {P}.temp_gks_scv scv
        LEFT JOIN {P}.temp_gene_context_qualifiers sgq
        ON
          sgq.scv_id = scv.id
        LEFT JOIN {P}.temp_moi_qualifiers smq
        ON
          smq.scv_id = scv.id
        LEFT JOIN {P}.temp_penetrance_qualifiers spq
        ON
          spq.scv_id = scv.id
        LEFT JOIN `{S}.gks_scv_condition_sets` scs
        ON
          scs.scv_id = scv.id
        LEFT JOIN scv_drugs sd
        ON
          sd.scv_id = scv.id
        WHERE
          scv.evidence_line_target_proposition IS NOT NULL
    """, '{S}', rec.schema_name);
    SET query_scv_target_proposition = REPLACE(query_scv_target_proposition, '{CT}', temp_create);
    SET query_scv_target_proposition = REPLACE(query_scv_target_proposition, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_scv_target_proposition;

    ---------------------------------------------------------------------------
    -- Step 7: Create statement SCV pre table
    ---------------------------------------------------------------------------
    SET query_statement_scv_pre = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_statement_scv_pre`
      as
      WITH scv_citation AS (
        SELECT
          scv.id,
          STRUCT(
            'Document' as type,
            IF(lower(cid.source) = 'pubmed', cid.id, null) as pmid,
            IF(lower(cid.source) = 'doi', cid.id, null) as doi,
            [CASE
            WHEN c.url IS NOT NULL THEN
              c.url
            WHEN LOWER(cid.source) = 'pubmed' THEN
              FORMAT('https://pubmed.ncbi.nlm.nih.gov/%s',cid.id)
            WHEN LOWER(cid.source) = 'pmc' THEN
              FORMAT('https://europepmc.org/article/PMC/%s',cid.id)
            WHEN LOWER(cid.source) = 'doi' THEN
              FORMAT('https://doi.org/%s',cid.id)
            WHEN LOWER(cid.source) = 'bookshelf' THEN
              FORMAT('https://www.ncbi.nlm.nih.gov/books/%s',cid.id)
            ELSE
              cid.curie
            END] as urls
          ) as doc
        FROM {P}.temp_gks_scv scv
        CROSS JOIN UNNEST(scv.scvCitations) as c
        CROSS JOIN UNNEST(c.id) as cid
        WHERE
          cid.source IS NOT NULL
          OR c.url IS NOT NULL
      ),
      scv_citations as (
        SELECT
          id,
          ARRAY_AGG(doc) as reportedIn
        FROM scv_citation
        GROUP BY id
      ),
      scv_method as (
        -- there are less than 10 assertion method attributes that contain multiple citations
        --   these are likely mis-submitted info since they should be in the interp citations
        --   not the assertion method citations which should almost exclusively be 1 item
        --   for now we comprimise by grouping any multi- citation id values together as a string
        --   and hoping that the citation source and url will aggregate to the same single record.
        --   this hacky policy works around the bad data as of 2024-04-07
        SELECT
          scv.id,
          STRUCT (
            'Method' as type,
            scv.method_type as methodType,
            a.attribute.value as name,
            IF(
              (cid.source is not null OR c.url is not null),
              STRUCT(
                'Document' as type,
                IF(LOWER(cid.source) = 'pubmed', STRING_AGG(cid.id), null) as pmid,
                IF(LOWER(cid.source) = 'doi', STRING_AGG(cid.id), null) as doi,
                [
                  CASE
                  WHEN c.url IS NOT NULL THEN
                    c.url
                  WHEN LOWER(cid.source) = 'pubmed' THEN
                    FORMAT('https://pubmed.ncbi.nlm.nih.gov/%s',STRING_AGG(cid.id))
                  WHEN LOWER(cid.source) = 'pmc' THEN
                    FORMAT('https://europepmc.org/article/PMC/%s',STRING_AGG(cid.id))
                  WHEN LOWER(cid.source) = 'doi' THEN
                    FORMAT('https://doi.org/%s',STRING_AGG(cid.id))
                  WHEN LOWER(cid.source) = 'bookshelf' THEN
                    FORMAT('https://www.ncbi.nlm.nih.gov/books/%s',STRING_AGG(cid.id))
                  ELSE
                    FORMAT('%s:%s', cid.source, STRING_AGG(cid.id))
                  END
                ] as urls
              ),
              null
            ) as reportedIn
          ) as specifiedBy
        FROM {P}.temp_gks_scv scv
        CROSS JOIN UNNEST(scv.attribs) as a
        LEFT JOIN UNNEST(a.citation) as c
        LEFT JOIN UNNEST(c.id) as cid
        WHERE
          a.attribute.type = 'AssertionMethod'
        GROUP BY
          scv.id,
          a.attribute.value,
          cid.source,
          c.url,
          scv.method_type
      )
      -- final output before it is normalized into json
      SELECT
        FORMAT('%s.%i', scv.id, scv.version) as id,
        'Statement' as type,
        sp as proposition,
        STRUCT(
          scv.submitted_classification as name,
          IF(
            scv.classification_code IS NOT NULL,
            STRUCT(scv.classification_code as code, scv.classif_and_strength_code_system as system),
            null
          ) as primaryCoding
        ) as classification,
         STRUCT(
          scv.strength_name as name,
          IF(
            scv.strength_code IS NOT NULL,
            STRUCT(scv.strength_code as code, scv.classif_and_strength_code_system as system),
            null
          ) as primaryCoding
        ) as strength,
        scv.direction,
        scv.classification_comment as description,
        [
          STRUCT(
            'Contribution' as type,
            scv.submitter as contributor,
            scv.date_last_updated as date,
            'submitted' as activityType
          ),
          STRUCT(
            'Contribution' as type,
            scv.submitter as contributor,
            scv.date_created as date,
            'created' as activityType
          ),
          STRUCT(
            'Contribution' as type,
            scv.submitter as contributor,
            scv.last_evaluated as date,
            'evaluated' as activityType
          )
        ] as contributions,
        sm.specifiedBy,
        scit.reportedIn,
        ARRAY_CONCAT(
          [
            STRUCT('clinvarScvId' as name, scv.id as value_string),
            STRUCT('clinvarScvVersion' as name, CAST(scv.version AS STRING) as value_string)
          ],
          IF(
            scv.review_status IS NULL,
            [],
            [STRUCT('clinvarScvReviewStatus' as name, scv.review_status as value_string)]
          ),
          IF(
            scv.submitted_classification IS NOT DISTINCT FROM scv.classification_name,
            [],
            [STRUCT('submittedScvClassification' as name, scv.submitted_classification as value_string)]
          ),
          IF(
            scv.local_key IS NULL,
            [],
            [STRUCT('submittedScvLocalKey' as name, scv.local_key as value_string)]
          )
        ) as extensions,
        IF (
          stp.id is not null,
          [
            STRUCT(
              FORMAT('%s.%i', scv.id, scv.version) as id,
              'EvidenceLine' as type,
              stp as proposition,
              'supports' as directionOfEvidenceProvided,
              CASE scv.classification_code
                WHEN 'tier 1' THEN
                  STRUCT('Level A/B' as name)
                WHEN 'tier 2' THEN
                  STRUCT('Level C/D' as name)
                ELSE
                  STRUCT(scv.classification_code as name)
              END as evidenceOutcome
            )
          ],
          []
        ) as hasEvidenceLines
      FROM {P}.temp_gks_scv scv
      JOIN {P}.temp_gks_scv_proposition sp
      ON
        sp.id = scv.id
      LEFT JOIN {P}.temp_gks_scv_target_proposition stp
      ON
        stp.id = scv.id
      LEFT JOIN scv_method sm
      ON
        sm.id = scv.id
      LEFT JOIN scv_citations scit
      ON
        scit.id = scv.id
    """, '{S}', rec.schema_name);
    SET query_statement_scv_pre = REPLACE(query_statement_scv_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_statement_scv_pre;

    IF NOT debug THEN
      DROP TABLE _SESSION.temp_gks_scv;
      DROP TABLE _SESSION.temp_gene_context_qualifiers;
      DROP TABLE _SESSION.temp_moi_qualifiers;
      DROP TABLE _SESSION.temp_penetrance_qualifiers;
      DROP TABLE _SESSION.temp_gks_scv_proposition;
      DROP TABLE _SESSION.temp_gks_scv_target_proposition;
    END IF;

  END FOR;
END;
