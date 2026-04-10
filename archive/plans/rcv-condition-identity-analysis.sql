-- =============================================================================
-- RCV Condition Identity Analysis
-- =============================================================================
-- Compares two approaches for condition grouping in the RCV aggregate proc:
--   Option A: trait_set_id (raw ClinVar trait set assignment from rcv_accession)
--   Option B: resolved condition identity (normalized trait_id from gks_scv_condition_mapping)
--
-- Purpose: Quantify how many RCVs would group differently under each approach.
-- Run against: a dated schema (e.g., clinvar_2026_04_06)
-- =============================================================================

-- Replace {S} with the target schema before running (e.g., clinvar_2026_04_06)

-- ---------------------------------------------------------------------------
-- 1. Per-RCV: count distinct resolved trait_ids vs the single trait_set_id
-- ---------------------------------------------------------------------------
-- This shows RCVs where SCVs within the same RCV resolve to different
-- individual trait identities after the condition mapping pipeline.
WITH rcv_scv_conditions AS (
  SELECT
    rm.rcv_accession,
    ra.trait_set_id,
    scv_id,
    cm.trait_id,
    cm.trait_name,
    cm.assign_type
  FROM `{S}.rcv_mapping` rm
  CROSS JOIN UNNEST(rm.scv_accessions) AS scv_id
  JOIN `{S}.rcv_accession` ra ON rm.rcv_accession = ra.id
  LEFT JOIN `{S}.gks_scv_condition_mapping` cm ON cm.scv_id = scv_id
),

-- ---------------------------------------------------------------------------
-- 2. Aggregate: per RCV, how many distinct trait_ids do SCVs resolve to?
-- ---------------------------------------------------------------------------
rcv_trait_diversity AS (
  SELECT
    rcv_accession,
    trait_set_id,
    COUNT(DISTINCT scv_id) AS scv_count,
    COUNT(DISTINCT trait_id) AS distinct_resolved_trait_ids,
    ARRAY_AGG(DISTINCT trait_id IGNORE NULLS) AS resolved_trait_ids,
    ARRAY_AGG(DISTINCT trait_name IGNORE NULLS) AS resolved_trait_names,
    COUNTIF(trait_id IS NULL) AS unresolved_count,
    ARRAY_AGG(DISTINCT assign_type IGNORE NULLS) AS assign_types
  FROM rcv_scv_conditions
  GROUP BY rcv_accession, trait_set_id
)

-- ---------------------------------------------------------------------------
-- 3. Summary report
-- ---------------------------------------------------------------------------
SELECT
  -- Total RCVs
  COUNT(*) AS total_rcvs,

  -- RCVs where all SCVs resolve to the same single trait_id
  COUNTIF(distinct_resolved_trait_ids = 1 AND unresolved_count = 0) AS uniform_single_trait,

  -- RCVs where SCVs resolve to multiple different trait_ids (divergence)
  COUNTIF(distinct_resolved_trait_ids > 1) AS divergent_resolved_traits,

  -- RCVs with some unresolved SCVs (trait_id is NULL)
  COUNTIF(unresolved_count > 0) AS has_unresolved_scvs,

  -- RCVs where all SCVs are unresolved
  COUNTIF(distinct_resolved_trait_ids = 0) AS all_unresolved

FROM rcv_trait_diversity;

-- ---------------------------------------------------------------------------
-- 4. Detail: RCVs with divergent resolved traits (for manual review)
-- ---------------------------------------------------------------------------
-- Uncomment to see the specific RCVs where grouping would differ:
--
-- SELECT *
-- FROM rcv_trait_diversity
-- WHERE distinct_resolved_trait_ids > 1
-- ORDER BY distinct_resolved_trait_ids DESC
-- LIMIT 100;

-- ---------------------------------------------------------------------------
-- 5. Impact on aggregation: would any RCV split into multiple groups?
-- ---------------------------------------------------------------------------
-- This checks if using resolved trait_id instead of trait_set_id would
-- cause a single RCV to produce multiple aggregate statements.
--
-- SELECT
--   rcv_accession,
--   trait_set_id,
--   scv_count,
--   distinct_resolved_trait_ids,
--   resolved_trait_names
-- FROM rcv_trait_diversity
-- WHERE distinct_resolved_trait_ids > 1
--   AND distinct_resolved_trait_ids != scv_count  -- not just 1:1 divergence
-- ORDER BY scv_count DESC
-- LIMIT 50;
