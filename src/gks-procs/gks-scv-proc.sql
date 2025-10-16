CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_scv_proc`(start_with DATE)
BEGIN
  FOR rec IN (select s.schema_name FROM clinvar_ingest.schema_on(start_with) as s)
  DO
    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_scv`
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
            FORMAT('clinvar.submitter:%%s',scv.submitter_id) as id,
            'Agent' as type,
            scv.submitter_name as name,
          ) as submitter

        FROM `%s.clinical_assertion` ca
        JOIN `%s.scv_summary` scv
        ON
          scv.id = ca.id 
        LEFT JOIN `clinvar_ingest.clinvar_clinsig_types` cct 
          ON 
            cct.code = scv.classif_type
            AND
            cct.statement_type = scv.statement_type
    """, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name
    );
  END FOR;

END;