# VCV Procedures

## Overview

VCV statement generation is split across two stored procedures that run sequentially:

1. **`gks_vcv_proc`** -- builds aggregation tables through a four-layer hierarchy, progressively combining SCV-level data into variant-level summaries
2. **`gks_vcv_statement_proc`** -- transforms those aggregation tables into GKS-formatted VCV statements with nested evidence lines

Both procedures accept the same parameters:

| Parameter | Type | Description |
|---|---|---|
| `on_date` | `DATE` | Identifies the ClinVar release schema to process |
| `debug` | `BOOL` | When `TRUE`, writes temp tables as persistent tables for inspection |

---

## gks_vcv_proc (Aggregation)

This procedure materializes base data from SCV-level sources and builds four layers of progressively broader aggregation. Each layer groups records at a coarser level, applying submission-level-specific classification and review status logic. See [Aggregation Rules](vcv-aggregation-rules.md) for the full logic reference.

### Step 1: Build temp_vcv_base_data

Materializes base data by joining `scv_summary` with `variation_archive`, `clinvar_statement_types`, `clinvar_clinsig_types`, `clinvar_proposition_types`, and `submission_level`. This step produces one row per SCV with all the metadata needed for aggregation.

Key derivations:

- **full_vcv_id** -- formatted as `{variation_id}.{version}` from `variation_archive`
- **original_submission_level** -- raw code from the `submission_level` lookup table
- **submission_level** -- remaps PG and EP to `PGEP`; all other codes pass through unchanged
- **submission_level_label** -- human-readable label from the lookup table
- **statement_group** -- category code from `clinvar_statement_types` (G for germline, S for somatic)
- **prop_type** -- proposition type code from `clinvar_proposition_types`

**Output:** `temp_vcv_base_data` -- one row per SCV with classification, proposition, and submission level metadata. <span class="role-badge badge-internal">Internal</span>

---

### Step 2: Build gks_vcv_layer1_base_agg

Core aggregation step that groups SCVs by `(variation_id, statement_group, prop_type, submission_level, tier_grouping)`. Tier grouping is only populated for somatic clinical impact (sci) propositions; it is NULL for all other proposition types.

The step uses four CTEs:

| CTE | Purpose |
|---|---|
| `core_agg` | GROUP BY with `ARRAY_AGG` of SCV IDs, contributing submission levels, and unique submitter count |
| `label_counts` | Per-classification-label SCV counts with significance values |
| `conflict_strings` | Aggregated classification labels, significance counts, and formatted conflict explanation strings |
| `somatic_conditions` | Condition names for somatic sci propositions, joined from `gks_scv_condition_mapping` |

The `final_prep` CTE applies submission-level-specific logic:

- **PGEP** -- no conflict detection; `actual_agg_classif_label` is NULL (PGEP uses the array format, not a single label); `pgep_strength` derived from contributing levels (PG, EP, or PGEP)
- **CP** -- conflict detection with review status upgrades: single submitter, multiple submitters with no conflicts, or conflicting classifications
- **FLAG** -- fixed label: "no classifications from unflagged records"
- **NOCL** -- passthrough label: "not provided"
- **aggregate_review_status** -- derived for all submission levels based on submitter count and conflict state

ID format: `{VCV}.{ver}-{group}-{prop}-{level}[-{tier}]`

**Output:** `gks_vcv_layer1_base_agg` -- one row per aggregation group. <span class="role-badge badge-pipeline">Pipeline table</span>

---

### Step 3: Build gks_vcv_layer2_tier_agg

Aggregates Layer 1 records by tier within each submission level. This layer applies only to somatic clinical impact (sci) propositions where `tier_grouping IS NOT NULL`. PGEP never appears at this layer because PGEP is germline-only.

The step ranks tiers by `tier_priority` (ascending) and SCV count (descending), then designates:

- The top-ranked tier as contributing
- All other tiers as non-contributing
- Secondary traits from non-contributing tiers that are not already present in the top tier

The aggregate label appends secondary trait information when applicable (e.g., "+lower levels of evidence for N other tumor types").

ID format: `{VCV}.{ver}-{group}-{prop}-{level}`

**Output:** `gks_vcv_layer2_tier_agg` -- one row per submission level within a proposition type. <span class="role-badge badge-pipeline">Pipeline table</span>

---

### Step 4: Build gks_vcv_layer3_prop_agg

Submission-level aggregator using winner-takes-all ranking. Takes a unified input of Layer 2 output (tiered records) combined with non-tiered Layer 1 records (`tier_grouping IS NULL`).

