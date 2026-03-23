CREATE OR REPLACE PROCEDURE `clinvar_ingest.get_gks_vcv_assembled_payload`(
  target_schema STRING,
  target_id STRING
)
BEGIN
  DECLARE sql_query STRING;

  SET sql_query = REPLACE("""
    WITH
    -------------------------------------------------------------------------
    -- STEP 1: PRE-AGGREGATE LAYER 1 INTO LAYER 2
    -------------------------------------------------------------------------
    l2_contributing AS (
      SELECT l2.id, ARRAY_AGG(TO_JSON(
        STRUCT(l1.type, l1.id, l1.direction, l1.strength, l1.classification, l1.proposition, l1.evidenceLines)
      )) AS evidenceItems
      FROM `{S}.gks_layer2_statements` l2
      CROSS JOIN UNNEST(l2.evidenceLines) AS el
      CROSS JOIN UNNEST(el.evidenceItems) AS item
      JOIN `{S}.gks_layer1_statements` l1 ON l1.id = JSON_VALUE(item, '$.id')
      WHERE l2.id LIKE CONCAT(@target_id, '%')
        AND el.strengthOfEvidenceProvided = 'contributing'
      GROUP BY l2.id
    ),
    l2_non_contributing AS (
      SELECT l2.id, ARRAY_AGG(TO_JSON(
        STRUCT(l1.type, l1.id, l1.direction, l1.strength, l1.classification, l1.proposition, l1.evidenceLines)
      )) AS evidenceItems
      FROM `{S}.gks_layer2_statements` l2
      CROSS JOIN UNNEST(l2.evidenceLines) AS el
      CROSS JOIN UNNEST(el.evidenceItems) AS item
      JOIN `{S}.gks_layer1_statements` l1 ON l1.id = JSON_VALUE(item, '$.id')
      WHERE l2.id LIKE CONCAT(@target_id, '%')
        AND el.strengthOfEvidenceProvided = 'non-contributing'
      GROUP BY l2.id
    ),
    layer_2_assembled AS (
      SELECT
        l2.id,
        (
          SELECT AS STRUCT
            l2.type, l2.id, l2.direction, l2.strength, l2.classification, l2.proposition,
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
        ) AS assembled_statement
      FROM `{S}.gks_layer2_statements` l2
      LEFT JOIN l2_contributing c ON l2.id = c.id
      LEFT JOIN l2_non_contributing nc ON l2.id = nc.id
      WHERE l2.id LIKE CONCAT(@target_id, '%')
    ),

    -------------------------------------------------------------------------
    -- STEP 2: PRE-AGGREGATE LAYER 2 (OR L1) INTO LAYER 3
    -- CLEAN DESIGN: Coalesces from L2 or directly from L1 for untiered records
    -------------------------------------------------------------------------
    l3_contributing AS (
      SELECT l3.id, ARRAY_AGG(TO_JSON(
        COALESCE(
          l2a.assembled_statement,
          STRUCT(l1.type, l1.id, l1.direction, l1.strength, l1.classification, l1.proposition, l1.evidenceLines)
        )
      )) AS evidenceItems
      FROM `{S}.gks_layer3_statements` l3
      CROSS JOIN UNNEST(l3.evidenceLines) AS el
      CROSS JOIN UNNEST(el.evidenceItems) AS item
      LEFT JOIN layer_2_assembled l2a ON l2a.id = JSON_VALUE(item, '$.id')
      LEFT JOIN `{S}.gks_layer1_statements` l1 ON l1.id = JSON_VALUE(item, '$.id')
      WHERE l3.id LIKE CONCAT(@target_id, '%')
        AND el.strengthOfEvidenceProvided = 'contributing'
      GROUP BY l3.id
    ),
    l3_non_contributing AS (
      SELECT l3.id, ARRAY_AGG(TO_JSON(
        COALESCE(
          l2a.assembled_statement,
          STRUCT(l1.type, l1.id, l1.direction, l1.strength, l1.classification, l1.proposition, l1.evidenceLines)
        )
      )) AS evidenceItems
      FROM `{S}.gks_layer3_statements` l3
      CROSS JOIN UNNEST(l3.evidenceLines) AS el
      CROSS JOIN UNNEST(el.evidenceItems) AS item
      LEFT JOIN layer_2_assembled l2a ON l2a.id = JSON_VALUE(item, '$.id')
      LEFT JOIN `{S}.gks_layer1_statements` l1 ON l1.id = JSON_VALUE(item, '$.id')
      WHERE l3.id LIKE CONCAT(@target_id, '%')
        AND el.strengthOfEvidenceProvided = 'non-contributing'
      GROUP BY l3.id
    ),
    layer_3_assembled AS (
      SELECT
        l3.id,
        (
          SELECT AS STRUCT
            l3.type, l3.id, l3.direction, l3.strength, l3.classification, l3.proposition,
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
        ) AS final_statement
      FROM `{S}.gks_layer3_statements` l3
      LEFT JOIN l3_contributing c ON l3.id = c.id
      LEFT JOIN l3_non_contributing nc ON l3.id = nc.id
      WHERE l3.id LIKE CONCAT(@target_id, '%')
    ),

    -------------------------------------------------------------------------
    -- STEP 3: PRE-AGGREGATE LAYER 3 INTO LAYER 4 (GERMLINE ONLY)
    -------------------------------------------------------------------------
    l4_contributing AS (
      SELECT l4.id, ARRAY_AGG(TO_JSON(l3a.final_statement)) AS evidenceItems
      FROM `{S}.gks_layer4_statements` l4
      CROSS JOIN UNNEST(l4.evidenceLines) AS el
      CROSS JOIN UNNEST(el.evidenceItems) AS item
      JOIN layer_3_assembled l3a ON l3a.id = JSON_VALUE(item, '$.id')
      WHERE l4.id LIKE CONCAT(@target_id, '%')
        AND el.strengthOfEvidenceProvided = 'contributing'
      GROUP BY l4.id
    ),
    l4_non_contributing AS (
      SELECT l4.id, ARRAY_AGG(TO_JSON(l3a.final_statement)) AS evidenceItems
      FROM `{S}.gks_layer4_statements` l4
      CROSS JOIN UNNEST(l4.evidenceLines) AS el
      CROSS JOIN UNNEST(el.evidenceItems) AS item
      JOIN layer_3_assembled l3a ON l3a.id = JSON_VALUE(item, '$.id')
      WHERE l4.id LIKE CONCAT(@target_id, '%')
        AND el.strengthOfEvidenceProvided = 'non-contributing'
      GROUP BY l4.id
    ),
    layer_4_assembled AS (
      SELECT
        l4.id,
        (
          SELECT AS STRUCT
            l4.type, l4.id, l4.direction, l4.strength, l4.classification, l4.proposition,
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
        ) AS final_statement
      FROM `{S}.gks_layer4_statements` l4
      LEFT JOIN l4_contributing c ON l4.id = c.id
      LEFT JOIN l4_non_contributing nc ON l4.id = nc.id
      WHERE l4.id LIKE CONCAT(@target_id, '%')
    )

    -------------------------------------------------------------------------
    -- STEP 4: OUTPUT CLEAN JSON (GERMLINE L4 + SOMATIC L3)
    -------------------------------------------------------------------------
    SELECT
      id,
      JSON_STRIP_NULLS(TO_JSON(final_statement), remove_empty => TRUE) AS gks_json_payload
    FROM layer_4_assembled

    UNION ALL

    SELECT
      id,
      JSON_STRIP_NULLS(TO_JSON(final_statement), remove_empty => TRUE) AS gks_json_payload
    FROM layer_3_assembled
    WHERE id LIKE CONCAT(@target_id, '%-S-%');

  """, '{S}', target_schema);

  EXECUTE IMMEDIATE sql_query USING target_id AS target_id;
END;
