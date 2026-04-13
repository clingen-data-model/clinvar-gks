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
    -- All submission levels use classification_mappableConcept (no PGEP
    -- per-SCV expansion).
    -------------------------------------------------------------------------
    SET query_layer1 = REPLACE("""
      {CT} `{P}.temp_vcv_layer1_statements` AS
      SELECT
        agg.id,

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
        ) AS classification_mappableConcept,

        STRUCT(
          'VariantAggregateClassificationProposition' AS type,
          agg.prop_id AS id,
          FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
          'hasAggregateClassification' AS predicate,

          STRUCT('Classification' AS conceptType, agg.actual_agg_classif_label AS name) AS objectClassification,

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

        IF(
          agg.aggregate_review_status IS NOT NULL,
          [STRUCT('clinvarReviewStatus' AS name, agg.aggregate_review_status AS value)],
          CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
        ) AS extensions,

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
    -- LAYER 2: TIER AGGREGATOR (Somatic only)
    -------------------------------------------------------------------------
    SET query_layer2 = REPLACE("""
      {CT} `{P}.temp_vcv_layer2_statements` AS
      SELECT
        agg.id,

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
        ) AS classification_mappableConcept,

        STRUCT(
          'VariantAggregateClassificationProposition' AS type,
          agg.prop_id AS id,
          FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
          'hasAggregateClassification' AS predicate,

          STRUCT('Classification' AS conceptType, agg.agg_label AS name) AS objectClassification,

          [
            STRUCT('AssertionGroup' AS name, CAST(csc.label AS STRING) AS value),
            STRUCT('PropositionType' AS name, CAST(cpt.label AS STRING) AS value),
            STRUCT('SubmissionLevel' AS name, CAST(sl.label AS STRING) AS value)
          ] AS aggregateQualifiers
        ) AS proposition,

        IF(
          agg.aggregate_review_status IS NOT NULL,
          [STRUCT('clinvarReviewStatus' AS name, agg.aggregate_review_status AS value)],
          CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
        ) AS extensions,

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
        ) AS classification_mappableConcept,

        STRUCT(
          'VariantAggregateClassificationProposition' AS type,
          agg.prop_id AS id,
          FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
          'hasAggregateClassification' AS predicate,

          STRUCT('Classification' AS conceptType, agg.agg_label AS name) AS objectClassification,

          [
            STRUCT('AssertionGroup' AS name, CAST(csc.label AS STRING) AS value),
            STRUCT('PropositionType' AS name, CAST(cpt.label AS STRING) AS value)
          ] AS aggregateQualifiers
        ) AS proposition,

        IF(
          agg.aggregate_review_status IS NOT NULL,
          [STRUCT('clinvarReviewStatus' AS name, agg.aggregate_review_status AS value)],
          CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
        ) AS extensions,

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
    -- LAYER 4: FINAL GROUP AGGREGATOR (Germline only)
    -------------------------------------------------------------------------
    SET query_layer4 = REPLACE("""
      {CT} `{P}.temp_vcv_layer4_statements` AS
      SELECT
        agg.id,

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
        ) AS classification_mappableConcept,

        STRUCT(
          'VariantAggregateClassificationProposition' AS type,
          agg.prop_id AS id,
          FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
          'hasAggregateClassification' AS predicate,

          STRUCT('Classification' AS conceptType, agg.agg_label AS name) AS objectClassification,

          [
            STRUCT('AssertionGroup' AS name, CAST(csc.label AS STRING) AS value)
          ] AS aggregateQualifiers
        ) AS proposition,

        IF(
          agg.aggregate_review_status IS NOT NULL,
          [STRUCT('clinvarReviewStatus' AS name, agg.aggregate_review_status AS value)],
          CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
        ) AS extensions,

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
    -- LAYER 1 PRE: L1 statements with inlined SCV evidence references
    -- No PGEP per-SCV expansion -- pass classification through unchanged.
    -------------------------------------------------------------------------
    SET query_l1_pre = REPLACE("""
      {CT} `{P}.temp_vcv_layer1_pre` AS
      SELECT
        l1.id, l1.type, l1.direction, l1.strength,
        l1.classification_mappableConcept,
        l1.proposition,
        l1.extensions,
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
          STRUCT(l1.type, l1.id, l1.direction, l1.strength,
            l1.classification_mappableConcept,
            l1.proposition, l1.extensions, l1.evidenceLines)
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
          STRUCT(l1.type, l1.id, l1.direction, l1.strength,
            l1.classification_mappableConcept,
            l1.proposition, l1.extensions, l1.evidenceLines)
        )) AS evidenceItems
        FROM `{P}.temp_vcv_layer2_statements` l2
        CROSS JOIN UNNEST(l2.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        JOIN `{P}.temp_vcv_layer1_pre` l1 ON l1.id = JSON_VALUE(item, '$.id')
        WHERE el.strengthOfEvidenceProvided = 'non-contributing'
        GROUP BY l2.id
      )
      SELECT
        l2.id, l2.type, l2.direction, l2.strength,
        l2.classification_mappableConcept,
        l2.proposition,
        l2.extensions,
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
            (SELECT AS STRUCT l2p.type, l2p.id, l2p.direction, l2p.strength,
              l2p.classification_mappableConcept,
              l2p.proposition, l2p.extensions, l2p.evidenceLines
             FROM `{P}.temp_vcv_layer2_pre` l2p WHERE l2p.id = JSON_VALUE(item, '$.id')),
            (SELECT AS STRUCT l1.type, l1.id, l1.direction, l1.strength,
              l1.classification_mappableConcept,
              l1.proposition, l1.extensions, l1.evidenceLines
             FROM `{P}.temp_vcv_layer1_pre` l1 WHERE l1.id = JSON_VALUE(item, '$.id'))
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
            (SELECT AS STRUCT l2p.type, l2p.id, l2p.direction, l2p.strength,
              l2p.classification_mappableConcept,
              l2p.proposition, l2p.extensions, l2p.evidenceLines
             FROM `{P}.temp_vcv_layer2_pre` l2p WHERE l2p.id = JSON_VALUE(item, '$.id')),
            (SELECT AS STRUCT l1.type, l1.id, l1.direction, l1.strength,
              l1.classification_mappableConcept,
              l1.proposition, l1.extensions, l1.evidenceLines
             FROM `{P}.temp_vcv_layer1_pre` l1 WHERE l1.id = JSON_VALUE(item, '$.id'))
          )
        )) AS evidenceItems
        FROM `{P}.temp_vcv_layer3_statements` l3
        CROSS JOIN UNNEST(l3.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        WHERE el.strengthOfEvidenceProvided = 'non-contributing'
        GROUP BY l3.id
      )
      SELECT
        l3.id, l3.type, l3.direction, l3.strength,
        l3.classification_mappableConcept,
        l3.proposition,
        l3.extensions,
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
          (SELECT AS STRUCT l3p.type, l3p.id, l3p.direction, l3p.strength,
            l3p.classification_mappableConcept,
            l3p.proposition, l3p.extensions, l3p.evidenceLines
           FROM `{P}.temp_vcv_layer3_pre` l3p WHERE l3p.id = JSON_VALUE(item, '$.id'))
        )) AS evidenceItems
        FROM `{P}.temp_vcv_layer4_statements` l4
        CROSS JOIN UNNEST(l4.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        WHERE el.strengthOfEvidenceProvided = 'contributing'
        GROUP BY l4.id
      ),
      l4_non_contributing AS (
        SELECT l4.id, ARRAY_AGG(TO_JSON(
          (SELECT AS STRUCT l3p.type, l3p.id, l3p.direction, l3p.strength,
            l3p.classification_mappableConcept,
            l3p.proposition, l3p.extensions, l3p.evidenceLines
           FROM `{P}.temp_vcv_layer3_pre` l3p WHERE l3p.id = JSON_VALUE(item, '$.id'))
        )) AS evidenceItems
        FROM `{P}.temp_vcv_layer4_statements` l4
        CROSS JOIN UNNEST(l4.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        WHERE el.strengthOfEvidenceProvided = 'non-contributing'
        GROUP BY l4.id
      )
      SELECT
        l4.id, l4.type, l4.direction, l4.strength,
        l4.classification_mappableConcept,
        l4.proposition,
        l4.extensions,
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
