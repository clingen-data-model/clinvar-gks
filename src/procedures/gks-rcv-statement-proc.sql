CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_rcv_statement_proc`(on_date DATE, debug BOOL)
BEGIN
  DECLARE query_condition_data STRING;
  DECLARE query_layer1 STRING;
  DECLARE query_layer2 STRING;
  DECLARE query_layer3 STRING;
  DECLARE query_layer4 STRING;
  DECLARE query_l1_pre STRING;
  DECLARE query_l2_pre STRING;
  DECLARE query_l3_pre STRING;
  DECLARE query_l4_pre STRING;
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
        'temp_rcv_layer1_statements', 'temp_rcv_layer2_statements',
        'temp_rcv_layer3_statements', 'temp_rcv_layer4_statements',
        'temp_rcv_layer1_pre', 'temp_rcv_layer2_pre',
        'temp_rcv_layer3_pre', 'temp_rcv_layer4_pre'
      ]);
    END IF;

    -------------------------------------------------------------------------
    -- CONDITION DATA: Resolve condition/conditionSet per RCV via rcv_mapping
    -- Picks one representative SCV per RCV to source the condition.
    -- Carries full normalized condition structure (without extensions).
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
        -- Single condition (MappableConcept without extensions)
        IF(scs.condition IS NOT NULL,
          STRUCT(
            scs.condition.id,
            scs.condition.name,
            scs.condition.conceptType,
            scs.condition.primaryCoding,
            scs.condition.mappings
          ),
          NULL
        ) AS condition,
        -- Condition set (ConceptSet without extensions)
        IF(scs.conditionSet IS NOT NULL,
          STRUCT(
            scs.conditionSet.id AS id,
            ARRAY(
              SELECT AS STRUCT c.id, c.name, c.conceptType, c.primaryCoding, c.mappings
              FROM UNNEST(scs.conditionSet.conditions) c
            ) AS conditions,
            scs.conditionSet.membershipOperator
          ),
          NULL
        ) AS conditionSet
      FROM rcv_scv_link rsl
      JOIN `{S}.gks_scv_condition_sets` scs ON scs.scv_id = rsl.scv_id
      WHERE rsl.rn = 1
    """, '{S}', rec.schema_name);
    SET query_condition_data = REPLACE(query_condition_data, '{CT}', temp_create);
    SET query_condition_data = REPLACE(query_condition_data, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_condition_data;

    -------------------------------------------------------------------------
    -- LAYER 1: BASE AGGREGATOR
    -------------------------------------------------------------------------
    SET query_layer1 = REPLACE("""
      {CT} `{P}.temp_rcv_layer1_statements` AS
      SELECT
        agg.id,

        -- Flattened GKS Payload
        'Statement' AS type,
        'supports' AS direction,
        'definitive' AS strength,

        -- classification_mappableConcept: for non-PGEP submission levels
        IF(
          agg.submission_level != 'PGEP',
          STRUCT(
            'Classification' AS conceptType,
            agg.actual_agg_classif_label AS name,
            IF(
              agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
              [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
              CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
            ) AS extension
          ),
          NULL
        ) AS classification_mappableConcept,

        -- classification_conceptSet: populated in L1 PRE for PGEP with 1 classification
        CAST(NULL AS STRUCT<
          type STRING,
          concepts ARRAY<STRUCT<conceptType STRING, name STRING>>,
          membershipOperator STRING,
          extensions ARRAY<STRUCT<name STRING, value STRING>>
        >) AS classification_conceptSet,

        -- classification_conceptSetSet: populated in L1 PRE for PGEP with 2+ classifications
        CAST(NULL AS STRUCT<
          type STRING,
          concepts ARRAY<STRUCT<
            type STRING,
            concepts ARRAY<STRUCT<conceptType STRING, name STRING>>,
            membershipOperator STRING,
            extensions ARRAY<STRUCT<name STRING, value STRING>>
          >>,
          membershipOperator STRING
        >) AS classification_conceptSetSet,

        STRUCT(
          'VariantAggregateConditionClassificationProposition' AS type,
          agg.prop_id AS id,
          FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
          'hasConditionClassification' AS predicate,

          -- objectConditionClassification: 3 concept fields (condition, conditionSet, classification)
          -- Only condition OR conditionSet is non-null per record
          rcd.condition AS objectConditionClassification_condition,
          rcd.conditionSet AS objectConditionClassification_conditionSet,

          -- classification: for non-PGEP
          IF(agg.submission_level != 'PGEP',
            STRUCT('Classification' AS conceptType, agg.actual_agg_classif_label AS name),
            NULL
          ) AS objectConditionClassification_classification,

          -- objectConditionClassification_conceptSetSet: populated in L1 PRE for PGEP
          CAST(NULL AS STRUCT<
            type STRING,
            concepts ARRAY<STRUCT<
              type STRING,
              concepts ARRAY<STRUCT<conceptType STRING, name STRING>>,
              membershipOperator STRING
            >>,
            membershipOperator STRING
          >) AS objectConditionClassification_conceptSetSet,

          [
            STRUCT('AssertionGroup' AS name, CAST(csc.label AS STRING) AS value),
            STRUCT('PropositionType' AS name, CAST(cpt.label AS STRING) AS value),
            STRUCT('SubmissionLevel' AS name, CAST(
              CASE
                WHEN agg.pgep_strength = 'PG' THEN 'practice guideline'
                WHEN agg.pgep_strength = 'EP' THEN 'expert panel'
                WHEN agg.pgep_strength = 'PGEP' THEN 'practice guideline and expert panel mix'
                ELSE sl.label
              END AS STRING) AS value)
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

      FROM `{S}.gks_rcv_layer1_base_agg` agg
      LEFT JOIN `{P}.temp_rcv_condition_data` rcd ON rcd.rcv_accession = agg.rcv_accession
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
      {CT} `{P}.temp_rcv_layer2_statements` AS
      SELECT
        agg.id,

        -- Flattened GKS Payload
        'Statement' AS type,
        'supports' AS direction,
        'definitive' AS strength,

        -- classification_mappableConcept: Layer 2 is tier-level (somatic only), never PGEP
        STRUCT(
          'Classification' AS conceptType,
          agg.agg_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extension
        ) AS classification_mappableConcept,

        CAST(NULL AS STRUCT<type STRING, concepts ARRAY<STRUCT<conceptType STRING, name STRING>>, membershipOperator STRING, extensions ARRAY<STRUCT<name STRING, value STRING>>>) AS classification_conceptSet,
        CAST(NULL AS STRUCT<type STRING, concepts ARRAY<STRUCT<type STRING, concepts ARRAY<STRUCT<conceptType STRING, name STRING>>, membershipOperator STRING, extensions ARRAY<STRUCT<name STRING, value STRING>>>>, membershipOperator STRING>) AS classification_conceptSetSet,

        STRUCT(
          'VariantAggregateConditionClassificationProposition' AS type,
          agg.prop_id AS id,
          FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
          'hasConditionClassification' AS predicate,

          -- objectConditionClassification: 3 concept fields
          rcd.condition AS objectConditionClassification_condition,
          rcd.conditionSet AS objectConditionClassification_conditionSet,
          STRUCT('Classification' AS conceptType, agg.agg_label AS name) AS objectConditionClassification_classification,

          CAST(NULL AS STRUCT<type STRING, concepts ARRAY<STRUCT<type STRING, concepts ARRAY<STRUCT<conceptType STRING, name STRING>>, membershipOperator STRING>>, membershipOperator STRING>) AS objectConditionClassification_conceptSetSet,

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

      FROM `{S}.gks_rcv_layer2_tier_agg` agg
      LEFT JOIN `{P}.temp_rcv_condition_data` rcd ON rcd.rcv_accession = agg.rcv_accession
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
      {CT} `{P}.temp_rcv_layer3_statements` AS
      SELECT
        agg.id,

        -- Flattened GKS Payload
        'Statement' AS type,
        'supports' AS direction,
        'definitive' AS strength,

        -- classification_mappableConcept: for non-PGEP (Layer 3 carries forward from contributing layer)
        IF(
          agg.contributing_submission_level != 'PGEP',
          STRUCT(
            'Classification' AS conceptType,
            agg.agg_label AS name,
            IF(
              agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
              [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
              CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
            ) AS extension
          ),
          NULL
        ) AS classification_mappableConcept,

        -- classification_conceptSet/conceptSetSet: populated downstream for PGEP
        CAST(NULL AS STRUCT<type STRING, concepts ARRAY<STRUCT<conceptType STRING, name STRING>>, membershipOperator STRING, extensions ARRAY<STRUCT<name STRING, value STRING>>>) AS classification_conceptSet,
        CAST(NULL AS STRUCT<type STRING, concepts ARRAY<STRUCT<type STRING, concepts ARRAY<STRUCT<conceptType STRING, name STRING>>, membershipOperator STRING, extensions ARRAY<STRUCT<name STRING, value STRING>>>>, membershipOperator STRING>) AS classification_conceptSetSet,

        STRUCT(
          'VariantAggregateConditionClassificationProposition' AS type,
          agg.prop_id AS id,
          FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
          'hasConditionClassification' AS predicate,

          -- objectConditionClassification: 3 concept fields
          rcd.condition AS objectConditionClassification_condition,
          rcd.conditionSet AS objectConditionClassification_conditionSet,
          IF(agg.contributing_submission_level != 'PGEP',
            STRUCT('Classification' AS conceptType, agg.agg_label AS name),
            NULL
          ) AS objectConditionClassification_classification,

          CAST(NULL AS STRUCT<type STRING, concepts ARRAY<STRUCT<type STRING, concepts ARRAY<STRUCT<conceptType STRING, name STRING>>, membershipOperator STRING>>, membershipOperator STRING>) AS objectConditionClassification_conceptSetSet,

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

      FROM `{S}.gks_rcv_layer3_prop_agg` agg
      LEFT JOIN `{P}.temp_rcv_condition_data` rcd ON rcd.rcv_accession = agg.rcv_accession
      LEFT JOIN `clinvar_ingest.clinvar_statement_categories` csc ON agg.statement_group = csc.code
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
    """, '{S}', rec.schema_name);
    SET query_layer3 = REPLACE(query_layer3, '{CT}', temp_create);
    SET query_layer3 = REPLACE(query_layer3, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_layer3;

    -------------------------------------------------------------------------
    -- LAYER 1 PRE: L1 statements with inlined SCV evidence items
    -- For PGEP: populates classification_conceptSet/conceptSetSet
    -- and objectConditionClassification/objectConditionClassification_conceptSetSet
    -------------------------------------------------------------------------
    SET query_l1_pre = REPLACE("""
      {CT} `{P}.temp_rcv_layer1_pre` AS
      WITH
      -- Per-SCV classification data for PGEP (not deduplicated -- one entry per SCV)
      pgep_scv_data AS (
        SELECT
          agg.id AS l1_id,
          scv_pre.classification.name AS classif_name,
          (SELECT ext.value_string FROM UNNEST(scv_pre.classification.extensions) ext WHERE ext.name = 'description' LIMIT 1) AS description,
          CASE
            WHEN scs.condition.name IS NOT NULL THEN scs.condition.name
            WHEN scs.conditionSet IS NOT NULL AND ARRAY_LENGTH(scs.conditionSet.conditions) >= 2
              THEN FORMAT('%i conditions', ARRAY_LENGTH(scs.conditionSet.conditions))
            ELSE 'unspecified condition'
          END AS condition_name,
          sl.label AS submission_level_label
        FROM `{S}.gks_rcv_layer1_base_agg` agg
        CROSS JOIN UNNEST(agg.full_scv_ids) AS full_scv_id
        JOIN `{S}.gks_scv_statement_pre` scv_pre ON scv_pre.id = FORMAT('clinvar.submission:%s', full_scv_id)
        JOIN `{S}.scv_summary` ss ON ss.full_scv_id = full_scv_id
        LEFT JOIN `{S}.gks_scv_condition_sets` scs ON scs.scv_id = ss.id
        LEFT JOIN `clinvar_ingest.submission_level` sl ON sl.rank = ss.rank
        WHERE agg.submission_level = 'PGEP'
      ),
      -- Build per-SCV AND-group concept arrays for classification (with extensions)
      pgep_classif_concept_groups AS (
        SELECT
          l1_id,
          STRUCT(
            'ConceptSet' AS type,
            [
              STRUCT('Classification' AS conceptType, classif_name AS name),
              STRUCT('Condition' AS conceptType, condition_name AS name),
              STRUCT('SubmissionLevel' AS conceptType, submission_level_label AS name)
            ] AS concepts,
            'AND' AS membershipOperator,
            [STRUCT('description' AS name, description AS value)] AS extensions
          ) AS concept_group
        FROM pgep_scv_data
      ),
      -- Build per-SCV AND-group concept arrays for objectConditionClassification (no extensions, deduplicated)
      pgep_obj_distinct AS (
        SELECT DISTINCT l1_id, classif_name, condition_name, submission_level_label
        FROM pgep_scv_data
      ),
      pgep_obj_concept_groups AS (
        SELECT
          l1_id,
          STRUCT(
            'ConceptSet' AS type,
            [
              STRUCT('Classification' AS conceptType, classif_name AS name),
              STRUCT('Condition' AS conceptType, condition_name AS name),
              STRUCT('SubmissionLevel' AS conceptType, submission_level_label AS name)
            ] AS concepts,
            'AND' AS membershipOperator
          ) AS concept_group
        FROM pgep_obj_distinct
      ),
      -- Aggregate into conceptSet (1 SCV) or conceptSetSet (2+ SCVs)
      pgep_classif_agg AS (
        SELECT l1_id,
          COUNT(*) AS scv_count,
          ARRAY_AGG(concept_group) AS concept_groups
        FROM pgep_classif_concept_groups
        GROUP BY l1_id
      ),
      pgep_obj_agg AS (
        SELECT l1_id,
          COUNT(*) AS concept_count,
          ARRAY_AGG(concept_group) AS concept_groups
        FROM pgep_obj_concept_groups
        GROUP BY l1_id
      )
      SELECT
        l1.id, l1.type, l1.direction, l1.strength,
        IF(agg.submission_level != 'PGEP', l1.classification_mappableConcept, NULL) AS classification_mappableConcept,
        -- classification_conceptSet: single PGEP classification
        IF(agg.submission_level = 'PGEP' AND pca.scv_count = 1,
          pca.concept_groups[OFFSET(0)],
          l1.classification_conceptSet
        ) AS classification_conceptSet,
        -- classification_conceptSetSet: multiple PGEP classifications
        IF(agg.submission_level = 'PGEP' AND pca.scv_count > 1,
          STRUCT('ConceptSet' AS type, pca.concept_groups AS concepts, 'AND' AS membershipOperator),
          l1.classification_conceptSetSet
        ) AS classification_conceptSetSet,
        STRUCT(
          l1.proposition.type,
          l1.proposition.id,
          l1.proposition.subjectVariant,
          l1.proposition.predicate,
          -- condition/conditionSet: always pass through
          l1.proposition.objectConditionClassification_condition,
          l1.proposition.objectConditionClassification_conditionSet,
          -- classification: for non-PGEP, pass through; for PGEP, NULL (handled by conceptSetSet)
          IF(agg.submission_level != 'PGEP', l1.proposition.objectConditionClassification_classification, NULL) AS objectConditionClassification_classification,
          -- objectConditionClassification_conceptSetSet: PGEP concept groups
          IF(agg.submission_level = 'PGEP' AND poa.concept_count = 1,
            STRUCT('ConceptSet' AS type, [poa.concept_groups[OFFSET(0)]] AS concepts, 'AND' AS membershipOperator),
            IF(agg.submission_level = 'PGEP' AND poa.concept_count > 1,
              STRUCT('ConceptSet' AS type, poa.concept_groups AS concepts, 'AND' AS membershipOperator),
              l1.proposition.objectConditionClassification_conceptSetSet
            )
          ) AS objectConditionClassification_conceptSetSet,
          l1.proposition.aggregateQualifiers
        ) AS proposition,
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
      FROM `{P}.temp_rcv_layer1_statements` l1
      JOIN `{S}.gks_rcv_layer1_base_agg` agg ON l1.id = agg.id
      LEFT JOIN pgep_classif_agg pca ON pca.l1_id = l1.id
      LEFT JOIN pgep_obj_agg poa ON poa.l1_id = l1.id
    """, '{S}', rec.schema_name);
    SET query_l1_pre = REPLACE(query_l1_pre, '{CT}', temp_create);
    SET query_l1_pre = REPLACE(query_l1_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_l1_pre;

    -------------------------------------------------------------------------
    -- LAYER 2 PRE: L2 statements with inlined L1 evidence items
    -------------------------------------------------------------------------
    SET query_l2_pre = REPLACE("""
      {CT} `{P}.temp_rcv_layer2_pre` AS
      WITH
      l2_contributing AS (
        SELECT l2.id, ARRAY_AGG(TO_JSON(
          STRUCT(l1.type, l1.id, l1.direction, l1.strength,
            l1.classification_mappableConcept, l1.classification_conceptSet, l1.classification_conceptSetSet,
            l1.proposition, l1.extensions, l1.evidenceLines)
        )) AS evidenceItems
        FROM `{P}.temp_rcv_layer2_statements` l2
        CROSS JOIN UNNEST(l2.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        JOIN `{P}.temp_rcv_layer1_pre` l1 ON l1.id = JSON_VALUE(item, '$.id')
        WHERE el.strengthOfEvidenceProvided = 'contributing'
        GROUP BY l2.id
      ),
      l2_non_contributing AS (
        SELECT l2.id, ARRAY_AGG(TO_JSON(
          STRUCT(l1.type, l1.id, l1.direction, l1.strength,
            l1.classification_mappableConcept, l1.classification_conceptSet, l1.classification_conceptSetSet,
            l1.proposition, l1.extensions, l1.evidenceLines)
        )) AS evidenceItems
        FROM `{P}.temp_rcv_layer2_statements` l2
        CROSS JOIN UNNEST(l2.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        JOIN `{P}.temp_rcv_layer1_pre` l1 ON l1.id = JSON_VALUE(item, '$.id')
        WHERE el.strengthOfEvidenceProvided = 'non-contributing'
        GROUP BY l2.id
      )
      SELECT
        l2.id, l2.type, l2.direction, l2.strength,
        l2.classification_mappableConcept,
        l2.classification_conceptSet,
        l2.classification_conceptSetSet,
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
      FROM `{P}.temp_rcv_layer2_statements` l2
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
      {CT} `{P}.temp_rcv_layer3_pre` AS
      WITH
      l3_contributing AS (
        SELECT l3.id, ARRAY_AGG(TO_JSON(
          COALESCE(
            (SELECT AS STRUCT l2p.type, l2p.id, l2p.direction, l2p.strength,
              l2p.classification_mappableConcept, l2p.classification_conceptSet, l2p.classification_conceptSetSet,
              l2p.proposition, l2p.extensions, l2p.evidenceLines
             FROM `{P}.temp_rcv_layer2_pre` l2p WHERE l2p.id = JSON_VALUE(item, '$.id')),
            (SELECT AS STRUCT l1.type, l1.id, l1.direction, l1.strength,
              l1.classification_mappableConcept, l1.classification_conceptSet, l1.classification_conceptSetSet,
              l1.proposition, l1.extensions, l1.evidenceLines
             FROM `{P}.temp_rcv_layer1_pre` l1 WHERE l1.id = JSON_VALUE(item, '$.id'))
          )
        )) AS evidenceItems
        FROM `{P}.temp_rcv_layer3_statements` l3
        CROSS JOIN UNNEST(l3.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        WHERE el.strengthOfEvidenceProvided = 'contributing'
        GROUP BY l3.id
      ),
      l3_non_contributing AS (
        SELECT l3.id, ARRAY_AGG(TO_JSON(
          COALESCE(
            (SELECT AS STRUCT l2p.type, l2p.id, l2p.direction, l2p.strength,
              l2p.classification_mappableConcept, l2p.classification_conceptSet, l2p.classification_conceptSetSet,
              l2p.proposition, l2p.extensions, l2p.evidenceLines
             FROM `{P}.temp_rcv_layer2_pre` l2p WHERE l2p.id = JSON_VALUE(item, '$.id')),
            (SELECT AS STRUCT l1.type, l1.id, l1.direction, l1.strength,
              l1.classification_mappableConcept, l1.classification_conceptSet, l1.classification_conceptSetSet,
              l1.proposition, l1.extensions, l1.evidenceLines
             FROM `{P}.temp_rcv_layer1_pre` l1 WHERE l1.id = JSON_VALUE(item, '$.id'))
          )
        )) AS evidenceItems
        FROM `{P}.temp_rcv_layer3_statements` l3
        CROSS JOIN UNNEST(l3.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        WHERE el.strengthOfEvidenceProvided = 'non-contributing'
        GROUP BY l3.id
      ),
      -- Propagate classification and objectConditionClassification from contributing child
      l3_child_props AS (
        SELECT l3.id,
          COALESCE(child.classification_conceptSet) AS child_classif_conceptSet,
          COALESCE(child.classification_conceptSetSet) AS child_classif_conceptSetSet,
          COALESCE(child.proposition.objectConditionClassification_classification) AS child_objCondClassif_classification,
          COALESCE(child.proposition.objectConditionClassification_conceptSetSet) AS child_objCondClassif_conceptSetSet
        FROM `{P}.temp_rcv_layer3_statements` l3
        CROSS JOIN UNNEST(l3.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        LEFT JOIN `{P}.temp_rcv_layer2_pre` l2p ON l2p.id = JSON_VALUE(item, '$.id')
        LEFT JOIN `{P}.temp_rcv_layer1_pre` l1p ON l1p.id = JSON_VALUE(item, '$.id') AND l2p.id IS NULL
        CROSS JOIN UNNEST([COALESCE(
          IF(l2p.id IS NOT NULL, STRUCT(l2p.classification_conceptSet, l2p.classification_conceptSetSet, l2p.proposition), NULL),
          STRUCT(l1p.classification_conceptSet, l1p.classification_conceptSetSet, l1p.proposition)
        )]) AS child
        WHERE el.strengthOfEvidenceProvided = 'contributing'
      )
      SELECT
        l3.id, l3.type, l3.direction, l3.strength,
        l3.classification_mappableConcept,
        COALESCE(lcp.child_classif_conceptSet, l3.classification_conceptSet) AS classification_conceptSet,
        COALESCE(lcp.child_classif_conceptSetSet, l3.classification_conceptSetSet) AS classification_conceptSetSet,
        STRUCT(
          l3.proposition.type,
          l3.proposition.id,
          l3.proposition.subjectVariant,
          l3.proposition.predicate,
          -- condition/conditionSet: pass through from L3 BASE (same for all layers within an RCV)
          l3.proposition.objectConditionClassification_condition,
          l3.proposition.objectConditionClassification_conditionSet,
          -- classification: propagate from contributing child if PGEP
          COALESCE(lcp.child_objCondClassif_classification, l3.proposition.objectConditionClassification_classification) AS objectConditionClassification_classification,
          COALESCE(lcp.child_objCondClassif_conceptSetSet, l3.proposition.objectConditionClassification_conceptSetSet) AS objectConditionClassification_conceptSetSet,
          l3.proposition.aggregateQualifiers
        ) AS proposition,
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
      FROM `{P}.temp_rcv_layer3_statements` l3
      LEFT JOIN l3_contributing c ON l3.id = c.id
      LEFT JOIN l3_non_contributing nc ON l3.id = nc.id
      LEFT JOIN l3_child_props lcp ON l3.id = lcp.id
    """, '{S}', rec.schema_name);
    SET query_l3_pre = REPLACE(query_l3_pre, '{CT}', temp_create);
    SET query_l3_pre = REPLACE(query_l3_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_l3_pre;

    -------------------------------------------------------------------------
    -- LAYER 4: FINAL GROUP AGGREGATOR (Germline only)
    -------------------------------------------------------------------------
    SET query_layer4 = REPLACE("""
      {CT} `{P}.temp_rcv_layer4_statements` AS
      SELECT
        agg.id,

        -- Flattened GKS Payload
        'Statement' AS type,
        'supports' AS direction,
        'definitive' AS strength,

        -- classification_mappableConcept: for non-PGEP (Layer 4 uses pgep_strength to detect PGEP)
        IF(
          agg.pgep_strength IS NULL,
          STRUCT(
            'Classification' AS conceptType,
            agg.agg_label AS name,
            IF(
              agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
              [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
              CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
            ) AS extension
          ),
          NULL
        ) AS classification_mappableConcept,

        -- classification_conceptSet/conceptSetSet: populated downstream for PGEP
        CAST(NULL AS STRUCT<type STRING, concepts ARRAY<STRUCT<conceptType STRING, name STRING>>, membershipOperator STRING, extensions ARRAY<STRUCT<name STRING, value STRING>>>) AS classification_conceptSet,
        CAST(NULL AS STRUCT<type STRING, concepts ARRAY<STRUCT<type STRING, concepts ARRAY<STRUCT<conceptType STRING, name STRING>>, membershipOperator STRING, extensions ARRAY<STRUCT<name STRING, value STRING>>>>, membershipOperator STRING>) AS classification_conceptSetSet,

        STRUCT(
          'VariantAggregateConditionClassificationProposition' AS type,
          agg.prop_id AS id,
          FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
          'hasConditionClassification' AS predicate,

          -- objectConditionClassification: 3 concept fields
          rcd.condition AS objectConditionClassification_condition,
          rcd.conditionSet AS objectConditionClassification_conditionSet,
          IF(agg.pgep_strength IS NULL,
            STRUCT('Classification' AS conceptType, agg.agg_label AS name),
            NULL
          ) AS objectConditionClassification_classification,

          CAST(NULL AS STRUCT<type STRING, concepts ARRAY<STRUCT<type STRING, concepts ARRAY<STRUCT<conceptType STRING, name STRING>>, membershipOperator STRING>>, membershipOperator STRING>) AS objectConditionClassification_conceptSetSet,

          [
            STRUCT('AssertionGroup' AS name, CAST(csc.label AS STRING) AS value)
          ] AS aggregateQualifiers
        ) AS proposition,

        IF(
          agg.aggregate_review_status IS NOT NULL,
          [STRUCT('clinvarReviewStatus' AS name, agg.aggregate_review_status AS value)],
          CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
        ) AS extensions,

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

      FROM `{S}.gks_rcv_layer4_group_agg` agg
      LEFT JOIN `{P}.temp_rcv_condition_data` rcd ON rcd.rcv_accession = agg.rcv_accession
      LEFT JOIN `clinvar_ingest.clinvar_statement_categories` csc ON agg.statement_group = csc.code
    """, '{S}', rec.schema_name);
    SET query_layer4 = REPLACE(query_layer4, '{CT}', temp_create);
    SET query_layer4 = REPLACE(query_layer4, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_layer4;

    -------------------------------------------------------------------------
    -- LAYER 4 PRE: L4 statements with inlined L3 evidence items
    -------------------------------------------------------------------------
    SET query_l4_pre = REPLACE("""
      {CT} `{P}.temp_rcv_layer4_pre` AS
      WITH
      l4_contributing AS (
        SELECT l4.id, ARRAY_AGG(TO_JSON(
          (SELECT AS STRUCT l3p.type, l3p.id, l3p.direction, l3p.strength,
            l3p.classification_mappableConcept, l3p.classification_conceptSet, l3p.classification_conceptSetSet,
            l3p.proposition, l3p.extensions, l3p.evidenceLines
           FROM `{P}.temp_rcv_layer3_pre` l3p WHERE l3p.id = JSON_VALUE(item, '$.id'))
        )) AS evidenceItems
        FROM `{P}.temp_rcv_layer4_statements` l4
        CROSS JOIN UNNEST(l4.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        WHERE el.strengthOfEvidenceProvided = 'contributing'
        GROUP BY l4.id
      ),
      l4_non_contributing AS (
        SELECT l4.id, ARRAY_AGG(TO_JSON(
          (SELECT AS STRUCT l3p.type, l3p.id, l3p.direction, l3p.strength,
            l3p.classification_mappableConcept, l3p.classification_conceptSet, l3p.classification_conceptSetSet,
            l3p.proposition, l3p.extensions, l3p.evidenceLines
           FROM `{P}.temp_rcv_layer3_pre` l3p WHERE l3p.id = JSON_VALUE(item, '$.id'))
        )) AS evidenceItems
        FROM `{P}.temp_rcv_layer4_statements` l4
        CROSS JOIN UNNEST(l4.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        WHERE el.strengthOfEvidenceProvided = 'non-contributing'
        GROUP BY l4.id
      ),
      -- Collect inner AND-groups from contributing L3 children that have conceptSet/conceptSetSet (PGEP-type)
      l4_classif_inner_groups AS (
        SELECT l4.id, concept_group
        FROM `{P}.temp_rcv_layer4_statements` l4
        CROSS JOIN UNNEST(l4.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        JOIN `{P}.temp_rcv_layer3_pre` l3p ON l3p.id = JSON_VALUE(item, '$.id')
        CROSS JOIN UNNEST(
          CASE
            WHEN l3p.classification_conceptSetSet IS NOT NULL THEN l3p.classification_conceptSetSet.concepts
            WHEN l3p.classification_conceptSet IS NOT NULL THEN [l3p.classification_conceptSet]
            ELSE []
          END
        ) AS concept_group
        WHERE el.strengthOfEvidenceProvided = 'contributing'
      ),
      l4_classif_agg AS (
        SELECT id,
          COUNT(*) AS group_count,
          ARRAY_AGG(concept_group) AS concept_groups
        FROM l4_classif_inner_groups
        GROUP BY id
      ),
      -- Propagate objectConditionClassification_classification from contributing L3 children
      l4_child_classif AS (
        SELECT l4.id,
          COALESCE(l3p.proposition.objectConditionClassification_classification) AS child_objCondClassif_classification,
          COALESCE(l3p.proposition.objectConditionClassification_conceptSetSet) AS child_objCondClassif_conceptSetSet
        FROM `{P}.temp_rcv_layer4_statements` l4
        CROSS JOIN UNNEST(l4.evidenceLines) AS el
        CROSS JOIN UNNEST(el.evidenceItems) AS item
        JOIN `{P}.temp_rcv_layer3_pre` l3p ON l3p.id = JSON_VALUE(item, '$.id')
        WHERE el.strengthOfEvidenceProvided = 'contributing'
      )
      SELECT
        l4.id, l4.type, l4.direction, l4.strength,
        l4.classification_mappableConcept,
        -- classification_conceptSet: 1 combined PGEP group
        IF(lca.group_count = 1, lca.concept_groups[OFFSET(0)], l4.classification_conceptSet) AS classification_conceptSet,
        -- classification_conceptSetSet: 2+ combined PGEP groups
        IF(lca.group_count > 1,
          STRUCT('ConceptSet' AS type, lca.concept_groups AS concepts, 'AND' AS membershipOperator),
          l4.classification_conceptSetSet
        ) AS classification_conceptSetSet,
        STRUCT(
          l4.proposition.type,
          l4.proposition.id,
          l4.proposition.subjectVariant,
          l4.proposition.predicate,
          -- condition/conditionSet: pass through (same for all layers within an RCV)
          l4.proposition.objectConditionClassification_condition,
          l4.proposition.objectConditionClassification_conditionSet,
          -- classification: propagate from contributing child
          COALESCE(lcc.child_objCondClassif_classification, l4.proposition.objectConditionClassification_classification) AS objectConditionClassification_classification,
          COALESCE(lcc.child_objCondClassif_conceptSetSet, l4.proposition.objectConditionClassification_conceptSetSet) AS objectConditionClassification_conceptSetSet,
          l4.proposition.aggregateQualifiers
        ) AS proposition,
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
      FROM `{P}.temp_rcv_layer4_statements` l4
      LEFT JOIN l4_contributing c ON l4.id = c.id
      LEFT JOIN l4_non_contributing nc ON l4.id = nc.id
      LEFT JOIN l4_classif_agg lca ON l4.id = lca.id
      LEFT JOIN l4_child_classif lcc ON l4.id = lcc.id
    """, '{S}', rec.schema_name);
    SET query_l4_pre = REPLACE(query_l4_pre, '{CT}', temp_create);
    SET query_l4_pre = REPLACE(query_l4_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_l4_pre;

    -------------------------------------------------------------------------
    -- FINAL: Combined RCV statement pre (germline L4 + somatic L3)
    -------------------------------------------------------------------------
    SET query_rcv_pre = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_rcv_statement_pre` AS
      SELECT * FROM `{P}.temp_rcv_layer4_pre`
      UNION ALL
      SELECT * FROM `{P}.temp_rcv_layer3_pre`
      WHERE id LIKE '%-S-%'
    """, '{S}', rec.schema_name);
    SET query_rcv_pre = REPLACE(query_rcv_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_rcv_pre;

    -- Drop temp tables when not in debug mode
    IF NOT debug THEN
      DROP TABLE _SESSION.temp_rcv_condition_data;
      DROP TABLE _SESSION.temp_rcv_layer1_statements;
      DROP TABLE _SESSION.temp_rcv_layer2_statements;
      DROP TABLE _SESSION.temp_rcv_layer3_statements;
      DROP TABLE _SESSION.temp_rcv_layer4_statements;
      DROP TABLE _SESSION.temp_rcv_layer1_pre;
      DROP TABLE _SESSION.temp_rcv_layer2_pre;
      DROP TABLE _SESSION.temp_rcv_layer3_pre;
      DROP TABLE _SESSION.temp_rcv_layer4_pre;
    END IF;

  END FOR;
END;
