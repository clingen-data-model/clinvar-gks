CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_rcv_statement_proc`(on_date DATE, debug BOOL)
BEGIN
  DECLARE query_condition_data STRING;
  DECLARE query_grouping_base STRING;
  DECLARE query_grouping_tier STRING;
  DECLARE query_agg_contribution STRING;
  DECLARE query_grouping_base_pre STRING;
  DECLARE query_grouping_tier_pre STRING;
  DECLARE query_agg_contribution_pre STRING;
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
        'temp_rcv_grouping_base_statements', 'temp_rcv_grouping_tier_statements',
        'temp_rcv_agg_contribution_statements',
        'temp_rcv_grouping_base_pre', 'temp_rcv_grouping_tier_pre',
        'temp_rcv_agg_contribution_pre'
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
        IF(scs.condition IS NOT NULL,
          TO_JSON(STRUCT(
            scs.condition.id,
            scs.condition.name,
            scs.condition.conceptType,
            scs.condition.primaryCoding,
            scs.condition.mappings
          )),
          TO_JSON(STRUCT(
            'ConceptSet' AS type,
            scs.conditionSet.id,
            ARRAY(
              SELECT AS STRUCT c.id, c.name, c.conceptType, c.primaryCoding, c.mappings
              FROM UNNEST(scs.conditionSet.conditions) c
            ) AS conditions,
            scs.conditionSet.membershipOperator
          ))
        ) AS condition_concept
      FROM rcv_scv_link rsl
      JOIN `{S}.gks_scv_condition_sets` scs ON scs.scv_id = rsl.scv_id
      WHERE rsl.rn = 1
    """, '{S}', rec.schema_name);
    SET query_condition_data = REPLACE(query_condition_data, '{CT}', temp_create);
    SET query_condition_data = REPLACE(query_condition_data, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_condition_data;

    -------------------------------------------------------------------------
    -- GROUPING LAYER: BASE GROUPING
    -------------------------------------------------------------------------
    SET query_grouping_base = REPLACE("""
      {CT} `{P}.temp_rcv_grouping_base_statements` AS
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

        IF(ARRAY_LENGTH(agg.full_scv_ids) = 1,
          agg.scv_strength_name,
          CASE
            WHEN agg.actual_agg_classif_label IN ('Pathogenic', 'Benign') THEN 'definitive'
            WHEN agg.actual_agg_classif_label IN ('Likely pathogenic', 'Likely benign') THEN 'likely'
            ELSE CAST(NULL AS STRING)
          END
        ) AS strength,

        sl.label AS confidence,

        -- classification: single MappableConcept for all submission levels
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
          cpt.gks_type AS type,
          agg.prop_id AS id,
          FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
          cpt.gks_predicate AS predicate,
          rcd.condition_concept AS objectCondition
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

      FROM `{S}.gks_rcv_grouping_base_agg` agg
      LEFT JOIN `{P}.temp_rcv_condition_data` rcd ON rcd.rcv_accession = agg.rcv_accession
      LEFT JOIN `clinvar_ingest.submission_level` sl ON agg.submission_level = sl.code
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
    """, '{S}', rec.schema_name);
    SET query_grouping_base = REPLACE(query_grouping_base, '{CT}', temp_create);
    SET query_grouping_base = REPLACE(query_grouping_base, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_grouping_base;


    -------------------------------------------------------------------------
    -- GROUPING LAYER: TIER GROUPING (Somatic only)
    -------------------------------------------------------------------------
    SET query_grouping_tier = REPLACE("""
      {CT} `{P}.temp_rcv_grouping_tier_statements` AS
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
          ) AS extension
        ) AS classification_mappableConcept,

        STRUCT(
          cpt.gks_type AS type,
          agg.prop_id AS id,
          FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
          cpt.gks_predicate AS predicate,
          rcd.condition_concept AS objectCondition
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

      FROM `{S}.gks_rcv_grouping_tier_agg` agg
      LEFT JOIN `{P}.temp_rcv_condition_data` rcd ON rcd.rcv_accession = agg.rcv_accession
      LEFT JOIN `clinvar_ingest.submission_level` sl ON agg.submission_level = sl.code
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
    """, '{S}', rec.schema_name);
    SET query_grouping_tier = REPLACE(query_grouping_tier, '{CT}', temp_create);
    SET query_grouping_tier = REPLACE(query_grouping_tier, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_grouping_tier;

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
          ) AS extension
        ) AS classification_mappableConcept,

        STRUCT(
          cpt.gks_type AS type,
          agg.prop_id AS id,
          FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
          cpt.gks_predicate AS predicate,
          rcd.condition_concept AS objectCondition
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

      FROM `{S}.gks_rcv_aggregate_contribution` agg
      LEFT JOIN `{P}.temp_rcv_condition_data` rcd ON rcd.rcv_accession = agg.rcv_accession
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
    """, '{S}', rec.schema_name);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{CT}', temp_create);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_agg_contribution;

    -------------------------------------------------------------------------
    -- GROUPING BASE PRE: Base Grouping statements with inlined SCV evidence items
    -- All submission levels (PG, EP, CP, NOCP, NOCL, FLAG) use the same flow.
    -------------------------------------------------------------------------
    SET query_grouping_base_pre = REPLACE("""
      {CT} `{P}.temp_rcv_grouping_base_pre` AS
      SELECT
        l1.id, l1.type, l1.direction, l1.strength, l1.confidence,
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
      FROM `{P}.temp_rcv_grouping_base_statements` l1
      JOIN `{S}.gks_rcv_grouping_base_agg` agg ON l1.id = agg.id
    """, '{S}', rec.schema_name);
    SET query_grouping_base_pre = REPLACE(query_grouping_base_pre, '{CT}', temp_create);
    SET query_grouping_base_pre = REPLACE(query_grouping_base_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_grouping_base_pre;

    -------------------------------------------------------------------------
    -- GROUPING TIER PRE: Tier Grouping statements with inlined Base Grouping evidence items
    -------------------------------------------------------------------------
    SET query_grouping_tier_pre = REPLACE("""
      {CT} `{P}.temp_rcv_grouping_tier_pre` AS
      WITH
      l2_contributing AS (
        SELECT l2.id, ARRAY_AGG(TO_JSON(
          STRUCT(l1.type, l1.id, l1.direction, l1.strength, l1.confidence,
            l1.classification_mappableConcept,
            l1.proposition, l1.extensions, l1.evidenceLines)
        )) AS evidenceItems
        FROM `{P}.temp_rcv_grouping_tier_statements` l2
        CROSS JOIN UNNEST(l2.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        JOIN `{P}.temp_rcv_grouping_base_pre` l1 ON l1.id = JSON_VALUE(item, '$.id')
        WHERE el.strengthOfEvidenceProvided = 'contributing'
        GROUP BY l2.id
      ),
      l2_non_contributing AS (
        SELECT l2.id, ARRAY_AGG(TO_JSON(
          STRUCT(l1.type, l1.id, l1.direction, l1.strength, l1.confidence,
            l1.classification_mappableConcept,
            l1.proposition, l1.extensions, l1.evidenceLines)
        )) AS evidenceItems
        FROM `{P}.temp_rcv_grouping_tier_statements` l2
        CROSS JOIN UNNEST(l2.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        JOIN `{P}.temp_rcv_grouping_base_pre` l1 ON l1.id = JSON_VALUE(item, '$.id')
        WHERE el.strengthOfEvidenceProvided = 'non-contributing'
        GROUP BY l2.id
      )
      SELECT
        l2.id, l2.type, l2.direction, l2.strength, l2.confidence,
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
      FROM `{P}.temp_rcv_grouping_tier_statements` l2
      LEFT JOIN l2_contributing c ON l2.id = c.id
      LEFT JOIN l2_non_contributing nc ON l2.id = nc.id
    """, '{S}', rec.schema_name);
    SET query_grouping_tier_pre = REPLACE(query_grouping_tier_pre, '{CT}', temp_create);
    SET query_grouping_tier_pre = REPLACE(query_grouping_tier_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_grouping_tier_pre;

    -------------------------------------------------------------------------
    -- AGGREGATE CONTRIBUTION PRE: Aggregate Contribution statements with inlined Tier Grouping/Base Grouping evidence items
    -------------------------------------------------------------------------
    SET query_agg_contribution_pre = REPLACE("""
      {CT} `{P}.temp_rcv_agg_contribution_pre` AS
      WITH
      l3_contributing AS (
        SELECT l3.id, ARRAY_AGG(TO_JSON(
          COALESCE(
            (SELECT AS STRUCT l2p.type, l2p.id, l2p.direction, l2p.strength, l2p.confidence,
              l2p.classification_mappableConcept,
              l2p.proposition, l2p.extensions, l2p.evidenceLines
             FROM `{P}.temp_rcv_grouping_tier_pre` l2p WHERE l2p.id = JSON_VALUE(item, '$.id')),
            (SELECT AS STRUCT l1.type, l1.id, l1.direction, l1.strength, l1.confidence,
              l1.classification_mappableConcept,
              l1.proposition, l1.extensions, l1.evidenceLines
             FROM `{P}.temp_rcv_grouping_base_pre` l1 WHERE l1.id = JSON_VALUE(item, '$.id'))
          )
        )) AS evidenceItems
        FROM `{P}.temp_rcv_agg_contribution_statements` l3
        CROSS JOIN UNNEST(l3.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        WHERE el.strengthOfEvidenceProvided = 'contributing'
        GROUP BY l3.id
      ),
      l3_non_contributing AS (
        SELECT l3.id, ARRAY_AGG(TO_JSON(
          COALESCE(
            (SELECT AS STRUCT l2p.type, l2p.id, l2p.direction, l2p.strength, l2p.confidence,
              l2p.classification_mappableConcept,
              l2p.proposition, l2p.extensions, l2p.evidenceLines
             FROM `{P}.temp_rcv_grouping_tier_pre` l2p WHERE l2p.id = JSON_VALUE(item, '$.id')),
            (SELECT AS STRUCT l1.type, l1.id, l1.direction, l1.strength, l1.confidence,
              l1.classification_mappableConcept,
              l1.proposition, l1.extensions, l1.evidenceLines
             FROM `{P}.temp_rcv_grouping_base_pre` l1 WHERE l1.id = JSON_VALUE(item, '$.id'))
          )
        )) AS evidenceItems
        FROM `{P}.temp_rcv_agg_contribution_statements` l3
        CROSS JOIN UNNEST(l3.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        WHERE el.strengthOfEvidenceProvided = 'non-contributing'
        GROUP BY l3.id
      )
      SELECT
        l3.id, l3.type, l3.direction, l3.strength, l3.confidence,
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
      FROM `{P}.temp_rcv_agg_contribution_statements` l3
      LEFT JOIN l3_contributing c ON l3.id = c.id
      LEFT JOIN l3_non_contributing nc ON l3.id = nc.id
    """, '{S}', rec.schema_name);
    SET query_agg_contribution_pre = REPLACE(query_agg_contribution_pre, '{CT}', temp_create);
    SET query_agg_contribution_pre = REPLACE(query_agg_contribution_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_agg_contribution_pre;

    -------------------------------------------------------------------------
    -- FINAL: RCV statement pre (all Aggregate Contribution statements)
    -------------------------------------------------------------------------
    SET query_rcv_pre = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_rcv_statement_pre` AS
      SELECT * FROM `{P}.temp_rcv_agg_contribution_pre`
    """, '{S}', rec.schema_name);
    SET query_rcv_pre = REPLACE(query_rcv_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_rcv_pre;

    -- Drop temp tables when not in debug mode
    IF NOT debug THEN
      DROP TABLE _SESSION.temp_rcv_condition_data;
      DROP TABLE _SESSION.temp_rcv_grouping_base_statements;
      DROP TABLE _SESSION.temp_rcv_grouping_tier_statements;
      DROP TABLE _SESSION.temp_rcv_agg_contribution_statements;
      DROP TABLE _SESSION.temp_rcv_grouping_base_pre;
      DROP TABLE _SESSION.temp_rcv_grouping_tier_pre;
      DROP TABLE _SESSION.temp_rcv_agg_contribution_pre;
    END IF;

  END FOR;
END;
