CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_rcv_proc`(on_date DATE, debug BOOL)
BEGIN
  DECLARE query_base STRING;
  DECLARE query_layer1 STRING;
  DECLARE query_layer2 STRING;
  DECLARE query_layer3 STRING;
  DECLARE query_layer4 STRING;
  DECLARE temp_create STRING;

  IF debug THEN
    SET temp_create = 'CREATE OR REPLACE TABLE';
  ELSE
    SET temp_create = 'CREATE TEMP TABLE';
  END IF;

  FOR rec IN (SELECT s.schema_name FROM `clinvar_ingest.schema_on`(on_date) AS s)
  DO

    -- Clean up any persistent temp tables from a prior debug run
    IF NOT debug THEN
      CALL `clinvar_ingest.cleanup_temp_tables`(rec.schema_name, [
        'temp_rcv_base_data'
      ]);
    END IF;

    -------------------------------------------------------------------------
    -- LAYER 1: MATERIALIZE BASE DATA (Metadata Driven)
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
          cct.original_description_order as classif_type_order,
          cct.significance,
          cpt.conflict_detectable,
          cpt.code as prop_type,
          cpt.label as prop_label,
          cpt.display_order as prop_display_order,
          ss.clinical_impact_assertion_type,
          ss.clinical_impact_clinical_significance,
          sl.code AS original_submission_level,
          sl.label AS submission_level_label,
          CASE WHEN sl.code IN ('PG', 'EP') THEN 'PGEP' ELSE sl.code END AS submission_level
      FROM `{S}.rcv_mapping` AS rm
      CROSS JOIN UNNEST(rm.scv_accessions) AS scv_id
      JOIN `{S}.scv_summary` AS ss ON ss.id = scv_id
      JOIN `{S}.rcv_accession` AS ra ON rm.rcv_accession = ra.id

      JOIN `clinvar_ingest.clinvar_statement_types` AS cst ON cst.code = ss.statement_type
      JOIN `clinvar_ingest.clinvar_clinsig_types` AS cct ON cct.code = ss.classif_type AND cct.statement_type = ss.statement_type
      JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON cpt.code = ss.original_proposition_type
      LEFT JOIN `clinvar_ingest.submission_level` sl ON sl.rank = ss.rank
    """, '{S}', rec.schema_name);
    SET query_base = REPLACE(query_base, '{CT}', temp_create);
    SET query_base = REPLACE(query_base, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_base;

    -------------------------------------------------------------------------
    -- LAYER 1: BASE AGGREGATION
    -------------------------------------------------------------------------
    SET query_layer1 = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_rcv_layer1_base_agg` AS
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
            ARRAY_AGG(DISTINCT original_submission_level) as contributing_submission_levels,
            COUNT(DISTINCT submitter_id) as unique_submitter_count,
            COUNT(full_scv_id) as scv_count,
            ANY_VALUE(clinical_impact_assertion_type) as clinical_impact_assertion_type,
            ANY_VALUE(clinical_impact_clinical_significance) as clinical_impact_clinical_significance
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
                 ARRAY_AGG(DISTINCT cm.trait_name IGNORE NULLS) as unique_traits
          FROM `{P}.temp_rcv_base_data` b
          JOIN `{S}.gks_scv_condition_mapping` cm ON b.scv_id = cm.scv_id
          WHERE b.prop_type = 'sci'
          GROUP BY 1, 2, 3, 4, 5, 6, 7
      ),
      final_prep AS (
          SELECT
            c.variation_id, c.rcv_accession, c.full_rcv_id, c.trait_set_id, c.statement_group, c.prop_type,
            c.submission_level, c.tier_grouping, c.full_scv_ids,
            c.tier_priority, c.prop_display_order, COALESCE(sc.unique_traits, []) as unique_traits,

            -- Conflict explanation: suppressed for PGEP and FLAG
            CASE
              WHEN c.submission_level IN ('PGEP', 'FLAG') THEN NULL
              ELSE IF(cs.significance_count > 1 AND c.conflict_detectable, cs.agg_string, CAST(NULL AS STRING))
            END AS agg_label_conflicting_explanation,

            -- Aggregate classification label: submission-level-specific logic
            CASE
              WHEN c.submission_level = 'PGEP' THEN NULL  -- PGEP uses array, not single label
              WHEN c.submission_level = 'FLAG' THEN 'no classifications from unflagged records'
              WHEN cs.significance_count > 1 AND c.conflict_detectable AND c.prop_type != 'sci' THEN
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

            -- PGEP strength derivation
            CASE
              WHEN c.submission_level = 'PGEP' THEN
                CASE
                  WHEN ARRAY_LENGTH(c.contributing_submission_levels) = 1 AND c.contributing_submission_levels[OFFSET(0)] = 'PG' THEN 'PG'
                  WHEN ARRAY_LENGTH(c.contributing_submission_levels) = 1 AND c.contributing_submission_levels[OFFSET(0)] = 'EP' THEN 'EP'
                  ELSE 'PGEP'
                END
              ELSE c.submission_level
            END AS pgep_strength,

            -- Aggregate review status for all submission levels
            CASE
              WHEN c.submission_level = 'PGEP' THEN
                CASE
                  WHEN ARRAY_LENGTH(c.contributing_submission_levels) = 1 AND c.contributing_submission_levels[OFFSET(0)] = 'PG' THEN 'practice guideline'
                  WHEN ARRAY_LENGTH(c.contributing_submission_levels) = 1 AND c.contributing_submission_levels[OFFSET(0)] = 'EP' THEN 'reviewed by expert panel'
                  ELSE 'practice guideline and expert panel mix'
                END
              WHEN c.submission_level = 'CP' AND c.unique_submitter_count = 1 THEN 'criteria provided, single submitter'
              WHEN c.submission_level = 'CP' AND cs.significance_count <= 1 THEN 'criteria provided, multiple submitters, no conflicts'
              WHEN c.submission_level = 'CP' AND cs.significance_count > 1 AND c.conflict_detectable THEN 'criteria provided, conflicting classifications'
              WHEN c.submission_level = 'CP' THEN 'criteria provided, single submitter'
              WHEN c.submission_level = 'NOCP' THEN 'no assertion criteria provided'
              WHEN c.submission_level = 'NOCL' THEN 'no classification provided'
              WHEN c.submission_level = 'FLAG' THEN 'flagged submission'
              ELSE NULL
            END AS aggregate_review_status,

            c.contributing_submission_levels
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
    """, '{S}', rec.schema_name);
    SET query_layer1 = REPLACE(query_layer1, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_layer1;

    -------------------------------------------------------------------------
    -- LAYER 2: TIER AGGREGATOR
    -------------------------------------------------------------------------
    SET query_layer2 = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_rcv_layer2_tier_agg` AS
      WITH statement_base AS (
          SELECT
            variation_id, rcv_accession, full_rcv_id, trait_set_id, statement_group, prop_type, submission_level,
            ARRAY_AGG(STRUCT(
              tier_priority, prop_display_order, actual_agg_classif_label,
              agg_label_conflicting_explanation, unique_traits, full_scv_ids, id, tier_grouping
            ) ORDER BY tier_priority ASC, ARRAY_LENGTH(full_scv_ids) DESC) as findings
          FROM `{S}.gks_rcv_layer1_base_agg`
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
        agg_label, agg_label_conflicting_explanation,
        top_unique_traits as unique_traits,
        contributing_tier_ids as contributing_statement_ids,
        non_contributing_tier_ids as non_contributing_statement_ids,
        CAST(NULL AS STRING) AS pgep_strength,
        CAST(NULL AS STRING) AS aggregate_review_status
      FROM final_state_prep
    """, '{S}', rec.schema_name);
    EXECUTE IMMEDIATE query_layer2;

    -------------------------------------------------------------------------
    -- LAYER 3: SUBMISSION LEVEL AGGREGATOR
    -------------------------------------------------------------------------
    SET query_layer3 = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_rcv_layer3_prop_agg` AS
      WITH unified_input AS (
          SELECT
            id as source_id, variation_id, rcv_accession, full_rcv_id, trait_set_id, statement_group, prop_type, submission_level,
            agg_label, agg_label_conflicting_explanation, prop_display_order,
            pgep_strength, aggregate_review_status
          FROM `{S}.gks_rcv_layer2_tier_agg`
          LEFT JOIN (SELECT DISTINCT prop_type as pt, MIN(prop_display_order) as prop_display_order FROM `{S}.gks_rcv_layer1_base_agg` GROUP BY 1) ON prop_type = pt
          UNION ALL
          SELECT
            id as source_id, variation_id, rcv_accession, full_rcv_id, trait_set_id, statement_group, prop_type, submission_level,
            actual_agg_classif_label as agg_label, agg_label_conflicting_explanation, prop_display_order,
            pgep_strength, aggregate_review_status
          FROM `{S}.gks_rcv_layer1_base_agg`
          WHERE tier_grouping IS NULL
      ),
      ranked_levels AS (
          SELECT ui.*,
            ROW_NUMBER() OVER(PARTITION BY ui.rcv_accession, ui.statement_group, ui.prop_type
              ORDER BY CASE WHEN ui.submission_level = 'PGEP' THEN 5 ELSE sl.rank END DESC) as rnk
          FROM unified_input ui
          LEFT JOIN `clinvar_ingest.submission_level` sl ON ui.submission_level = sl.code
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
        w.agg_label, w.agg_label_conflicting_explanation,
        w.prop_display_order,
        w.pgep_strength, w.aggregate_review_status,
        COALESCE(nc.non_contributing_details, []) as non_contributing_details
      FROM winner_takes_all w
      LEFT JOIN non_contributing nc USING (rcv_accession, statement_group, prop_type)
    """, '{S}', rec.schema_name);
    EXECUTE IMMEDIATE query_layer3;

    -------------------------------------------------------------------------
    -- LAYER 4: FINAL GROUP AGGREGATOR (Germline only)
    -------------------------------------------------------------------------
    SET query_layer4 = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_rcv_layer4_group_agg` AS
      WITH ranked_props AS (
          SELECT rp.*,
            RANK() OVER(PARTITION BY rp.rcv_accession, rp.statement_group
              ORDER BY CASE WHEN rp.contributing_submission_level = 'PGEP' THEN 5 ELSE sl.rank END DESC) as grp_rnk
          FROM `{S}.gks_rcv_layer3_prop_agg` rp
          LEFT JOIN `clinvar_ingest.submission_level` sl ON rp.contributing_submission_level = sl.code
          WHERE rp.statement_group = 'G'
      ),
      contributing_props AS (
          SELECT rcv_accession, variation_id, full_rcv_id, trait_set_id, statement_group,
            ARRAY_AGG(id) as contributing_layer3_ids,
            ARRAY_TO_STRING(ARRAY_AGG(agg_label ORDER BY prop_display_order ASC), '; ') as agg_label,
            NULLIF(ARRAY_TO_STRING(ARRAY_AGG(agg_label_conflicting_explanation IGNORE NULLS ORDER BY prop_display_order ASC), '; '), '') as agg_label_conflicting_explanation,
            ANY_VALUE(pgep_strength) AS pgep_strength,
            ANY_VALUE(aggregate_review_status) AS aggregate_review_status
          FROM ranked_props
          WHERE grp_rnk = 1
          GROUP BY 1, 2, 3, 4, 5
      ),
      non_contributing_props AS (
          SELECT rcv_accession, statement_group,
            ARRAY_AGG(STRUCT(id as layer_id, contributing_submission_level as submission_level, agg_label, agg_label_conflicting_explanation)) as non_contributing_details
          FROM ranked_props
          WHERE grp_rnk > 1
          GROUP BY 1, 2
      )
      SELECT
        FORMAT('%s-%s', c.full_rcv_id, c.statement_group) AS id,
        FORMAT('%s-%s', c.rcv_accession, c.statement_group) AS prop_id,
        c.variation_id, c.rcv_accession, c.full_rcv_id, c.trait_set_id, c.statement_group,
        c.agg_label, c.agg_label_conflicting_explanation,
        c.contributing_layer3_ids,
        c.pgep_strength, c.aggregate_review_status,
        COALESCE(nc.non_contributing_details, []) as non_contributing_details
      FROM contributing_props c
      LEFT JOIN non_contributing_props nc USING (rcv_accession, statement_group)
    """, '{S}', rec.schema_name);
    EXECUTE IMMEDIATE query_layer4;

    IF NOT debug THEN
      DROP TABLE _SESSION.temp_rcv_base_data;
    END IF;

  END FOR;
END;
