CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_vcv_statement_proc`(on_date DATE, debug BOOL)
BEGIN
  DECLARE query_layer1 STRING;
  DECLARE query_layer2 STRING;
  DECLARE query_layer3 STRING;
  DECLARE query_layer4 STRING;
  DECLARE query_l1_pre STRING;
  DECLARE query_l2_pre STRING;
  DECLARE query_l3_pre STRING;
  DECLARE query_l4_pre STRING;
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
        'temp_vcv_layer1_statements', 'temp_vcv_layer2_statements',
        'temp_vcv_layer3_statements', 'temp_vcv_layer4_statements',
        'temp_vcv_layer1_pre', 'temp_vcv_layer2_pre',
        'temp_vcv_layer3_pre', 'temp_vcv_layer4_pre'
      ]);
    END IF;

    -------------------------------------------------------------------------
    -- LAYER 1: BASE AGGREGATOR
    -------------------------------------------------------------------------
    SET query_layer1 = REPLACE("""
      {CT} `{P}.temp_vcv_layer1_statements` AS
      SELECT
        agg.id,

        -- Flattened GKS Payload
        'Statement' AS type,
        'supports' AS direction,
        'definitive' AS strength,

        STRUCT(
          'Classification' AS conceptType,
          agg.actual_agg_classif_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extension
        ) AS classification,

        STRUCT(
          'VariantAggregateClassificationProposition' AS type,
          agg.prop_id AS id,
          FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
          'hasAggregateClassification' AS predicate,

          STRUCT('Classification' AS conceptType, agg.actual_agg_classif_label AS name) AS objectClassification_mappableConcept,
          CAST(NULL AS STRUCT<type STRING, concepts ARRAY<STRUCT<conceptType STRING, name STRING>>, membershipOperator STRING>) AS objectClassification_conceptSet,

          [
            STRUCT('AssertionGroup' AS name, CAST(csc.label AS STRING) AS value),
            STRUCT('PropositionType' AS name, CAST(cpt.label AS STRING) AS value),
            STRUCT('SubmissionLevel' AS name, CAST(sl.label AS STRING) AS value)
          ] || IF(
            agg.tier_grouping IS NOT NULL,
            [STRUCT('ClassificationTier' AS name, CAST(cct.label AS STRING) AS value)],
            CAST([] AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS aggregateQualifiers
        ) AS proposition,

        [
          STRUCT(
            'EvidenceLine' AS type,
            'supports' AS directionOfEvidenceProvided,
            'contributing' AS strengthOfEvidenceProvided,
            ARRAY(
              SELECT TO_JSON(STRUCT(scv_id AS id))
              FROM UNNEST(agg.full_scv_ids) AS scv_id
            ) AS evidenceItems
          )
        ] AS evidenceLines

      FROM `{S}.gks_vcv_layer1_base_agg` agg
      LEFT JOIN `clinvar_ingest.clinvar_statement_categories` csc ON agg.statement_group = csc.code
      LEFT JOIN `clinvar_ingest.submission_level` sl ON agg.submission_level = sl.code
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      LEFT JOIN `clinvar_ingest.clinvar_clinsig_types` cct ON agg.tier_grouping = cct.code
    """, '{S}', rec.schema_name);
    SET query_layer1 = REPLACE(query_layer1, '{CT}', temp_create);
    SET query_layer1 = REPLACE(query_layer1, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_layer1;


    -------------------------------------------------------------------------
    -- LAYER 2: TIER AGGREGATOR
    -------------------------------------------------------------------------
    SET query_layer2 = REPLACE("""
      {CT} `{P}.temp_vcv_layer2_statements` AS
      SELECT
        agg.id,

        -- Flattened GKS Payload
        'Statement' AS type,
        'supports' AS direction,
        'definitive' AS strength,

        STRUCT(
          'Classification' AS conceptType,
          agg.agg_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extension
        ) AS classification,

        STRUCT(
          'VariantAggregateClassificationProposition' AS type,
          agg.prop_id AS id,
          FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
          'hasAggregateClassification' AS predicate,

          STRUCT('Classification' AS conceptType, agg.agg_label AS name) AS objectClassification_mappableConcept,
          CAST(NULL AS STRUCT<type STRING, concepts ARRAY<STRUCT<conceptType STRING, name STRING>>, membershipOperator STRING>) AS objectClassification_conceptSet,

          [
            STRUCT('AssertionGroup' AS name, CAST(csc.label AS STRING) AS value),
            STRUCT('PropositionType' AS name, CAST(cpt.label AS STRING) AS value),
            STRUCT('SubmissionLevel' AS name, CAST(sl.label AS STRING) AS value)
          ] AS aggregateQualifiers
        ) AS proposition,

        -- Dynamic Evidence Lines
        ARRAY(
          SELECT AS STRUCT val.* FROM UNNEST([
            STRUCT(
              'EvidenceLine' AS type,
              'supports' AS directionOfEvidenceProvided,
              'contributing' AS strengthOfEvidenceProvided,
              ARRAY(
                SELECT TO_JSON(STRUCT(stmt_id AS id))
                FROM UNNEST(agg.contributing_statement_ids) AS stmt_id
              ) AS evidenceItems
            ),
            STRUCT(
              'EvidenceLine' AS type,
              'supports' AS directionOfEvidenceProvided,
              'non-contributing' AS strengthOfEvidenceProvided,
              ARRAY(
                SELECT TO_JSON(STRUCT(stmt_id AS id))
                FROM UNNEST(agg.non_contributing_statement_ids) AS stmt_id
              ) AS evidenceItems
            )
          ]) AS val
          WHERE val.strengthOfEvidenceProvided = 'contributing'
             OR ARRAY_LENGTH(val.evidenceItems) > 0
        ) AS evidenceLines

      FROM `{S}.gks_vcv_layer2_tier_agg` agg
      LEFT JOIN `clinvar_ingest.clinvar_statement_categories` csc ON agg.statement_group = csc.code
      LEFT JOIN `clinvar_ingest.submission_level` sl ON agg.submission_level = sl.code
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
    """, '{S}', rec.schema_name);
    SET query_layer2 = REPLACE(query_layer2, '{CT}', temp_create);
    SET query_layer2 = REPLACE(query_layer2, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_layer2;

    -------------------------------------------------------------------------
    -- LAYER 3: SUBMISSION LEVEL AGGREGATOR
    -------------------------------------------------------------------------
    SET query_layer3 = REPLACE("""
      {CT} `{P}.temp_vcv_layer3_statements` AS
      SELECT
        agg.id,

        -- Flattened GKS Payload
        'Statement' AS type,
        'supports' AS direction,
        'definitive' AS strength,

        STRUCT(
          'Classification' AS conceptType,
          agg.agg_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extension
        ) AS classification,

        STRUCT(
          'VariantAggregateClassificationProposition' AS type,
          agg.prop_id AS id,
          FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
          'hasAggregateClassification' AS predicate,

          STRUCT('Classification' AS conceptType, agg.agg_label AS name) AS objectClassification_mappableConcept,
          CAST(NULL AS STRUCT<type STRING, concepts ARRAY<STRUCT<conceptType STRING, name STRING>>, membershipOperator STRING>) AS objectClassification_conceptSet,

          [
            STRUCT('AssertionGroup' AS name, CAST(csc.label AS STRING) AS value),
            STRUCT('PropositionType' AS name, CAST(cpt.label AS STRING) AS value)
          ] AS aggregateQualifiers
        ) AS proposition,

        -- Dynamic Evidence Lines
        ARRAY(
          SELECT AS STRUCT val.* FROM UNNEST([
            STRUCT(
              'EvidenceLine' AS type,
              'supports' AS directionOfEvidenceProvided,
              'contributing' AS strengthOfEvidenceProvided,
              [TO_JSON(STRUCT(agg.contributing_layer_id AS id))] AS evidenceItems
            ),
            STRUCT(
              'EvidenceLine' AS type,
              'supports' AS directionOfEvidenceProvided,
              'non-contributing' AS strengthOfEvidenceProvided,
              ARRAY(
                SELECT TO_JSON(STRUCT(nc.layer_id AS id))
                FROM UNNEST(agg.non_contributing_details) AS nc
              ) AS evidenceItems
            )
          ]) AS val
          WHERE val.strengthOfEvidenceProvided = 'contributing'
             OR ARRAY_LENGTH(val.evidenceItems) > 0
        ) AS evidenceLines

      FROM `{S}.gks_vcv_layer3_prop_agg` agg
      LEFT JOIN `clinvar_ingest.clinvar_statement_categories` csc ON agg.statement_group = csc.code
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
    """, '{S}', rec.schema_name);
    SET query_layer3 = REPLACE(query_layer3, '{CT}', temp_create);
    SET query_layer3 = REPLACE(query_layer3, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_layer3;

    -------------------------------------------------------------------------
    -- LAYER 4: FINAL GROUP AGGREGATOR
    -------------------------------------------------------------------------
    SET query_layer4 = REPLACE("""
      {CT} `{P}.temp_vcv_layer4_statements` AS
      SELECT
        agg.id,

        -- Flattened GKS Payload
        'Statement' AS type,
        'supports' AS direction,
        'definitive' AS strength,

        STRUCT(
          'Classification' AS conceptType,
          agg.agg_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extension
        ) AS classification,

        STRUCT(
          'VariantAggregateClassificationProposition' AS type,
          agg.prop_id AS id,
          FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
          'hasAggregateClassification' AS predicate,

          STRUCT('Classification' AS conceptType, agg.agg_label AS name) AS objectClassification_mappableConcept,
          CAST(NULL AS STRUCT<type STRING, concepts ARRAY<STRUCT<conceptType STRING, name STRING>>, membershipOperator STRING>) AS objectClassification_conceptSet,

          [
            STRUCT('AssertionGroup' AS name, CAST(csc.label AS STRING) AS value)
          ] AS aggregateQualifiers
        ) AS proposition,

        -- Dynamic Evidence Lines
        ARRAY(
          SELECT AS STRUCT val.* FROM UNNEST([
            STRUCT(
              'EvidenceLine' AS type,
              'supports' AS directionOfEvidenceProvided,
              'contributing' AS strengthOfEvidenceProvided,
              ARRAY(
                SELECT TO_JSON(STRUCT(stmt_id AS id))
                FROM UNNEST(agg.contributing_layer3_ids) AS stmt_id
              ) AS evidenceItems
            ),
            STRUCT(
              'EvidenceLine' AS type,
              'supports' AS directionOfEvidenceProvided,
              'non-contributing' AS strengthOfEvidenceProvided,
              ARRAY(
                SELECT TO_JSON(STRUCT(nc.layer_id AS id))
                FROM UNNEST(agg.non_contributing_details) AS nc
              ) AS evidenceItems
            )
          ]) AS val
          WHERE val.strengthOfEvidenceProvided = 'contributing'
             OR ARRAY_LENGTH(val.evidenceItems) > 0
        ) AS evidenceLines

      FROM `{S}.gks_vcv_layer4_group_agg` agg
      LEFT JOIN `clinvar_ingest.clinvar_statement_categories` csc ON agg.statement_group = csc.code
    """, '{S}', rec.schema_name);
    SET query_layer4 = REPLACE(query_layer4, '{CT}', temp_create);
    SET query_layer4 = REPLACE(query_layer4, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_layer4;

    -------------------------------------------------------------------------
    -- LAYER 1 PRE: L1 statements with inlined SCV evidence items
    -- For EP/PG submission levels, adds per-SCV formatted name attribute
    -------------------------------------------------------------------------
    SET query_l1_pre = REPLACE("""
      {CT} `{P}.temp_vcv_layer1_pre` AS
      WITH
      scv_conditions AS (
        SELECT scv_id, STRING_AGG(DISTINCT trait_name, ', ' ORDER BY trait_name) AS condition_name
        FROM `{S}.gks_scv_condition_mapping`
        GROUP BY scv_id
      ),
      ep_pg_scv_name AS (
        SELECT
          agg.id AS l1_id,
          ARRAY_AGG(
            CONCAT(
              'for ', COALESCE(sc.condition_name, 'unspecified condition'), '\\n',
              'Classification is based on the ', LOWER(sl.label), ' submission', '\\n',
              COALESCE(FORMAT_DATE('%b %Y', ss.last_evaluated), 'date unknown'), ' by ', ss.submitter_name
            )
            ORDER BY ss.full_scv_id
          ) AS formatted_array
        FROM `{S}.gks_vcv_layer1_base_agg` agg
        CROSS JOIN UNNEST(agg.full_scv_ids) AS full_scv_id
        JOIN `{S}.scv_summary` ss ON ss.full_scv_id = full_scv_id
        LEFT JOIN scv_conditions sc ON sc.scv_id = ss.id
        LEFT JOIN `clinvar_ingest.submission_level` sl ON sl.code = agg.submission_level
        WHERE agg.submission_level IN ('EP', 'PG')
        GROUP BY agg.id
      )
      SELECT
        l1.id, l1.type, l1.direction, l1.strength,
        STRUCT(
          l1.classification.conceptType,
          l1.classification.name,
          IF(l1.classification.extension IS NOT NULL OR ep.formatted_array IS NOT NULL,
            ARRAY(
              SELECT AS STRUCT e.name, e.value,
                CAST(NULL AS ARRAY<STRING>) AS value_array
              FROM UNNEST(IFNULL(l1.classification.extension, [])) e
            )
            || CASE
              WHEN ep.formatted_array IS NOT NULL AND ARRAY_LENGTH(ep.formatted_array) = 1
                THEN [STRUCT('explanation' AS name, ep.formatted_array[OFFSET(0)] AS value, CAST(NULL AS ARRAY<STRING>) AS value_array)]
              WHEN ep.formatted_array IS NOT NULL
                THEN [STRUCT('explanation' AS name, CAST(NULL AS STRING) AS value, ep.formatted_array AS value_array)]
              ELSE CAST([] AS ARRAY<STRUCT<name STRING, value STRING, value_array ARRAY<STRING>>>)
            END,
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING, value_array ARRAY<STRING>>>)
          ) AS extension
        ) AS classification,
        l1.proposition,
        [
          STRUCT(
            'EvidenceLine' AS type,
            'supports' AS directionOfEvidenceProvided,
            'contributing' AS strengthOfEvidenceProvided,
            ARRAY(
              SELECT TO_JSON(STRUCT(FORMAT('clinvar.submission:%s', scv_id) AS id))
              FROM UNNEST(agg.full_scv_ids) AS scv_id
            ) AS evidenceItems
          )
        ] AS evidenceLines
      FROM `{P}.temp_vcv_layer1_statements` l1
      JOIN `{S}.gks_vcv_layer1_base_agg` agg ON l1.id = agg.id
      LEFT JOIN ep_pg_scv_name ep ON ep.l1_id = l1.id
    """, '{S}', rec.schema_name);
    SET query_l1_pre = REPLACE(query_l1_pre, '{CT}', temp_create);
    SET query_l1_pre = REPLACE(query_l1_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_l1_pre;

    -------------------------------------------------------------------------
    -- LAYER 2 PRE: L2 statements with inlined L1 evidence items
    -------------------------------------------------------------------------
    SET query_l2_pre = REPLACE("""
      {CT} `{P}.temp_vcv_layer2_pre` AS
      WITH
      l2_contributing AS (
        SELECT l2.id, ARRAY_AGG(TO_JSON(
          STRUCT(l1.type, l1.id, l1.direction, l1.strength, l1.classification, l1.proposition, l1.evidenceLines)
        )) AS evidenceItems
        FROM `{P}.temp_vcv_layer2_statements` l2
        CROSS JOIN UNNEST(l2.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        JOIN `{P}.temp_vcv_layer1_pre` l1 ON l1.id = JSON_VALUE(item, '$.id')
        WHERE el.strengthOfEvidenceProvided = 'contributing'
        GROUP BY l2.id
      ),
      l2_non_contributing AS (
        SELECT l2.id, ARRAY_AGG(TO_JSON(
          STRUCT(l1.type, l1.id, l1.direction, l1.strength, l1.classification, l1.proposition, l1.evidenceLines)
        )) AS evidenceItems
        FROM `{P}.temp_vcv_layer2_statements` l2
        CROSS JOIN UNNEST(l2.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        JOIN `{P}.temp_vcv_layer1_pre` l1 ON l1.id = JSON_VALUE(item, '$.id')
        WHERE el.strengthOfEvidenceProvided = 'non-contributing'
        GROUP BY l2.id
      ),
      l2_explanations AS (
        SELECT l2.id,
          ARRAY_CONCAT_AGG(
            COALESCE(
              IF(ext.value IS NOT NULL, [ext.value], NULL),
              ext.value_array
            )
          ) AS explanation_strings
        FROM `{P}.temp_vcv_layer2_statements` l2
        CROSS JOIN UNNEST(l2.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        JOIN `{P}.temp_vcv_layer1_pre` l1 ON l1.id = JSON_VALUE(item, '$.id')
        CROSS JOIN UNNEST(l1.classification.extension) AS ext
        WHERE el.strengthOfEvidenceProvided = 'contributing'
          AND ext.name = 'explanation'
        GROUP BY l2.id
      )
      SELECT
        l2.id, l2.type, l2.direction, l2.strength,
        STRUCT(
          l2.classification.conceptType,
          l2.classification.name,
          IF(l2.classification.extension IS NOT NULL OR expl.explanation_strings IS NOT NULL,
            ARRAY(
              SELECT AS STRUCT e.name, e.value,
                CAST(NULL AS ARRAY<STRING>) AS value_array
              FROM UNNEST(IFNULL(l2.classification.extension, [])) e
            )
            || CASE
              WHEN expl.explanation_strings IS NOT NULL AND ARRAY_LENGTH(expl.explanation_strings) = 1
                THEN [STRUCT('explanation' AS name, expl.explanation_strings[OFFSET(0)] AS value, CAST(NULL AS ARRAY<STRING>) AS value_array)]
              WHEN expl.explanation_strings IS NOT NULL
                THEN [STRUCT('explanation' AS name, CAST(NULL AS STRING) AS value, expl.explanation_strings AS value_array)]
              ELSE CAST([] AS ARRAY<STRUCT<name STRING, value STRING, value_array ARRAY<STRING>>>)
            END,
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING, value_array ARRAY<STRING>>>)
          ) AS extension
        ) AS classification,
        l2.proposition,
        ARRAY_CONCAT(
          IF(c.evidenceItems IS NOT NULL,
            [STRUCT('EvidenceLine' AS type, 'supports' AS directionOfEvidenceProvided, 'contributing' AS strengthOfEvidenceProvided, c.evidenceItems AS evidenceItems)],
            CAST([] AS ARRAY<STRUCT<type STRING, directionOfEvidenceProvided STRING, strengthOfEvidenceProvided STRING, evidenceItems ARRAY<JSON>>>)
          ),
          IF(nc.evidenceItems IS NOT NULL,
            [STRUCT('EvidenceLine' AS type, 'supports' AS directionOfEvidenceProvided, 'non-contributing' AS strengthOfEvidenceProvided, nc.evidenceItems AS evidenceItems)],
            CAST([] AS ARRAY<STRUCT<type STRING, directionOfEvidenceProvided STRING, strengthOfEvidenceProvided STRING, evidenceItems ARRAY<JSON>>>)
          )
        ) AS evidenceLines
      FROM `{P}.temp_vcv_layer2_statements` l2
      LEFT JOIN l2_contributing c ON l2.id = c.id
      LEFT JOIN l2_non_contributing nc ON l2.id = nc.id
      LEFT JOIN l2_explanations expl ON l2.id = expl.id
    """, '{S}', rec.schema_name);
    SET query_l2_pre = REPLACE(query_l2_pre, '{CT}', temp_create);
    SET query_l2_pre = REPLACE(query_l2_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_l2_pre;

    -------------------------------------------------------------------------
    -- LAYER 3 PRE: L3 statements with inlined L2/L1 evidence items
    -------------------------------------------------------------------------
    SET query_l3_pre = REPLACE("""
      {CT} `{P}.temp_vcv_layer3_pre` AS
      WITH
      l3_contributing AS (
        SELECT l3.id, ARRAY_AGG(TO_JSON(
          COALESCE(
            (SELECT AS STRUCT l2p.type, l2p.id, l2p.direction, l2p.strength, l2p.classification, l2p.proposition, l2p.evidenceLines FROM `{P}.temp_vcv_layer2_pre` l2p WHERE l2p.id = JSON_VALUE(item, '$.id')),
            (SELECT AS STRUCT l1.type, l1.id, l1.direction, l1.strength, l1.classification, l1.proposition, l1.evidenceLines FROM `{P}.temp_vcv_layer1_pre` l1 WHERE l1.id = JSON_VALUE(item, '$.id'))
          )
        )) AS evidenceItems
        FROM `{P}.temp_vcv_layer3_statements` l3
        CROSS JOIN UNNEST(l3.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        WHERE el.strengthOfEvidenceProvided = 'contributing'
        GROUP BY l3.id
      ),
      l3_non_contributing AS (
        SELECT l3.id, ARRAY_AGG(TO_JSON(
          COALESCE(
            (SELECT AS STRUCT l2p.type, l2p.id, l2p.direction, l2p.strength, l2p.classification, l2p.proposition, l2p.evidenceLines FROM `{P}.temp_vcv_layer2_pre` l2p WHERE l2p.id = JSON_VALUE(item, '$.id')),
            (SELECT AS STRUCT l1.type, l1.id, l1.direction, l1.strength, l1.classification, l1.proposition, l1.evidenceLines FROM `{P}.temp_vcv_layer1_pre` l1 WHERE l1.id = JSON_VALUE(item, '$.id'))
          )
        )) AS evidenceItems
        FROM `{P}.temp_vcv_layer3_statements` l3
        CROSS JOIN UNNEST(l3.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        WHERE el.strengthOfEvidenceProvided = 'non-contributing'
        GROUP BY l3.id
      ),
      l3_explanations AS (
        SELECT l3.id,
          ARRAY_CONCAT_AGG(
            COALESCE(
              IF(ext.value IS NOT NULL, [ext.value], NULL),
              ext.value_array
            )
          ) AS explanation_strings
        FROM `{P}.temp_vcv_layer3_statements` l3
        CROSS JOIN UNNEST(l3.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        LEFT JOIN `{P}.temp_vcv_layer2_pre` l2p ON l2p.id = JSON_VALUE(item, '$.id')
        LEFT JOIN `{P}.temp_vcv_layer1_pre` l1p ON l1p.id = JSON_VALUE(item, '$.id') AND l2p.id IS NULL
        CROSS JOIN UNNEST(COALESCE(l2p.classification.extension, l1p.classification.extension)) AS ext
        WHERE el.strengthOfEvidenceProvided = 'contributing'
          AND ext.name = 'explanation'
        GROUP BY l3.id
      )
      SELECT
        l3.id, l3.type, l3.direction, l3.strength,
        STRUCT(
          l3.classification.conceptType,
          l3.classification.name,
          IF(l3.classification.extension IS NOT NULL OR expl.explanation_strings IS NOT NULL,
            ARRAY(
              SELECT AS STRUCT e.name, e.value,
                CAST(NULL AS ARRAY<STRING>) AS value_array
              FROM UNNEST(IFNULL(l3.classification.extension, [])) e
            )
            || CASE
              WHEN expl.explanation_strings IS NOT NULL AND ARRAY_LENGTH(expl.explanation_strings) = 1
                THEN [STRUCT('explanation' AS name, expl.explanation_strings[OFFSET(0)] AS value, CAST(NULL AS ARRAY<STRING>) AS value_array)]
              WHEN expl.explanation_strings IS NOT NULL
                THEN [STRUCT('explanation' AS name, CAST(NULL AS STRING) AS value, expl.explanation_strings AS value_array)]
              ELSE CAST([] AS ARRAY<STRUCT<name STRING, value STRING, value_array ARRAY<STRING>>>)
            END,
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING, value_array ARRAY<STRING>>>)
          ) AS extension
        ) AS classification,
        l3.proposition,
        ARRAY_CONCAT(
          IF(c.evidenceItems IS NOT NULL,
            [STRUCT('EvidenceLine' AS type, 'supports' AS directionOfEvidenceProvided, 'contributing' AS strengthOfEvidenceProvided, c.evidenceItems AS evidenceItems)],
            CAST([] AS ARRAY<STRUCT<type STRING, directionOfEvidenceProvided STRING, strengthOfEvidenceProvided STRING, evidenceItems ARRAY<JSON>>>)
          ),
          IF(nc.evidenceItems IS NOT NULL,
            [STRUCT('EvidenceLine' AS type, 'supports' AS directionOfEvidenceProvided, 'non-contributing' AS strengthOfEvidenceProvided, nc.evidenceItems AS evidenceItems)],
            CAST([] AS ARRAY<STRUCT<type STRING, directionOfEvidenceProvided STRING, strengthOfEvidenceProvided STRING, evidenceItems ARRAY<JSON>>>)
          )
        ) AS evidenceLines
      FROM `{P}.temp_vcv_layer3_statements` l3
      LEFT JOIN l3_contributing c ON l3.id = c.id
      LEFT JOIN l3_non_contributing nc ON l3.id = nc.id
      LEFT JOIN l3_explanations expl ON l3.id = expl.id
    """, '{S}', rec.schema_name);
    SET query_l3_pre = REPLACE(query_l3_pre, '{CT}', temp_create);
    SET query_l3_pre = REPLACE(query_l3_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_l3_pre;

    -------------------------------------------------------------------------
    -- LAYER 4 PRE: L4 statements with inlined L3 evidence items
    -------------------------------------------------------------------------
    SET query_l4_pre = REPLACE("""
      {CT} `{P}.temp_vcv_layer4_pre` AS
      WITH
      l4_contributing AS (
        SELECT l4.id, ARRAY_AGG(TO_JSON(
          (SELECT AS STRUCT l3p.type, l3p.id, l3p.direction, l3p.strength, l3p.classification, l3p.proposition, l3p.evidenceLines FROM `{P}.temp_vcv_layer3_pre` l3p WHERE l3p.id = JSON_VALUE(item, '$.id'))
        )) AS evidenceItems
        FROM `{P}.temp_vcv_layer4_statements` l4
        CROSS JOIN UNNEST(l4.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        WHERE el.strengthOfEvidenceProvided = 'contributing'
        GROUP BY l4.id
      ),
      l4_non_contributing AS (
        SELECT l4.id, ARRAY_AGG(TO_JSON(
          (SELECT AS STRUCT l3p.type, l3p.id, l3p.direction, l3p.strength, l3p.classification, l3p.proposition, l3p.evidenceLines FROM `{P}.temp_vcv_layer3_pre` l3p WHERE l3p.id = JSON_VALUE(item, '$.id'))
        )) AS evidenceItems
        FROM `{P}.temp_vcv_layer4_statements` l4
        CROSS JOIN UNNEST(l4.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        WHERE el.strengthOfEvidenceProvided = 'non-contributing'
        GROUP BY l4.id
      ),
      l4_explanations AS (
        SELECT l4.id,
          ARRAY_CONCAT_AGG(
            COALESCE(
              IF(ext.value IS NOT NULL, [ext.value], NULL),
              ext.value_array
            )
          ) AS explanation_strings
        FROM `{P}.temp_vcv_layer4_statements` l4
        CROSS JOIN UNNEST(l4.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        JOIN `{P}.temp_vcv_layer3_pre` l3p ON l3p.id = JSON_VALUE(item, '$.id')
        CROSS JOIN UNNEST(l3p.classification.extension) AS ext
        WHERE el.strengthOfEvidenceProvided = 'contributing'
          AND ext.name = 'explanation'
        GROUP BY l4.id
      )
      SELECT
        l4.id, l4.type, l4.direction, l4.strength,
        STRUCT(
          l4.classification.conceptType,
          l4.classification.name,
          IF(l4.classification.extension IS NOT NULL OR expl.explanation_strings IS NOT NULL,
            ARRAY(
              SELECT AS STRUCT e.name, e.value,
                CAST(NULL AS ARRAY<STRING>) AS value_array
              FROM UNNEST(IFNULL(l4.classification.extension, [])) e
            )
            || CASE
              WHEN expl.explanation_strings IS NOT NULL AND ARRAY_LENGTH(expl.explanation_strings) = 1
                THEN [STRUCT('explanation' AS name, expl.explanation_strings[OFFSET(0)] AS value, CAST(NULL AS ARRAY<STRING>) AS value_array)]
              WHEN expl.explanation_strings IS NOT NULL
                THEN [STRUCT('explanation' AS name, CAST(NULL AS STRING) AS value, expl.explanation_strings AS value_array)]
              ELSE CAST([] AS ARRAY<STRUCT<name STRING, value STRING, value_array ARRAY<STRING>>>)
            END,
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING, value_array ARRAY<STRING>>>)
          ) AS extension
        ) AS classification,
        l4.proposition,
        ARRAY_CONCAT(
          IF(c.evidenceItems IS NOT NULL,
            [STRUCT('EvidenceLine' AS type, 'supports' AS directionOfEvidenceProvided, 'contributing' AS strengthOfEvidenceProvided, c.evidenceItems AS evidenceItems)],
            CAST([] AS ARRAY<STRUCT<type STRING, directionOfEvidenceProvided STRING, strengthOfEvidenceProvided STRING, evidenceItems ARRAY<JSON>>>)
          ),
          IF(nc.evidenceItems IS NOT NULL,
            [STRUCT('EvidenceLine' AS type, 'supports' AS directionOfEvidenceProvided, 'non-contributing' AS strengthOfEvidenceProvided, nc.evidenceItems AS evidenceItems)],
            CAST([] AS ARRAY<STRUCT<type STRING, directionOfEvidenceProvided STRING, strengthOfEvidenceProvided STRING, evidenceItems ARRAY<JSON>>>)
          )
        ) AS evidenceLines
      FROM `{P}.temp_vcv_layer4_statements` l4
      LEFT JOIN l4_contributing c ON l4.id = c.id
      LEFT JOIN l4_non_contributing nc ON l4.id = nc.id
      LEFT JOIN l4_explanations expl ON l4.id = expl.id
    """, '{S}', rec.schema_name);
    SET query_l4_pre = REPLACE(query_l4_pre, '{CT}', temp_create);
    SET query_l4_pre = REPLACE(query_l4_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_l4_pre;

    -------------------------------------------------------------------------
    -- FINAL: Combined VCV statement pre (germline L4 + somatic L3)
    -------------------------------------------------------------------------
    SET query_vcv_pre = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_vcv_statement_pre` AS
      SELECT * FROM `{P}.temp_vcv_layer4_pre`
      UNION ALL
      SELECT * FROM `{P}.temp_vcv_layer3_pre`
      WHERE id LIKE '%-S-%'
    """, '{S}', rec.schema_name);
    SET query_vcv_pre = REPLACE(query_vcv_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_vcv_pre;

    -- Drop temp tables when not in debug mode
    IF NOT debug THEN
      DROP TABLE _SESSION.temp_vcv_layer1_statements;
      DROP TABLE _SESSION.temp_vcv_layer2_statements;
      DROP TABLE _SESSION.temp_vcv_layer3_statements;
      DROP TABLE _SESSION.temp_vcv_layer4_statements;
      DROP TABLE _SESSION.temp_vcv_layer1_pre;
      DROP TABLE _SESSION.temp_vcv_layer2_pre;
      DROP TABLE _SESSION.temp_vcv_layer3_pre;
      DROP TABLE _SESSION.temp_vcv_layer4_pre;
    END IF;

  END FOR;
END;
