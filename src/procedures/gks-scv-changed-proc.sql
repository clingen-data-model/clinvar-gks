-- ============================================================================
-- gks_scv_changed — shared per-release SCV changed/removed sets + change audit
-- ============================================================================
-- Computes, once per release, the single consistent set of SCVs that every
-- incremental downstream GKS SCV proc (gks_scv_condition, gks_scv_statement) and
-- Plan 3's aggregate cascade consume. Writes three persistent {S} tables:
--
--   {S}.scv_removed_ids(scv_id)                 -- diff_clinical_assertion removed
--   {S}.scv_changed_ids(scv_id)                 -- new|modified ∪ submitted-side ∪
--                                                  trait-content ∪ rcv-mapping,
--                                                  minus removed  (per-SCV recompute set)
--   {S}.gks_scv_change_audit(...)               -- version/review-status classifier
--       scv_id STRING, baseline_release DATE, compare_release DATE,
--       version_changed BOOL, review_status_changed BOOL, unexplained BOOL
--
-- Every per-SCV output is derived from that one SCV's own record, so any
-- byte-modified SCV can change its own output — recompute the full new|modified set
-- (the version/review_status refinement in the audit is for Plan 3's aggregate
-- cascade, not to shrink this per-SCV set). But gks_scv_condition_sets' condition
-- resolution ALSO depends on shared inputs (trait / trait_set / trait_mapping /
-- clinical_assertion_trait / rcv_mapping), so an SCV whose clinical_assertion is
-- byte-identical (change_type='exact_match', NOT in diff_clinical_assertion) can
-- still change output. The cascade arms below add those SCVs. gks_dict_scv /
-- gks_dict_evidence_line embed the resulting struct, so this cascade is load-bearing
-- for them too — folding all impacted SCVs into this one shared set recomputes all.
--
-- Trait-content cascade — keyed on the ACTUAL resolution inputs (gks-scv-condition-
-- proc.sql STEP 7-8), NOT on baseline output pointers. Baseline pointers cannot see
-- a NEW trait attaching to an otherwise-unchanged SCV (the original 4056→1 bug): e.g.
-- SCV000833724 gained mapped_trait_id when new trait 25997 (medgen C1851936) matched
-- its trait_mapping.medgen_id, yet its baseline pointer still read clinvar.trait:3280.
-- The two resolutions:
--   mapped_trait_id  (proc :754-761): trait matched by medgen on lookup_medgen_id =
--     COALESCE(trait_mapping.medgen_id, clinical_assertion_trait.medgen_id), where
--     cat_medgen_id = IFNULL(medgen.code, cat.medgen_id) and medgen.code = UPPER(xref.id)
--     for a MedGen/UMLS xref (proc :487-488,522).
--     -> add SCVs whose mapped/submitted medgen = a CHANGED trait's medgen_id — matching
--        BOTH the clinical_assertion_trait.medgen_id column AND MedGen/UMLS xref-derived
--        medgen (changed medgens: cur trait for new/modified, base trait for removed).
--     NB this is trait.medgen_id ↔ SCV medgen — the CORRECT keyspace; it is NOT the
--     rejected "diff_trait.id vs submitted MedGen 'C…' id" join.
--   normalized_trait_id (proc :791-849): resolved from the RCV trait set
--     (temp_all_rcv_traits, keyed rcv_mapping.trait_set_id -> trait_set.trait_ids).
--     -> add SCVs (via rcv_mapping.scv_accessions) whose RCV trait_set contains a
--        changed trait, or whose RCV trait_set itself changed (diff_trait_set).
--
-- Submitted-side cascade (an SCV's OWN submitted trait rows changed while the
-- clinical_assertion bytes did not):
--   trait_mapping cascade: {S}.diff_trait_mapping (distinct-row diff) — its
--     record_key JSON carries clinical_assertion_id (= scv id):
--     JSON_VALUE(record_key,'$.clinical_assertion_id'), non-exact rows.
--   clinical_assertion_trait cascade: {S}.diff_clinical_assertion_trait (keyed id) —
--     its id is '{scv}.{n}' (proc reads via SPLIT(id,'.'), see gks-scv-condition-proc
--     :454-456), so scv = SPLIT(id,'.')[OFFSET(0)], non-exact rows.
--   clinical_assertion_trait_set cascade: {S}.diff_clinical_assertion_trait_set
--     (keyed id) — 1:1 with the SCV; its id IS the scv id (proc joins rmt.scv_id =
--     cats.id, :269,279-281), some carry a '.{n}' suffix so normalize via SPLIT.
--     Drives @multipleConditionExplanation (output) + cats_trait_count (STEP 9 gate).
--
-- All-or-nothing driver gate: dataset_diff_all wraps each table diff in an EXCEPTION
-- handler and continues, so a required diff_* can be silently absent. If ANY required
-- driver is missing (diff_clinical_assertion, diff_trait, diff_trait_set,
-- diff_trait_mapping, diff_clinical_assertion_trait, diff_clinical_assertion_trait_set,
-- diff_rcv_mapping, diff_submitter) we take the everything-changed fallback rather than
-- a partial set.
--
-- RCV-mapping cascade: an RCV whose mapping changed (diff_rcv_mapping non-exact) can
-- flip its SCVs' normalized assignment with no SCV/trait edit. Expand changed RCVs to
-- SCVs via rcv_mapping.scv_accessions from BOTH cur and base (membership moves).
--
-- Submitter cascade: gks_dict_scv embeds submitter.name INLINE in its classification
-- description (gks-scv-statement-proc.sql ~:763), sourced from the DENORMALIZED
-- scv_summary.submitter_name. A submitter RENAME (diff_submitter new/modified/removed)
-- changes that name for all its SCVs while their clinical_assertion stays byte-identical
-- (exact_match) — no other arm sees it, so gks_dict_scv/evidence_line would carry them
-- forward stale. Expand changed submitters to SCVs via scv_summary.submitter_id.
--
-- diff_clinical_assertion is keyed on ['id','version'], so a VERSION BUMP shows the
-- same scv_id as BOTH change_type='new' (id.newver) AND 'removed' (id.oldver). Thus
-- scv_removed_ids must be TRULY-GONE = removed EXCEPT DISTINCT (new ∪ modified);
-- otherwise version-bumped (still-live) SCVs get anti-joined out of scv_changed_ids
-- and vanish from both carry-forward and staging.
--
-- Change audit: because version changes never surface as change_type='modified'
-- (they are new+removed under the id,version key), the audit is computed over the
-- whole scv_changed_ids set by joining {S}.scv_summary cur vs {base}.scv_summary base
-- ON id: version_changed = cur.version IS DISTINCT FROM base.version,
-- review_status_changed likewise, unexplained = present-in-both AND neither changed.
--
-- Baseline = nearest existing prior release (schema_on(prev_release_date)).
-- FIRST RUN / no usable baseline (baseline missing, base lacks scv_summary, or ANY
-- required diff driver absent — see the all-or-nothing gate above): scv_changed_ids =
-- ALL scv ids from {S}.scv_summary, scv_removed_ids empty, gks_scv_change_audit empty.
-- The per-arm *_present guards remain only as defense-in-depth on the incremental path.
-- ============================================================================

CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_scv_changed`(on_date DATE)
BEGIN
  DECLARE base_schema STRING;
  DECLARE base_rel DATE;
  DECLARE cur_rel DATE;
  DECLARE base_has_summary BOOL DEFAULT FALSE;
  DECLARE diff_ca_present BOOL DEFAULT FALSE;
  DECLARE diff_trait_present BOOL DEFAULT FALSE;
  DECLARE diff_trait_set_present BOOL DEFAULT FALSE;
  DECLARE diff_trait_mapping_present BOOL DEFAULT FALSE;
  DECLARE diff_cat_present BOOL DEFAULT FALSE;
  DECLARE diff_cats_present BOOL DEFAULT FALSE;
  DECLARE diff_rcv_mapping_present BOOL DEFAULT FALSE;
  DECLARE diff_submitter_present BOOL DEFAULT FALSE;
  DECLARE all_drivers_present BOOL DEFAULT FALSE;
  DECLARE content_ctes STRING;
  DECLARE content_arm STRING;
  DECLARE submitted_arm STRING;
  DECLARE rcvmap_arm STRING;
  DECLARE submitter_arm STRING;
  DECLARE q STRING;

  FOR rec IN (SELECT s.schema_name FROM `clinvar_ingest.schema_on`(on_date) AS s)
  DO
    SET base_schema = (SELECT schema_name FROM `clinvar_ingest.schema_on`(
                        (SELECT prev_release_date FROM `clinvar_ingest.schema_on`(on_date))));
    SET base_rel = (SELECT release_date FROM `clinvar_ingest.schema_on`(
                      (SELECT prev_release_date FROM `clinvar_ingest.schema_on`(on_date))));
    SET cur_rel = (SELECT release_date FROM `clinvar_ingest.schema_on`(on_date));

    -- Structural presence checks (current release drivers + baseline tables).
    EXECUTE IMMEDIATE FORMAT(
      "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'diff_clinical_assertion'",
      rec.schema_name) INTO diff_ca_present;
    EXECUTE IMMEDIATE FORMAT(
      "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'diff_trait'",
      rec.schema_name) INTO diff_trait_present;
    EXECUTE IMMEDIATE FORMAT(
      "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'diff_trait_set'",
      rec.schema_name) INTO diff_trait_set_present;
    EXECUTE IMMEDIATE FORMAT(
      "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'diff_trait_mapping'",
      rec.schema_name) INTO diff_trait_mapping_present;
    EXECUTE IMMEDIATE FORMAT(
      "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'diff_clinical_assertion_trait'",
      rec.schema_name) INTO diff_cat_present;
    EXECUTE IMMEDIATE FORMAT(
      "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'diff_clinical_assertion_trait_set'",
      rec.schema_name) INTO diff_cats_present;
    EXECUTE IMMEDIATE FORMAT(
      "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'diff_rcv_mapping'",
      rec.schema_name) INTO diff_rcv_mapping_present;
    EXECUTE IMMEDIATE FORMAT(
      "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'diff_submitter'",
      rec.schema_name) INTO diff_submitter_present;
    IF base_schema IS NOT NULL THEN
      EXECUTE IMMEDIATE FORMAT(
        "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'scv_summary'",
        base_schema) INTO base_has_summary;
    END IF;

    -- All-or-nothing gate: dataset_diff_all wraps each table diff in an EXCEPTION
    -- handler and CONTINUES on failure, so a single diff_* can be absent while others
    -- exist. A per-arm skip would then silently produce a partial (wrong-looking-valid)
    -- changed set. So require the FULL required-driver set; if ANY is missing, take the
    -- everything-changed fallback (same safe path as no-baseline). Per-arm guards below
    -- remain as defense-in-depth.
    SET all_drivers_present =
      diff_ca_present AND diff_trait_present AND diff_trait_set_present
      AND diff_trait_mapping_present AND diff_cat_present AND diff_cats_present
      AND diff_rcv_mapping_present AND diff_submitter_present;

    IF base_schema IS NULL OR NOT base_has_summary OR NOT all_drivers_present THEN
      -- First run / no usable baseline / any required diff driver missing:
      -- everything changed, nothing removed, no audit (safe conservative fallback).
      EXECUTE IMMEDIATE FORMAT(
        "CREATE OR REPLACE TABLE `%s.scv_changed_ids` AS SELECT id AS scv_id FROM `%s.scv_summary`",
        rec.schema_name, rec.schema_name);
      EXECUTE IMMEDIATE FORMAT(
        "CREATE OR REPLACE TABLE `%s.scv_removed_ids` AS SELECT id AS scv_id FROM `%s.scv_summary` WHERE FALSE",
        rec.schema_name, rec.schema_name);
      EXECUTE IMMEDIATE FORMAT("""
        CREATE OR REPLACE TABLE `%s.gks_scv_change_audit` (
          scv_id               STRING,
          baseline_release     DATE,
          compare_release      DATE,
          version_changed      BOOL,
          review_status_changed BOOL,
          unexplained          BOOL
        )
      """, rec.schema_name);
    ELSE
      -- ---------------------------------------------------------------------
      -- scv_removed_ids = TRULY-GONE = removed EXCEPT (new ∪ modified).
      -- diff_clinical_assertion is keyed on [id,version]: a version bump appears as
      -- both 'removed' (old ver) and 'new' (new ver) for the same scv_id, so a plain
      -- 'removed' filter would sweep in still-live version-bumped SCVs.
      -- ---------------------------------------------------------------------
      SET q = """
        CREATE OR REPLACE TABLE `{S}.scv_removed_ids` AS
        SELECT id AS scv_id FROM `{S}.diff_clinical_assertion` WHERE change_type = 'removed'
        EXCEPT DISTINCT
        SELECT id FROM `{S}.diff_clinical_assertion` WHERE change_type IN ('new','modified')
      """;
      SET q = REPLACE(q, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE q;

      -- ---------------------------------------------------------------------
      -- scv_changed_ids = diff_clinical_assertion(new|modified)
      --   ∪ submitted-side ∪ trait-content ∪ rcv-mapping SCVs, minus scv_removed_ids
      -- ---------------------------------------------------------------------
      -- The trait-content cascade keys on the ACTUAL resolution inputs of
      -- gks_scv_condition_sets (see gks-scv-condition-proc.sql STEP 7-8), NOT on the
      -- baseline output pointers (which can't see a NEW trait attaching to an
      -- otherwise-unchanged SCV). The two resolutions and their inputs:
      --   mapped_trait_id  (proc :754-761): trait matched by medgen on
      --     lookup_medgen_id = COALESCE(trait_mapping.medgen_id, clinical_assertion_trait.medgen_id).
      --     -> add SCVs whose mapped/submitted medgen equals a CHANGED trait's medgen_id
      --        (changed trait medgens read from cur trait for new/modified + base trait for removed).
      --   normalized_trait_id (proc :791-849): resolved from the RCV trait set
      --     (temp_all_rcv_traits, keyed on rcv_mapping.trait_set_id -> trait_set.trait_ids).
      --     -> add SCVs (via rcv_mapping.scv_accessions) whose RCV trait_set contains a
      --        changed trait, or whose RCV trait_set itself changed (diff_trait_set).
      -- All arms are top-level (uncorrelated) UNION DISTINCT selects; the id sets are
      -- factored into CTEs so change_type lists are one-line edits. Emitted only when
      -- diff_trait + diff_trait_set are present.
      SET content_ctes = "";
      SET content_arm = "";
      IF diff_trait_present AND diff_trait_set_present THEN
        SET content_ctes = """
          changed_trait_ids AS (
            SELECT id FROM `{S}.diff_trait` WHERE change_type IN ('new','modified','removed')
          ),
          changed_traitset_ids AS (
            SELECT id FROM `{S}.diff_trait_set` WHERE change_type IN ('new','modified','removed')
          ),
          changed_trait_medgen AS (
            SELECT DISTINCT medgen_id FROM `{S}.trait`
            WHERE id IN (SELECT id FROM changed_trait_ids) AND medgen_id IS NOT NULL
            UNION DISTINCT
            SELECT DISTINCT medgen_id FROM `{BASE}.trait`
            WHERE id IN (SELECT id FROM changed_trait_ids) AND medgen_id IS NOT NULL
          ),
          rcv_tsets_with_changed_trait AS (
            SELECT DISTINCT ts.id
            FROM `{S}.trait_set` ts, UNNEST(ts.trait_ids) tid
            WHERE tid IN (SELECT id FROM changed_trait_ids)
          ),
        """;
        SET content_arm = """
          -- mapped_trait_id: changed-trait medgen ↔ SCV mapped medgen (trait_mapping)
          UNION DISTINCT
          SELECT tm.clinical_assertion_id AS scv_id
          FROM `{S}.trait_mapping` tm
          WHERE tm.medgen_id IN (SELECT medgen_id FROM changed_trait_medgen)
          -- mapped_trait_id: changed-trait medgen ↔ SCV submitted medgen (clinical_assertion_trait)
          UNION DISTINCT
          SELECT SPLIT(cat.id, '.')[OFFSET(0)] AS scv_id
          FROM `{S}.clinical_assertion_trait` cat
          WHERE cat.medgen_id IN (SELECT medgen_id FROM changed_trait_medgen)
          -- mapped_trait_id: changed-trait medgen ↔ SCV MedGen/UMLS xref-derived medgen.
          -- cat_medgen_id = IFNULL(medgen.code, cat.medgen_id) where medgen.code =
          -- UPPER(xref.id) for db IN ('MedGen','UMLS') (proc :487-488,522). Covers SCVs
          -- with a NULL medgen_id column but a MedGen/UMLS xref to a changed trait.
          UNION DISTINCT
          SELECT SPLIT(cat.id, '.')[OFFSET(0)] AS scv_id
          FROM `{S}.clinical_assertion_trait` cat, UNNEST(cat.xrefs) x
          WHERE JSON_VALUE(x, '$.db') IN ('MedGen','UMLS')
            AND UPPER(JSON_VALUE(x, '$.id')) IN (SELECT medgen_id FROM changed_trait_medgen)
          -- normalized_trait_id: SCV's RCV trait_set contains a changed trait
          UNION DISTINCT
          SELECT scv AS scv_id
          FROM `{S}.rcv_mapping` rm, UNNEST(rm.scv_accessions) scv
          WHERE rm.trait_set_id IN (SELECT id FROM rcv_tsets_with_changed_trait)
          -- normalized_trait_id: SCV's RCV trait_set itself changed (diff_trait_set)
          UNION DISTINCT
          SELECT scv AS scv_id
          FROM `{S}.rcv_mapping` rm, UNNEST(rm.scv_accessions) scv
          WHERE rm.trait_set_id IN (SELECT id FROM changed_traitset_ids)
        """;
      END IF;

      -- Submitted-side cascade: SCVs whose submitted-condition resolution changed
      -- (medgen_id / original_medgen_match) even though clinical_assertion is
      -- byte-identical. Each arm guarded on its own diff table's presence.
      SET submitted_arm = "";
      IF diff_trait_mapping_present THEN
        SET submitted_arm = submitted_arm || """
          -- trait_mapping changed -> scv via record_key JSON clinical_assertion_id
          UNION DISTINCT
          SELECT JSON_VALUE(record_key, '$.clinical_assertion_id') AS scv_id
          FROM `{S}.diff_trait_mapping`
          WHERE change_type <> 'exact_match'
        """;
      END IF;
      IF diff_cat_present THEN
        SET submitted_arm = submitted_arm || """
          -- clinical_assertion_trait changed -> scv via id prefix ('{scv}.{n}')
          UNION DISTINCT
          SELECT SPLIT(id, '.')[OFFSET(0)] AS scv_id
          FROM `{S}.diff_clinical_assertion_trait`
          WHERE change_type <> 'exact_match'
        """;
      END IF;
      IF diff_cats_present THEN
        SET submitted_arm = submitted_arm || """
          -- clinical_assertion_trait_set changed -> scv. Its id IS the scv id
          -- (temp_gks_scv_trait_sets joins rmt.scv_id = cats.id, proc :269,279-281);
          -- some ids carry a '.{n}' version suffix, so normalize via SPLIT. Drives
          -- @multipleConditionExplanation (output extension) + cats_trait_count (STEP 9).
          UNION DISTINCT
          SELECT SPLIT(id, '.')[OFFSET(0)] AS scv_id
          FROM `{S}.diff_clinical_assertion_trait_set`
          WHERE change_type <> 'exact_match'
        """;
      END IF;

      -- RCV-mapping cascade: normalized resolution reads the RCV trait set via
      -- rcv_mapping; an RCV whose mapping changed (scv membership / trait_set_id)
      -- can flip its SCVs' normalized assignment with no SCV/trait edit. Expand
      -- changed RCVs to SCVs from BOTH cur and base rcv_mapping (membership moves).
      SET rcvmap_arm = "";
      IF diff_rcv_mapping_present THEN
        SET rcvmap_arm = """
          UNION DISTINCT
          SELECT scv AS scv_id
          FROM `{S}.rcv_mapping` rm, UNNEST(rm.scv_accessions) scv
          WHERE rm.rcv_accession IN (SELECT rcv_accession FROM `{S}.diff_rcv_mapping` WHERE change_type <> 'exact_match')
          UNION DISTINCT
          SELECT scv AS scv_id
          FROM `{BASE}.rcv_mapping` rm, UNNEST(rm.scv_accessions) scv
          WHERE rm.rcv_accession IN (SELECT rcv_accession FROM `{S}.diff_rcv_mapping` WHERE change_type <> 'exact_match')
        """;
      END IF;

      -- Submitter cascade: gks_dict_scv embeds submitter.name INLINE in its
      -- classification description (gks-scv-statement-proc.sql ~:763), sourced from
      -- the DENORMALIZED scv_summary.submitter_name. A submitter RENAME changes that
      -- name for all the submitter's SCVs while their clinical_assertion stays
      -- byte-identical (diff_clinical_assertion=exact_match) — no other arm catches it,
      -- so gks_dict_scv/evidence_line would carry them forward stale. Expand changed
      -- submitters to their SCVs via scv_summary.submitter_id.
      SET submitter_arm = "";
      IF diff_submitter_present THEN
        SET submitter_arm = """
          UNION DISTINCT
          SELECT s.id AS scv_id
          FROM `{S}.scv_summary` s
          WHERE s.submitter_id IN (SELECT id FROM `{S}.diff_submitter` WHERE change_type IN ('new','modified','removed'))
        """;
      END IF;

      -- NULL-safe anti-join for "changed minus removed" (NOT IN goes UNKNOWN for
      -- all rows if any removed scv_id is NULL -> silently empty; mirrors
      -- variation-vrs-changed-proc.sql:74-81). Also drop any NULL scv_id a parse
      -- arm might yield.
      SET q = """
        CREATE OR REPLACE TABLE `{S}.scv_changed_ids` AS
        WITH {CONTENT_CTES}
        u AS (
          SELECT id AS scv_id
          FROM `{S}.diff_clinical_assertion`
          WHERE change_type IN ('new','modified')
          {CONTENT_ARM}
          {SUBMITTED_ARM}
          {RCVMAP_ARM}
          {SUBMITTER_ARM}
        )
        SELECT DISTINCT u.scv_id
        FROM u
        LEFT JOIN `{S}.scv_removed_ids` r ON r.scv_id = u.scv_id
        WHERE r.scv_id IS NULL
          AND u.scv_id IS NOT NULL
      """;
      SET q = REPLACE(q, '{CONTENT_CTES}', content_ctes);
      SET q = REPLACE(q, '{CONTENT_ARM}', content_arm);
      SET q = REPLACE(q, '{SUBMITTED_ARM}', submitted_arm);
      SET q = REPLACE(q, '{RCVMAP_ARM}', rcvmap_arm);
      SET q = REPLACE(q, '{SUBMITTER_ARM}', submitter_arm);
      SET q = REPLACE(q, '{BASE}', base_schema);
      SET q = REPLACE(q, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE q;

      -- ---------------------------------------------------------------------
      -- gks_scv_change_audit — version/review-status classifier over the whole
      -- changed set (Plan 3 consumes this). Computed by comparing scv_summary
      -- cur vs base ON id, since version bumps never appear as change_type='modified'.
      -- ---------------------------------------------------------------------
      SET q = """
        CREATE OR REPLACE TABLE `{S}.gks_scv_change_audit` AS
        SELECT
          ci.scv_id,
          DATE '{BREL}' AS baseline_release,
          DATE '{CREL}' AS compare_release,
          (cur.version IS DISTINCT FROM base.version) AS version_changed,
          (cur.review_status IS DISTINCT FROM base.review_status) AS review_status_changed,
          (base.id IS NOT NULL AND cur.id IS NOT NULL
             AND NOT (cur.version IS DISTINCT FROM base.version)
             AND NOT (cur.review_status IS DISTINCT FROM base.review_status)) AS unexplained
        FROM `{S}.scv_changed_ids` ci
        LEFT JOIN `{S}.scv_summary`    cur  ON cur.id  = ci.scv_id
        LEFT JOIN `{BASE}.scv_summary` base ON base.id = ci.scv_id
      """;
      SET q = REPLACE(q, '{BREL}', CAST(base_rel AS STRING));
      SET q = REPLACE(q, '{CREL}', CAST(cur_rel AS STRING));
      SET q = REPLACE(q, '{BASE}', base_schema);
      SET q = REPLACE(q, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE q;
    END IF;

    -- Surface the unexplained-modified count in the job output.
    EXECUTE IMMEDIATE FORMAT(
      "SELECT COUNT(*) AS unexplained_scv FROM `%s.gks_scv_change_audit` WHERE unexplained",
      rec.schema_name);
  END FOR;
END;
