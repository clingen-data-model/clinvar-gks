-- ============================================================================
-- gks_scv_changed — shared per-release SCV changed/removed sets + change audit
-- ============================================================================
-- Computes, once per release, the single consistent set of SCVs that every
-- incremental downstream GKS SCV proc (gks_scv_condition, gks_scv_statement) and
-- Plan 3's aggregate cascade consume. Writes three persistent {S} tables:
--
--   {S}.scv_removed_ids(scv_id)                 -- diff_clinical_assertion removed
--   {S}.scv_changed_ids(scv_id)                 -- new|modified ∪ trait-driven,
--                                                  minus removed  (per-SCV recompute set)
--   {S}.gks_scv_change_audit(...)               -- reason classifier for modified SCVs
--       scv_id STRING, baseline_release DATE, compare_release DATE,
--       version_changed BOOL, review_status_changed BOOL, unexplained BOOL
--
-- Every per-SCV output is derived from that one SCV's own record, so any
-- byte-modified SCV can change its own output — recompute the full new|modified set
-- (the version/review_status refinement in the audit is for Plan 3's aggregate
-- cascade, not to shrink this per-SCV set).
--
-- Trait-driven SCVs (the trait-content cascade): a trait/trait_set edit changes
-- gks_scv_condition_sets' normalized fields (normalized_match/normalized_resolution/
-- mapping) with NO SCV version bump, and gks_dict_scv/gks_dict_evidence_line embed
-- that struct. So scv_changed_ids must add SCVs that reference a changed
-- trait/traitset. The per-SCV trait linkage is the CLINVAR trait id embedded in the
-- condition pointers of {base}.gks_scv_condition_sets — NOT the submitted medgen_id
-- (a submitted MedGen 'C…' id, a different keyspace that never matches diff_trait.id).
--
--   Trait-id-bearing fields chosen (verified against the live schema + data):
--     multi-condition  extensions.value_submitted_condition_set.concepts[]:
--         .normalized_match  '#/condition/clinvar.trait:{id}'  (always populated)
--         .direct_match      '#/condition/clinvar.trait:{id}'  (populated when mapped≠normalized)
--     multi-condition  extensions.value_submitted_condition_set.conditionSet:
--                          '#/conditionSet/clinvar.traitset:{id}'
--     single-condition extensions.value_submitted_condition (NON-array struct):
--         .normalized_match  '#/condition/clinvar.trait:{id}'  (always populated)
--         .direct_match      '#/condition/clinvar.trait:{id}'
--         .conditionSet      '#/conditionSet/clinvar.traitset:{id}'  (usually null for singles)
--   normalized_match is the reliably-populated field (proc line ~913,
--   FORMAT('#/condition/clinvar.trait:%s', normalized_trait_id)); direct_match and the
--   conditionSet arms are added for completeness. BOTH the multi-condition concepts[]
--   UNNEST AND the single-condition non-array struct are covered — a concepts-only
--   UNNEST silently drops every single-condition SCV.
--   Clinvar ids are parsed with REGEXP_EXTRACT(field, r'clinvar\.trait:(.+)$') /
--   r'clinvar\.traitset:(.+)$' and matched to {S}.diff_trait.id / {S}.diff_trait_set.id.
--   The baseline condition_sets are used (not current): current isn't built yet when
--   this runs, and only UNCHANGED SCVs referencing a changed trait are the concern —
--   those exist in the baseline (new/modified SCVs are already covered).
--
-- Baseline = nearest existing prior release (schema_on(prev_release_date)).
-- FIRST RUN / no usable baseline (baseline missing, base lacks scv_summary, or
-- diff_clinical_assertion absent): scv_changed_ids = ALL scv ids from {S}.scv_summary,
-- scv_removed_ids empty, gks_scv_change_audit empty. If diff_trait/diff_trait_set or
-- {base}.gks_scv_condition_sets are absent, the trait-driven arm is skipped.
-- ============================================================================

CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_scv_changed`(on_date DATE)
BEGIN
  DECLARE base_schema STRING;
  DECLARE base_rel DATE;
  DECLARE cur_rel DATE;
  DECLARE base_has_summary BOOL DEFAULT FALSE;
  DECLARE base_has_condsets BOOL DEFAULT FALSE;
  DECLARE diff_ca_present BOOL DEFAULT FALSE;
  DECLARE diff_trait_present BOOL DEFAULT FALSE;
  DECLARE diff_trait_set_present BOOL DEFAULT FALSE;
  DECLARE trait_arm STRING;
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
    IF base_schema IS NOT NULL THEN
      EXECUTE IMMEDIATE FORMAT(
        "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'scv_summary'",
        base_schema) INTO base_has_summary;
      EXECUTE IMMEDIATE FORMAT(
        "SELECT COUNT(*) = 1 FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'gks_scv_condition_sets'",
        base_schema) INTO base_has_condsets;
    END IF;

    IF base_schema IS NULL OR NOT diff_ca_present OR NOT base_has_summary THEN
      -- First run / no usable baseline: everything changed, nothing removed, no audit.
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
      -- scv_removed_ids
      -- ---------------------------------------------------------------------
      EXECUTE IMMEDIATE FORMAT(
        "CREATE OR REPLACE TABLE `%s.scv_removed_ids` AS SELECT id AS scv_id FROM `%s.diff_clinical_assertion` WHERE change_type = 'removed'",
        rec.schema_name, rec.schema_name);

      -- ---------------------------------------------------------------------
      -- gks_scv_change_audit — classify each MODIFIED SCV by reason
      -- ---------------------------------------------------------------------
      SET q = """
        CREATE OR REPLACE TABLE `{S}.gks_scv_change_audit` AS
        SELECT
          d.id AS scv_id,
          DATE '{BREL}' AS baseline_release,
          DATE '{CREL}' AS compare_release,
          (cur.version IS DISTINCT FROM base.version) AS version_changed,
          (cur.review_status IS DISTINCT FROM base.review_status) AS review_status_changed,
          (NOT (cur.version IS DISTINCT FROM base.version)
             AND NOT (cur.review_status IS DISTINCT FROM base.review_status)) AS unexplained
        FROM `{S}.diff_clinical_assertion` d
        JOIN `{S}.scv_summary` cur ON cur.id = d.id
        LEFT JOIN `{BASE}.scv_summary` base ON base.id = d.id
        WHERE d.change_type = 'modified'
      """;
      SET q = REPLACE(q, '{BREL}', CAST(base_rel AS STRING));
      SET q = REPLACE(q, '{CREL}', CAST(cur_rel AS STRING));
      SET q = REPLACE(q, '{BASE}', base_schema);
      SET q = REPLACE(q, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE q;

      -- ---------------------------------------------------------------------
      -- scv_changed_ids = diff_clinical_assertion(new|modified)
      --                   ∪ trait-driven SCVs, minus scv_removed_ids
      -- ---------------------------------------------------------------------
      -- Each arm is a top-level (uncorrelated) query: the concepts[] UNNEST is a
      -- FROM cross join and the changed-trait id sets are uncorrelated IN subqueries.
      -- (A correlated IN inside EXISTS(UNNEST(...)) can't be de-correlated by BQ.)
      SET trait_arm = "";
      IF diff_trait_present AND diff_trait_set_present AND base_has_condsets THEN
        SET trait_arm = """
          -- multi-condition concepts[] (clinvar.trait pointers)
          UNION DISTINCT
          SELECT cs.scv_id
          FROM `{BASE}.gks_scv_condition_sets` cs,
               UNNEST(cs.extensions.value_submitted_condition_set.concepts) c
          WHERE REGEXP_EXTRACT(c.normalized_match, r'clinvar\\.trait:(.+)$')
                  IN (SELECT id FROM `{S}.diff_trait` WHERE change_type IN ('new','modified','removed'))
             OR REGEXP_EXTRACT(c.direct_match, r'clinvar\\.trait:(.+)$')
                  IN (SELECT id FROM `{S}.diff_trait` WHERE change_type IN ('new','modified','removed'))
          -- multi-condition conditionSet (clinvar.traitset pointer)
          UNION DISTINCT
          SELECT cs.scv_id
          FROM `{BASE}.gks_scv_condition_sets` cs
          WHERE REGEXP_EXTRACT(cs.extensions.value_submitted_condition_set.conditionSet, r'clinvar\\.traitset:(.+)$')
                  IN (SELECT id FROM `{S}.diff_trait_set` WHERE change_type IN ('new','modified','removed'))
          -- single-condition (NON-array struct): trait + traitset pointers
          UNION DISTINCT
          SELECT cs.scv_id
          FROM `{BASE}.gks_scv_condition_sets` cs
          WHERE REGEXP_EXTRACT(cs.extensions.value_submitted_condition.normalized_match, r'clinvar\\.trait:(.+)$')
                  IN (SELECT id FROM `{S}.diff_trait` WHERE change_type IN ('new','modified','removed'))
             OR REGEXP_EXTRACT(cs.extensions.value_submitted_condition.direct_match, r'clinvar\\.trait:(.+)$')
                  IN (SELECT id FROM `{S}.diff_trait` WHERE change_type IN ('new','modified','removed'))
             OR REGEXP_EXTRACT(cs.extensions.value_submitted_condition.conditionSet, r'clinvar\\.traitset:(.+)$')
                  IN (SELECT id FROM `{S}.diff_trait_set` WHERE change_type IN ('new','modified','removed'))
        """;
      END IF;

      SET q = """
        CREATE OR REPLACE TABLE `{S}.scv_changed_ids` AS
        WITH u AS (
          SELECT id AS scv_id
          FROM `{S}.diff_clinical_assertion`
          WHERE change_type IN ('new','modified')
          {TRAIT_ARM}
        )
        SELECT DISTINCT scv_id
        FROM u
        WHERE scv_id NOT IN (SELECT scv_id FROM `{S}.scv_removed_ids`)
      """;
      SET q = REPLACE(q, '{TRAIT_ARM}', trait_arm);
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
