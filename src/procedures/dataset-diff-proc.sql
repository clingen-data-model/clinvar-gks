-- ============================================================================
-- dataset_diff — generic snapshot-to-snapshot table delta
-- ============================================================================
-- Builds `<compare_schema>.diff_<target_table>` describing how every record in
-- the COMPARE snapshot differs from the BASELINE snapshot for one table. The
-- diff table is written into the COMPARE (2nd/newer) snapshot's own dataset.
--
-- Each output row is classified:
--   'new'         — key present only in the compare snapshot
--   'removed'     — key present only in the baseline snapshot
--   'exact_match' — key present in both AND semantically identical
--                   (identical after order-independent canonicalization, so a
--                    mere reordering of arrays / JSON keys still matches)
--   'modified'    — key present in both but content differs
-- For 'modified' rows, change_note lists the top-level columns that changed.
--
-- Comparison is a TWO-TIER fingerprint for speed + reliability:
--   1. cheap: raw TO_JSON_STRING equality resolves the vast majority of rows
--      (schema-ordered serialization; identical bytes => identical).
--   2. exact: only when raw bytes differ do we call the JS canonicalizer, which
--      makes array / JSON-key order irrelevant. So the expensive UDF runs on a
--      tiny fraction of rows (e.g. a few hundred out of ~7M for clinical_assertion).
--
-- Parameters
--   baseline_schema  dataset name of the OLDER snapshot   e.g. 'clinvar_2026_07_15_v2_5_0'
--   compare_schema   dataset name of the NEWER snapshot   e.g. 'clinvar_2026_07_20_v2_5_0'
--   target_table     table to diff                        e.g. 'clinical_assertion'
--   key_columns      natural key. If empty, the whole (non-ignored) row is the
--                    key and DISTINCT is forced (see trait_mapping).
--   ignore_columns   columns excluded from the comparison AND the key — always
--                    include 'release_date' (differs on every snapshot).
--   use_distinct     apply SELECT DISTINCT to each snapshot before diffing
--                    (needed for tables that may contain duplicate rows).
--
-- Output: <compare_schema>.diff_<target_table>, clustered by change_type, with
--   the key columns expanded for readability plus record_key, change_type,
--   change_note, baseline_release, compare_release.
-- ============================================================================

CREATE OR REPLACE PROCEDURE `clinvar_ingest.dataset_diff`(
  baseline_schema STRING,
  compare_schema  STRING,
  target_table    STRING,
  key_columns     ARRAY<STRING>,
  ignore_columns  ARRAY<STRING>,
  use_distinct    BOOL
)
BEGIN
  DECLARE sql STRING;
  DECLARE except_clause STRING DEFAULT '';
  DECLARE content_expr STRING;
  DECLARE key_expr STRING;
  DECLARE key_sel STRING;        -- "src.id AS _k0, src.version AS _k1, " (trailing sep or '')
  DECLARE key_coalesce STRING;   -- "COALESCE(base._k0,comp._k0) AS id, ...  , "
  DECLARE key_names STRING;      -- "id, version, "  (trailing sep or '')
  DECLARE base_src STRING;
  DECLARE comp_src STRING;

  -- EXCEPT(...) clause for ignored columns (applied to both content and, when
  -- there is no explicit key, the key).
  IF ARRAY_LENGTH(ignore_columns) > 0 THEN
    SET except_clause = ' EXCEPT(' || ARRAY_TO_STRING(ignore_columns, ', ') || ')';
  END IF;

  -- Serialized content used for comparison (schema-ordered, ignore cols dropped).
  SET content_expr = 'TO_JSON_STRING((SELECT AS STRUCT src.*' || except_clause || '))';

  -- Key expression + expanded key column plumbing.
  IF ARRAY_LENGTH(key_columns) > 0 THEN
    SET key_expr = 'TO_JSON_STRING(STRUCT(' ||
      (SELECT STRING_AGG('src.' || c, ', ') FROM UNNEST(key_columns) c) || '))';
    SET key_sel = (SELECT STRING_AGG('src.' || c || ' AS _k' || CAST(o AS STRING), ', ')
                   FROM UNNEST(key_columns) c WITH OFFSET o) || ', ';
    SET key_coalesce = (SELECT STRING_AGG(
                          'COALESCE(base._k' || CAST(o AS STRING) || ', comp._k' || CAST(o AS STRING) || ') AS ' || c, ', ')
                        FROM UNNEST(key_columns) c WITH OFFSET o) || ', ';
    SET key_names = (SELECT STRING_AGG(c, ', ') FROM UNNEST(key_columns) c) || ', ';
  ELSE
    -- No natural key: identity is the whole (non-ignored) row.
    SET key_expr = content_expr;
    SET key_sel = '';
    SET key_coalesce = '';
    SET key_names = '';
  END IF;

  -- Snapshot sources, optionally de-duplicated.
  SET base_src = '`' || baseline_schema || '.' || target_table || '`';
  SET comp_src = '`' || compare_schema  || '.' || target_table || '`';
  IF use_distinct THEN
    SET base_src = '(SELECT DISTINCT * FROM ' || base_src || ')';
    SET comp_src = '(SELECT DISTINCT * FROM ' || comp_src || ')';
  END IF;

  SET sql = """
    CREATE OR REPLACE TABLE `@compare_schema.diff_@table`
    CLUSTER BY change_type AS
    WITH base AS (
      SELECT @key_expr AS _key, @key_sel @content_expr AS _content
      FROM @base_src src
    ),
    comp AS (
      SELECT @key_expr AS _key, @key_sel @content_expr AS _content
      FROM @comp_src src
    ),
    joined AS (
      SELECT
        COALESCE(base._key, comp._key) AS record_key,
        @key_coalesce
        base._content AS base_content,
        comp._content AS comp_content
      FROM base FULL OUTER JOIN comp ON base._key = comp._key
    ),
    classified AS (
      SELECT
        record_key,
        @key_names
        base_content,
        comp_content,
        CASE
          WHEN base_content IS NULL THEN 'new'
          WHEN comp_content IS NULL THEN 'removed'
          WHEN base_content = comp_content THEN 'exact_match'
          WHEN `clinvar_ingest.canonicalize_json`(base_content)
             = `clinvar_ingest.canonicalize_json`(comp_content) THEN 'exact_match'
          ELSE 'modified'
        END AS change_type
      FROM joined
    )
    SELECT
      record_key,
      @key_names
      change_type,
      IF(change_type = 'modified',
         `clinvar_ingest.json_changed_keys`(base_content, comp_content),
         NULL) AS change_note,
      (SELECT MAX(release_date) FROM @base_src) AS baseline_release,
      (SELECT MAX(release_date) FROM @comp_src) AS compare_release
    FROM classified
  """;

  SET sql = REPLACE(sql, '@compare_schema', compare_schema);
  SET sql = REPLACE(sql, '@table',        target_table);
  SET sql = REPLACE(sql, '@key_expr',     key_expr);
  SET sql = REPLACE(sql, '@content_expr', content_expr);
  SET sql = REPLACE(sql, '@key_sel',      key_sel);
  SET sql = REPLACE(sql, '@key_coalesce', key_coalesce);
  SET sql = REPLACE(sql, '@key_names',    key_names);
  SET sql = REPLACE(sql, '@base_src',     base_src);
  SET sql = REPLACE(sql, '@comp_src',     comp_src);

  EXECUTE IMMEDIATE sql;
END;
