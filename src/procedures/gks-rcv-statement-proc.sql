CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_rcv_statement_proc`(on_date DATE, debug BOOL)
BEGIN
  DECLARE query_condition_data STRING;
  DECLARE query_classification STRING;
  DECLARE query_priority STRING;
  DECLARE query_agg_contribution STRING;
  DECLARE dict_rcv_evidence_line_query STRING;
  DECLARE dict_rcv_proposition_query STRING;
  DECLARE query_rcv_pre STRING;
  DECLARE temp_create STRING;

  IF debug THEN
    SET temp_create = 'CREATE OR REPLACE TABLE';
  ELSE
    SET temp_create = 'CREATE TEMP TABLE';
  END IF;

  FOR rec IN (SELECT s.schema_name FROM `clinvar_ingest.schema_on`(on_date) AS s)
  DO

    -- Clean up any persistent temp tables from a prior debug run
    IF NOT debug THEN
      CALL `clinvar_ingest.cleanup_temp_tables`(rec.schema_name, [
        'temp_rcv_condition_data',
        'temp_rcv_classification_statements', 'temp_rcv_priority_statements',
        'temp_rcv_agg_contribution_statements'
      ]);
    END IF;

    -------------------------------------------------------------------------
    -- CONDITION DATA: Resolve condition concept per RCV via rcv_mapping
    -- Picks one representative SCV per RCV; produces a single JSON value
    -- representing either the SCV's condition (MappableConcept) or
    -- conditionSet (ConceptSet of conditions). Extensions are excluded.
    -------------------------------------------------------------------------
    SET query_condition_data = REPLACE("""
      {CT} `{P}.temp_rcv_condition_data` AS
      WITH rcv_scv_link AS (
        SELECT
          rm.rcv_accession,
          scv_id,
          ROW_NUMBER() OVER (PARTITION BY rm.rcv_accession ORDER BY scv_id) AS rn
        FROM `{S}.rcv_mapping` rm
        CROSS JOIN UNNEST(rm.scv_accessions) AS scv_id
      )
      SELECT
        rsl.rcv_accession,
        COALESCE(
          scs.extensions.value_submitted_condition.condition,
          scs.extensions.value_submitted_condition.conditionSet,
          scs.extensions.value_submitted_condition_set.condition,
          scs.extensions.value_submitted_condition_set.conditionSet
        ) AS condition_concept
      FROM rcv_scv_link rsl
      JOIN `{S}.gks_scv_condition_sets` scs ON scs.scv_id = rsl.scv_id
      WHERE rsl.rn = 1
    """, '{S}', rec.schema_name);
    SET query_condition_data = REPLACE(query_condition_data, '{CT}', temp_create);
    SET query_condition_data = REPLACE(query_condition_data, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_condition_data;

    -------------------------------------------------------------------------
    -- GROUPING LAYER: CLASSIFICATION GROUPING
    -------------------------------------------------------------------------
    SET query_classification = REPLACE("""
      {CT} `{P}.temp_rcv_classification_statements` AS
      SELECT
        agg.id,

        -- Flattened GKS Payload
        'Statement' AS type,

        IF(ARRAY_LENGTH(agg.full_scv_ids) = 1,
          agg.scv_direction,
          CASE
            WHEN agg.actual_agg_classif_label IN ('Pathogenic', 'Likely pathogenic', 'Pathogenic/Likely pathogenic') THEN 'supports'
            WHEN agg.actual_agg_classif_label IN ('Benign', 'Likely benign', 'Benign/Likely benign') THEN 'disputes'
            WHEN agg.actual_agg_classif_label = 'Uncertain significance' THEN 'neutral'
            WHEN agg.actual_agg_classif_label LIKE 'Conflicting%%' THEN 'neutral'
            ELSE 'supports'
          END
        ) AS direction,

        STRUCT(
          'MappableConcept' AS type, 'Strength' AS conceptType,
          IF(ARRAY_LENGTH(agg.full_scv_ids) = 1,
            agg.scv_strength_name,
            CASE
              WHEN agg.actual_agg_classif_label IN ('Pathogenic', 'Benign', 'Oncogenic') THEN 'Definitive'
              WHEN agg.actual_agg_classif_label IN ('Likely pathogenic', 'Likely benign', 'Likely Oncogenic') THEN 'Likely'
              WHEN agg.actual_agg_classif_label LIKE 'Tier I%' THEN 'Strong'
              WHEN agg.actual_agg_classif_label LIKE 'Tier II%' THEN 'Potential'
              WHEN agg.actual_agg_classif_label LIKE 'Tier IV%' THEN 'Likely'
              ELSE CAST(NULL AS STRING)
            END
          ) AS name
        ) AS strength,

        STRUCT('MappableConcept' AS type, 'Confidence' AS conceptType, sl.label AS name) AS confidence,

        -- classification: single MappableConcept for all submission levels
        STRUCT(
          'MappableConcept' AS type, 'Classification' AS conceptType,
          agg.actual_agg_classif_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extensions
        ) AS classification,

        FORMAT('#/%s-proposition/%s',
          CASE
            WHEN cpt.gks_type LIKE 'Clinvar%' THEN 'varcustom'
            WHEN cpt.gks_type = 'VariantOncogenicityProposition' THEN 'vartumor'
            WHEN cpt.gks_type = 'VariantTherapeuticResponseProposition' THEN 'vartherapy'
            WHEN cpt.gks_type IN ('VariantPathogenicityProposition','VariantClinicalSignificanceProposition',
                                  'VariantDiagnosticProposition','VariantPrognosticProposition') THEN 'varcond'
            ELSE ERROR(FORMAT('unmapped proposition type for delivery grouping: %t', cpt.gks_type))
          END,
          agg.prop_id) AS proposition,

        IF(
          agg.aggregate_review_status IS NOT NULL,
          [STRUCT('clinvarReviewStatus' AS name, agg.aggregate_review_status AS value)],
          CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
        ) AS extensions,

        [FORMAT('#/evidenceLine/%s.contributing', agg.id)] AS hasEvidenceLines

      FROM `{S}.gks_rcv_classification_agg` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      LEFT JOIN `clinvar_ingest.submission_level` sl ON agg.submission_level = sl.code
    """, '{S}', rec.schema_name);
    SET query_classification = REPLACE(query_classification, '{CT}', temp_create);
    SET query_classification = REPLACE(query_classification, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_classification;


    -------------------------------------------------------------------------
    -- GROUPING LAYER: PRIORITY GROUPING (Somatic only)
    -------------------------------------------------------------------------
    SET query_priority = REPLACE("""
      {CT} `{P}.temp_rcv_priority_statements` AS
      SELECT
        agg.id,

        'Statement' AS type,

        CASE
          WHEN agg.agg_label IN ('Pathogenic', 'Likely pathogenic', 'Pathogenic/Likely pathogenic') THEN 'supports'
          WHEN agg.agg_label IN ('Benign', 'Likely benign', 'Benign/Likely benign') THEN 'disputes'
          WHEN agg.agg_label = 'Uncertain significance' THEN 'neutral'
          WHEN agg.agg_label LIKE 'Conflicting%%' THEN 'neutral'
          ELSE 'supports'
        END AS direction,

        STRUCT(
          'MappableConcept' AS type, 'Strength' AS conceptType,
          CASE
            WHEN agg.agg_label IN ('Pathogenic', 'Benign', 'Oncogenic') THEN 'Definitive'
            WHEN agg.agg_label IN ('Likely pathogenic', 'Likely benign', 'Likely Oncogenic') THEN 'Likely'
            WHEN agg.agg_label LIKE 'Tier I%' THEN 'Strong'
            WHEN agg.agg_label LIKE 'Tier II%' THEN 'Potential'
            WHEN agg.agg_label LIKE 'Tier IV%' THEN 'Likely'
            ELSE CAST(NULL AS STRING)
          END AS name
        ) AS strength,

        STRUCT('MappableConcept' AS type, 'Confidence' AS conceptType, sl.label AS name) AS confidence,

        STRUCT(
          'MappableConcept' AS type, 'Classification' AS conceptType,
          agg.agg_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extensions
        ) AS classification,

        FORMAT('#/%s-proposition/%s',
          CASE
            WHEN cpt.gks_type LIKE 'Clinvar%' THEN 'varcustom'
            WHEN cpt.gks_type = 'VariantOncogenicityProposition' THEN 'vartumor'
            WHEN cpt.gks_type = 'VariantTherapeuticResponseProposition' THEN 'vartherapy'
            WHEN cpt.gks_type IN ('VariantPathogenicityProposition','VariantClinicalSignificanceProposition',
                                  'VariantDiagnosticProposition','VariantPrognosticProposition') THEN 'varcond'
            ELSE ERROR(FORMAT('unmapped proposition type for delivery grouping: %t', cpt.gks_type))
          END,
          agg.prop_id) AS proposition,

        IF(
          agg.aggregate_review_status IS NOT NULL,
          [STRUCT('clinvarReviewStatus' AS name, agg.aggregate_review_status AS value)],
          CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
        ) AS extensions,

        ARRAY_CONCAT(
          [FORMAT('#/evidenceLine/%s.contributing', agg.id)],
          IF(ARRAY_LENGTH(agg.non_contributing_statement_ids) > 0,
            [FORMAT('#/evidenceLine/%s.non-contributing', agg.id)],
            []
          )
        ) AS hasEvidenceLines

      FROM `{S}.gks_rcv_priority_agg` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      LEFT JOIN `clinvar_ingest.submission_level` sl ON agg.submission_level = sl.code
    """, '{S}', rec.schema_name);
    SET query_priority = REPLACE(query_priority, '{CT}', temp_create);
    SET query_priority = REPLACE(query_priority, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_priority;

    -------------------------------------------------------------------------
    -- AGGREGATE CONTRIBUTION LAYER
    -------------------------------------------------------------------------
    SET query_agg_contribution = REPLACE("""
      {CT} `{P}.temp_rcv_agg_contribution_statements` AS
      SELECT
        agg.id,

        'Statement' AS type,

        CASE
          WHEN agg.agg_label IN ('Pathogenic', 'Likely pathogenic', 'Pathogenic/Likely pathogenic') THEN 'supports'
          WHEN agg.agg_label IN ('Benign', 'Likely benign', 'Benign/Likely benign') THEN 'disputes'
          WHEN agg.agg_label = 'Uncertain significance' THEN 'neutral'
          WHEN agg.agg_label LIKE 'Conflicting%%' THEN 'neutral'
          ELSE 'supports'
        END AS direction,

        STRUCT(
          'MappableConcept' AS type, 'Strength' AS conceptType,
          CASE
            WHEN agg.agg_label IN ('Pathogenic', 'Benign', 'Oncogenic') THEN 'Definitive'
            WHEN agg.agg_label IN ('Likely pathogenic', 'Likely benign', 'Likely Oncogenic') THEN 'Likely'
            WHEN agg.agg_label LIKE 'Tier I%' THEN 'Strong'
            WHEN agg.agg_label LIKE 'Tier II%' THEN 'Potential'
            WHEN agg.agg_label LIKE 'Tier IV%' THEN 'Likely'
            ELSE CAST(NULL AS STRING)
          END AS name
        ) AS strength,

        STRUCT('MappableConcept' AS type, 'Confidence' AS conceptType, agg.contributing_submission_level_label AS name) AS confidence,

        STRUCT(
          'MappableConcept' AS type, 'Classification' AS conceptType,
          agg.agg_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extensions
        ) AS classification,

        FORMAT('#/%s-proposition/%s',
          CASE
            WHEN cpt.gks_type LIKE 'Clinvar%' THEN 'varcustom'
            WHEN cpt.gks_type = 'VariantOncogenicityProposition' THEN 'vartumor'
            WHEN cpt.gks_type = 'VariantTherapeuticResponseProposition' THEN 'vartherapy'
            WHEN cpt.gks_type IN ('VariantPathogenicityProposition','VariantClinicalSignificanceProposition',
                                  'VariantDiagnosticProposition','VariantPrognosticProposition') THEN 'varcond'
            ELSE ERROR(FORMAT('unmapped proposition type for delivery grouping: %t', cpt.gks_type))
          END,
          agg.prop_id) AS proposition,

        IF(
          agg.aggregate_review_status IS NOT NULL,
          [STRUCT('clinvarReviewStatus' AS name, agg.aggregate_review_status AS value)],
          CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
        ) AS extensions,

        ARRAY_CONCAT(
          [FORMAT('#/evidenceLine/%s.contributing', agg.id)],
          IF(agg.non_contributing_details IS NOT NULL AND ARRAY_LENGTH(agg.non_contributing_details) > 0,
            [FORMAT('#/evidenceLine/%s.non-contributing', agg.id)],
            []
          )
        ) AS hasEvidenceLines

      FROM `{S}.gks_rcv_aggregate_contribution` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
    """, '{S}', rec.schema_name);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{CT}', temp_create);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_agg_contribution;

    -------------------------------------------------------------------------
    -- Dictionary table - RCV evidence lines
    -- Extracts evidence lines from all 3 statement layers into flat rows.
    -- Classification: 1 Contributing evidence line per statement (SCV items)
    -- Priority/Aggregate: Contributing + optional Non-contributing (RCV items)
    -------------------------------------------------------------------------
    SET dict_rcv_evidence_line_query = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_dict_rcv_evidence_line`
      AS
      -- Classification layer: always 1 Contributing evidence line
      SELECT
        FORMAT('%s.contributing', agg.id) AS id,
        'EvidenceLine' AS type,
        'supports' AS directionOfEvidenceProvided,
        STRUCT('MappableConcept' AS type, 'Strength' AS conceptType, 'Contributing' AS name) AS strengthOfEvidenceProvided,
        ARRAY(
          SELECT FORMAT('#/scv/clinvar.submission:%s', scv_id)
          FROM UNNEST(agg.full_scv_ids) AS scv_id
        ) AS evidenceItems
      FROM `{S}.gks_rcv_classification_agg` agg

      UNION ALL

      -- Priority layer: Contributing evidence line
      SELECT
        FORMAT('%s.contributing', agg.id) AS id,
        'EvidenceLine' AS type,
        'supports' AS directionOfEvidenceProvided,
        STRUCT('MappableConcept' AS type, 'Strength' AS conceptType, 'Contributing' AS name) AS strengthOfEvidenceProvided,
        ARRAY(
          SELECT FORMAT('#/rcv/%s', stmt_id)
          FROM UNNEST(agg.contributing_statement_ids) AS stmt_id
        ) AS evidenceItems
      FROM `{S}.gks_rcv_priority_agg` agg

      UNION ALL

      -- Priority layer: Non-contributing evidence line (only when items exist)
      SELECT
        FORMAT('%s.non-contributing', agg.id) AS id,
        'EvidenceLine' AS type,
        'neutral' AS directionOfEvidenceProvided,
        STRUCT('MappableConcept' AS type, 'Strength' AS conceptType, 'Non-contributing' AS name) AS strengthOfEvidenceProvided,
        ARRAY(
          SELECT FORMAT('#/rcv/%s', stmt_id)
          FROM UNNEST(agg.non_contributing_statement_ids) AS stmt_id
        ) AS evidenceItems
      FROM `{S}.gks_rcv_priority_agg` agg
      WHERE ARRAY_LENGTH(agg.non_contributing_statement_ids) > 0

      UNION ALL

      -- Aggregate layer: Contributing evidence line
      SELECT
        FORMAT('%s.contributing', agg.id) AS id,
        'EvidenceLine' AS type,
        'supports' AS directionOfEvidenceProvided,
        STRUCT('MappableConcept' AS type, 'Strength' AS conceptType, 'Contributing' AS name) AS strengthOfEvidenceProvided,
        [FORMAT('#/rcv/%s', agg.contributing_layer_id)] AS evidenceItems
      FROM `{S}.gks_rcv_aggregate_contribution` agg

      UNION ALL

      -- Aggregate layer: Non-contributing evidence line (only when items exist)
      SELECT
        FORMAT('%s.non-contributing', agg.id) AS id,
        'EvidenceLine' AS type,
        'neutral' AS directionOfEvidenceProvided,
        STRUCT('MappableConcept' AS type, 'Strength' AS conceptType, 'Non-contributing' AS name) AS strengthOfEvidenceProvided,
        ARRAY(
          SELECT FORMAT('#/rcv/%s', nc.layer_id)
          FROM UNNEST(agg.non_contributing_details) AS nc
        ) AS evidenceItems
      FROM `{S}.gks_rcv_aggregate_contribution` agg
      WHERE agg.non_contributing_details IS NOT NULL AND ARRAY_LENGTH(agg.non_contributing_details) > 0
    """, '{S}', rec.schema_name);
    EXECUTE IMMEDIATE dict_rcv_evidence_line_query;

    -------------------------------------------------------------------------
    -- Dictionary table - RCV propositions (global, keyed by proposition id)
    -- Collects propositions from all 3 layers (classification, priority, agg)
    -------------------------------------------------------------------------
    SET dict_rcv_proposition_query = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_dict_rcv_proposition`
      AS
      SELECT
        agg.prop_id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          -- custom types collapse to CustomProposition + customPropositionType; standard keep their specific type
          IF(cpt.gks_type LIKE 'Clinvar%', 'CustomProposition', cpt.gks_type) AS type,
          IF(cpt.gks_type LIKE 'Clinvar%', cpt.gks_type, CAST(NULL AS STRING)) AS customPropositionType,
          agg.prop_id AS id,
          -- standard uses subjectVariant; custom uses subject (same variation pointer)
          IF(cpt.gks_type LIKE 'Clinvar%', CAST(NULL AS STRING), FORMAT('#/variation/clinvar:%s', agg.variation_id)) AS subjectVariant,
          IF(cpt.gks_type LIKE 'Clinvar%', FORMAT('#/variation/clinvar:%s', agg.variation_id), CAST(NULL AS STRING)) AS subject,
          CASE cpt.gks_type
            WHEN 'VariantPathogenicityProposition' THEN 'isCausalFor'
            WHEN 'VariantOncogenicityProposition' THEN 'isOncogenicFor'
            WHEN 'VariantClinicalSignificanceProposition' THEN 'hasClinicalSignificanceFor'
            WHEN 'ClinvarAffectsProposition' THEN 'hasAffectFor'
            WHEN 'ClinvarAssociationProposition' THEN 'isAssociatedWith'
            WHEN 'ClinvarConfersSensitivityProposition' THEN 'confersSensitivityFor'
            WHEN 'ClinvarConflictingDataFromSubmitterProposition' THEN 'isConflictingDataFromSubmittersFor'
            WHEN 'ClinvarDrugResponseProposition' THEN 'hasDrugResponseFor'
            WHEN 'ClinvarNotProvidedProposition' THEN 'hasNoProvidedClassificationFor'
            WHEN 'ClinvarOtherProposition' THEN 'isClinvarOtherAssociationFor'
            WHEN 'ClinvarProtectiveProposition' THEN 'isProtectiveFor'
            WHEN 'ClinvarRiskFactorProposition' THEN 'isRiskFactorFor'
            ELSE 'isClinvarUndefinedAssociationFor'
          END AS predicate,
          -- object field is 3-way: custom->object, standard Oncogenicity->objectTumorType, other standard->objectCondition (same value)
          IF(cpt.gks_type LIKE 'Clinvar%' OR cpt.gks_type = 'VariantOncogenicityProposition', CAST(NULL AS STRING), rcd.condition_concept) AS objectCondition,
          IF((NOT (cpt.gks_type LIKE 'Clinvar%')) AND cpt.gks_type = 'VariantOncogenicityProposition', rcd.condition_concept, CAST(NULL AS STRING)) AS objectTumorType,
          IF(cpt.gks_type LIKE 'Clinvar%', rcd.condition_concept, CAST(NULL AS STRING)) AS object
        )), remove_empty => TRUE) as value
      FROM `{S}.gks_rcv_classification_agg` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      LEFT JOIN {P}.temp_rcv_condition_data rcd ON rcd.rcv_accession = agg.rcv_accession
      UNION ALL
      SELECT
        agg.prop_id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          -- custom types collapse to CustomProposition + customPropositionType; standard keep their specific type
          IF(cpt.gks_type LIKE 'Clinvar%', 'CustomProposition', cpt.gks_type) AS type,
          IF(cpt.gks_type LIKE 'Clinvar%', cpt.gks_type, CAST(NULL AS STRING)) AS customPropositionType,
          agg.prop_id AS id,
          -- standard uses subjectVariant; custom uses subject (same variation pointer)
          IF(cpt.gks_type LIKE 'Clinvar%', CAST(NULL AS STRING), FORMAT('#/variation/clinvar:%s', agg.variation_id)) AS subjectVariant,
          IF(cpt.gks_type LIKE 'Clinvar%', FORMAT('#/variation/clinvar:%s', agg.variation_id), CAST(NULL AS STRING)) AS subject,
          CASE cpt.gks_type
            WHEN 'VariantPathogenicityProposition' THEN 'isCausalFor'
            WHEN 'VariantOncogenicityProposition' THEN 'isOncogenicFor'
            WHEN 'VariantClinicalSignificanceProposition' THEN 'hasClinicalSignificanceFor'
            WHEN 'ClinvarAffectsProposition' THEN 'hasAffectFor'
            WHEN 'ClinvarAssociationProposition' THEN 'isAssociatedWith'
            WHEN 'ClinvarConfersSensitivityProposition' THEN 'confersSensitivityFor'
            WHEN 'ClinvarConflictingDataFromSubmitterProposition' THEN 'isConflictingDataFromSubmittersFor'
            WHEN 'ClinvarDrugResponseProposition' THEN 'hasDrugResponseFor'
            WHEN 'ClinvarNotProvidedProposition' THEN 'hasNoProvidedClassificationFor'
            WHEN 'ClinvarOtherProposition' THEN 'isClinvarOtherAssociationFor'
            WHEN 'ClinvarProtectiveProposition' THEN 'isProtectiveFor'
            WHEN 'ClinvarRiskFactorProposition' THEN 'isRiskFactorFor'
            ELSE 'isClinvarUndefinedAssociationFor'
          END AS predicate,
          -- object field is 3-way: custom->object, standard Oncogenicity->objectTumorType, other standard->objectCondition (same value)
          IF(cpt.gks_type LIKE 'Clinvar%' OR cpt.gks_type = 'VariantOncogenicityProposition', CAST(NULL AS STRING), rcd.condition_concept) AS objectCondition,
          IF((NOT (cpt.gks_type LIKE 'Clinvar%')) AND cpt.gks_type = 'VariantOncogenicityProposition', rcd.condition_concept, CAST(NULL AS STRING)) AS objectTumorType,
          IF(cpt.gks_type LIKE 'Clinvar%', rcd.condition_concept, CAST(NULL AS STRING)) AS object
        )), remove_empty => TRUE) as value
      FROM `{S}.gks_rcv_priority_agg` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      LEFT JOIN {P}.temp_rcv_condition_data rcd ON rcd.rcv_accession = agg.rcv_accession
      UNION ALL
      SELECT
        agg.prop_id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          -- custom types collapse to CustomProposition + customPropositionType; standard keep their specific type
          IF(cpt.gks_type LIKE 'Clinvar%', 'CustomProposition', cpt.gks_type) AS type,
          IF(cpt.gks_type LIKE 'Clinvar%', cpt.gks_type, CAST(NULL AS STRING)) AS customPropositionType,
          agg.prop_id AS id,
          -- standard uses subjectVariant; custom uses subject (same variation pointer)
          IF(cpt.gks_type LIKE 'Clinvar%', CAST(NULL AS STRING), FORMAT('#/variation/clinvar:%s', agg.variation_id)) AS subjectVariant,
          IF(cpt.gks_type LIKE 'Clinvar%', FORMAT('#/variation/clinvar:%s', agg.variation_id), CAST(NULL AS STRING)) AS subject,
          CASE cpt.gks_type
            WHEN 'VariantPathogenicityProposition' THEN 'isCausalFor'
            WHEN 'VariantOncogenicityProposition' THEN 'isOncogenicFor'
            WHEN 'VariantClinicalSignificanceProposition' THEN 'hasClinicalSignificanceFor'
            WHEN 'ClinvarAffectsProposition' THEN 'hasAffectFor'
            WHEN 'ClinvarAssociationProposition' THEN 'isAssociatedWith'
            WHEN 'ClinvarConfersSensitivityProposition' THEN 'confersSensitivityFor'
            WHEN 'ClinvarConflictingDataFromSubmitterProposition' THEN 'isConflictingDataFromSubmittersFor'
            WHEN 'ClinvarDrugResponseProposition' THEN 'hasDrugResponseFor'
            WHEN 'ClinvarNotProvidedProposition' THEN 'hasNoProvidedClassificationFor'
            WHEN 'ClinvarOtherProposition' THEN 'isClinvarOtherAssociationFor'
            WHEN 'ClinvarProtectiveProposition' THEN 'isProtectiveFor'
            WHEN 'ClinvarRiskFactorProposition' THEN 'isRiskFactorFor'
            ELSE 'isClinvarUndefinedAssociationFor'
          END AS predicate,
          -- object field is 3-way: custom->object, standard Oncogenicity->objectTumorType, other standard->objectCondition (same value)
          IF(cpt.gks_type LIKE 'Clinvar%' OR cpt.gks_type = 'VariantOncogenicityProposition', CAST(NULL AS STRING), rcd.condition_concept) AS objectCondition,
          IF((NOT (cpt.gks_type LIKE 'Clinvar%')) AND cpt.gks_type = 'VariantOncogenicityProposition', rcd.condition_concept, CAST(NULL AS STRING)) AS objectTumorType,
          IF(cpt.gks_type LIKE 'Clinvar%', rcd.condition_concept, CAST(NULL AS STRING)) AS object
        )), remove_empty => TRUE) as value
      FROM `{S}.gks_rcv_aggregate_contribution` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      LEFT JOIN {P}.temp_rcv_condition_data rcd ON rcd.rcv_accession = agg.rcv_accession
    """, '{S}', rec.schema_name);
    SET dict_rcv_proposition_query = REPLACE(dict_rcv_proposition_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE dict_rcv_proposition_query;

    -------------------------------------------------------------------------
    -- FINAL: RCV statement pre (all statement layers)
    -------------------------------------------------------------------------
    SET query_rcv_pre = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_dict_rcv` AS
      SELECT * FROM `{P}.temp_rcv_agg_contribution_statements`
      UNION ALL
      SELECT * FROM `{P}.temp_rcv_classification_statements`
      UNION ALL
      SELECT * FROM `{P}.temp_rcv_priority_statements`
    """, '{S}', rec.schema_name);
    SET query_rcv_pre = REPLACE(query_rcv_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_rcv_pre;

    -- Drop temp tables when not in debug mode
    IF NOT debug THEN
      DROP TABLE _SESSION.temp_rcv_condition_data;
      DROP TABLE _SESSION.temp_rcv_classification_statements;
      DROP TABLE _SESSION.temp_rcv_priority_statements;
      DROP TABLE _SESSION.temp_rcv_agg_contribution_statements;
    END IF;

  END FOR;
END;
