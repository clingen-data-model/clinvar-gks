-- ============================================================================
-- dataset_diff_on — on_date driver bridging dataset_diff_all into the GKS idiom
-- ============================================================================
-- The GKS procedures are called with an (on_date, debug) signature and resolve
-- the active release snapshot via `clinvar_ingest.schema_on(on_date)`. A diff,
-- however, is inherently a TWO-snapshot operation. This driver bridges the two:
-- given a single `on_date`, it resolves
--   * the COMPARE snapshot  = the release active on on_date               (newer)
--   * the BASELINE snapshot = the nearest EXISTING release before it      (older)
-- and calls `clinvar_ingest.dataset_diff_all(baseline, compare)`, which writes
-- `<compare_schema>.diff_<table>` for the full ClinVar table set.
--
-- Prior-release resolution uses the registry that already backs schema_on:
--   schema_on(on_date).prev_release_date -> schema_on(prev_release_date).
-- Because schema_on only returns releases whose DATASET still exists, the
-- baseline automatically falls back to the nearest surviving prior snapshot if
-- an intermediate release has been archived/deleted.
--
-- First-run / no-baseline: for the earliest release, prev_release_date points at
-- a floor sentinel date with no matching dataset, so schema_on(prev_release_date)
-- returns zero rows and base_schema resolves to NULL. In that case there is
-- nothing to diff against — the driver emits a warning and returns WITHOUT
-- creating diff tables. Callers must treat "no diff tables" as "first run =>
-- full rebuild", never as "nothing changed".
--
-- No `debug` parameter: unlike the per-release GKS procs, dataset_diff_all writes
-- persistent `diff_<table>` outputs (not session temp tables), so there is no
-- temp-vs-debug table mode to switch.
--
-- Usage:
--   CALL `clinvar_ingest.dataset_diff_on`(CURRENT_DATE());
--   CALL `clinvar_ingest.dataset_diff_on`(DATE '2026-07-20');
-- ============================================================================

CREATE OR REPLACE PROCEDURE `clinvar_ingest.dataset_diff_on`(on_date DATE)
BEGIN
  DECLARE cur_schema  STRING;
  DECLARE prev_date   DATE;
  DECLARE base_schema STRING;

  -- COMPARE snapshot: the release active on on_date, plus its prior release date.
  -- Scalar subqueries against schema_on (which is LIMIT 1) yield NULL if no
  -- release exists on/before on_date.
  SET cur_schema = (SELECT schema_name       FROM `clinvar_ingest.schema_on`(on_date));
  SET prev_date  = (SELECT prev_release_date  FROM `clinvar_ingest.schema_on`(on_date));

  IF cur_schema IS NULL THEN
    RAISE USING MESSAGE = FORMAT('dataset_diff_on: no ClinVar release found on or before %t', on_date);
  END IF;

  -- BASELINE snapshot: nearest existing release before the compare snapshot.
  SET base_schema = (SELECT schema_name FROM `clinvar_ingest.schema_on`(prev_date));

  IF base_schema IS NULL THEN
    SELECT FORMAT(
      'dataset_diff_on: no baseline snapshot before %t for release %s — first run, full rebuild required (no diff tables written)',
      prev_date, cur_schema) AS diff_warning;
    RETURN;
  END IF;

  CALL `clinvar_ingest.dataset_diff_all`(base_schema, cur_schema);
END;
