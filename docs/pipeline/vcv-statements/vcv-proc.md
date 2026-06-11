# VCV Procedures

## Overview

VCV statement generation is split across two stored procedures that run sequentially:

1. **`gks_vcv_proc`** -- builds aggregation tables through a two-layer aggregation hierarchy, progressively combining SCV-level data into variant-level summaries
2. **`gks_vcv_statement_proc`** -- transforms those aggregation tables into GKS-formatted VCV statements with nested evidence lines

Both procedures accept the same parameters:

| Parameter | Type | Description |
|---|---|---|
| `on_date` | `DATE` | Identifies the ClinVar release schema to process |
| `debug` | `BOOL` | When `TRUE`, writes temp tables as persistent tables for inspection |

---

## gks_vcv_proc (Aggregation)

This procedure materializes base data from SCV-level sources and builds two layers of progressively broader aggregation. Each layer groups records at a coarser level, applying submission-level-specific classification and review status logic. See [Aggregation Rules](vcv-aggregation-rules.md) for the full logic reference.

### Step 1: Build temp_vcv_base_data

Materializes base data by joining `scv_summary` with `variation_archive`, `clinvar_statement_types`, `clinvar_clinsig_types`, `clinvar_proposition_types`, and `submission_level`. This step produces one row per SCV with all the metadata needed for aggregation.

Key derivations:

- **full_vcv_id** -- formatted as `{variation_id}.{version}` from `variation_archive`
- **submission_level** -- code from the `submission_level` lookup table (PG, EP, CP, NOCP, NOCL, FLAG)
- **submission_level_label** -- human-readable label from the lookup table
- **statement_group** -- category code from `clinvar_statement_types` (G for germline, S for somatic)
- **prop_type** -- proposition type code from `clinvar_proposition_types`

**Output:** `temp_vcv_base_data` -- one row per SCV with classification, proposition, and submission level metadata. <span class="role-badge badge-internal">Internal</span>

---

### Step 2: Build gks_vcv_grouping_base_agg

Core aggregation step that groups SCVs by `(variation_id, statement_group, prop_type, submission_level, tier_grouping)`. Tier grouping is only populated for somatic clinical impact (sci) propositions; it is NULL for all other proposition types.

The step uses four CTEs:

| CTE | Purpose |
|---|---|
| `core_agg` | GROUP BY with `ARRAY_AGG` of SCV IDs and unique submitter count |
| `label_counts` | Per-classification-label SCV counts with significance values |
| `conflict_strings` | Aggregated classification labels, significance counts, and formatted conflict explanation strings |
| `somatic_conditions` | Condition names for somatic sci propositions, joined from `gks_scv_condition_mapping` |

The `final_prep` CTE applies submission-level-specific logic:

- **PG / EP / CP** -- conflict detection and concordance logic; CP additionally receives review-status upgrades based on single vs multiple submitters
- **FLAG** -- fixed label: "no classifications from unflagged records"
- **NOCL** -- passthrough label: "not provided"
- **aggregate_review_status** -- derived for all submission levels based on the level itself and, for CP, submitter count and conflict state

ID format: `{VCV}.{ver}-{GROUP}-{PROP}-{LEVEL}[-{TIER}]` (all tier components are uppercase, e.g., `VCV000012582.63-G-SCI-CP-PATHOGENIC`)

**Output:** `gks_vcv_grouping_base_agg` -- one row per aggregation group. <span class="role-badge badge-pipeline">Pipeline table</span>

---

### Step 3: Build gks_vcv_grouping_tier_agg

Aggregates Base Grouping records by tier within each submission level. This layer applies only to somatic clinical impact (sci) propositions where `tier_grouping IS NOT NULL`.

The step ranks tiers by `tier_priority` (ascending) and SCV count (descending), then designates:

- The top-ranked tier as contributing
- All other tiers as non-contributing
- Secondary traits from non-contributing tiers that are not already present in the top tier

The aggregate label appends secondary trait information when applicable (e.g., "+lower levels of evidence for N other tumor types").

ID format: `{VCV}.{ver}-{GROUP}-{PROP}-{LEVEL}` (uppercase components)

