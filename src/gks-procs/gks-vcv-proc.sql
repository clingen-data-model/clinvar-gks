CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_vcv_proc`(on_date DATE)
BEGIN
  DECLARE query_domain_agg STRING;
  DECLARE query_statement_agg STRING;
  DECLARE query_final_agg STRING;

  FOR rec IN (SELECT s.schema_name FROM `clinvar_ingest.schema_on`(on_date) AS s)
  DO
    
    -------------------------------------------------------------------------
    -- LAYER 1: DOMAIN-DRIVEN AGGREGATOR (The 3 Tracks)
    -------------------------------------------------------------------------
    SET query_domain_agg = FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_vcv_domain_agg` AS
      WITH condition_prep AS (
        SELECT scv_id, TO_JSON_STRING(ARRAY_AGG(STRUCT(trait_name, trait_id) ORDER BY trait_id)) as condition_set_json
        FROM `%s.gks_scv_condition_mapping` GROUP BY scv_id
      ),
      base_data AS (
          SELECT ss.id, 
            ss.full_scv_id, 
            ss.submitter_id, ss.last_evaluated, ss.submission_date, ss.variation_id, 
            ss.statement_type, cst.code AS statement_code, ss.original_proposition_type as proposition_type,
            ss.rank as submission_rank, ss.release_date, cct.significance, cct.label AS classif_label, 
            cct.original_description_order as classif_type_order, cct.code as classif_type,
            cpt.conflict_detectable, cpt.label as prop_label, cpt.display_order as prop_display_order, 
            cp.condition_set_json,
            
            -- Dynamically pulled from the stable rank mapping
            sl.code AS submission_level
            
          FROM `%s.scv_summary` AS ss
          JOIN `clinvar_ingest.clinvar_statement_types` AS cst ON cst.statement_type = ss.statement_type
          JOIN `clinvar_ingest.clinvar_clinsig_types` AS cct ON cct.code = ss.classif_type AND cct.statement_type = ss.statement_type
          JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON ss.original_proposition_type = cpt.code
          
          -- NEW JOIN: Hooking up the submission levels purely by rank
          LEFT JOIN `clinvar_ingest.submission_level` sl ON ss.rank = sl.rank
          
          LEFT JOIN condition_prep cp ON ss.id = cp.scv_id
      ),
      
      classif_counts_onco AS (
          SELECT variation_id, statement_type, submission_level, classif_label, MIN(classif_type_order) as classif_type_order, COUNT(id) as scv_count
          FROM base_data WHERE statement_code = 'O'
          GROUP BY 1, 2, 3, 4
      ),
      onco_strings AS (
          SELECT variation_id, statement_type, submission_level,
                 STRING_AGG(FORMAT('%%s(%%d)', classif_label, scv_count), '; ' ORDER BY classif_type_order) AS agg_string
          FROM classif_counts_onco
          GROUP BY 1, 2, 3
      ),
      classif_counts_germline AS (
          SELECT variation_id, statement_type, proposition_type, submission_level, classif_label, classif_type_order, COUNT(id) as scv_count
          FROM base_data WHERE statement_code = 'G'
          GROUP BY 1, 2, 3, 4, 5, 6
      ),
      germline_strings AS (
          SELECT variation_id, statement_type, proposition_type, submission_level,
                 STRING_AGG(FORMAT('%%s(%%d)', classif_label, scv_count), '; ' ORDER BY classif_type_order) AS agg_string
          FROM classif_counts_germline
          GROUP BY 1, 2, 3, 4
      ),
      
      somatic_track AS (
          SELECT 
            b.variation_id, b.statement_type, b.statement_code, 
            b.proposition_type, b.prop_display_order,
            b.submission_level, b.submission_rank, 
            b.classif_type AS domain_grouping_key, b.classif_type_order AS priority_order,
            FALSE AS conflicting,
            (COUNT(DISTINCT b.submitter_id) > 1) AS multiple,
            CASE WHEN b.submission_rank = 1 AND COUNT(DISTINCT b.submitter_id) > 1 THEN 2 ELSE b.submission_rank END AS agg_rank,
            ARRAY_AGG(DISTINCT b.full_scv_id) as full_scv_ids, 
            ARRAY_AGG(DISTINCT b.condition_set_json IGNORE NULLS) as deduplicated_json_condition_sets,
            ANY_VALUE(b.classif_label) AS agg_classif_label,
            CAST(NULL AS STRING) AS agg_label_conflicting_explanation,
            ANY_VALUE(b.prop_label) AS prop_label,
            MAX(b.release_date) as release_date
          FROM base_data b
          WHERE b.statement_code = 'S'
          GROUP BY b.variation_id, b.statement_type, b.statement_code, b.proposition_type, b.prop_display_order, b.submission_level, b.submission_rank, b.classif_type, b.classif_type_order
      ),
      
      onco_track AS (
          SELECT 
            b.variation_id, b.statement_type, b.statement_code, 
            b.proposition_type, b.prop_display_order,
            b.submission_level, b.submission_rank, 
            'AGGREGATED' AS domain_grouping_key, MIN(b.classif_type_order) AS priority_order,
            (COUNT(DISTINCT b.significance) > 1) AS conflicting,
            (COUNT(DISTINCT b.submitter_id) > 1) AS multiple,
            CASE WHEN b.submission_rank = 1 AND COUNT(DISTINCT b.significance) = 1 AND COUNT(DISTINCT b.submitter_id) > 1 THEN 2 ELSE b.submission_rank END AS agg_rank,
            ARRAY_AGG(DISTINCT b.full_scv_id) as full_scv_ids, 
            ARRAY_AGG(DISTINCT b.condition_set_json IGNORE NULLS) as deduplicated_json_condition_sets,
            STRING_AGG(DISTINCT b.classif_label, '/' ORDER BY b.classif_label) AS agg_classif_label,
            IF(COUNT(DISTINCT b.significance) > 1, ANY_VALUE(os.agg_string), NULL) AS agg_label_conflicting_explanation,
            ANY_VALUE(b.prop_label) AS prop_label,
            MAX(b.release_date) as release_date
          FROM base_data b
          LEFT JOIN onco_strings os USING (variation_id, statement_type, submission_level)
          WHERE b.statement_code = 'O'
          GROUP BY b.variation_id, b.statement_type, b.statement_code, b.proposition_type, b.prop_display_order, b.submission_level, b.submission_rank
      ),
      
      germline_track AS (
          SELECT 
            b.variation_id, b.statement_type, b.statement_code, 
            b.proposition_type, b.prop_display_order,
            b.submission_level, b.submission_rank, 
            IF(NOT ANY_VALUE(b.conflict_detectable), ANY_VALUE(b.classif_type), 'AGGREGATED') AS domain_grouping_key, 
            MIN(b.classif_type_order) AS priority_order,
            (ANY_VALUE(b.conflict_detectable) AND COUNT(DISTINCT b.significance) > 1) AS conflicting,
            (ANY_VALUE(b.conflict_detectable) AND COUNT(DISTINCT b.submitter_id) > 1) AS multiple,
            CASE WHEN b.submission_rank = 1 AND COUNT(DISTINCT b.significance) = 1 AND COUNT(DISTINCT b.submitter_id) > 1 THEN 2 ELSE b.submission_rank END AS agg_rank,
            ARRAY_AGG(DISTINCT b.full_scv_id) as full_scv_ids, 
            ARRAY_AGG(DISTINCT b.condition_set_json IGNORE NULLS) as deduplicated_json_condition_sets,
            STRING_AGG(DISTINCT b.classif_label, '/' ORDER BY b.classif_label) AS agg_classif_label,
            IF(ANY_VALUE(b.conflict_detectable) AND COUNT(DISTINCT b.significance) > 1, ANY_VALUE(gs.agg_string), NULL) AS agg_label_conflicting_explanation,
            ANY_VALUE(b.prop_label) AS prop_label,
            MAX(b.release_date) as release_date
          FROM base_data b
          LEFT JOIN germline_strings gs USING (variation_id, statement_type, proposition_type, submission_level)
          WHERE b.statement_code = 'G'
          GROUP BY b.variation_id, b.statement_type, b.statement_code, b.proposition_type, b.prop_display_order, b.submission_level, b.submission_rank
      ),
      
      combined_tracks AS (
          SELECT * FROM somatic_track
          UNION ALL SELECT * FROM onco_track
          UNION ALL SELECT * FROM germline_track
      ),
      final_prep AS (
        SELECT ct.*, FORMAT('%%s.%%i', vcv.id, vcv.version) as full_vcv_id, 
          CASE 
               WHEN ct.submission_rank >= 3 THEN 'AUTHORITY' 
               WHEN ct.conflicting THEN 'CONFLICT' 
               WHEN ct.multiple THEN 'MULTIPLE_AGREE' 
               WHEN ct.submission_rank < 0 THEN 'NO_DATA' 
               ELSE 'SINGLE' 
          END AS data_state
        FROM combined_tracks ct
        JOIN `%s.variation_archive` vcv USING (variation_id)
      ),
      label_prep AS (
          SELECT *,
            CASE
              WHEN conflicting THEN 
                CASE 
                  WHEN statement_code = 'O' THEN 'Conflicting classifications of oncogenicity'
                  WHEN LOWER(proposition_type) = 'pathogenic' THEN 'Conflicting classifications of pathogenicity'
                  ELSE FORMAT('Conflicting classifications of %%s', LOWER(prop_label))
                END
              WHEN statement_code = 'S' THEN
                CASE 
                  WHEN ARRAY_LENGTH(deduplicated_json_condition_sets) = 1 THEN FORMAT('%%s for %%s', agg_classif_label, (SELECT STRING_AGG(JSON_VALUE(t, '$.trait_name'), ', ') FROM UNNEST(JSON_QUERY_ARRAY(deduplicated_json_condition_sets[OFFSET(0)])) t))
                  WHEN ARRAY_LENGTH(deduplicated_json_condition_sets) > 1 THEN FORMAT('%%s for %%d tumor types', agg_classif_label, ARRAY_LENGTH(deduplicated_json_condition_sets))
                  ELSE agg_classif_label
                END
              ELSE agg_classif_label
            END AS actual_agg_classif_label
          FROM final_prep
      ),
      rank_status_lookup AS (
          SELECT rules.rule_type, rules.is_scv, def.rank, def.review_status, def.start_release_date, def.end_release_date
          FROM `clinvar_ingest.status_rules` rules JOIN `clinvar_ingest.status_definitions` def USING (review_status)
      )
      SELECT
        CASE 
          WHEN lp.statement_code = 'G' THEN FORMAT('%%s-%%s-%%s-%%s', lp.full_vcv_id, lp.statement_code, lp.submission_level, lp.proposition_type) 
          WHEN lp.statement_code = 'S' THEN FORMAT('%%s-%%s-%%s-%%s', lp.full_vcv_id, lp.statement_code, lp.submission_level, LOWER(lp.domain_grouping_key))
          ELSE FORMAT('%%s-%%s-%%s', lp.full_vcv_id, lp.statement_code, lp.submission_level) 
        END AS id,
        CASE 
          WHEN lp.statement_code = 'G' THEN FORMAT('%%s.%%s.%%s.%%s', lp.variation_id, lp.statement_code, lp.submission_level, lp.proposition_type) 
          WHEN lp.statement_code = 'S' THEN FORMAT('%%s.%%s.%%s.%%s', lp.variation_id, lp.statement_code, lp.submission_level, LOWER(lp.domain_grouping_key))
          ELSE FORMAT('%%s.%%s.%%s', lp.variation_id, lp.statement_code, lp.submission_level) 
        END AS prop_id,
        lp.variation_id, lp.full_vcv_id, lp.statement_type, lp.statement_code, lp.submission_level, lp.domain_grouping_key, lp.agg_rank, lp.submission_rank, lp.proposition_type, lp.prop_display_order, lp.priority_order AS tier_priority, lp.conflicting, lp.multiple, lp.data_state, 
        lp.actual_agg_classif_label, lp.agg_label_conflicting_explanation, lp.deduplicated_json_condition_sets, lp.full_scv_ids, rsl.review_status AS agg_rank_label, lp.release_date
      FROM label_prep lp
      LEFT JOIN rank_status_lookup rsl ON lp.agg_rank = rsl.rank AND lp.release_date BETWEEN rsl.start_release_date AND rsl.end_release_date AND rsl.is_scv = FALSE AND (rsl.rule_type IS NULL OR rsl.rule_type = lp.data_state)
      QUALIFY ROW_NUMBER() OVER(
        PARTITION BY lp.variation_id, lp.statement_type, lp.proposition_type, lp.submission_level, lp.domain_grouping_key
        ORDER BY CASE WHEN rsl.rule_type IS NOT NULL THEN 1 ELSE 2 END, rsl.review_status DESC
      ) = 1;
    """, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name);

    EXECUTE IMMEDIATE query_domain_agg;

    -------------------------------------------------------------------------
    -- LAYER 2: STATEMENT LEVEL AGGREGATOR
    -------------------------------------------------------------------------
    SET query_statement_agg = FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_vcv_statement_level_agg` AS
      WITH statement_base AS (
          SELECT variation_id, full_vcv_id, statement_type, statement_code, submission_level, submission_rank,
            ARRAY_AGG(STRUCT(agg_rank, tier_priority, prop_display_order, actual_agg_classif_label, agg_label_conflicting_explanation, deduplicated_json_condition_sets, full_scv_ids, id) ORDER BY tier_priority ASC, agg_rank DESC) as findings,
            MAX(agg_rank) AS statement_agg_rank, MAX(release_date) as release_date, LOGICAL_OR(conflicting) as statement_conflicting, LOGICAL_OR(multiple) as statement_multiple
          FROM `%s.gks_vcv_domain_agg`
          GROUP BY variation_id, full_vcv_id, statement_type, statement_code, submission_level, submission_rank
      ),
      delta_prep AS (
          SELECT sb.*, sb.findings[OFFSET(0)].actual_agg_classif_label as top_label,
            sb.findings[OFFSET(0)].agg_label_conflicting_explanation as agg_label_conflicting_explanation,
            -- LAYER 2 CASCADING FILTER: SCVs, Conditions, AND Prop IDs
            ARRAY(SELECT DISTINCT scv FROM UNNEST(sb.findings) f WITH OFFSET i, UNNEST(f.full_scv_ids) scv WHERE sb.statement_code IN ('G', 'O') OR i = 0) as contributing_scv_ids,
            ARRAY(SELECT DISTINCT scv FROM UNNEST(sb.findings) f WITH OFFSET i, UNNEST(f.full_scv_ids) scv WHERE sb.statement_code = 'S' AND i > 0) as non_contributing_scv_ids,
            
            ARRAY(SELECT DISTINCT js FROM UNNEST(sb.findings) f WITH OFFSET i, UNNEST(f.deduplicated_json_condition_sets) js WHERE sb.statement_code IN ('G', 'O') OR i = 0) as contributing_condition_sets,
            ARRAY(SELECT DISTINCT js FROM UNNEST(sb.findings) f WITH OFFSET i, UNNEST(f.deduplicated_json_condition_sets) js WHERE sb.statement_code = 'S' AND i > 0) as non_contributing_condition_sets,
            
            ARRAY(SELECT DISTINCT f.id FROM UNNEST(sb.findings) f WITH OFFSET i WHERE sb.statement_code IN ('G', 'O') OR i = 0) as contributing_statement_ids,
            ARRAY(SELECT DISTINCT f.id FROM UNNEST(sb.findings) f WITH OFFSET i WHERE sb.statement_code = 'S' AND i > 0) as non_contributing_statement_ids,

            ARRAY(
              SELECT DISTINCT js FROM UNNEST(sb.findings) as f WITH OFFSET i CROSS JOIN UNNEST(f.deduplicated_json_condition_sets) as js
              WHERE i > 0 AND js NOT IN UNNEST(sb.findings[OFFSET(0)].deduplicated_json_condition_sets)
            ) as secondary_condition_sets_json
          FROM statement_base sb
      ),
      final_state_prep AS (
          SELECT *,
            CASE 
              WHEN statement_code IN ('G', 'O') THEN ARRAY_TO_STRING(ARRAY(SELECT f.actual_agg_classif_label FROM UNNEST(findings) f ORDER BY f.prop_display_order ASC), '; ')
              ELSE top_label || IF(ARRAY_LENGTH(secondary_condition_sets_json) > 0, FORMAT('\\n+lower levels of evidence for %%d other tumor types', ARRAY_LENGTH(secondary_condition_sets_json)), '')
            END as agg_label,
            CASE 
                 WHEN submission_rank >= 3 THEN 'AUTHORITY' WHEN statement_conflicting THEN 'CONFLICT' WHEN statement_multiple THEN 'MULTIPLE_AGREE' WHEN submission_rank < 0 THEN 'NO_DATA' ELSE 'SINGLE' 
            END AS data_state
          FROM delta_prep
      ),
      rank_status_lookup AS (
          SELECT rules.rule_type, rules.is_scv, def.rank, def.review_status, def.start_release_date, def.end_release_date
          FROM `clinvar_ingest.status_rules` rules JOIN `clinvar_ingest.status_definitions` def USING (review_status)
      )
      SELECT
        FORMAT('%%s-%%s-%%s', fsp.full_vcv_id, fsp.statement_code, fsp.submission_level) AS id,
        FORMAT('%%s.%%s.%%s', fsp.variation_id, fsp.statement_code, fsp.submission_level) AS prop_id,
        fsp.variation_id, fsp.full_vcv_id, fsp.statement_type, fsp.statement_code, fsp.submission_level, fsp.submission_rank, fsp.statement_agg_rank AS agg_rank, fsp.agg_label, fsp.agg_label_conflicting_explanation,
        fsp.contributing_scv_ids, fsp.non_contributing_scv_ids, fsp.contributing_condition_sets, fsp.non_contributing_condition_sets,
        fsp.contributing_statement_ids, fsp.non_contributing_statement_ids,
        fsp.release_date, rsl.review_status AS statement_review_status
      FROM final_state_prep fsp
      LEFT JOIN rank_status_lookup rsl ON fsp.statement_agg_rank = rsl.rank AND fsp.release_date BETWEEN rsl.start_release_date AND rsl.end_release_date AND rsl.is_scv = FALSE AND (rsl.rule_type IS NULL OR rsl.rule_type = fsp.data_state)
      QUALIFY ROW_NUMBER() OVER(
        PARTITION BY fsp.variation_id, fsp.full_vcv_id, fsp.statement_code, fsp.submission_level 
        ORDER BY CASE WHEN rsl.rule_type IS NOT NULL THEN 1 ELSE 2 END, rsl.review_status DESC
      ) = 1;
    """, rec.schema_name, rec.schema_name);

    EXECUTE IMMEDIATE query_statement_agg;

    -------------------------------------------------------------------------
    -- LAYER 3: FINAL STATEMENT AGGREGATOR (Winner Takes All)
    -------------------------------------------------------------------------
    SET query_final_agg = FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_vcv_statement_final` AS
      WITH ranked_statements AS (
          SELECT 
              *,
              ROW_NUMBER() OVER(PARTITION BY variation_id, full_vcv_id, statement_type ORDER BY submission_rank DESC) as rnk
          FROM `%s.gks_vcv_statement_level_agg`
      ),
      contributing AS (
          SELECT * FROM ranked_statements WHERE rnk = 1
      ),
      -- The Great Funnel: SCVs
      nc_scv_flat AS (
          SELECT variation_id, full_vcv_id, statement_type, scv AS nc_scv_id
          FROM ranked_statements CROSS JOIN UNNEST(
              IF(rnk = 1, non_contributing_scv_ids, ARRAY_CONCAT(contributing_scv_ids, non_contributing_scv_ids))
          ) scv
      ),
      nc_scv_agg AS (
          SELECT variation_id, full_vcv_id, statement_type, ARRAY_AGG(DISTINCT nc_scv_id) AS final_nc_scv_ids
          FROM nc_scv_flat GROUP BY variation_id, full_vcv_id, statement_type
      ),
      -- The Great Funnel: Conditions
      nc_cond_flat AS (
          SELECT variation_id, full_vcv_id, statement_type, cond AS nc_cond_id
          FROM ranked_statements CROSS JOIN UNNEST(
              IF(rnk = 1, non_contributing_condition_sets, ARRAY_CONCAT(contributing_condition_sets, non_contributing_condition_sets))
          ) cond
      ),
      nc_cond_agg AS (
          SELECT variation_id, full_vcv_id, statement_type, ARRAY_AGG(DISTINCT nc_cond_id) AS final_nc_condition_sets
          FROM nc_cond_flat GROUP BY variation_id, full_vcv_id, statement_type
      ),
      -- The Great Funnel: Statement IDs
      nc_stmt_flat AS (
          SELECT variation_id, full_vcv_id, statement_type, stmt AS nc_statement_id
          FROM ranked_statements CROSS JOIN UNNEST(
              IF(rnk = 1, non_contributing_statement_ids, ARRAY_CONCAT(contributing_statement_ids, non_contributing_statement_ids))
          ) stmt
      ),
      nc_stmt_agg AS (
          SELECT variation_id, full_vcv_id, statement_type, ARRAY_AGG(DISTINCT nc_statement_id) AS final_nc_statement_ids
          FROM nc_stmt_flat GROUP BY variation_id, full_vcv_id, statement_type
      ),
      
      nc_details_agg AS (
          SELECT 
              variation_id,
              full_vcv_id, 
              statement_type,
              ARRAY_AGG(STRUCT(
                  id AS layer2_id,
                  submission_level,
                  submission_rank,
                  agg_label,
                  agg_label_conflicting_explanation,
                  statement_review_status,
                  contributing_scv_ids,
                  non_contributing_scv_ids,
                  contributing_condition_sets,
                  non_contributing_condition_sets,
                  contributing_statement_ids,
                  non_contributing_statement_ids
              ) ORDER BY submission_rank DESC) as nc_details
          FROM ranked_statements 
          WHERE rnk > 1
          GROUP BY variation_id, full_vcv_id, statement_type
      ),
      non_contributing AS (
          SELECT d.variation_id, d.full_vcv_id, d.statement_type, s.final_nc_scv_ids, c.final_nc_condition_sets, p.final_nc_statement_ids, d.nc_details
          FROM nc_details_agg d
          LEFT JOIN nc_scv_agg s USING (variation_id, full_vcv_id, statement_type)
          LEFT JOIN nc_cond_agg c USING (variation_id, full_vcv_id, statement_type)
          LEFT JOIN nc_stmt_agg p USING (variation_id, full_vcv_id, statement_type)
      )
      SELECT
        FORMAT('%%s-%%s', c.full_vcv_id, c.statement_code) AS id,
        FORMAT('%%s.%%s', c.variation_id, c.statement_code) AS prop_id,
        c.variation_id,
        c.full_vcv_id,
        c.statement_type,
        c.statement_code,
        
        c.id AS contributing_layer2_id,
        c.submission_level AS contributing_submission_level,
        c.submission_rank AS contributing_submission_rank,
        c.agg_rank AS contributing_agg_rank,
        c.agg_label AS contributing_agg_label,
        c.agg_label_conflicting_explanation AS contributing_agg_label_conflicting_explanation,
        c.statement_review_status AS contributing_review_status,
        c.contributing_scv_ids,
        c.contributing_condition_sets,
        c.contributing_statement_ids,
        c.release_date,
        
        COALESCE(nc.final_nc_scv_ids, []) AS non_contributing_scv_ids,
        COALESCE(nc.final_nc_condition_sets, []) AS non_contributing_condition_sets,
        COALESCE(nc.final_nc_statement_ids, []) AS non_contributing_statement_ids,
        COALESCE(nc.nc_details, []) AS non_contributing_details

      FROM contributing c
      LEFT JOIN non_contributing nc USING (variation_id, full_vcv_id, statement_type);
    """, rec.schema_name, rec.schema_name);

    EXECUTE IMMEDIATE query_final_agg;

  END FOR;
END;