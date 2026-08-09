-- ============================================================================
-- gks_rcvvcv_changed — shared per-release impacted-RCV / impacted-VCV parent sets
-- ============================================================================
-- Computes, ONCE per release, the two impacted-parent sets that every incremental
-- RCV/VCV proc (gks_rcv, gks_rcv_statement, gks_vcv, gks_vcv_statement) consumes to
-- restrict its recompute + drive its carry-forward merge. Writes two persistent
-- {S} tables:
--
--   {S}.rcv_impacted_ids(rcv_accession)   -- RCV parents to recompute this release
--   {S}.vcv_impacted_ids(vcv_accession)   -- VCV parents to recompute this release
--
-- RCV and VCV are INDEPENDENT parallel aggregates over SCVs (spec §3.2 — VCV never
-- reads RCV). Both are membership-first: the aggregation cascade's single hardest
-- case is a changed SCV forcing recompute of its parent even though the parent's
-- own row is byte-identical (the statement re-aggregates across members).
--
-- Member-SCV driver = scv_changed_ids ∪ scv_removed_ids (from gks_scv_changed).
-- BOTH are needed: a REMOVED SCV's old parent must recompute (it lost a member),
-- and scv_changed_ids already folds in every content/trait/version driver Plan 2
-- hardened. Using the full scv_changed_ids (not the narrower version/review-status
-- audit subset) is deliberate SAFE OVER-INCLUSION: an SCV changed for a reason that
-- doesn't move the aggregate (e.g. submitter rename — the agg counts submitter_id,
-- not name) recomputes its parent to a byte-identical row → the oracle stays 0.
--
-- ---------------------------------------------------------------------------
-- rcv_impacted_ids arms (uncorrelated UNION DISTINCT; anti-join out removed):
--   (1) MEMBERSHIP: RCVs with ≥1 member SCV in (scv_changed_ids ∪ scv_removed_ids),
--       via the UNION of CURRENT {S}.rcv_mapping AND BASELINE {base}.rcv_mapping
--       (CROSS JOIN UNNEST(scv_accessions)). Unioning both memberships makes a
--       re-assigned SCV recompute BOTH its old (baseline) and new (current) parent.
--   (2) MAPPING DIFF: diff_rcv_mapping non-exact → rcv_accession (membership/
--       trait_set changed for the RCV even if no member SCV row changed).
--   (3) ACCESSION DIFF: diff_rcv_accession (new|modified) → id (the RCV's own
--       accession record changed).
--   minus REMOVED RCVs = RCVs ABSENT from current {S}.rcv_accession (semi-join to
--       current). ⚠️ We do NOT use diff_rcv_accession.change_type='removed':
--       diff_rcv_accession is keyed [id,version], so a version bump emits a spurious
--       'removed' row for the OLD version while the RCV is still live and MUST
--       recompute (its version is embedded in full_rcv_id → the output id). Removal
--       = absence from current only (same [id,version] trap gks_scv_changed handles).
--   (No own-agg-row-diff arm: this proc runs BEFORE gks_rcv_proc, so there is no
--    current agg table to diff; arms 1-3 subsume spec §3.2's own-record diffs.)
--
-- vcv_impacted_ids arms (uncorrelated UNION DISTINCT; anti-join out removed):
--   (1) MEMBERSHIP: VCVs whose variation has ≥1 member SCV. VCV membership = SCVs
--       sharing the VCV's variation_id (VCV ⋈ SCV on variation_id). Resolve the
--       member SCVs' variation_id over the UNION of CURRENT + BASELINE scv_summary
--       (a removed SCV's variation only exists in baseline), then map
--       variation_id → variation_archive.id over CURRENT + BASELINE variation_archive.
--   (2) ARCHIVE DIFF: diff_variation_archive (new|modified) → id (the VCV's own
--       variation_archive record changed).
--   minus REMOVED VCVs = VCVs ABSENT from current {S}.variation_archive (semi-join
--       to current). ⚠️ Same [id,version] trap: NOT diff_variation_archive
--       change_type='removed' (a version bump flags the old version removed while
--       the VCV is live and must recompute — its version is in full_vcv_id → id).
--   (No own-agg-row-diff arm — same reason as RCV.)
--
-- All-or-nothing driver gate (mirrors gks_scv_changed): dataset_diff_all wraps each
-- table diff in an EXCEPTION handler and continues, so a required diff_* can be
-- silently absent. Required drivers = diff_rcv_mapping, diff_rcv_accession,
-- diff_variation_archive (current) + scv_changed_ids, scv_removed_ids (from
-- gks_scv_changed) + baseline resolvable with rcv_mapping / scv_summary /
-- variation_archive. If ANY is missing → EVERYTHING-IMPACTED fallback
-- (rcv_impacted_ids = all {S}.rcv_accession.id; vcv_impacted_ids = all
-- {S}.variation_archive.id) and RETURN; incremental safely degrades to full.
--
-- Baseline = nearest existing prior release (schema_on(prev_release_date)).
-- ============================================================================

CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_rcvvcv_changed`(on_date DATE)
BEGIN
  DECLARE base_schema STRING;
  DECLARE base_has_rcv_mapping BOOL DEFAULT FALSE;
  DECLARE base_has_summary BOOL DEFAULT FALSE;
  DECLARE base_has_var_archive BOOL DEFAULT FALSE;
  DECLARE diff_rcv_mapping_present BOOL DEFAULT FALSE;
  DECLARE diff_rcv_accession_present BOOL DEFAULT FALSE;
  DECLARE diff_var_archive_present BOOL DEFAULT FALSE;
  DECLARE scv_changed_present BOOL DEFAULT FALSE;
  DECLARE scv_removed_present BOOL DEFAULT FALSE;
  DECLARE all_drivers_present BOOL DEFAULT FALSE;
  DECLARE q STRING;

  FOR rec IN (SELECT s.schema_name FROM `clinvar_ingest.schema_on`(on_date) AS s)
  DO
    SET base_schema = (SELECT schema_name FROM `clinvar_ingest.schema_on`(
                        (SELECT prev_release_date FROM `clinvar_ingest.schema_on`(on_date))));

    -- Structural presence checks: current-release diff drivers + changed-set tables.
    EXECUTE IMMEDIATE FORMAT(
      "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'diff_rcv_mapping'",
      rec.schema_name) INTO diff_rcv_mapping_present;
    EXECUTE IMMEDIATE FORMAT(
      "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'diff_rcv_accession'",
      rec.schema_name) INTO diff_rcv_accession_present;
    EXECUTE IMMEDIATE FORMAT(
      "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'diff_variation_archive'",
      rec.schema_name) INTO diff_var_archive_present;
    EXECUTE IMMEDIATE FORMAT(
      "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'scv_changed_ids'",
      rec.schema_name) INTO scv_changed_present;
    EXECUTE IMMEDIATE FORMAT(
      "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'scv_removed_ids'",
      rec.schema_name) INTO scv_removed_present;

    -- Baseline membership tables (needed for the current+baseline UNION arms).
    IF base_schema IS NOT NULL THEN
      EXECUTE IMMEDIATE FORMAT(
        "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'rcv_mapping'",
        base_schema) INTO base_has_rcv_mapping;
      EXECUTE IMMEDIATE FORMAT(
        "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'scv_summary'",
        base_schema) INTO base_has_summary;
      EXECUTE IMMEDIATE FORMAT(
        "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'variation_archive'",
        base_schema) INTO base_has_var_archive;
    END IF;

    -- All-or-nothing gate: require the FULL required-driver set; if ANY is missing,
    -- take the everything-impacted fallback (safe: incremental degrades to full).
    SET all_drivers_present =
      diff_rcv_mapping_present AND diff_rcv_accession_present AND diff_var_archive_present
      AND scv_changed_present AND scv_removed_present
      AND base_schema IS NOT NULL AND base_has_rcv_mapping AND base_has_summary
      AND base_has_var_archive;

    IF NOT all_drivers_present THEN
      -- First run / no usable baseline / any required driver missing:
      -- everything impacted (recompute all parents = full rebuild).
      EXECUTE IMMEDIATE FORMAT(
        "CREATE OR REPLACE TABLE `%s.rcv_impacted_ids` AS SELECT DISTINCT id AS rcv_accession FROM `%s.rcv_accession`",
        rec.schema_name, rec.schema_name);
      EXECUTE IMMEDIATE FORMAT(
        "CREATE OR REPLACE TABLE `%s.vcv_impacted_ids` AS SELECT DISTINCT id AS vcv_accession FROM `%s.variation_archive`",
        rec.schema_name, rec.schema_name);
    ELSE
      -- ---------------------------------------------------------------------
      -- rcv_impacted_ids — membership (cur+base) ∪ mapping-diff ∪ accession-diff,
      -- minus RCVs absent from current rcv_accession (removed). Semi-join to
      -- current is naturally NULL-safe (a NULL rcv_accession never matches IN).
      -- ---------------------------------------------------------------------
      SET q = """
        CREATE OR REPLACE TABLE `{S}.rcv_impacted_ids` AS
        WITH member_scvs AS (
          SELECT scv_id FROM `{S}.scv_changed_ids`
          UNION DISTINCT
          SELECT scv_id FROM `{S}.scv_removed_ids`
        ),
        u AS (
          -- (1) membership via CURRENT rcv_mapping
          SELECT rm.rcv_accession
          FROM `{S}.rcv_mapping` rm, UNNEST(rm.scv_accessions) AS scv
          WHERE scv IN (SELECT scv_id FROM member_scvs)
          -- (1) membership via BASELINE rcv_mapping (old parent of a re-assigned SCV)
          UNION DISTINCT
          SELECT rm.rcv_accession
          FROM `{BASE}.rcv_mapping` rm, UNNEST(rm.scv_accessions) AS scv
          WHERE scv IN (SELECT scv_id FROM member_scvs)
          -- (2) RCV membership/trait_set changed
          UNION DISTINCT
          SELECT rcv_accession
          FROM `{S}.diff_rcv_mapping`
          WHERE change_type <> 'exact_match'
          -- (3) RCV's own accession record changed (NOT 'removed' — [id,version] trap)
          UNION DISTINCT
          SELECT id AS rcv_accession
          FROM `{S}.diff_rcv_accession`
          WHERE change_type IN ('new','modified')
        )
        SELECT DISTINCT u.rcv_accession
        FROM u
        WHERE u.rcv_accession IN (SELECT id FROM `{S}.rcv_accession`)
      """;
      SET q = REPLACE(q, '{BASE}', base_schema);
      SET q = REPLACE(q, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE q;

      -- ---------------------------------------------------------------------
      -- vcv_impacted_ids — member-SCV variation (cur+base) mapped to VCV over
      -- cur+base variation_archive ∪ archive-diff, minus VCVs absent from current
      -- variation_archive (removed). Semi-join to current is NULL-safe.
      -- ---------------------------------------------------------------------
      SET q = """
        CREATE OR REPLACE TABLE `{S}.vcv_impacted_ids` AS
        WITH member_scvs AS (
          SELECT scv_id FROM `{S}.scv_changed_ids`
          UNION DISTINCT
          SELECT scv_id FROM `{S}.scv_removed_ids`
        ),
        member_variation_ids AS (
          -- member SCVs' variation_id over CURRENT scv_summary
          SELECT ss.variation_id
          FROM `{S}.scv_summary` ss
          WHERE ss.id IN (SELECT scv_id FROM member_scvs) AND ss.variation_id IS NOT NULL
          -- member SCVs' variation_id over BASELINE scv_summary (removed SCV's variation)
          UNION DISTINCT
          SELECT ss.variation_id
          FROM `{BASE}.scv_summary` ss
          WHERE ss.id IN (SELECT scv_id FROM member_scvs) AND ss.variation_id IS NOT NULL
        ),
        u AS (
          -- (1) variation_id -> VCV over CURRENT variation_archive
          SELECT va.id AS vcv_accession
          FROM `{S}.variation_archive` va
          WHERE va.variation_id IN (SELECT variation_id FROM member_variation_ids)
          -- (1) variation_id -> VCV over BASELINE variation_archive
          UNION DISTINCT
          SELECT va.id AS vcv_accession
          FROM `{BASE}.variation_archive` va
          WHERE va.variation_id IN (SELECT variation_id FROM member_variation_ids)
          -- (2) VCV's own variation_archive record changed (NOT 'removed' — [id,version] trap)
          UNION DISTINCT
          SELECT id AS vcv_accession
          FROM `{S}.diff_variation_archive`
          WHERE change_type IN ('new','modified')
        )
        SELECT DISTINCT u.vcv_accession
        FROM u
        WHERE u.vcv_accession IN (SELECT id FROM `{S}.variation_archive`)
      """;
      SET q = REPLACE(q, '{BASE}', base_schema);
      SET q = REPLACE(q, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE q;
    END IF;
  END FOR;
END;
