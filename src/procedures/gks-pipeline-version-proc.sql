-- ============================================================================
-- gks_pipeline_version — per-release stamp of the pipeline build version
-- ============================================================================
-- Writes a single-row {S}.gks_pipeline_version for the release active on on_date:
--   audit_stamp  STRING  -- `git describe --tags --always --dirty` (provenance; never gates)
--   gate_key     STRING  -- last commit hash over build-relevant paths (drives carry-forward)
--   computed_at  TIMESTAMP
-- The orchestration layer (run-release.sh) computes both values from git and passes
-- them in. Downstream *_build procs read {base}.gks_pipeline_version.gate_key and
-- compare it to {S}.gks_pipeline_version.gate_key; a mismatch forces a full rebuild.
-- ============================================================================
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_pipeline_version`(on_date DATE, audit_stamp STRING, gate_key STRING)
BEGIN
  FOR rec IN (SELECT s.schema_name FROM `clinvar_ingest.schema_on`(on_date) AS s)
  DO
    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_pipeline_version` AS
      SELECT %T AS audit_stamp, %T AS gate_key, CURRENT_TIMESTAMP() AS computed_at
    """, rec.schema_name, audit_stamp, gate_key);
  END FOR;
END;
