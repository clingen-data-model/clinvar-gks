-- ============================================================================
-- gks_oracle_compare — assert two builds of a table are canonically identical
-- ============================================================================
-- Compares `<schema_a>.<table>` vs `<schema_b>.<table>` as a canonical-row MULTISET:
-- each row is reduced to canonicalize_json(TO_JSON_STRING(row)) (order-independent),
-- grouped, and the per-canonical-row multiplicities are compared. This is dup-key-safe
-- (tables with legitimately duplicate primary keys, e.g. gks_dict_allele, compare
-- correctly) and strictly stronger than a per-pk collapse. SELECTs one result row:
--   (table_name, a_only, b_only, canonical_diffs)
-- a_only  = total canonical rows present more times in A than B
-- b_only  = ... more times in B than A
-- canonical_diffs = number of distinct canonical rows whose multiplicity differs
-- 0/0/0 == the two builds are identical.
-- ============================================================================
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_oracle_compare`(
  schema_a STRING, schema_b STRING, table_name STRING)
BEGIN
  DECLARE q STRING;
  SET q = """
    WITH a AS (SELECT `clinvar_ingest.canonicalize_json`(TO_JSON_STRING(t)) AS h FROM `{A}.{T}` t),
         b AS (SELECT `clinvar_ingest.canonicalize_json`(TO_JSON_STRING(t)) AS h FROM `{B}.{T}` t),
         ac AS (SELECT h, COUNT(*) AS n FROM a GROUP BY h),
         bc AS (SELECT h, COUNT(*) AS n FROM b GROUP BY h),
         j AS (SELECT h, IFNULL(ac.n,0) AS an, IFNULL(bc.n,0) AS bn FROM ac FULL OUTER JOIN bc USING(h))
    SELECT
      '{T}' AS table_name,
      IFNULL(SUM(GREATEST(an-bn,0)),0) AS a_only,
      IFNULL(SUM(GREATEST(bn-an,0)),0) AS b_only,
      COUNTIF(an != bn) AS canonical_diffs
    FROM j
  """;
  SET q = REPLACE(q, '{A}', schema_a);
  SET q = REPLACE(q, '{B}', schema_b);
  SET q = REPLACE(q, '{T}', table_name);
  EXECUTE IMMEDIATE q;
END;
