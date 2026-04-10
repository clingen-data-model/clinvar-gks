-- =============================================================================
-- RCV Aggregate Statement Validation
-- =============================================================================
-- Compares computed RCV aggregate classifications (from gks_rcv_layer3_prop_agg)
-- against ClinVar's rcv_accession_classification table.
--
-- Replace {S} with the target schema before running (e.g., clinvar_2026_04_06)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Summary comparison: computed vs ClinVar classification
-- ---------------------------------------------------------------------------
WITH computed AS (
  SELECT
    rcv_accession,
    statement_group,
    prop_type,
    contributing_submission_level,
    agg_label,
    aggregate_review_status
  FROM `{S}.gks_rcv_layer3_prop_agg`
),
clinvar_raw AS (
  SELECT
    rac.rcv_id AS rcv_accession,
    rac.statement_type,
    rac.review_status AS clinvar_review_status,
    ac.interp_description AS clinvar_classification,
    ac.clinical_impact_assertion_type,
    ac.clinical_impact_clinical_significance
  FROM `{S}.rcv_accession_classification` rac
  CROSS JOIN UNNEST(rac.agg_classification) ac
),
joined AS (
  SELECT
    COALESCE(c.rcv_accession, cv.rcv_accession) AS rcv_accession,
    c.statement_group,
    c.prop_type,
    c.agg_label AS computed_classification,
    cv.clinvar_classification,
    c.aggregate_review_status AS computed_review_status,
    cv.clinvar_review_status,
    CASE
      WHEN c.rcv_accession IS NULL THEN 'missing_from_computed'
      WHEN cv.rcv_accession IS NULL THEN 'missing_from_clinvar'
      WHEN c.agg_label = cv.clinvar_classification THEN 'match'
      ELSE 'mismatch'
    END AS status
  FROM computed c
  FULL OUTER JOIN clinvar_raw cv ON c.rcv_accession = cv.rcv_accession
)

SELECT
  status,
  COUNT(*) AS count,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct
FROM joined
GROUP BY status
ORDER BY count DESC;

-- ---------------------------------------------------------------------------
-- 2. Detail: mismatched classifications (for investigation)
-- ---------------------------------------------------------------------------
-- Uncomment to see specific mismatches:
--
-- SELECT *
-- FROM joined
-- WHERE status = 'mismatch'
-- ORDER BY rcv_accession
-- LIMIT 100;

-- ---------------------------------------------------------------------------
-- 3. Review status comparison
-- ---------------------------------------------------------------------------
-- Uncomment to compare review status values:
--
-- SELECT
--   CASE
--     WHEN computed_review_status = clinvar_review_status THEN 'match'
--     ELSE 'mismatch'
--   END AS review_status_match,
--   COUNT(*) AS count
-- FROM joined
-- WHERE status != 'missing_from_computed' AND status != 'missing_from_clinvar'
-- GROUP BY 1;
