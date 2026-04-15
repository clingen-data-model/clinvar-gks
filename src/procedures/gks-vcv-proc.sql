CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_vcv_proc`(on_date DATE, debug BOOL)
BEGIN
  DECLARE query_base STRING;
  DECLARE query_grouping_base STRING;
  DECLARE query_grouping_tier STRING;
  DECLARE query_agg_contribution STRING;
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
        'temp_vcv_base_data'
      ]);
    END IF;

    -------------------------------------------------------------------------
    -- GROUPING LAYER: MATERIALIZE BASE DATA (Metadata Driven)
    -- PG and EP are kept as separate submission levels (no PGEP grouping).
    -------------------------------------------------------------------------
    SET query_base = REPLACE("""
      {CT} `{P}.temp_vcv_base_data`
      CLUSTER BY variation_id, statement_group, submission_level AS
      SELECT
          ss.variation_id,
          va.id AS vcv_accession,
          FORMAT('%s.%d', va.id, va.version) AS full_vcv_id,
          ss.id AS scv_id,
          ss.full_scv_id,
          ss.submitter_id,
          ss.rank as submission_rank,

          cst.category_code AS statement_group,

          cct.label AS classif_label,
          cct.code as classif_type,
          cct.original_description_order as classif_type_order,
          cct.significance,
          cct.direction as scv_direction,
          cct.strength_name as scv_strength_name,
          cpt.conflict_detectable,
          cpt.code as prop_type,
          cpt.label as prop_label,
          cpt.display_order as prop_display_order,
          sl.code AS submission_level,
          sl.label AS submission_level_label
      FROM `{S}.scv_summary` AS ss
      JOIN `{S}.variation_archive` AS va ON ss.variation_id = va.variation_id

      JOIN `clinvar_ingest.clinvar_statement_types` AS cst ON cst.code = ss.statement_type
      JOIN `clinvar_ingest.clinvar_clinsig_types` AS cct ON cct.code = ss.classif_type AND cct.statement_type = ss.statement_type
      JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON cpt.code = ss.original_proposition_type
      LEFT JOIN `clinvar_ingest.submission_level` sl ON sl.rank = ss.rank
    """, '{S}', rec.schema_name);
    SET query_base = REPLACE(query_base, '{CT}', temp_create);
    SET query_base = REPLACE(query_base, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_base;

    -------------------------------------------------------------------------
    -- GROUPING LAYER: BASE GROUPING
    -- Only matching submission_levels aggregate together (PG with PG,
    -- EP with EP, CP with CP, etc.). No PGEP grouping.
    -------------------------------------------------------------------------
    SET query_grouping_base = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_vcv_grouping_base_agg` AS
      WITH
      core_agg AS (
          SELECT
            variation_id, vcv_accession, full_vcv_id, statement_group, prop_type, submission_level,
            IF(prop_type = 'sci', classif_type, CAST(NULL AS STRING)) as tier_grouping,
            ANY_VALUE(prop_label) as prop_label,
            ANY_VALUE(conflict_detectable) as conflict_detectable,
            MIN(classif_type_order) as tier_priority,
            MIN(prop_display_order) as prop_display_order,
            ARRAY_AGG(DISTINCT full_scv_id) as full_scv_ids,
            COUNT(DISTINCT submitter_id) as unique_submitter_count,
            ANY_VALUE(scv_direction) as scv_direction,
            ANY_VALUE(scv_strength_name) as scv_strength_name,
            ANY_VALUE(submission_level_label) as submission_level_label
          FROM `{P}.temp_vcv_base_data`
          GROUP BY 1, 2, 3, 4, 5, 6, 7
      ),
      label_counts AS (
          SELECT variation_id, statement_group, prop_type, submission_level,
                 IF(prop_type = 'sci', classif_type, CAST(NULL AS STRING)) as tier_grouping,
                 classif_label, classif_type_order,
                 significance,
                 COUNT(full_scv_id) as scv_count
          FROM `{P}.temp_vcv_base_data`
          GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
      ),
      conflict_strings AS (
          SELECT variation_id, statement_group, prop_type, submission_level, tier_grouping,
                 STRING_AGG(classif_label, '/' ORDER BY classif_type_order) as agg_classif_label,
                 STRING_AGG(FORMAT('%s(%d)', classif_label, scv_count), '; ' ORDER BY classif_type_order) as agg_string,
                 COUNT(DISTINCT significance) as significance_count
          FROM label_counts
          GROUP BY 1, 2, 3, 4, 5
      ),
      somatic_conditions AS (
          SELECT b.variation_id, b.statement_group, b.prop_type, b.submission_level, b.classif_type as tier_grouping,
                 ARRAY_AGG(DISTINCT cm.trait_name IGNORE NULLS) as unique_traits
          FROM `{P}.temp_vcv_base_data` b
          JOIN `{S}.gks_scv_condition_mapping` cm ON b.scv_id = cm.scv_id
          WHERE b.prop_type = 'sci'
          GROUP BY 1, 2, 3, 4, 5
      ),
      vcv_conditions AS (
          SELECT b.variation_id, b.statement_group, b.prop_type, b.submission_level,
                 IF(b.prop_type = 'sci', b.classif_type, CAST(NULL AS STRING)) as tier_grouping,
                 ARRAY_AGG(DISTINCT condition_json) as unique_conditions
          FROM `{P}.temp_vcv_base_data` b
          JOIN `{S}.gks_scv_condition_sets` scs ON b.scv_id = scs.scv_id
          CROSS JOIN UNNEST(
            IF(scs.condition IS NOT NULL,
              [TO_JSON(STRUCT(
                scs.condition.id, scs.condition.name, scs.condition.conceptType,
                scs.condition.primaryCoding, scs.condition.mappings
              ))],
              ARRAY(SELECT TO_JSON(STRUCT(
                c.id, c.name, c.conceptType, c.primaryCoding, c.mappings
              )) FROM UNNEST(scs.conditionSet.conditions) c)
            )
          ) as condition_json
          GROUP BY 1, 2, 3, 4, 5
      ),
      final_prep AS (
          SELECT
            c.variation_id, c.vcv_accession, c.full_vcv_id, c.statement_group, c.prop_type,
            c.submission_level, c.submission_level_label, c.tier_grouping, c.full_scv_ids,
            c.tier_priority, c.prop_display_order, COALESCE(sc.unique_traits, []) as unique_traits,
            COALESCE(vc.unique_conditions, CAST([] AS ARRAY<JSON>)) as unique_conditions,
            c.scv_direction, c.scv_strength_name,

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
                CASE
                  WHEN ARRAY_LENGTH(sc.unique_traits) = 1 THEN FORMAT('%s for %s', cs.agg_classif_label, sc.unique_traits[OFFSET(0)])
                  WHEN ARRAY_LENGTH(sc.unique_traits) > 1 THEN FORMAT('%s for %d tumor types', cs.agg_classif_label, ARRAY_LENGTH(sc.unique_traits))
                  ELSE cs.agg_classif_label
                END
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
            END AS aggregate_review_status
          FROM core_agg c
          LEFT JOIN conflict_strings cs
            ON c.variation_id = cs.variation_id AND c.statement_group = cs.statement_group AND c.prop_type = cs.prop_type
            AND c.submission_level = cs.submission_level AND IFNULL(c.tier_grouping, '') = IFNULL(cs.tier_grouping, '')
          LEFT JOIN somatic_conditions sc
            ON c.variation_id = sc.variation_id AND c.statement_group = sc.statement_group AND c.prop_type = sc.prop_type
            AND c.submission_level = sc.submission_level AND IFNULL(c.tier_grouping, '') = IFNULL(sc.tier_grouping, '')
          LEFT JOIN vcv_conditions vc
            ON c.variation_id = vc.variation_id AND c.statement_group = vc.statement_group AND c.prop_type = vc.prop_type
            AND c.submission_level = vc.submission_level AND IFNULL(c.tier_grouping, '') = IFNULL(vc.tier_grouping, '')
      )
      SELECT
        CASE
          WHEN tier_grouping IS NOT NULL THEN FORMAT('%s-%s-%s-%s-%s', full_vcv_id, statement_group, UPPER(prop_type), submission_level, UPPER(tier_grouping))
          ELSE FORMAT('%s-%s-%s-%s', full_vcv_id, statement_group, UPPER(prop_type), submission_level)
        END AS id,
        CASE
          WHEN tier_grouping IS NOT NULL THEN FORMAT('%s-%s-%s-%s-%s', vcv_accession, statement_group, UPPER(prop_type), submission_level, UPPER(tier_grouping))
          ELSE FORMAT('%s-%s-%s-%s', vcv_accession, statement_group, UPPER(prop_type), submission_level)
        END AS prop_id,
        *
      FROM final_prep
    """, '{S}', rec.schema_name);
    SET query_grouping_base = REPLACE(query_grouping_base, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_grouping_base;

    -------------------------------------------------------------------------
    -- GROUPING LAYER: TIER GROUPING (Somatic only)
    -------------------------------------------------------------------------
    SET query_grouping_tier = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_vcv_grouping_tier_agg` AS
      WITH statement_base AS (
          SELECT
            variation_id, vcv_accession, full_vcv_id, statement_group, prop_type, submission_level,
            ANY_VALUE(submission_level_label) as submission_level_label,
            ARRAY_AGG(STRUCT(
              tier_priority, prop_display_order, actual_agg_classif_label,
              agg_label_conflicting_explanation, unique_traits, unique_conditions, full_scv_ids, id, tier_grouping
            ) ORDER BY tier_priority ASC, ARRAY_LENGTH(full_scv_ids) DESC) as findings
          FROM `{S}.gks_vcv_grouping_base_agg`
          WHERE tier_grouping IS NOT NULL
          GROUP BY 1, 2, 3, 4, 5, 6
      ),
      delta_prep AS (
          SELECT sb.*,
            sb.findings[OFFSET(0)].tier_grouping as top_tier_grouping,
            sb.findings[OFFSET(0)].actual_agg_classif_label as top_label,
            sb.findings[OFFSET(0)].agg_label_conflicting_explanation as agg_label_conflicting_explanation,
            sb.findings[OFFSET(0)].unique_traits as top_unique_traits,
            sb.findings[OFFSET(0)].unique_conditions as unique_conditions,
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
        FORMAT('%s-%s-%s-%s', full_vcv_id, statement_group, UPPER(prop_type), submission_level) AS id,
        FORMAT('%s-%s-%s-%s', vcv_accession, statement_group, UPPER(prop_type), submission_level) AS prop_id,
        variation_id, vcv_accession, full_vcv_id, statement_group, prop_type, submission_level,
        submission_level_label,
        agg_label, agg_label_conflicting_explanation,
        top_unique_traits as unique_traits,
        unique_conditions,
        contributing_tier_ids as contributing_statement_ids,
        non_contributing_tier_ids as non_contributing_statement_ids,
        CAST(NULL AS STRING) AS aggregate_review_status
      FROM final_state_prep
    """, '{S}', rec.schema_name);
    EXECUTE IMMEDIATE query_grouping_tier;

    -------------------------------------------------------------------------
    -- AGGREGATE CONTRIBUTION LAYER
    -- Winner-takes-all ranking: PG > EP > CP > NOCP > NOCL > FLAG
    -------------------------------------------------------------------------
    SET query_agg_contribution = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_vcv_aggregate_contribution` AS
      WITH unified_input AS (
          SELECT
            id as source_id, variation_id, vcv_accession, full_vcv_id, statement_group, prop_type, submission_level,
            submission_level_label,
            agg_label, agg_label_conflicting_explanation, prop_display_order,
            aggregate_review_status, unique_conditions
          FROM `{S}.gks_vcv_grouping_tier_agg`
          LEFT JOIN (SELECT DISTINCT prop_type as pt, MIN(prop_display_order) as prop_display_order FROM `{S}.gks_vcv_grouping_base_agg` GROUP BY 1) ON prop_type = pt
          UNION ALL
          SELECT
            id as source_id, variation_id, vcv_accession, full_vcv_id, statement_group, prop_type, submission_level,
            submission_level_label,
            actual_agg_classif_label as agg_label, agg_label_conflicting_explanation, prop_display_order,
            aggregate_review_status, unique_conditions
          FROM `{S}.gks_vcv_grouping_base_agg`
          WHERE tier_grouping IS NULL
      ),
      ranked_levels AS (
          SELECT ui.*,
            ROW_NUMBER() OVER(PARTITION BY ui.variation_id, ui.statement_group, ui.prop_type
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
            variation_id, statement_group, prop_type,
            ARRAY_AGG(STRUCT(source_id as layer_id, submission_level, agg_label, agg_label_conflicting_explanation)) as non_contributing_details
          FROM ranked_levels
          WHERE rnk > 1
          GROUP BY 1, 2, 3
      )
      SELECT
        FORMAT('%s-%s-%s', w.full_vcv_id, w.statement_group, UPPER(w.prop_type)) AS id,
        FORMAT('%s-%s-%s', w.vcv_accession, w.statement_group, UPPER(w.prop_type)) AS prop_id,
        w.variation_id, w.vcv_accession, w.full_vcv_id, w.statement_group, w.prop_type,
        w.source_id as contributing_layer_id,
        w.submission_level as contributing_submission_level,
        w.submission_level_label as contributing_submission_level_label,
        w.agg_label, w.agg_label_conflicting_explanation,
        w.prop_display_order,
        w.aggregate_review_status,
        w.unique_conditions,
        COALESCE(nc.non_contributing_details, []) as non_contributing_details
      FROM winner_takes_all w
      LEFT JOIN non_contributing nc USING (variation_id, statement_group, prop_type)
    """, '{S}', rec.schema_name);
    EXECUTE IMMEDIATE query_agg_contribution;

    IF NOT debug THEN
      DROP TABLE _SESSION.temp_vcv_base_data;
    END IF;

  END FOR;
END;