**Output:** `gks_vcv_grouping_tier_agg` -- one row per submission level within a proposition type. <span class="role-badge badge-pipeline">Pipeline table</span>

---

### Step 4: Build gks_vcv_aggregate_contribution

Submission-level aggregator using winner-takes-all ranking. Takes a unified input of Tier Grouping output (tiered records) combined with non-tiered Base Grouping records (`tier_grouping IS NULL`).

Records are ranked by submission level within each `(variation_id, statement_group, prop_type)` group using the explicit ordering `PG=6, EP=5, CP=4, NOCP=3, NOCL=2, FLAG=1`. The highest-ranked submission level becomes the contributing result; all others become non-contributing.

Non-contributing details are preserved as an array of structs containing the layer ID, submission level, aggregate label, and conflicting explanation for each non-contributing record.

ID format: `{VCV}.{ver}-{GROUP}-{PROP}` (uppercase components)

**Output:** `gks_vcv_aggregate_contribution` -- one row per proposition type within a statement group. <span class="role-badge badge-pipeline">Pipeline table</span>

---

## gks_vcv_statement_proc (Statement Generation)

This procedure transforms the aggregation tables produced by `gks_vcv_proc` into GKS-formatted VCV statements. It generates statement structures at each layer (BASE), inlines evidence items from the layer below (PRE), then combines the results into a final output table.

The procedure executes 7 sections: three BASE steps, three PRE steps, and one FINAL union.

---

### BASE Statement Steps

Each BASE section reads from the corresponding aggregation table and produces a statement structure with the following fields:

| Field | Description |
|---|---|
| `classification` | A simple Classification concept with `name` and optional `conflictingExplanation` extension |
| `confidence` | The submission level label (e.g., `"expert panel"`, `"assertion criteria provided"`) |
| `direction` | Derived from the classification label; passed through from the contributing SCV for single-SCV aggregations |
| `strength` | Derived from the classification label; passed through from the contributing SCV for single-SCV aggregations |
| `proposition` | Contains `objectCondition` (the unique conditions from contributing SCVs — a single MappableConcept or an OR ConceptSet), the SCV-matching proposition type from `clinvar_proposition_types.gks_type`, the SCV-matching predicate from `clinvar_proposition_types.gks_predicate`, and `subjectVariant` reference |
| `extensions` | Array with `clinvarReviewStatus` value |
| `evidenceLines` | References to child layer IDs (SCV IDs for Base Grouping, contributing/non-contributing statement IDs for Tier Grouping and Aggregate Contribution) |

Step-specific differences:

- **Base Grouping BASE** -- references SCV IDs directly in evidence lines; includes tier info in the proposition for tiered records
- **Tier Grouping BASE** -- references Base Grouping IDs; somatic only; includes contributing and non-contributing evidence lines
- **Aggregate Contribution BASE** -- references a single contributing child (from Tier Grouping or Base Grouping) plus non-contributing details

**Output:** `temp_vcv_grouping_base_statements`, `temp_vcv_grouping_tier_statements`, `temp_vcv_agg_contribution_statements` -- one per step. <span class="role-badge badge-internal">Internal</span>

---

### Grouping Base PRE

Inlines SCV evidence items into each Base Grouping BASE statement. Evidence lines are rewritten to reference SCV IDs in `clinvar.submission:{scv_id}` format. The `classification`, `confidence`, `direction`, `strength`, and `proposition` fields are carried forward from the BASE statement unchanged.

**Output:** `temp_vcv_grouping_base_pre` <span class="role-badge badge-internal">Internal</span>

---

### Grouping Tier PRE

Inlines Grouping Base PRE evidence items into Tier Grouping statements. This step is somatic only. Classification, confidence, direction, strength, and proposition are passed through without modification.

Contributing and non-contributing evidence lines are rebuilt with the full inlined Grouping Base PRE statement structures.

**Output:** `temp_vcv_grouping_tier_pre` <span class="role-badge badge-internal">Internal</span>

---

### Aggregate Contribution PRE

