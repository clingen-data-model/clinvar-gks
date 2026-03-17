CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_vcv_proposition_proc`(start_with DATE)
BEGIN
  FOR rec IN (select s.schema_name FROM clinvar_ingest.schema_on(start_with) as s)
  DO
  --   subjectVariant: clinvar:10
  -- predicate: hasAggregateClassification
  -- aggregateQualifier:
  --   - name:  classificationCategory
  --     value: GermlineClassification
  --            OncogenicityClassification
  --            SomaticClinicalImpact
  --   - name:  classificationType
  --     value: Mendelian diseases (VariantPathogenicity) path
  --            drug response
  --            association
  --            protective
  --            Affects
  --            conflicting data from submitters
  --            other
  --            not provided
  --            risk factor
  --            oncogenicity (VariantOncogenicity)
  --            clinical impact 
  --   - name:  reviewStatus
  --     value: -3 (no classifications from unflagged records)
  --            -2 (no classification for the single variant)
  --            -1 (no classification provided)
  --            0 (no assertion criteria provided)
  --            1 (criteria provided, single submitter)
  --            1 (criteria provided, conflicting classifications)
  --            2 (criteria provided, multiple submitters, no conflicts) path
  --            2 (criteria provided, multiple submitters) onco
  --            3 (reviewed by expert panel)
  --            4 (practice guideline)
-- ;

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_vcv_cat_type_rank_agg_proposition`
      AS
        SELECT 
          vcv.id,
          'VariantCategoryTypeRankAggregate' as type,
          FORMAT('clinvar:%%s', vcv.variation_id) as subjectVariation,  
          'hasAggregateClassification' as predicate,
          [
            STRUCT(
              'classificationCategory' as name, 
              vcv.statement_type as value_string,
              CAST(null as INT) as value_int
            ),
            STRUCT(
              'classificationType' as name, 
              cpt.label as value_string,
              CAST(null as INT) as value_int
            ),
            STRUCT(
              'aggregateRank' as name, 
              CAST(null as STRING) as value_string,
              vcv.agg_rank as value_int
            )
          ] as aggregateQualifier,
          [
            STRUCT( 
              'aggregateReviewStatus' as name, 

              IF(vcv.statement_type = 'SomaticClinicalImpact' AND vcv.agg_rank = 2, REPLACE(cs.label,', no conflicts',''),cs.label) as value)
              
          ] as extensions
        FROM `%s.gks_vcv_proposition_agg` vcv
        LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt
        ON
          cpt.code = vcv.original_proposition_type
        -- LEFT JOIN `clinvar_ingest.clinvar_status` cs
        -- ON
        --   NOT cs.scv
        --   AND
        --   cs.rank = vcv.agg_rank
        --   AND
        --   vcv.release_date BETWEEN cs.start_release_date AND cs.end_release_date
    """, 
    rec.schema_name, 
    rec.schema_name
    );

    -- EXECUTE IMMEDIATE FORMAT("""
    --   CREATE OR REPLACE TABLE `%s.gks_scv_target_proposition`
    --   AS
    --     WITH scv_drugs AS (
    --       SELECT
    --         scv_id,
    --         ARRAY_AGG(STRUCT(drug.name, 'Drug' as conceptType)) as therapies,
    --         STRUCT(CAST(null as string) as name, CAST(null as string) as conceptType) as therapy
    --       FROM (
    --         SELECT 
    --           scv.id as scv_id,
    --           drug as name
    --         FROM `%s.gks_scv` scv
    --         CROSS JOIN UNNEST(scv.drugTherapy) as drug
    --       ) drug
    --       GROUP BY
    --         scv_id
    --       HAVING COUNT(*) > 1
    --       UNION ALL
    --       SELECT 
    --         scv.id as scv_id,
    --         [STRUCT(CAST(null as string) as name, CAST(null as string) as conceptType)] as therapies,
    --         STRUCT(
    --           ARRAY_AGG(drug)[SAFE_OFFSET(0)] as name,
    --           'Drug' as conceptType
    --         ) as therapy
    --       FROM `%s.gks_scv` scv
    --       CROSS JOIN UNNEST(scv.drugTherapy) as drug
    --       GROUP BY
    --         scv.id
    --       HAVING COUNT(*) = 1
    --     )
    --     SELECT 
    --       scv.id,
    --       scv.evidence_line_target_proposition.type as type,
    --       '4/proposition/subjectVariation' as subjectVariation,  
    --       scv.evidence_line_target_proposition.pred as predicate,
    --       IF(
    --         scv.clinical_impact_assertion_type IS DISTINCT FROM 'therapeutic',
    --         scs.condition,
    --         null
    --       ) as objectCondition_single,
    --       IF(
    --         scv.clinical_impact_assertion_type IS DISTINCT FROM 'therapeutic',
    --         scs.conditionSet, 
    --         null
    --       ) as objectCondition_compound,
    --       IF(
    --         ARRAY_LENGTH(sd.therapies) > 1, 
    --         STRUCT(sd.therapies, 'AND' as membershipOperator), 
    --         null
    --       ) as objectTherapy_compound,
    --       sd.therapy as objectTherapy_single,
    --       IF(
    --         scv.clinical_impact_assertion_type IS NOT DISTINCT FROM 'therapeutic',
    --         scs.condition,
    --         null
    --       ) as conditionQualifier_single,
    --       IF(
    --         scv.clinical_impact_assertion_type IS NOT DISTINCT FROM 'therapeutic',
    --         scs.conditionSet,
    --         null
    --       ) as conditionQualifier_compound,
    --       (SELECT AS STRUCT sgq.* EXCEPT(scv_id)) as geneContextQualifier,
    --       (SELECT AS STRUCT smq.* EXCEPT(scv_id)) as modeOfInheritanceQualifier,
    --       (SELECT AS STRUCT spq.* EXCEPT(scv_id)) as penetranceQualifier
    --     FROM `%s.gks_scv` scv
    --     LEFT JOIN _SESSION.temp_gene_context_qualifiers sgq
    --     ON
    --       sgq.scv_id = scv.id
    --     LEFT JOIN _SESSION.temp_moi_qualifiers smq
    --     ON
    --       smq.scv_id = scv.id
    --     LEFT JOIN _SESSION.temp_penetrance_qualifiers spq
    --     ON
    --       spq.scv_id = scv.id
    --     LEFT JOIN `%s.gks_scv_condition_sets` scs
    --     ON
    --       scs.scv_id = scv.id
    --     LEFT JOIN scv_drugs sd
    --     ON
    --       sd.scv_id = scv.id
    --     WHERE
    --       scv.evidence_line_target_proposition IS NOT NULL
    -- """, 
    -- rec.schema_name, 
    -- rec.schema_name, 
    -- rec.schema_name, 
    -- rec.schema_name,
    -- rec.schema_name
    -- );

    -- DROP TABLE _SESSION.temp_gene_context_qualifiers;
    -- DROP TABLE _SESSION.temp_moi_qualifiers;
    -- DROP TABLE _SESSION.temp_penetrance_qualifiers;

  END FOR;
END;

