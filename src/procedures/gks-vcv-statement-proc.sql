CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_vcv_statement_proc`(on_date DATE)
BEGIN
  DECLARE query_layer1 STRING;
  DECLARE query_layer2 STRING;
  DECLARE query_layer3 STRING;
  DECLARE query_layer4 STRING;

  FOR rec IN (SELECT s.schema_name FROM `clinvar_ingest.schema_on`(on_date) AS s)
  DO

    -------------------------------------------------------------------------
    -- LAYER 1: BASE AGGREGATOR
    -------------------------------------------------------------------------
    SET query_layer1 = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_layer1_statements` AS
      SELECT
        agg.id,

        -- Flattened GKS Payload
        'Statement' AS type,
        'supports' AS direction,
        'definitive' AS strength,

        STRUCT(
          agg.actual_agg_classif_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extension
        ) AS classification,

        STRUCT(
          'AggregateStatementProposition' AS type,
          agg.prop_id AS id,
          CAST(agg.variation_id AS STRING) AS subjectVariant,
          'hasAggregateClassification' AS predicate,

          [
            STRUCT('AssertionGroup' AS name, CAST(csc.label AS STRING) AS value),
            STRUCT('PropositionType' AS name, CAST(cpt.label AS STRING) AS value),
            STRUCT('SubmissionLevel' AS name, CAST(sl.label AS STRING) AS value)
          ] || IF(
            agg.tier_grouping IS NOT NULL,
            [STRUCT('ClassificationTier' AS name, CAST(cct.label AS STRING) AS value)],
            CAST([] AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS aggregateQualifier
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
    EXECUTE IMMEDIATE query_layer1;


    -------------------------------------------------------------------------
    -- LAYER 2: TIER AGGREGATOR
    -------------------------------------------------------------------------
    SET query_layer2 = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_layer2_statements` AS
      SELECT
        agg.id,

        -- Flattened GKS Payload
        'Statement' AS type,
        'supports' AS direction,
        'definitive' AS strength,

        STRUCT(
          agg.agg_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extension
        ) AS classification,

        STRUCT(
          'AggregateStatementProposition' AS type,
          agg.prop_id AS id,
          CAST(agg.variation_id AS STRING) AS subjectVariant,
          'hasAggregateClassification' AS predicate,

          [
            STRUCT('AssertionGroup' AS name, CAST(csc.label AS STRING) AS value),
            STRUCT('PropositionType' AS name, CAST(cpt.label AS STRING) AS value),
            STRUCT('SubmissionLevel' AS name, CAST(sl.label AS STRING) AS value)
          ] AS aggregateQualifier
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
    EXECUTE IMMEDIATE query_layer2;

    -------------------------------------------------------------------------
    -- LAYER 3: SUBMISSION LEVEL AGGREGATOR
    -------------------------------------------------------------------------
    SET query_layer3 = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_layer3_statements` AS
      SELECT
        agg.id,

        -- Flattened GKS Payload
        'Statement' AS type,
        'supports' AS direction,
        'definitive' AS strength,

        STRUCT(
          agg.agg_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extension
        ) AS classification,

        STRUCT(
          'AggregateStatementProposition' AS type,
          agg.prop_id AS id,
          CAST(agg.variation_id AS STRING) AS subjectVariant,
          'hasAggregateClassification' AS predicate,

          [
            STRUCT('AssertionGroup' AS name, CAST(csc.label AS STRING) AS value),
            STRUCT('PropositionType' AS name, CAST(cpt.label AS STRING) AS value)
          ] AS aggregateQualifier
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
    EXECUTE IMMEDIATE query_layer3;

    -------------------------------------------------------------------------
    -- LAYER 4: FINAL GROUP AGGREGATOR
    -------------------------------------------------------------------------
    SET query_layer4 = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_layer4_statements` AS
      SELECT
        agg.id,

        -- Flattened GKS Payload
        'Statement' AS type,
        'supports' AS direction,
        'definitive' AS strength,

        STRUCT(
          agg.agg_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extension
        ) AS classification,

        STRUCT(
          'AggregateStatementProposition' AS type,
          agg.prop_id AS id,
          CAST(agg.variation_id AS STRING) AS subjectVariant,
          'hasAggregateClassification' AS predicate,

          [
            STRUCT('AssertionGroup' AS name, CAST(csc.label AS STRING) AS value)
          ] AS aggregateQualifier
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
    EXECUTE IMMEDIATE query_layer4;

  END FOR;
END;