Inlines evidence items from either Grouping Tier PRE or Grouping Base PRE (using COALESCE to check Tier Grouping first, then Base Grouping). Classification, confidence, direction, strength, and proposition on the Aggregate Contribution statement are taken directly from the Aggregate Contribution BASE row and are not modified at the PRE step.

**Output:** `temp_vcv_agg_contribution_pre` <span class="role-badge badge-internal">Internal</span>

---

### FINAL

Selects all Aggregate Contribution PRE statements into the final output table.

**Output:** `gks_vcv_statement_pre` -- the complete set of VCV statements ready for JSON serialization by `gks_json_proc`. <span class="role-badge badge-pipeline">Pipeline table</span>

---

## Output Tables

| Table | Procedure | Description | Role |
|---|---|---|---|
| `temp_vcv_base_data` | `gks_vcv_proc` | Materialized SCV base data with submission level mappings | <span class="role-badge badge-internal">Internal</span> |
| `gks_vcv_grouping_base_agg` | `gks_vcv_proc` | Base aggregation by variation + group + prop + level (+ tier) | <span class="role-badge badge-pipeline">Pipeline table</span> |
| `gks_vcv_grouping_tier_agg` | `gks_vcv_proc` | Tier aggregation within submission level (somatic only) | <span class="role-badge badge-pipeline">Pipeline table</span> |
| `gks_vcv_aggregate_contribution` | `gks_vcv_proc` | Submission level aggregation with winner-takes-all | <span class="role-badge badge-pipeline">Pipeline table</span> |
| `temp_vcv_grouping_base_statements` | `gks_vcv_statement_proc` | BASE statement structures for Base Grouping | <span class="role-badge badge-internal">Internal</span> |
| `temp_vcv_grouping_tier_statements` | `gks_vcv_statement_proc` | BASE statement structures for Tier Grouping | <span class="role-badge badge-internal">Internal</span> |
| `temp_vcv_agg_contribution_statements` | `gks_vcv_statement_proc` | BASE statement structures for Aggregate Contribution | <span class="role-badge badge-internal">Internal</span> |
| `temp_vcv_grouping_base_pre` | `gks_vcv_statement_proc` | PRE statement structures with inlined SCV evidence | <span class="role-badge badge-internal">Internal</span> |
| `temp_vcv_grouping_tier_pre` | `gks_vcv_statement_proc` | PRE statement structures with inlined Base Grouping evidence | <span class="role-badge badge-internal">Internal</span> |
| `temp_vcv_agg_contribution_pre` | `gks_vcv_statement_proc` | PRE statement structures with inlined Tier/Base Grouping evidence | <span class="role-badge badge-internal">Internal</span> |
| `gks_vcv_statement_pre` | `gks_vcv_statement_proc` | Final VCV statements from Aggregate Contribution PRE | <span class="role-badge badge-pipeline">Pipeline table</span> |

---

## Dependencies

### gks_vcv_proc

- **Source Tables**: `scv_summary`, `variation_archive`, `gks_scv_condition_mapping`
- **Lookup Tables**: `clinvar_statement_types`, `clinvar_clinsig_types`, `clinvar_proposition_types`, `submission_level`
- **UDFs**: `clinvar_ingest.schema_on`, `clinvar_ingest.cleanup_temp_tables`
- **Upstream Procedures**: `gks_scv_statement_proc` (for `gks_scv_condition_mapping`)

### gks_vcv_statement_proc

- **Aggregation Tables**: `gks_vcv_grouping_base_agg`, `gks_vcv_grouping_tier_agg`, `gks_vcv_aggregate_contribution`
- **Statement Tables**: `gks_scv_statement_pre`, `gks_scv_condition_sets`
- **Source Tables**: `scv_summary`
- **Lookup Tables**: `clinvar_statement_categories`, `clinvar_proposition_types`, `submission_level`, `clinvar_clinsig_types`
- **UDFs**: `clinvar_ingest.schema_on`, `clinvar_ingest.cleanup_temp_tables`
- **Upstream Procedures**: `gks_vcv_proc`, `gks_scv_statement_proc`
- **Downstream Consumers**: `gks_json_proc`