Records are ranked by submission level within each `(variation_id, statement_group, prop_type)` group, with PGEP receiving rank 5 (above PG's rank of 4). The highest-ranked submission level becomes the contributing result; all others become non-contributing.

Non-contributing details are preserved as an array of structs containing the layer ID, submission level, aggregate label, and conflicting explanation for each non-contributing record.

ID format: `{VCV}.{ver}-{group}-{prop}`

**Output:** `gks_vcv_layer3_prop_agg` -- one row per proposition type within a statement group. <span class="role-badge badge-pipeline">Pipeline table</span>

---

### Step 5: Build gks_vcv_layer4_group_agg

Final group aggregator for germline statements only (`statement_group = 'G'`). Ranks Layer 3 records by submission level within each `(variation_id, statement_group)` group, then designates:

- The top-ranked proposition type(s) as contributing (uses `RANK`, so ties are included)
- All lower-ranked proposition types as non-contributing

Contributing records' aggregate labels are concatenated with semicolons, ordered by proposition display order.

ID format: `{VCV}.{ver}-{group}`

**Output:** `gks_vcv_layer4_group_agg` -- one row per statement group (germline only). <span class="role-badge badge-pipeline">Pipeline table</span>

---

## gks_vcv_statement_proc (Statement Generation)

This procedure transforms the aggregation tables produced by `gks_vcv_proc` into GKS-formatted VCV statements. It generates statement structures at each layer (BASE), inlines evidence items and populates PGEP classification fields (PRE), then combines the results into a final output table.

The procedure executes 9 sections: four BASE layers, four PRE layers, and one FINAL union.

---

### Layers 1--4 BASE

Each BASE section reads from the corresponding aggregation table and produces a statement structure with the following fields:

| Field | Description |
|---|---|
| `classification_mappableConcept` | For non-PGEP: a simple Classification concept with `name` and optional `conflictingExplanation` extension |
| `classification_conceptSet` | NULL placeholder -- populated in the PRE layer for PGEP with a single classification group |
| `classification_conceptSetSet` | NULL placeholder -- populated in the PRE layer for PGEP with multiple classification groups |
| `proposition` | Contains `objectClassification` (same three-way split as classification), `aggregateQualifiers` (assertion group, proposition type, submission level, and optional tier), and `subjectVariant` reference |
| `extensions` | Array with `clinvarReviewStatus` value |
| `evidenceLines` | References to child layer IDs (SCV IDs for L1, contributing/non-contributing statement IDs for L2--L4) |

Layer-specific differences:

- **Layer 1 BASE** -- references SCV IDs directly in evidence lines; includes `ClassificationTier` qualifier for tiered records
- **Layer 2 BASE** -- references Layer 1 IDs; somatic only, never PGEP; includes contributing and non-contributing evidence lines
- **Layer 3 BASE** -- references a single contributing child (from L2 or L1) plus non-contributing details; `aggregateQualifiers` omit `SubmissionLevel` (since this layer aggregates across levels)
- **Layer 4 BASE** -- references Layer 3 IDs; germline only; `aggregateQualifiers` contain only `AssertionGroup`

**Output:** `temp_vcv_layer{N}_statements` -- one per layer. <span class="role-badge badge-internal">Internal</span>

---

### Layer 1 PRE

Inlines SCV evidence items from `gks_scv_statement_pre` and populates the PGEP classification and objectClassification fields.

For PGEP records, the step:

1. Joins each contributing SCV to `gks_scv_statement_pre`, `scv_summary`, `gks_scv_condition_sets`, and `submission_level` to extract per-SCV classification, condition, and submission level data
2. Builds ConceptSet AND-groups for **classification** -- each group contains three concepts (Classification, Condition, SubmissionLevel) plus a `description` extension
3. Builds ConceptSet AND-groups for **objectClassification** -- same structure but deduplicated across submitters and without extensions
4. Populates `classification_conceptSet` (single classification) or `classification_conceptSetSet` (multiple classifications) based on SCV count
5. Applies the same conceptSet/conceptSetSet logic to objectClassification

For non-PGEP records, the existing `classification_mappableConcept` and `objectClassification_mappableConcept` are carried forward unchanged.

Evidence lines are rewritten to reference SCV IDs in `clinvar.submission:{scv_id}` format.

**Output:** `temp_vcv_layer1_pre` <span class="role-badge badge-internal">Internal</span>

---

### Layer 2 PRE

Inlines Layer 1 PRE evidence items into Layer 2 statements. This layer is somatic only and never contains PGEP, so classification and objectClassification are passed through without modification.

Contributing and non-contributing evidence lines are rebuilt with the full inlined Layer 1 PRE statement structures.

**Output:** `temp_vcv_layer2_pre` <span class="role-badge badge-internal">Internal</span>

---

### Layer 3 PRE

Inlines evidence items from either Layer 2 PRE or Layer 1 PRE (using COALESCE to check L2 first, then L1). Additionally propagates classification and objectClassification from the single contributing child:

- `classification_conceptSet` and `classification_conceptSetSet` are copied from the contributing child when present
- `objectClassification_conceptSet` and `objectClassification_conceptSetSet` are likewise propagated
- `objectClassification_mappableConcept` is propagated when the child has one

This propagation ensures that PGEP concept structures flow upward through the layer hierarchy.

**Output:** `temp_vcv_layer3_pre` <span class="role-badge badge-internal">Internal</span>

---

### Layer 4 PRE

Inlines Layer 3 PRE evidence items into Layer 4 statements. For PGEP-type records where contributing children have conceptSet or conceptSetSet data, this step combines the inner AND-groups from all contributing Layer 3 children:

- Collects all inner concept groups from contributing children's `classification_conceptSet` and `classification_conceptSetSet`
- Re-counts the combined groups: 1 group produces a `classification_conceptSet`, 2+ groups produce a `classification_conceptSetSet`
- Applies the same logic to objectClassification

Children that only have `mappableConcept` (non-PGEP) are excluded from this recombination -- their classification stays as `mappableConcept` on the Layer 4 BASE.

**Output:** `temp_vcv_layer4_pre` <span class="role-badge badge-internal">Internal</span>

---

### FINAL

Combines Layer 4 PRE (germline) and Layer 3 PRE (somatic, filtered by `id LIKE '%-S-%'`) via `UNION ALL` into the final output table.

**Output:** `gks_vcv_statement_pre` -- the complete set of VCV statements ready for JSON serialization by `gks_json_proc`. <span class="role-badge badge-pipeline">Pipeline table</span>

---

## Output Tables

| Table | Procedure | Description | Role |
|---|---|---|---|
| `temp_vcv_base_data` | `gks_vcv_proc` | Materialized SCV base data with submission level mappings | <span class="role-badge badge-internal">Internal</span> |
| `gks_vcv_layer1_base_agg` | `gks_vcv_proc` | Base aggregation by variation + group + prop + level (+ tier) | <span class="role-badge badge-pipeline">Pipeline table</span> |
| `gks_vcv_layer2_tier_agg` | `gks_vcv_proc` | Tier aggregation within submission level (somatic only) | <span class="role-badge badge-pipeline">Pipeline table</span> |
| `gks_vcv_layer3_prop_agg` | `gks_vcv_proc` | Submission level aggregation with winner-takes-all | <span class="role-badge badge-pipeline">Pipeline table</span> |
| `gks_vcv_layer4_group_agg` | `gks_vcv_proc` | Group aggregation across proposition types (germline only) | <span class="role-badge badge-pipeline">Pipeline table</span> |
| `temp_vcv_layer{N}_statements` | `gks_vcv_statement_proc` | BASE statement structures for layers 1--4 | <span class="role-badge badge-internal">Internal</span> |
| `temp_vcv_layer{N}_pre` | `gks_vcv_statement_proc` | PRE statement structures with inlined evidence for layers 1--4 | <span class="role-badge badge-internal">Internal</span> |
| `gks_vcv_statement_pre` | `gks_vcv_statement_proc` | Final combined VCV statements (germline L4 + somatic L3) | <span class="role-badge badge-pipeline">Pipeline table</span> |

---

## Dependencies

### gks_vcv_proc

- **Source Tables**: `scv_summary`, `variation_archive`, `gks_scv_condition_mapping`
- **Lookup Tables**: `clinvar_statement_types`, `clinvar_clinsig_types`, `clinvar_proposition_types`, `submission_level`
- **UDFs**: `clinvar_ingest.schema_on`, `clinvar_ingest.cleanup_temp_tables`
- **Upstream Procedures**: `gks_scv_statement_proc` (for `gks_scv_condition_mapping`)

### gks_vcv_statement_proc

- **Aggregation Tables**: `gks_vcv_layer1_base_agg`, `gks_vcv_layer2_tier_agg`, `gks_vcv_layer3_prop_agg`, `gks_vcv_layer4_group_agg`
- **Statement Tables**: `gks_scv_statement_pre`, `gks_scv_condition_sets`
- **Source Tables**: `scv_summary`
- **Lookup Tables**: `clinvar_statement_categories`, `clinvar_proposition_types`, `submission_level`, `clinvar_clinsig_types`
- **UDFs**: `clinvar_ingest.schema_on`, `clinvar_ingest.cleanup_temp_tables`
- **Upstream Procedures**: `gks_vcv_proc`, `gks_scv_statement_proc`
- **Downstream Consumers**: `gks_json_proc`
