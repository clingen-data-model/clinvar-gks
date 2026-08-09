-------------------------------------------------------------------------------
-- gks_rcv — build the three RCV aggregation-layer outputs from a release:
--   gks_rcv_classification_agg   (from temp_rcv_base_data + gks_scv_condition_sets)
--   gks_rcv_priority_agg         (reads gks_rcv_classification_agg)
--   gks_rcv_aggregate_contribution (reads BOTH prior agg tables)
--
-- Three entry points:
--   gks_rcv_proc(on_date, debug)              -> full rebuild (unchanged behavior)
--   gks_rcv_proc_incremental(on_date, debug)  -> incremental (carry-forward + merge)
--   gks_rcv_build(on_date, debug, incremental) -> internal implementation
--
-- Incremental strategy (see docs/superpowers/plans/2026-08-08-incremental-gks-
-- downstream-plan-3-rcv-vcv.md, Chunk 2):
--   All three outputs are per-RCV-parent (every row carries rcv_accession). Only the
--   RCV parents impacted by this release are recomputed; the rest are carried forward
--   from the baseline release. The impacted-parent set is the persistent {S} table
--   rcv_impacted_ids produced by gks_rcvvcv_changed (membership-first over
--   scv_changed_ids ∪ scv_removed_ids plus rcv_mapping / rcv_accession diffs).
--
--   Chained-layer read source (the incremental trap): priority reads classification
--   and aggregate reads BOTH. In incremental mode the whole chain is recomputed
--   impacted-only into {P}.stg_gks_rcv_* and each layer reads the PRIOR layer's stg
--   table (NOT {S}.*), so the chain is impacted-consistent regardless of merge order.
--   Each stg table is then UNION-CTAS-merged into {S}: carry forward the baseline rows
--   whose rcv_accession is NOT impacted AND still present in {S}.rcv_accession (so a
--   removed RCV is not resurrected), UNION ALL the freshly recomputed impacted rows.
--   Correctness note: every aggregation in all three layers groups/partitions by
--   rcv_accession (per-parent), so recomputing an impacted subset yields byte-identical
--   rows to a full build filtered to that subset. The single global subquery
--   (MIN(prop_display_order) GROUP BY prop_type in the aggregate layer) is constant per
--   prop_type (proposition_types.code -> display_order is 1:1), so it is invariant to
--   the parent subset.
--
--   Version-invalidation: the guard falls back to a full rebuild when the baseline is
--   missing/incomplete, the impacted set / required inputs are absent, or the pipeline
--   gate_key mismatches. Call the *_incremental wrapper only when carry-forward is safe.
-------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_rcv_build`(on_date DATE, debug BOOL, incremental BOOL)
BEGIN
  DECLARE query_base STRING;
  DECLARE query_classification STRING;
  DECLARE query_priority STRING;
  DECLARE query_agg_contribution STRING;
  DECLARE query_merge STRING;
  DECLARE temp_create STRING;

  -- incremental control / fallback guard
  DECLARE eff_incremental BOOL DEFAULT FALSE;
  DECLARE baseline_schema STRING DEFAULT NULL;
  DECLARE base_ok BOOL DEFAULT FALSE;
  DECLARE diff_ok BOOL DEFAULT FALSE;
  DECLARE gate_ok BOOL DEFAULT FALSE;
  DECLARE stamps_exist BOOL DEFAULT FALSE;

  -- mode-dependent fragments ('' / real-table targets in full mode)
  DECLARE pfilter STRING;         -- temp_rcv_base_data parent filter
  DECLARE class_head STRING;      -- classification target (real table vs stg temp)
  DECLARE priority_head STRING;   -- priority target
  DECLARE agg_head STRING;        -- aggregate target
  DECLARE class_src STRING;       -- classification read source (used by priority + aggregate)
  DECLARE priority_src STRING;    -- priority read source (used by aggregate)

  IF debug THEN
    SET temp_create = 'CREATE OR REPLACE TABLE';
  ELSE
    SET temp_create = 'CREATE TEMP TABLE';
  END IF;

  FOR rec IN (SELECT s.schema_name, s.prev_release_date FROM `clinvar_ingest.schema_on`(on_date) AS s)
  DO

    -----------------------------------------------------------------------
    -- Resolve baseline + fallback guard: incremental is only safe when the
    -- prior release exists with all three rcv agg outputs, the current release
    -- has the impacted-parent set + required inputs, AND the pipeline gate_key
    -- matches the baseline. Otherwise fall back to full.
    -----------------------------------------------------------------------
    SET eff_incremental = FALSE;
    SET baseline_schema = NULL;
    SET base_ok = FALSE;
    SET diff_ok = FALSE;
    SET gate_ok = FALSE;
    SET stamps_exist = FALSE;

    IF incremental AND rec.prev_release_date IS NOT NULL THEN
      SET baseline_schema = (
        SELECT s2.schema_name FROM `clinvar_ingest.schema_on`(rec.prev_release_date) AS s2 LIMIT 1
      );
    END IF;

    IF baseline_schema IS NOT NULL THEN
      -- baseline must have all 3 rcv agg outputs
      EXECUTE IMMEDIATE FORMAT("""
        SELECT (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES`
                WHERE table_name IN ('gks_rcv_classification_agg','gks_rcv_priority_agg',
                  'gks_rcv_aggregate_contribution')) = 3
      """, baseline_schema) INTO base_ok;

      -- current release must have the impacted-parent set + the aggregation inputs.
      EXECUTE IMMEDIATE FORMAT("""
        SELECT (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES`
                WHERE table_name IN ('rcv_impacted_ids','rcv_mapping','scv_summary',
                  'rcv_accession')) = 4
      """, rec.schema_name) INTO diff_ok;

      -- version gate — TWO statements. BigQuery resolves table refs at analysis time
      -- and does NOT short-circuit that resolution, so a single combined statement
      -- referencing {base}.gks_pipeline_version would ERROR (not return FALSE) when a
      -- pre-feature baseline lacks the stamp. First confirm both stamps exist; only
      -- then compare gate_key.
      EXECUTE IMMEDIATE FORMAT("""
        SELECT
          (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name='gks_pipeline_version')=1
          AND
          (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name='gks_pipeline_version')=1
      """, baseline_schema, rec.schema_name) INTO stamps_exist;
      IF stamps_exist THEN
        EXECUTE IMMEDIATE FORMAT("""
          SELECT (SELECT gate_key FROM `%s.gks_pipeline_version`)
               = (SELECT gate_key FROM `%s.gks_pipeline_version`)
        """, baseline_schema, rec.schema_name) INTO gate_ok;
        -- an empty stamp table yields NULL; NULL-strict so the guard falls back to full
        SET gate_ok = IFNULL(gate_ok, FALSE);
      END IF;

      SET eff_incremental = base_ok AND diff_ok AND gate_ok;
    END IF;

    -----------------------------------------------------------------------
    -- Mode-dependent fragments. In full mode all filters are empty and each
    -- layer writes straight to {S} and reads the prior layer from {S}. In
    -- incremental mode the base temp is filtered to impacted RCVs, each layer
    -- is staged to {P}.stg_* and reads the prior layer from {P}.stg_*, and the
    -- merge carries forward the unimpacted baseline rows.
    -----------------------------------------------------------------------
    IF eff_incremental THEN
      SET pfilter = 'AND rm.rcv_accession IN (SELECT rcv_accession FROM `{S}.rcv_impacted_ids`)';
      SET class_head = '{CT} `{P}.stg_gks_rcv_classification_agg`';
      SET priority_head = '{CT} `{P}.stg_gks_rcv_priority_agg`';
      SET agg_head = '{CT} `{P}.stg_gks_rcv_aggregate_contribution`';
      SET class_src = '`{P}.stg_gks_rcv_classification_agg`';
      SET priority_src = '`{P}.stg_gks_rcv_priority_agg`';
    ELSE
      SET pfilter = '';
      SET class_head = 'CREATE OR REPLACE TABLE `{S}.gks_rcv_classification_agg`';
      SET priority_head = 'CREATE OR REPLACE TABLE `{S}.gks_rcv_priority_agg`';
      SET agg_head = 'CREATE OR REPLACE TABLE `{S}.gks_rcv_aggregate_contribution`';
      SET class_src = '`{S}.gks_rcv_classification_agg`';
      SET priority_src = '`{S}.gks_rcv_priority_agg`';
    END IF;

    -- Clean up any persistent temp tables from a prior debug run
    IF NOT debug THEN
      CALL `clinvar_ingest.cleanup_temp_tables`(rec.schema_name, [
        'temp_rcv_base_data',
        'stg_gks_rcv_classification_agg',
        'stg_gks_rcv_priority_agg',
        'stg_gks_rcv_aggregate_contribution'
      ]);
    END IF;

    -------------------------------------------------------------------------
    -- GROUPING LAYER: MATERIALIZE BASE DATA (Metadata Driven)
    -- {PFILTER} restricts to impacted RCV parents in incremental mode ('' in full),
    -- which propagates the restriction to all three agg outputs (they read only
    -- temp_rcv_base_data + {S}.gks_scv_condition_sets).
    -------------------------------------------------------------------------
    SET query_base = REPLACE("""
      {CT} `{P}.temp_rcv_base_data`
      CLUSTER BY variation_id, rcv_accession, statement_group, submission_level AS
      SELECT
          ss.variation_id,
          ra.id AS rcv_accession,
          FORMAT('%s.%d', ra.id, ra.version) AS full_rcv_id,
          ra.trait_set_id,
          ss.id AS scv_id,
          ss.full_scv_id,
          ss.submitter_id,
          ss.rank as submission_rank,

          cst.category_code AS statement_group,

          cct.label AS classif_label,
          cct.code as classif_type,
          cct.description_order as classif_type_order,
          cct.significance,
          cct.direction as scv_direction,
          cct.strength_label as scv_strength_name,
          cpt.conflict_detectable,
          cpt.code as prop_type,
          cpt.label as prop_label,
          cpt.display_order as prop_display_order,
          ss.clinical_impact_assertion_type,
          ss.clinical_impact_clinical_significance,
          sl.code AS submission_level,
          sl.label AS submission_level_label
      FROM `{S}.rcv_mapping` AS rm
      CROSS JOIN UNNEST(rm.scv_accessions) AS scv_id
      JOIN `{S}.scv_summary` AS ss ON ss.id = scv_id
      JOIN `{S}.rcv_accession` AS ra ON rm.rcv_accession = ra.id

      JOIN `clinvar_ingest.clinvar_statement_types` AS cst ON cst.code = ss.statement_type
      JOIN (
        `clinvar_ingest.clinvar_clinsig_types` AS cct
        JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON cpt.code = cct.proposition_type
      ) ON cct.code = ss.classif_type AND cpt.statement_type_code = ss.statement_type
      LEFT JOIN `clinvar_ingest.submission_level` sl ON sl.rank = ss.rank
      WHERE TRUE
        {PFILTER}
    """, '{PFILTER}', pfilter);
    SET query_base = REPLACE(query_base, '{S}', rec.schema_name);
    SET query_base = REPLACE(query_base, '{CT}', temp_create);
    SET query_base = REPLACE(query_base, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_base;

    -------------------------------------------------------------------------
    -- GROUPING LAYER: CLASSIFICATION GROUPING
    -- {CLASS_HEAD}: real table in full mode, {P}.stg_* in incremental mode.
    -------------------------------------------------------------------------
    SET query_classification = REPLACE("""
      {CLASS_HEAD} AS
      WITH
      core_agg AS (
          SELECT
            variation_id, rcv_accession, full_rcv_id, trait_set_id, statement_group, prop_type, submission_level,
            IF(prop_type = 'sci', classif_type, CAST(NULL AS STRING)) as tier_grouping,
            ANY_VALUE(prop_label) as prop_label,
            ANY_VALUE(conflict_detectable) as conflict_detectable,
            MIN(classif_type_order) as tier_priority,
            MIN(prop_display_order) as prop_display_order,
            ARRAY_AGG(DISTINCT full_scv_id) as full_scv_ids,
            COUNT(DISTINCT submitter_id) as unique_submitter_count,
            COUNT(full_scv_id) as scv_count,
            -- Per-record attributes that are NOT functionally determined by the group
            -- key (a group can span SCVs that disagree, e.g. a somatic tier with
            -- differing clinical_impact, or a conflicting non-sci group with differing
            -- direction/strength). ANY_VALUE would pick arbitrarily and is unstable
            -- across executions, which breaks incremental carry-forward (recompute must
            -- be byte-identical to the carried-forward baseline row). Pick all four from
            -- ONE deterministic representative record (smallest full_scv_id) so the pick
            -- is stable and internally coherent.
            ARRAY_AGG(STRUCT(
              clinical_impact_assertion_type AS ciat,
              clinical_impact_clinical_significance AS cics,
              scv_direction AS sdir,
              scv_strength_name AS sstr
            ) ORDER BY full_scv_id LIMIT 1)[OFFSET(0)].ciat as clinical_impact_assertion_type,
            ARRAY_AGG(STRUCT(
              clinical_impact_assertion_type AS ciat,
              clinical_impact_clinical_significance AS cics,
              scv_direction AS sdir,
              scv_strength_name AS sstr
            ) ORDER BY full_scv_id LIMIT 1)[OFFSET(0)].cics as clinical_impact_clinical_significance,
            ARRAY_AGG(STRUCT(
              clinical_impact_assertion_type AS ciat,
              clinical_impact_clinical_significance AS cics,
              scv_direction AS sdir,
              scv_strength_name AS sstr
            ) ORDER BY full_scv_id LIMIT 1)[OFFSET(0)].sdir as scv_direction,
            ARRAY_AGG(STRUCT(
              clinical_impact_assertion_type AS ciat,
              clinical_impact_clinical_significance AS cics,
              scv_direction AS sdir,
              scv_strength_name AS sstr
            ) ORDER BY full_scv_id LIMIT 1)[OFFSET(0)].sstr as scv_strength_name,
            ANY_VALUE(submission_level_label) as submission_level_label
          FROM `{P}.temp_rcv_base_data`
          GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
      ),
      label_counts AS (
          SELECT variation_id, rcv_accession, trait_set_id, statement_group, prop_type, submission_level,
                 IF(prop_type = 'sci', classif_type, CAST(NULL AS STRING)) as tier_grouping,
                 classif_label, classif_type_order,
                 significance,
                 COUNT(full_scv_id) as scv_count
          FROM `{P}.temp_rcv_base_data`
          GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
      ),
      conflict_strings AS (
          SELECT variation_id, rcv_accession, trait_set_id, statement_group, prop_type, submission_level, tier_grouping,
                 STRING_AGG(classif_label, '/' ORDER BY classif_type_order) as agg_classif_label,
                 STRING_AGG(FORMAT('%s(%d)', classif_label, scv_count), '; ' ORDER BY classif_type_order) as agg_string,
                 COUNT(DISTINCT significance) as significance_count
          FROM label_counts
          GROUP BY 1, 2, 3, 4, 5, 6, 7
      ),
      somatic_conditions AS (
          SELECT b.variation_id, b.rcv_accession, b.trait_set_id, b.statement_group, b.prop_type, b.submission_level, b.classif_type as tier_grouping,
                 ARRAY_AGG(DISTINCT trait_name IGNORE NULLS) as unique_traits
          FROM `{P}.temp_rcv_base_data` b
          JOIN `{S}.gks_scv_condition_sets` scs_sc ON b.scv_id = scs_sc.scv_id
          CROSS JOIN UNNEST(
            IF(scs_sc.extensions.value_submitted_condition IS NOT NULL,
              [scs_sc.extensions.value_submitted_condition.name],
              ARRAY(SELECT c.name FROM UNNEST(scs_sc.extensions.value_submitted_condition_set.concepts) c)
            )
          ) as trait_name
          WHERE b.prop_type = 'sci'
          GROUP BY 1, 2, 3, 4, 5, 6, 7
      ),
      final_prep AS (
          SELECT
            c.variation_id, c.rcv_accession, c.full_rcv_id, c.trait_set_id, c.statement_group, c.prop_type,
            c.submission_level, c.tier_grouping, c.full_scv_ids,
            c.tier_priority, c.prop_display_order, COALESCE(sc.unique_traits, []) as unique_traits,

            -- Conflict explanation: suppressed for PG, EP, and FLAG (single-source levels)
            CASE
              WHEN c.submission_level IN ('PG', 'EP', 'FLAG') THEN NULL
              ELSE IF(cs.significance_count > 1 AND c.conflict_detectable, cs.agg_string, CAST(NULL AS STRING))
            END AS agg_label_conflicting_explanation,

            -- Aggregate classification label: submission-level-specific logic
            CASE
              WHEN c.submission_level = 'FLAG' THEN 'no classifications from unflagged records'
              WHEN cs.significance_count > 1 AND c.conflict_detectable AND c.prop_type != 'sci' AND c.submission_level NOT IN ('PG', 'EP') THEN
                FORMAT('Conflicting classifications of %s', LOWER(c.prop_label))
              WHEN c.prop_type = 'sci' THEN
                FORMAT('%s - %s - %s (%d)',
                  cs.agg_classif_label,
                  IFNULL(c.clinical_impact_assertion_type, 'unknown'),
                  IFNULL(c.clinical_impact_clinical_significance, 'unknown'),
                  c.scv_count
                )
              ELSE cs.agg_classif_label
            END AS actual_agg_classif_label,

            -- Aggregate review status for all submission levels
            CASE
              WHEN c.submission_level = 'PG' THEN 'practice guideline'
              WHEN c.submission_level = 'EP' THEN 'reviewed by expert panel'
              WHEN c.submission_level = 'CP' AND c.unique_submitter_count = 1 THEN 'criteria provided, single submitter'
              WHEN c.submission_level = 'CP' AND cs.significance_count <= 1 THEN 'criteria provided, multiple submitters, no conflicts'
              WHEN c.submission_level = 'CP' AND cs.significance_count > 1 AND c.conflict_detectable THEN 'criteria provided, conflicting classifications'
              WHEN c.submission_level = 'CP' THEN 'criteria provided, single submitter'
              WHEN c.submission_level = 'NOCP' THEN 'no assertion criteria provided'
              WHEN c.submission_level = 'NOCL' THEN 'no classification provided'
              WHEN c.submission_level = 'FLAG' THEN 'flagged submission'
              ELSE NULL
            END AS aggregate_review_status,
            c.scv_direction, c.scv_strength_name, c.submission_level_label
          FROM core_agg c
          LEFT JOIN conflict_strings cs
            ON c.variation_id = cs.variation_id AND c.rcv_accession = cs.rcv_accession AND c.trait_set_id = cs.trait_set_id
            AND c.statement_group = cs.statement_group AND c.prop_type = cs.prop_type
            AND c.submission_level = cs.submission_level AND IFNULL(c.tier_grouping, '') = IFNULL(cs.tier_grouping, '')
          LEFT JOIN somatic_conditions sc
            ON c.variation_id = sc.variation_id AND c.rcv_accession = sc.rcv_accession AND c.trait_set_id = sc.trait_set_id
            AND c.statement_group = sc.statement_group AND c.prop_type = sc.prop_type
            AND c.submission_level = sc.submission_level AND IFNULL(c.tier_grouping, '') = IFNULL(sc.tier_grouping, '')
      )
      SELECT
        CASE
          WHEN tier_grouping IS NOT NULL THEN FORMAT('%s-%s-%s-%s-%s', full_rcv_id, statement_group, UPPER(prop_type), submission_level, UPPER(tier_grouping))
          ELSE FORMAT('%s-%s-%s-%s', full_rcv_id, statement_group, UPPER(prop_type), submission_level)
        END AS id,
        CASE
          WHEN tier_grouping IS NOT NULL THEN FORMAT('%s-%s-%s-%s-%s', rcv_accession, statement_group, UPPER(prop_type), submission_level, UPPER(tier_grouping))
          ELSE FORMAT('%s-%s-%s-%s', rcv_accession, statement_group, UPPER(prop_type), submission_level)
        END AS prop_id,
        *
      FROM final_prep
    """, '{CLASS_HEAD}', class_head);
    SET query_classification = REPLACE(query_classification, '{S}', rec.schema_name);
    SET query_classification = REPLACE(query_classification, '{CT}', temp_create);
    SET query_classification = REPLACE(query_classification, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_classification;

    -------------------------------------------------------------------------
    -- GROUPING LAYER: PRIORITY GROUPING (Somatic only)
    -- Reads {CLASS_SRC} (prior layer): {S} in full mode, {P}.stg_* in incremental.
    -------------------------------------------------------------------------
    SET query_priority = REPLACE("""
      {PRIORITY_HEAD} AS
      WITH statement_base AS (
          SELECT
            variation_id, rcv_accession, full_rcv_id, trait_set_id, statement_group, prop_type, submission_level,
            ANY_VALUE(submission_level_label) as submission_level_label,
            ARRAY_AGG(STRUCT(
              tier_priority, prop_display_order, actual_agg_classif_label,
              agg_label_conflicting_explanation, unique_traits, full_scv_ids, id, tier_grouping
            ) ORDER BY tier_priority ASC, ARRAY_LENGTH(full_scv_ids) DESC) as findings
          FROM {CLASS_SRC}
          WHERE tier_grouping IS NOT NULL
          GROUP BY 1, 2, 3, 4, 5, 6, 7
      ),
      delta_prep AS (
          SELECT sb.*,
            sb.findings[OFFSET(0)].tier_grouping as top_tier_grouping,
            sb.findings[OFFSET(0)].actual_agg_classif_label as top_label,
            sb.findings[OFFSET(0)].agg_label_conflicting_explanation as agg_label_conflicting_explanation,
            sb.findings[OFFSET(0)].unique_traits as top_unique_traits,
            ARRAY(SELECT DISTINCT f.id FROM UNNEST(sb.findings) f WITH OFFSET i WHERE i = 0) as contributing_tier_ids,
            ARRAY(SELECT DISTINCT f.id FROM UNNEST(sb.findings) f WITH OFFSET i WHERE i > 0) as non_contributing_tier_ids,
            ARRAY(
              SELECT DISTINCT t FROM UNNEST(sb.findings) as f WITH OFFSET i CROSS JOIN UNNEST(f.unique_traits) as t
              WHERE i > 0 AND t NOT IN UNNEST(sb.findings[OFFSET(0)].unique_traits)
            ) as secondary_traits
          FROM statement_base sb
      ),
      final_state_prep AS (
          SELECT *,
            top_label || IF(ARRAY_LENGTH(secondary_traits) > 0, FORMAT('\\n+lower levels of evidence for %d other tumor types', ARRAY_LENGTH(secondary_traits)), '') as agg_label
          FROM delta_prep
      )
      SELECT
        FORMAT('%s-%s-%s-%s', full_rcv_id, statement_group, UPPER(prop_type), submission_level) AS id,
        FORMAT('%s-%s-%s-%s', rcv_accession, statement_group, UPPER(prop_type), submission_level) AS prop_id,
        variation_id, rcv_accession, full_rcv_id, trait_set_id, statement_group, prop_type, submission_level,
        submission_level_label,
        agg_label, agg_label_conflicting_explanation,
        top_unique_traits as unique_traits,
        contributing_tier_ids as contributing_statement_ids,
        non_contributing_tier_ids as non_contributing_statement_ids,
        CAST(NULL AS STRING) AS aggregate_review_status
      FROM final_state_prep
    """, '{PRIORITY_HEAD}', priority_head);
    SET query_priority = REPLACE(query_priority, '{CLASS_SRC}', class_src);
    SET query_priority = REPLACE(query_priority, '{S}', rec.schema_name);
    SET query_priority = REPLACE(query_priority, '{CT}', temp_create);
    SET query_priority = REPLACE(query_priority, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_priority;

    -------------------------------------------------------------------------
    -- AGGREGATE CONTRIBUTION LAYER
    -- Reads BOTH {PRIORITY_SRC} and {CLASS_SRC}: {S} in full mode, {P}.stg_* in
    -- incremental. The MIN(prop_display_order) GROUP BY prop_type subquery is
    -- constant per prop_type, so it is invariant to the impacted subset.
    -------------------------------------------------------------------------
    SET query_agg_contribution = REPLACE("""
      {AGG_HEAD} AS
      WITH unified_input AS (
          SELECT
            id as source_id, variation_id, rcv_accession, full_rcv_id, trait_set_id, statement_group, prop_type, submission_level,
            submission_level_label,
            agg_label, agg_label_conflicting_explanation, prop_display_order,
            aggregate_review_status
          FROM {PRIORITY_SRC}
          LEFT JOIN (SELECT DISTINCT prop_type as pt, MIN(prop_display_order) as prop_display_order FROM {CLASS_SRC} GROUP BY 1) ON prop_type = pt
          UNION ALL
          SELECT
            id as source_id, variation_id, rcv_accession, full_rcv_id, trait_set_id, statement_group, prop_type, submission_level,
            submission_level_label,
            actual_agg_classif_label as agg_label, agg_label_conflicting_explanation, prop_display_order,
            aggregate_review_status
          FROM {CLASS_SRC}
          WHERE tier_grouping IS NULL
      ),
      ranked_levels AS (
          SELECT ui.*,
            ROW_NUMBER() OVER(PARTITION BY ui.rcv_accession, ui.statement_group, ui.prop_type
              ORDER BY CASE ui.submission_level
                WHEN 'PG' THEN 6
                WHEN 'EP' THEN 5
                WHEN 'CP' THEN 4
                WHEN 'NOCP' THEN 3
                WHEN 'NOCL' THEN 2
                WHEN 'FLAG' THEN 1
                ELSE 0
              END DESC) as rnk
          FROM unified_input ui
      ),
      winner_takes_all AS (
          SELECT * FROM ranked_levels WHERE rnk = 1
      ),
      non_contributing AS (
          SELECT
            rcv_accession, statement_group, prop_type,
            ARRAY_AGG(STRUCT(source_id as layer_id, submission_level, agg_label, agg_label_conflicting_explanation)) as non_contributing_details
          FROM ranked_levels
          WHERE rnk > 1
          GROUP BY 1, 2, 3
      )
      SELECT
        FORMAT('%s-%s-%s', w.full_rcv_id, w.statement_group, UPPER(w.prop_type)) AS id,
        FORMAT('%s-%s-%s', w.rcv_accession, w.statement_group, UPPER(w.prop_type)) AS prop_id,
        w.variation_id, w.rcv_accession, w.full_rcv_id, w.trait_set_id, w.statement_group, w.prop_type,
        w.source_id as contributing_layer_id,
        w.submission_level as contributing_submission_level,
        w.submission_level_label as contributing_submission_level_label,
        w.agg_label, w.agg_label_conflicting_explanation,
        w.prop_display_order,
        w.aggregate_review_status,
        COALESCE(nc.non_contributing_details, []) as non_contributing_details
      FROM winner_takes_all w
      LEFT JOIN non_contributing nc USING (rcv_accession, statement_group, prop_type)
    """, '{AGG_HEAD}', agg_head);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{PRIORITY_SRC}', priority_src);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{CLASS_SRC}', class_src);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{S}', rec.schema_name);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{CT}', temp_create);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_agg_contribution;

    -----------------------------------------------------------------------
    -- Incremental only: UNION-CTAS carry-forward merge for each of the three
    -- outputs. Carry forward the baseline rows whose rcv_accession is NOT in the
    -- impacted set (NULL-safe LEFT JOIN anti-join) AND still present in the current
    -- {S}.rcv_accession (so a removed RCV is not resurrected). UNION ALL the
    -- freshly recomputed impacted rows from {P}.stg_*. Explicit column lists so any
    -- schema/column-order drift errors instead of silently corrupting.
    -----------------------------------------------------------------------
    IF eff_incremental THEN

      -- classification
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_rcv_classification_agg` AS
        SELECT
          b.id, b.prop_id, b.variation_id, b.rcv_accession, b.full_rcv_id, b.trait_set_id,
          b.statement_group, b.prop_type, b.submission_level, b.tier_grouping, b.full_scv_ids,
          b.tier_priority, b.prop_display_order, b.unique_traits, b.agg_label_conflicting_explanation,
          b.actual_agg_classif_label, b.aggregate_review_status, b.scv_direction, b.scv_strength_name,
          b.submission_level_label
        FROM `{BASE}.gks_rcv_classification_agg` b
        LEFT JOIN `{S}.rcv_impacted_ids` imp ON imp.rcv_accession = b.rcv_accession
        WHERE imp.rcv_accession IS NULL
          AND b.rcv_accession IN (SELECT id FROM `{S}.rcv_accession`)
        UNION ALL
        SELECT
          id, prop_id, variation_id, rcv_accession, full_rcv_id, trait_set_id,
          statement_group, prop_type, submission_level, tier_grouping, full_scv_ids,
          tier_priority, prop_display_order, unique_traits, agg_label_conflicting_explanation,
          actual_agg_classif_label, aggregate_review_status, scv_direction, scv_strength_name,
          submission_level_label
        FROM `{P}.stg_gks_rcv_classification_agg`
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;

      -- priority
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_rcv_priority_agg` AS
        SELECT
          b.id, b.prop_id, b.variation_id, b.rcv_accession, b.full_rcv_id, b.trait_set_id,
          b.statement_group, b.prop_type, b.submission_level, b.submission_level_label,
          b.agg_label, b.agg_label_conflicting_explanation, b.unique_traits,
          b.contributing_statement_ids, b.non_contributing_statement_ids, b.aggregate_review_status
        FROM `{BASE}.gks_rcv_priority_agg` b
        LEFT JOIN `{S}.rcv_impacted_ids` imp ON imp.rcv_accession = b.rcv_accession
        WHERE imp.rcv_accession IS NULL
          AND b.rcv_accession IN (SELECT id FROM `{S}.rcv_accession`)
        UNION ALL
        SELECT
          id, prop_id, variation_id, rcv_accession, full_rcv_id, trait_set_id,
          statement_group, prop_type, submission_level, submission_level_label,
          agg_label, agg_label_conflicting_explanation, unique_traits,
          contributing_statement_ids, non_contributing_statement_ids, aggregate_review_status
        FROM `{P}.stg_gks_rcv_priority_agg`
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;

      -- aggregate_contribution
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_rcv_aggregate_contribution` AS
        SELECT
          b.id, b.prop_id, b.variation_id, b.rcv_accession, b.full_rcv_id, b.trait_set_id,
          b.statement_group, b.prop_type, b.contributing_layer_id, b.contributing_submission_level,
          b.contributing_submission_level_label, b.agg_label, b.agg_label_conflicting_explanation,
          b.prop_display_order, b.aggregate_review_status, b.non_contributing_details
        FROM `{BASE}.gks_rcv_aggregate_contribution` b
        LEFT JOIN `{S}.rcv_impacted_ids` imp ON imp.rcv_accession = b.rcv_accession
        WHERE imp.rcv_accession IS NULL
          AND b.rcv_accession IN (SELECT id FROM `{S}.rcv_accession`)
        UNION ALL
        SELECT
          id, prop_id, variation_id, rcv_accession, full_rcv_id, trait_set_id,
          statement_group, prop_type, contributing_layer_id, contributing_submission_level,
          contributing_submission_level_label, agg_label, agg_label_conflicting_explanation,
          prop_display_order, aggregate_review_status, non_contributing_details
        FROM `{P}.stg_gks_rcv_aggregate_contribution`
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;

    END IF;

    IF NOT debug THEN
      DROP TABLE IF EXISTS _SESSION.temp_rcv_base_data;
      IF eff_incremental THEN
        DROP TABLE IF EXISTS _SESSION.stg_gks_rcv_classification_agg;
        DROP TABLE IF EXISTS _SESSION.stg_gks_rcv_priority_agg;
        DROP TABLE IF EXISTS _SESSION.stg_gks_rcv_aggregate_contribution;
      END IF;
    END IF;

  END FOR;
END;


-- Full rebuild (unchanged public signature/behavior)
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_rcv_proc`(on_date DATE, debug BOOL)
BEGIN
  CALL `clinvar_ingest.gks_rcv_build`(on_date, debug, FALSE);
END;


-- Incremental rebuild (carry-forward + merge). Guarded: falls back to full when the
-- baseline is missing/incomplete, the impacted set / required inputs are missing, or the
-- pipeline gate mismatches.
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_rcv_proc_incremental`(on_date DATE, debug BOOL)
BEGIN
  CALL `clinvar_ingest.gks_rcv_build`(on_date, debug, TRUE);
END;
