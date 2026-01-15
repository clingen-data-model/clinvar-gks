BEGIN
  FOR rec IN (select s.schema_name FROM clinvar_ingest.schema_on(on_date) as s)
  DO

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_vcv_level_one`
      AS
        WITH initial_prep AS (
          -- 1. Prepare base data: Join the tables once.
          SELECT
            ss.id,
            ss.submitter_id,
            ss.last_evaluated,
            ss.submission_date,
            ss.variation_id,
            ss.statement_type,
            ss.original_proposition_type,
            ss.rank,
            ss.significance,
            ss.classif_type,
            cct.label AS classif_label,
            cct.original_description_order
          FROM `%s.scv_summary` AS ss
          LEFT JOIN `clinvar_ingest.clinvar_clinsig_types` AS cct 
          ON 
            cct.code = ss.classif_type 
            AND 
            cct.original_proposition_type = ss.original_proposition_type
          
        )
        , 
        numeric_aggregates AS (
          -- 2. First aggregation path: Calculate all numeric and simple aggregates.
          -- This pass is efficient as it only deals with primitive types as well as captures associated scv ids.
          SELECT
            variation_id,
            statement_type,
            original_proposition_type,
            rank as submission_rank,
            -- add the 'special' 2-star agg rank when no conflicts on multiple submissions occur on a 1-star ranked set of scvs
            IF(rank = 1 AND COUNT(DISTINCT significance) = 1 AND COUNT(DISTINCT submitter_id) > 1, 2, rank) AS agg_rank,
            (COUNT(DISTINCT significance) > 1) AS conflicting,
            (COUNT(DISTINCT submitter_id) > 1) AS multiple,
            COUNT(DISTINCT significance) AS actual_unique_significance_count,
            BIT_OR(CASE significance WHEN 2 THEN 4 WHEN 1 THEN 2 WHEN 0 THEN 1 ELSE 0 END) AS actual_agg_sig_type,
            `clinvar_ingest.createSigType`(
              COUNT(DISTINCT IF(significance = 0, submitter_id, NULL)),
              COUNT(DISTINCT IF(significance = 1, submitter_id, NULL)),
              COUNT(DISTINCT IF(significance = 2, submitter_id, NULL))
            ) AS actual_sig_type,
            COUNT(DISTINCT submitter_id) AS actual_submitter_count,
            COUNT(DISTINCT id) AS actual_submission_count,
            MAX(last_evaluated) AS actual_max_last_evaluated,
            MAX(submission_date) AS actual_max_submission_date,
            ARRAY_AGG(id) as scv_ids
          FROM initial_prep
          GROUP BY
            variation_id, 
            statement_type, 
            original_proposition_type, 
            rank
        )
        , 
        string_aggregates AS (
          -- 3. Second aggregation path: Handle the complex, ordered string aggregations.
          SELECT
            variation_id,
            statement_type,
            original_proposition_type,
            rank as submission_rank,
            STRING_AGG(classif_label, '/' ORDER BY original_description_order) AS agg_classif_label,
            STRING_AGG(classif_type, '; ' ORDER BY original_description_order) AS actual_agg_classif,
            STRING_AGG(classif_label || '(' || scv_count_per_classif || ')', '; ' ORDER BY original_description_order) AS agg_classif_label_w_count,
            STRING_AGG(classif_type || '(' || scv_count_per_classif || ')', '; ' ORDER BY original_description_order) AS actual_agg_classif_w_count
          FROM
            (
              -- First, find the distinct classifications and their counts/order
              SELECT
                variation_id,
                statement_type,
                original_proposition_type,
                rank,
                classif_type,
                classif_label,
                original_description_order,
                COUNT(DISTINCT id) AS scv_count_per_classif
              FROM initial_prep
              GROUP BY 1, 2, 3, 4, 5, 6, 7
            )
          GROUP BY
            variation_id, 
            statement_type, 
            original_proposition_type, 
            rank
        )
        -- 4. Final Join: Combine the results of the two fast aggregation paths.
        SELECT
          FORMAT('%%s.%%s.%%i.%%s', na.variation_id, LEFT(na.statement_type, 1), na.agg_rank, na.original_proposition_type) AS id,
          na.variation_id,
          na.statement_type,
          na.original_proposition_type,
          na.agg_rank,
          na.submission_rank,
          na.conflicting,
          na.multiple,
          na.actual_unique_significance_count,
          na.actual_agg_sig_type,
          na.actual_sig_type,
          na.actual_submitter_count,
          na.actual_submission_count,
          na.actual_max_last_evaluated,
          na.actual_max_submission_date,
          sa.actual_agg_classif,
          sa.actual_agg_classif_w_count,
          IF(na.conflicting, FORMAT('Conflicting classifications of %%s', LOWER(cpt.label)),sa.agg_classif_label) AS actual_agg_classif_label,
          sa.agg_classif_label_w_count,
          na.scv_ids
        FROM numeric_aggregates AS na
        LEFT JOIN string_aggregates AS sa USING (
          variation_id, 
          statement_type, 
          original_proposition_type, 
          submission_rank
        )
        LEFT JOIN `clinvar_ingest.clinvar_proposition_types` AS cpt
        ON
          cpt.code = na.original_proposition_type
    """, 
    rec.schema_name, 
    rec.schema_name
    );

  END FOR;
END