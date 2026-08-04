-- ============================================================================
-- variation_vrs_changed — which variations need (re)vrsification this release
-- ============================================================================
-- `variation_identity` is always fully rebuilt (cheap). This procedure computes,
-- per release, the set of variations whose `variation_identity` row differs from
-- the prior release — i.e. the ones that must be sent through vrs-python — plus
-- the set that was removed. Everything else is carried forward from the prior
-- release's `gks_vrs`.
--
-- Writes into the release's own dataset:
--   <S>.variation_vrs_changed  (variation_id)  -- new + modified -> re-vrsify
--   <S>.variation_vrs_removed  (variation_id)  -- gone -> delete from gks_vrs
--
-- Comparison is the whole `variation_identity` row (it is exactly what becomes
-- `gks_vrs.in`), two-tier for speed + order-independence:
--   1. cheap: raw TO_JSON_STRING byte-compare resolves ~all rows;
--   2. exact: canonicalize_json (order-independent) runs only on rows whose bytes
--      differ, so unordered ARRAY_AGG (`mappings`) / array order does not inflate
--      the changed set.
--
-- Baseline = nearest existing prior release (schema_on(prev_release_date)).
-- FIRST RUN / no usable baseline (no prior release, or prior lacks
-- variation_identity): every variation is "changed" and none "removed" — the
-- caller then does a full extract + `bq load --replace` of gks_vrs.
-- ============================================================================

CREATE OR REPLACE PROCEDURE `clinvar_ingest.variation_vrs_changed`(on_date DATE)
BEGIN
  DECLARE base_schema STRING;
  DECLARE base_has_vi BOOL DEFAULT FALSE;
  DECLARE q STRING;

  FOR rec IN (SELECT s.schema_name FROM `clinvar_ingest.schema_on`(on_date) AS s)
  DO
    SET base_schema = (SELECT schema_name FROM `clinvar_ingest.schema_on`(
                        (SELECT prev_release_date FROM `clinvar_ingest.schema_on`(on_date))));
    SET base_has_vi = FALSE;
    IF base_schema IS NOT NULL THEN
      EXECUTE IMMEDIATE FORMAT(
        "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'variation_identity'",
        base_schema) INTO base_has_vi;
    END IF;

    IF base_schema IS NULL OR NOT base_has_vi THEN
      -- First run / no usable baseline: everything is changed, nothing removed.
      EXECUTE IMMEDIATE FORMAT(
        "CREATE OR REPLACE TABLE `%s.variation_vrs_changed` AS SELECT variation_id FROM `%s.variation_identity`",
        rec.schema_name, rec.schema_name);
      EXECUTE IMMEDIATE FORMAT(
        "CREATE OR REPLACE TABLE `%s.variation_vrs_removed` AS SELECT variation_id FROM `%s.variation_identity` WHERE FALSE",
        rec.schema_name, rec.schema_name);
    ELSE
      -- Changed = new (not in baseline) + modified (in both, canonically different).
      SET q = REPLACE(REPLACE("""
        CREATE OR REPLACE TABLE `{S}.variation_vrs_changed` AS
        WITH cur  AS (SELECT variation_id, TO_JSON_STRING(t) AS h FROM `{S}.variation_identity`    t),
             base AS (SELECT variation_id, TO_JSON_STRING(t) AS h FROM `{BASE}.variation_identity` t),
             joined AS (
               SELECT COALESCE(cur.variation_id, base.variation_id) AS variation_id,
                      cur.h AS ch, base.h AS bh
               FROM cur FULL OUTER JOIN base USING(variation_id)
             ),
             raw_changed AS (
               SELECT variation_id, ch, bh
               FROM joined
               WHERE ch IS NOT NULL AND (bh IS NULL OR ch != bh)   -- present now, new-or-raw-differs
             )
        SELECT variation_id FROM raw_changed
        WHERE bh IS NULL
           OR `clinvar_ingest.canonicalize_json`(ch) != `clinvar_ingest.canonicalize_json`(bh)
      """, '{S}', rec.schema_name), '{BASE}', base_schema);
      EXECUTE IMMEDIATE q;

      SET q = REPLACE(REPLACE("""
        CREATE OR REPLACE TABLE `{S}.variation_vrs_removed` AS
        SELECT base.variation_id
        FROM `{BASE}.variation_identity` base
        LEFT JOIN `{S}.variation_identity` cur USING(variation_id)
        WHERE cur.variation_id IS NULL
      """, '{S}', rec.schema_name), '{BASE}', base_schema);
      EXECUTE IMMEDIATE q;
    END IF;
  END FOR;
END;
