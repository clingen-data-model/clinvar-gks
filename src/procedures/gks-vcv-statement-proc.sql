CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_vcv_statement_proc`(on_date DATE, debug BOOL)
BEGIN
  DECLARE query_classification STRING;
  DECLARE query_priority STRING;
  DECLARE query_agg_contribution STRING;
  DECLARE query_classification_pre STRING;
  DECLARE query_priority_pre STRING;
  DECLARE query_agg_contribution_pre STRING;
  DECLARE dict_vcv_proposition_query STRING;
  DECLARE query_vcv_pre STRING;
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
        'temp_vcv_classification_statements', 'temp_vcv_priority_statements',
        'temp_vcv_agg_contribution_statements',
        'temp_vcv_classification_pre', 'temp_vcv_priority_pre',
        'temp_vcv_agg_contribution_pre'
      ]);
    END IF;

    -------------------------------------------------------------------------
    -- GROUPING LAYER: CLASSIFICATION GROUPING
    -- All submission levels use classification (no PGEP
    -- per-SCV expansion).
    -------------------------------------------------------------------------
    SET query_classification = REPLACE("""
      {CT} `{P}.temp_vcv_classification_statements` AS
      SELECT
        agg.id,

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

        IF(ARRAY_LENGTH(agg.full_scv_ids) = 1,
          agg.scv_strength_name,
          CASE
            WHEN agg.actual_agg_classif_label IN ('Pathogenic', 'Benign') THEN 'definitive'
            WHEN agg.actual_agg_classif_label IN ('Likely pathogenic', 'Likely benign') THEN 'likely'
            ELSE CAST(NULL AS STRING)
          END
        ) AS strength,

        sl.label AS confidence,

        STRUCT(
          'Classification' AS conceptType,
          agg.actual_agg_classif_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extensions
        ) AS classification,

        FORMAT('#/proposition/%s', agg.prop_id) AS proposition,

        IF(
          agg.aggregate_review_status IS NOT NULL,
          [STRUCT('clinvarReviewStatus' AS name, agg.aggregate_review_status AS value)],
          CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
        ) AS extensionss,

        [
          STRUCT(
            'EvidenceLine' AS type,
            'supports' AS directionOfEvidenceProvided,
            'contributing' AS strengthOfEvidenceProvided,
            ARRAY(
              SELECT FORMAT('#/scv/clinvar.submission:%s', scv_id)
              FROM UNNEST(agg.full_scv_ids) AS scv_id
            ) AS evidenceItems
          )
        ] AS evidenceLines

      FROM `{S}.gks_vcv_classification_agg` agg
      LEFT JOIN `clinvar_ingest.submission_level` sl ON agg.submission_level = sl.code
    """, '{S}', rec.schema_name);
    SET query_classification = REPLACE(query_classification, '{CT}', temp_create);
    SET query_classification = REPLACE(query_classification, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_classification;


    -------------------------------------------------------------------------
    -- GROUPING LAYER: PRIORITY GROUPING (Somatic only)
    -------------------------------------------------------------------------
    SET query_priority = REPLACE("""
      {CT} `{P}.temp_vcv_priority_statements` AS
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

        CASE
          WHEN agg.agg_label IN ('Pathogenic', 'Benign') THEN 'definitive'
          WHEN agg.agg_label IN ('Likely pathogenic', 'Likely benign') THEN 'likely'
          ELSE CAST(NULL AS STRING)
        END AS strength,

        sl.label AS confidence,

        STRUCT(
          'Classification' AS conceptType,
          agg.agg_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extensions
        ) AS classification,

        FORMAT('#/proposition/%s', agg.prop_id) AS proposition,

        IF(
          agg.aggregate_review_status IS NOT NULL,
          [STRUCT('clinvarReviewStatus' AS name, agg.aggregate_review_status AS value)],
          CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
        ) AS extensionss,

        ARRAY(
          SELECT AS STRUCT val.* FROM UNNEST([
            STRUCT(
              'EvidenceLine' AS type,
              'supports' AS directionOfEvidenceProvided,
              'contributing' AS strengthOfEvidenceProvided,
              ARRAY(
                SELECT FORMAT('#/vcv/%s', stmt_id)
                FROM UNNEST(agg.contributing_statement_ids) AS stmt_id
              ) AS evidenceItems
            ),
            STRUCT(
              'EvidenceLine' AS type,
              'neutral' AS directionOfEvidenceProvided,
              'non-contributing' AS strengthOfEvidenceProvided,
              ARRAY(
                SELECT FORMAT('#/vcv/%s', stmt_id)
                FROM UNNEST(agg.non_contributing_statement_ids) AS stmt_id
              ) AS evidenceItems
            )
          ]) AS val
          WHERE val.strengthOfEvidenceProvided = 'contributing'
             OR ARRAY_LENGTH(val.evidenceItems) > 0
        ) AS evidenceLines

      FROM `{S}.gks_vcv_priority_agg` agg
      LEFT JOIN `clinvar_ingest.submission_level` sl ON agg.submission_level = sl.code
    """, '{S}', rec.schema_name);
    SET query_priority = REPLACE(query_priority, '{CT}', temp_create);
    SET query_priority = REPLACE(query_priority, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_priority;

    -------------------------------------------------------------------------
    -- AGGREGATE CONTRIBUTION LAYER
    -------------------------------------------------------------------------
    SET query_agg_contribution = REPLACE("""
      {CT} `{P}.temp_vcv_agg_contribution_statements` AS
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

        CASE
          WHEN agg.agg_label IN ('Pathogenic', 'Benign') THEN 'definitive'
          WHEN agg.agg_label IN ('Likely pathogenic', 'Likely benign') THEN 'likely'
          ELSE CAST(NULL AS STRING)
        END AS strength,

        agg.contributing_submission_level_label AS confidence,

        STRUCT(
          'Classification' AS conceptType,
          agg.agg_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extensions
        ) AS classification,

        FORMAT('#/proposition/%s', agg.prop_id) AS proposition,

        IF(
          agg.aggregate_review_status IS NOT NULL,
          [STRUCT('clinvarReviewStatus' AS name, agg.aggregate_review_status AS value)],
          CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
        ) AS extensionss,

        ARRAY(
          SELECT AS STRUCT val.* FROM UNNEST([
            STRUCT(
              'EvidenceLine' AS type,
              'supports' AS directionOfEvidenceProvided,
              'contributing' AS strengthOfEvidenceProvided,
              [FORMAT('#/vcv/%s', agg.contributing_layer_id)] AS evidenceItems
            ),
            STRUCT(
              'EvidenceLine' AS type,
              'neutral' AS directionOfEvidenceProvided,
              'non-contributing' AS strengthOfEvidenceProvided,
              ARRAY(
                SELECT FORMAT('#/vcv/%s', nc.layer_id)
                FROM UNNEST(agg.non_contributing_details) AS nc
              ) AS evidenceItems
            )
          ]) AS val
          WHERE val.strengthOfEvidenceProvided = 'contributing'
             OR ARRAY_LENGTH(val.evidenceItems) > 0
        ) AS evidenceLines

      FROM `{S}.gks_vcv_aggregate_contribution` agg
    """, '{S}', rec.schema_name);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{CT}', temp_create);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_agg_contribution;

    -------------------------------------------------------------------------
    -- GROUPING BASE PRE: Classification statements with inlined SCV evidence references
    -- No PGEP per-SCV expansion -- pass classification through unchanged.
    -------------------------------------------------------------------------
    SET query_classification_pre = REPLACE("""
      {CT} `{P}.temp_vcv_classification_pre` AS
      SELECT
        l1.id, l1.type, l1.direction, l1.strength, l1.confidence,
        l1.classification,
        l1.proposition,
        l1.extensions,
        [
          STRUCT(
            'EvidenceLine' AS type,
            'supports' AS directionOfEvidenceProvided,
            'contributing' AS strengthOfEvidenceProvided,
            ARRAY(
              SELECT FORMAT('#/scv/clinvar.submission:%s', scv_id)
              FROM UNNEST(agg.full_scv_ids) AS scv_id
            ) AS evidenceItems
          )
        ] AS evidenceLines
      FROM `{P}.temp_vcv_classification_statements` l1
      JOIN `{S}.gks_vcv_classification_agg` agg ON l1.id = agg.id
    """, '{S}', rec.schema_name);
    SET query_classification_pre = REPLACE(query_classification_pre, '{CT}', temp_create);
    SET query_classification_pre = REPLACE(query_classification_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_classification_pre;

    -------------------------------------------------------------------------
    -- GROUPING TIER PRE: Priority statements with inlined Classification evidence items
    -------------------------------------------------------------------------
    SET query_priority_pre = REPLACE("""
      {CT} `{P}.temp_vcv_priority_pre` AS
      WITH
      l2_contributing AS (
        SELECT l2.id, ARRAY_AGG(TO_JSON(
          STRUCT(l1.type, l1.id, l1.direction, l1.strength, l1.confidence,
            l1.classification,
            l1.proposition, l1.extensions, l1.evidenceLines)
        )) AS evidenceItems
        FROM `{P}.temp_vcv_priority_statements` l2
        CROSS JOIN UNNEST(l2.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        JOIN `{P}.temp_vcv_classification_pre` l1 ON l1.id = REGEXP_EXTRACT(item, r'#/vcv/(.+)')
        WHERE el.strengthOfEvidenceProvided = 'contributing'
        GROUP BY l2.id
      ),
      l2_non_contributing AS (
        SELECT l2.id, ARRAY_AGG(TO_JSON(
          STRUCT(l1.type, l1.id, l1.direction, l1.strength, l1.confidence,
            l1.classification,
            l1.proposition, l1.extensions, l1.evidenceLines)
        )) AS evidenceItems
        FROM `{P}.temp_vcv_priority_statements` l2
        CROSS JOIN UNNEST(l2.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        JOIN `{P}.temp_vcv_classification_pre` l1 ON l1.id = REGEXP_EXTRACT(item, r'#/vcv/(.+)')
        WHERE el.strengthOfEvidenceProvided = 'non-contributing'
        GROUP BY l2.id
      )
      SELECT
        l2.id, l2.type, l2.direction, l2.strength, l2.confidence,
        l2.classification,
        l2.proposition,
        l2.extensions,
        ARRAY_CONCAT(
          IF(c.evidenceItems IS NOT NULL,
            [STRUCT('EvidenceLine' AS type, 'supports' AS directionOfEvidenceProvided, 'contributing' AS strengthOfEvidenceProvided, c.evidenceItems AS evidenceItems)],
            CAST([] AS ARRAY<STRUCT<type STRING, directionOfEvidenceProvided STRING, strengthOfEvidenceProvided STRING, evidenceItems ARRAY<JSON>>>)
          ),
          IF(nc.evidenceItems IS NOT NULL,
            [STRUCT('EvidenceLine' AS type, 'neutral' AS directionOfEvidenceProvided, 'non-contributing' AS strengthOfEvidenceProvided, nc.evidenceItems AS evidenceItems)],
            CAST([] AS ARRAY<STRUCT<type STRING, directionOfEvidenceProvided STRING, strengthOfEvidenceProvided STRING, evidenceItems ARRAY<JSON>>>)
          )
        ) AS evidenceLines
      FROM `{P}.temp_vcv_priority_statements` l2
      LEFT JOIN l2_contributing c ON l2.id = c.id
      LEFT JOIN l2_non_contributing nc ON l2.id = nc.id
    """, '{S}', rec.schema_name);
    SET query_priority_pre = REPLACE(query_priority_pre, '{CT}', temp_create);
    SET query_priority_pre = REPLACE(query_priority_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_priority_pre;

    -------------------------------------------------------------------------
    -- AGGREGATE CONTRIBUTION PRE: Agg Contribution statements with inlined Priority/Base evidence items
    -------------------------------------------------------------------------
    SET query_agg_contribution_pre = REPLACE("""
      {CT} `{P}.temp_vcv_agg_contribution_pre` AS
      WITH
      all_layer_statements AS (
        SELECT id, type, direction, strength, confidence,
          classification, proposition, extensions, TO_JSON(evidenceLines) as evidenceLines
        FROM `{P}.temp_vcv_priority_pre`
        UNION ALL
        SELECT id, type, direction, strength, confidence,
          classification, proposition, extensions, TO_JSON(evidenceLines) as evidenceLines
        FROM `{P}.temp_vcv_classification_pre`
      ),
      l3_contributing AS (
        SELECT l3.id, ARRAY_AGG(TO_JSON(
          STRUCT(als.type, als.id, als.direction, als.strength, als.confidence,
            als.classification,
            als.proposition, als.extensions, als.evidenceLines)
        )) AS evidenceItems
        FROM `{P}.temp_vcv_agg_contribution_statements` l3
        CROSS JOIN UNNEST(l3.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        JOIN all_layer_statements als ON als.id = REGEXP_EXTRACT(item, r'#/vcv/(.+)')
        WHERE el.strengthOfEvidenceProvided = 'contributing'
        GROUP BY l3.id
      ),
      l3_non_contributing AS (
        SELECT l3.id, ARRAY_AGG(TO_JSON(
          STRUCT(als.type, als.id, als.direction, als.strength, als.confidence,
            als.classification,
            als.proposition, als.extensions, als.evidenceLines)
        )) AS evidenceItems
        FROM `{P}.temp_vcv_agg_contribution_statements` l3
        CROSS JOIN UNNEST(l3.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        JOIN all_layer_statements als ON als.id = REGEXP_EXTRACT(item, r'#/vcv/(.+)')
        WHERE el.strengthOfEvidenceProvided = 'non-contributing'
        GROUP BY l3.id
      )
      SELECT
        l3.id, l3.type, l3.direction, l3.strength, l3.confidence,
        l3.classification,
        l3.proposition,
        l3.extensions,
        ARRAY_CONCAT(
          IF(c.evidenceItems IS NOT NULL,
            [STRUCT('EvidenceLine' AS type, 'supports' AS directionOfEvidenceProvided, 'contributing' AS strengthOfEvidenceProvided, c.evidenceItems AS evidenceItems)],
            CAST([] AS ARRAY<STRUCT<type STRING, directionOfEvidenceProvided STRING, strengthOfEvidenceProvided STRING, evidenceItems ARRAY<JSON>>>)
          ),
          IF(nc.evidenceItems IS NOT NULL,
            [STRUCT('EvidenceLine' AS type, 'neutral' AS directionOfEvidenceProvided, 'non-contributing' AS strengthOfEvidenceProvided, nc.evidenceItems AS evidenceItems)],
            CAST([] AS ARRAY<STRUCT<type STRING, directionOfEvidenceProvided STRING, strengthOfEvidenceProvided STRING, evidenceItems ARRAY<JSON>>>)
          )
        ) AS evidenceLines
      FROM `{P}.temp_vcv_agg_contribution_statements` l3
      LEFT JOIN l3_contributing c ON l3.id = c.id
      LEFT JOIN l3_non_contributing nc ON l3.id = nc.id
    """, '{S}', rec.schema_name);
    SET query_agg_contribution_pre = REPLACE(query_agg_contribution_pre, '{CT}', temp_create);
    SET query_agg_contribution_pre = REPLACE(query_agg_contribution_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_agg_contribution_pre;

    -------------------------------------------------------------------------
    -- Dictionary table - VCV propositions (global, keyed by proposition id)
    -- Collects propositions from all 3 layers (classification, priority, agg)
    -------------------------------------------------------------------------
    SET dict_vcv_proposition_query = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_dict_vcv_proposition`
      AS
      SELECT
        agg.prop_id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          cpt.gks_type AS type,
          agg.prop_id AS id,
          FORMAT('#/variation/clinvar:%s', agg.variation_id) AS subjectVariant,
          CASE cpt.gks_type
            WHEN 'VariantPathogenicityProposition' THEN 'isCausalFor'
            WHEN 'VariantOncogenicityProposition' THEN 'isOncogenicFor'
            WHEN 'VariantClinicalSignificanceProposition' THEN 'isClinicallySignificantFor'
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
          agg.unique_conditions AS objectCondition
        )), remove_empty => TRUE) as value
      FROM `{S}.gks_vcv_classification_agg` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      UNION ALL
      SELECT
        agg.prop_id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          cpt.gks_type AS type,
          agg.prop_id AS id,
          FORMAT('#/variation/clinvar:%s', agg.variation_id) AS subjectVariant,
          CASE cpt.gks_type
            WHEN 'VariantPathogenicityProposition' THEN 'isCausalFor'
            WHEN 'VariantOncogenicityProposition' THEN 'isOncogenicFor'
            WHEN 'VariantClinicalSignificanceProposition' THEN 'isClinicallySignificantFor'
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
          agg.unique_conditions AS objectCondition
        )), remove_empty => TRUE) as value
      FROM `{S}.gks_vcv_priority_agg` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      UNION ALL
      SELECT
        agg.prop_id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          cpt.gks_type AS type,
          agg.prop_id AS id,
          FORMAT('#/variation/clinvar:%s', agg.variation_id) AS subjectVariant,
          CASE cpt.gks_type
            WHEN 'VariantPathogenicityProposition' THEN 'isCausalFor'
            WHEN 'VariantOncogenicityProposition' THEN 'isOncogenicFor'
            WHEN 'VariantClinicalSignificanceProposition' THEN 'isClinicallySignificantFor'
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
          agg.unique_conditions AS objectCondition
        )), remove_empty => TRUE) as value
      FROM `{S}.gks_vcv_aggregate_contribution` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
    """, '{S}', rec.schema_name);
    SET dict_vcv_proposition_query = REPLACE(dict_vcv_proposition_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE dict_vcv_proposition_query;

    -------------------------------------------------------------------------
    -- FINAL: VCV statement pre (all Aggregate Contribution statements)
    -------------------------------------------------------------------------
    SET query_vcv_pre = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_vcv_statement_pre` AS
      SELECT * FROM `{P}.temp_vcv_agg_contribution_pre`
    """, '{S}', rec.schema_name);
    SET query_vcv_pre = REPLACE(query_vcv_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_vcv_pre;

    -- Drop temp tables when not in debug mode
    IF NOT debug THEN
      DROP TABLE _SESSION.temp_vcv_classification_statements;
      DROP TABLE _SESSION.temp_vcv_priority_statements;
      DROP TABLE _SESSION.temp_vcv_agg_contribution_statements;
      DROP TABLE _SESSION.temp_vcv_classification_pre;
      DROP TABLE _SESSION.temp_vcv_priority_pre;
      DROP TABLE _SESSION.temp_vcv_agg_contribution_pre;
    END IF;

  END FOR;
END;
