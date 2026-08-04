-- ============================================================================
-- gks_change_log — per-release A/U/D change log for the gks_* record tables
-- ============================================================================
-- For each tracked gks_* table, records which records were Added / Updated /
-- Deleted vs the prior release, into a single per-release meta table
-- <S>.gks_change_log:
--
--   table_name        STRING   -- e.g. 'gks_scv_statement'
--   change_type       STRING   -- 'A' (added) | 'U' (updated) | 'D' (deleted)
--   pk                STRING   -- the record's primary-key value
--   baseline_release  DATE     -- release the diff was computed against (NULL on first run)
--   compare_release   DATE     -- this release
--
-- This log is the driver for incremental GKS carry-forward: a record whose pk is
-- NOT in the log for its table is unchanged (carry forward from the prior release);
-- A/U get recomputed, D get deleted.
--
-- Every tracked gks_* table has a single-value primary key (verified): 'id' for the
-- final artifacts / dict tables. `gks_catvar` / `gks_dict_variation` may contain
-- exact-duplicate id rows (a separate catvar-proc data issue), so each table is
-- de-duplicated to one canonical content per pk (GROUP BY pk + ANY_VALUE) before
-- diffing — the dup collapses harmlessly.
--
-- Comparison is two-tier for speed + order-independence: cheap raw TO_JSON_STRING
-- compare, then `canonicalize_json` only on rows whose bytes differ (so unordered
-- ARRAY_AGG / array order does not create false 'U's).
--
-- Baseline = nearest existing prior release (schema_on(prev_release_date)).
-- FIRST RUN / no baseline table for a tracked table: every current record is 'A'.
--
-- To track more tables, add {name, pk} to the `tracked` array. `pk` is any valid
-- SQL expression over the table's columns (e.g. a nested field like `in`.variation_id).
-- ============================================================================

CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_change_log`(on_date DATE)
BEGIN
  DECLARE tracked ARRAY<STRUCT<name STRING, pk STRING>> DEFAULT [
    STRUCT('gks_catvar'        AS name, 'id' AS pk),
    STRUCT('gks_scv_statement',       'id'),
    STRUCT('gks_rcv_statement',       'id'),
    STRUCT('gks_vcv_statement',       'id')
  ];
  DECLARE i INT64 DEFAULT 0;
  DECLARE t STRUCT<name STRING, pk STRING>;
  DECLARE base_schema STRING;
  DECLARE base_rel DATE;
  DECLARE cur_rel DATE;
  DECLARE base_has BOOL;
  DECLARE q STRING;

  FOR rec IN (SELECT s.schema_name FROM `clinvar_ingest.schema_on`(on_date) AS s)
  DO
    SET base_schema = (SELECT schema_name FROM `clinvar_ingest.schema_on`(
                        (SELECT prev_release_date FROM `clinvar_ingest.schema_on`(on_date))));
    SET base_rel = (SELECT release_date FROM `clinvar_ingest.schema_on`(
                      (SELECT prev_release_date FROM `clinvar_ingest.schema_on`(on_date))));
    SET cur_rel = (SELECT release_date FROM `clinvar_ingest.schema_on`(on_date));

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_change_log` (
        table_name       STRING,
        change_type      STRING,
        pk               STRING,
        baseline_release DATE,
        compare_release  DATE
      ) CLUSTER BY table_name, change_type
    """, rec.schema_name);

    SET i = 0;
    WHILE i < ARRAY_LENGTH(tracked) DO
      SET t = tracked[OFFSET(i)];
      SET i = i + 1;

      SET base_has = FALSE;
      IF base_schema IS NOT NULL THEN
        EXECUTE IMMEDIATE FORMAT(
          "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = '%s'",
          base_schema, t.name) INTO base_has;
      END IF;

      IF NOT base_has THEN
        -- First run / no baseline table: every current record is Added.
        SET q = """
          INSERT INTO `{S}.gks_change_log` (table_name, change_type, pk, baseline_release, compare_release)
          SELECT '{T}', 'A', CAST({PK} AS STRING), NULL, DATE '{CREL}'
          FROM `{S}.{T}`
          GROUP BY {PK}
        """;
        SET q = REPLACE(q, '{PK}', t.pk);
        SET q = REPLACE(q, '{CREL}', CAST(cur_rel AS STRING));
        SET q = REPLACE(q, '{T}', t.name);
        SET q = REPLACE(q, '{S}', rec.schema_name);
        EXECUTE IMMEDIATE q;
      ELSE
        SET q = """
          INSERT INTO `{S}.gks_change_log` (table_name, change_type, pk, baseline_release, compare_release)
          WITH cur AS (
            SELECT CAST({PK} AS STRING) AS pk, ANY_VALUE(TO_JSON_STRING(t)) AS h
            FROM `{S}.{T}` t GROUP BY {PK}
          ),
          base AS (
            SELECT CAST({PK} AS STRING) AS pk, ANY_VALUE(TO_JSON_STRING(t)) AS h
            FROM `{BASE}.{T}` t GROUP BY {PK}
          ),
          joined AS (
            SELECT COALESCE(cur.pk, base.pk) AS pk, cur.h AS ch, base.h AS bh
            FROM cur FULL OUTER JOIN base USING(pk)
          ),
          -- tier 1: keep only rows that are new, removed, or raw-byte different
          raw_changed AS (
            SELECT pk, ch, bh FROM joined
            WHERE bh IS NULL OR ch IS NULL OR ch != bh
          )
          SELECT
            '{T}',
            CASE WHEN bh IS NULL THEN 'A' WHEN ch IS NULL THEN 'D' ELSE 'U' END,
            pk,
            DATE '{BREL}',
            DATE '{CREL}'
          FROM raw_changed
          -- tier 2: canonicalize only the raw-different rows, so array-order noise
          -- does not create false 'U's
          WHERE bh IS NULL OR ch IS NULL
             OR `clinvar_ingest.canonicalize_json`(ch) != `clinvar_ingest.canonicalize_json`(bh)
        """;
        SET q = REPLACE(q, '{PK}', t.pk);
        SET q = REPLACE(q, '{BASE}', base_schema);
        SET q = REPLACE(q, '{BREL}', CAST(base_rel AS STRING));
        SET q = REPLACE(q, '{CREL}', CAST(cur_rel AS STRING));
        SET q = REPLACE(q, '{T}', t.name);
        SET q = REPLACE(q, '{S}', rec.schema_name);
        EXECUTE IMMEDIATE q;
      END IF;
    END WHILE;
  END FOR;
END;
