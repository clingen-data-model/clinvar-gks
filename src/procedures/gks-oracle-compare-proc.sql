-- ============================================================================
-- gks_oracle_compare — assert two builds of a table are canonically identical
-- ============================================================================
-- Compares `<schema_a>.<table>` vs `<schema_b>.<table>` keyed by <pk> using the
-- same two-tier compare as gks_change_log: cheap TO_JSON_STRING first, then
-- canonicalize_json only on byte-different rows (so array-order noise is ignored).
-- SELECTs a single result row: (table_name, a_only, b_only, canonical_diffs).
-- 0/0/0 == pass. Duplicate-pk tables collapse via GROUP BY + ANY_VALUE (matches
-- gks_change_log's handling of catvar's known dup-id rows).
-- ============================================================================
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_oracle_compare`(
  schema_a STRING, schema_b STRING, table_name STRING, pk STRING)
BEGIN
  DECLARE q STRING;
  SET q = """
    WITH a AS (
      SELECT CAST({PK} AS STRING) AS pk, ANY_VALUE(TO_JSON_STRING(t)) AS h
      FROM `{A}.{T}` t GROUP BY {PK}
    ),
    b AS (
      SELECT CAST({PK} AS STRING) AS pk, ANY_VALUE(TO_JSON_STRING(t)) AS h
      FROM `{B}.{T}` t GROUP BY {PK}
    ),
    joined AS (
      SELECT COALESCE(a.pk, b.pk) AS pk, a.h AS ah, b.h AS bh
      FROM a FULL OUTER JOIN b USING(pk)
    )
    SELECT
      '{T}' AS table_name,
      COUNTIF(bh IS NULL) AS a_only,
      COUNTIF(ah IS NULL) AS b_only,
      COUNTIF(ah IS NOT NULL AND bh IS NOT NULL
              AND `clinvar_ingest.canonicalize_json`(ah) != `clinvar_ingest.canonicalize_json`(bh)) AS canonical_diffs
    FROM joined
  """;
  SET q = REPLACE(q, '{PK}', pk);
  SET q = REPLACE(q, '{A}', schema_a);
  SET q = REPLACE(q, '{B}', schema_b);
  SET q = REPLACE(q, '{T}', table_name);
  EXECUTE IMMEDIATE q;
END;
