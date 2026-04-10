# RCV Procedures

## Overview

RCV statement generation is split across two stored procedures that run sequentially:

1. **`gks_rcv_proc`** -- builds aggregation tables through a four-layer hierarchy, progressively combining SCV-level data into condition-specific RCV-level summaries
2. **`gks_rcv_statement_proc`** -- transforms those aggregation tables into GKS-formatted RCV statements with nested evidence lines and condition data

Both procedures accept the same parameters:

| Parameter | Type | Description |
|---|---|---|
| `on_date` | `DATE` | Identifies the ClinVar release schema to process |
| `debug` | `BOOL` | When `TRUE`, writes temp tables as persistent tables for inspection |

---

## gks_rcv_proc (Aggregation)

This procedure materializes base data from SCV-level sources and builds four layers of progressively broader aggregation. Each layer groups records at a coarser level, applying submission-level-specific classification and review status logic. The aggregation logic mirrors VCV but operates per (variation, condition) pair rather than per variation.

### Step 1: Build temp_rcv_base_data

Materializes base data by joining `scv_summary` with `rcv_mapping` (unnesting `scv_accessions`), `rcv_accession`, `clinvar_statement_types`, `clinvar_clinsig_types`, `clinvar_proposition_types`, and `submission_level`. This step produces one row per SCV with all the metadata needed for condition-specific aggregation.

Key derivations:

- **full_rcv_id** -- formatted as `{rcv_accession}.{version}` from `rcv_accession`
- **trait_set_id** -- the condition grouping key from `rcv_mapping`, used in all downstream GROUP BY clauses
- **original_submission_level** -- raw code from the `submission_level` lookup table
- **submission_level** -- remaps PG and EP to `PGEP`; all other codes pass through unchanged
- **submission_level_label** -- human-readable label from the lookup table
- **statement_group** -- category code from `clinvar_statement_types` (G for germline, S for somatic)
- **prop_type** -- proposition type code from `clinvar_proposition_types`

**Output:** `temp_rcv_base_data` -- one row per SCV with classification, proposition, condition, and submission level metadata. <span class="role-badge badge-internal">Internal</span>

---

### Step 2: Build gks_rcv_layer1_base_agg

Core aggregation step that groups SCVs by `(rcv_accession, trait_set_id, statement_group, prop_type, submission_level, tier_grouping)`. Tier grouping is only populated for somatic clinical impact (sci) propositions; it is NULL for all other proposition types.

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

ID format: `{RCV}.{ver}-{group}-{prop}-{level}[-{tier}]`

**Output:** `gks_rcv_layer1_base_agg` -- one row per aggregation group. <span class="role-badge badge-pipeline">Pipeline table</span>

---

### Step 3: Build gks_rcv_layer2_tier_agg

Aggregates Layer 1 records by tier within each submission level. This layer applies only to somatic clinical impact (sci) propositions where `tier_grouping IS NOT NULL`. PGEP never appears at this layer because PGEP is germline-only.

The step ranks tiers by `tier_priority` (ascending) and SCV count (descending), then designates:

- The top-ranked tier as contributing
- All other tiers as non-contributing
- Secondary traits from non-contributing tiers that are not already present in the top tier

The aggregate label appends secondary trait information when applicable.

ID format: `{RCV}.{ver}-{group}-{prop}-{level}`

**Output:** `gks_rcv_layer2_tier_agg` -- one row per submission level within a proposition type. <span class="role-badge badge-pipeline">Pipeline table</span>

---

### Step 4: Build gks_rcv_layer3_prop_agg

Submission-level aggregator using winner-takes-all ranking. Takes a unified input of Layer 2 output (tiered records) combined with non-tiered Layer 1 records (`tier_grouping IS NULL`).

Records are ranked by submission level within each `(rcv_accession, trait_set_id, statement_group, prop_type)` group, with PGEP receiving rank 5 (above PG's rank of 4). The highest-ranked submission level becomes the contributing result; all others become non-contributing.

A key difference from VCV: the winner-takes-all partition is by `rcv_accession` (not `variation_id`), since each RCV accession already represents a unique (variation, condition) pair.

Non-contributing details are preserved as an array of structs containing the layer ID, submission level, aggregate label, and conflicting explanation for each non-contributing record.

ID format: `{RCV}.{ver}-{group}-{prop}`

**Output:** `gks_rcv_layer3_prop_agg` -- one row per proposition type within a statement group. <span class="role-badge badge-pipeline">Pipeline table</span>

---

### Step 5: Build gks_rcv_layer4_group_agg

Final group aggregator for germline statements only (`statement_group = 'G'`). Ranks Layer 3 records by submission level within each `(rcv_accession, trait_set_id, statement_group)` group, then designates:

- The top-ranked proposition type(s) as contributing (uses `RANK`, so ties are included)
- All lower-ranked proposition types as non-contributing

Contributing records' aggregate labels are concatenated with semicolons, ordered by proposition display order.

ID format: `{RCV}.{ver}-{group}`

**Output:** `gks_rcv_layer4_group_agg` -- one row per statement group (germline only). <span class="role-badge badge-pipeline">Pipeline table</span>

---

## gks_rcv_statement_proc (Statement Generation)

This procedure transforms the aggregation tables produced by `gks_rcv_proc` into GKS-formatted RCV statements. It resolves condition data, generates statement structures at each layer (BASE), inlines evidence items and populates PGEP classification fields (PRE), then combines the results into a final output table.

The procedure executes 10 sections: condition data resolution, four BASE layers, four PRE layers, and one FINAL union.

---

### Condition Data Resolution

Before building statement structures, the procedure materializes `temp_rcv_condition_data` by joining `rcv_mapping` (unnesting `scv_accessions`) with `gks_scv_condition_sets`. This table provides the condition name and condition concept data needed to populate `objectConditionClassification` ConceptSets in the proposition.

**Output:** `temp_rcv_condition_data` -- condition data per RCV accession. <span class="role-badge badge-internal">Internal</span>

---

### Layers 1--4 BASE

Each BASE section reads from the corresponding aggregation table and produces a statement structure with the following fields:

| Field | Description |
|---|---|
| `classification_mappableConcept` | For non-PGEP: a simple Classification concept with `name` and optional `conflictingExplanation` extension |
| `classification_conceptSet` | NULL placeholder -- populated in the PRE layer for PGEP with a single classification group |
| `classification_conceptSetSet` | NULL placeholder -- populated in the PRE layer for PGEP with multiple classification groups |
| `proposition` | Contains `objectConditionClassification` (a ConceptSet combining condition + classification as 2 concepts), `aggregateQualifiers`, `subjectVariant` reference, type `VariantAggregateConditionClassificationProposition`, and predicate `hasConditionClassification` |
| `extensions` | Array with `clinvarReviewStatus` value |
| `evidenceLines` | References to child layer IDs (SCV IDs for L1, contributing/non-contributing statement IDs for L2--L4) |

The `objectConditionClassification` ConceptSet is built by joining condition data from `temp_rcv_condition_data` with the aggregate classification label, producing a two-concept AND-group:

1. A Disease/condition concept (from condition data)
2. A Classification concept (from the aggregate label)

Layer-specific differences:

- **Layer 1 BASE** -- references SCV IDs directly in evidence lines; includes `ClassificationTier` qualifier for tiered records
- **Layer 2 BASE** -- references Layer 1 IDs; somatic only, never PGEP; includes contributing and non-contributing evidence lines
- **Layer 3 BASE** -- references a single contributing child (from L2 or L1) plus non-contributing details; `aggregateQualifiers` omit `SubmissionLevel` (since this layer aggregates across levels)
- **Layer 4 BASE** -- references Layer 3 IDs; germline only; `aggregateQualifiers` contain only `AssertionGroup`

**Output:** `temp_rcv_layer{N}_statements` -- one per layer. <span class="role-badge badge-internal">Internal</span>

---

### Layer 1 PRE

Inlines SCV evidence items from `gks_scv_statement_pre` and populates the PGEP classification and objectConditionClassification fields.

For PGEP records, the step:

1. Joins each contributing SCV to `gks_scv_statement_pre`, `scv_summary`, `gks_scv_condition_sets`, and `submission_level` to extract per-SCV classification, condition, and submission level data
2. Builds ConceptSet AND-groups for **classification** -- each group contains three concepts (Classification, Condition, SubmissionLevel) plus a `description` extension
3. Builds ConceptSet AND-groups for **objectConditionClassification** -- same structure but deduplicated across submitters and without extensions
4. Populates `classification_conceptSet` (single classification) or `classification_conceptSetSet` (multiple classifications) based on SCV count
5. Applies the same conceptSet/conceptSetSet logic to objectConditionClassification, using `objectConditionClassification_conceptSetSet` for the multiple case

For non-PGEP records, the existing `classification_mappableConcept` and `objectConditionClassification` are carried forward unchanged.

Evidence lines are rewritten to reference SCV IDs in `clinvar.submission:{scv_id}` format.

**Output:** `temp_rcv_layer1_pre` <span class="role-badge badge-internal">Internal</span>

---

### Layer 2 PRE

Inlines Layer 1 PRE evidence items into Layer 2 statements. This layer is somatic only and never contains PGEP, so classification and objectConditionClassification are passed through without modification.

Contributing and non-contributing evidence lines are rebuilt with the full inlined Layer 1 PRE statement structures.

**Output:** `temp_rcv_layer2_pre` <span class="role-badge badge-internal">Internal</span>

---

### Layer 3 PRE

Inlines evidence items from either Layer 2 PRE or Layer 1 PRE (using COALESCE to check L2 first, then L1). Additionally propagates classification and objectConditionClassification from the single contributing child:

- `classification_conceptSet` and `classification_conceptSetSet` are copied from the contributing child when present
- `objectConditionClassification_conceptSet` and `objectConditionClassification_conceptSetSet` are likewise propagated
- `objectConditionClassification` (mappable ConceptSet) is propagated when the child has one

This propagation ensures that PGEP concept structures flow upward through the layer hierarchy.

**Output:** `temp_rcv_layer3_pre` <span class="role-badge badge-internal">Internal</span>

---

### Layer 4 PRE

Inlines Layer 3 PRE evidence items into Layer 4 statements. For PGEP-type records where contributing children have conceptSet or conceptSetSet data, this step combines the inner AND-groups from all contributing Layer 3 children:

- Collects all inner concept groups from contributing children's `classification_conceptSet` and `classification_conceptSetSet`
- Re-counts the combined groups: 1 group produces a `classification_conceptSet`, 2+ groups produce a `classification_conceptSetSet`
- Applies the same logic to objectConditionClassification

Children that only have `mappableConcept` (non-PGEP) are excluded from this recombination -- their classification stays as `mappableConcept` on the Layer 4 BASE.

**Output:** `temp_rcv_layer4_pre` <span class="role-badge badge-internal">Internal</span>

---

### FINAL

Combines Layer 4 PRE (germline) and Layer 3 PRE (somatic, filtered by `id LIKE '%-S-%'`) via `UNION ALL` into the final output table.

**Output:** `gks_rcv_statement_pre` -- the complete set of RCV statements ready for JSON serialization by `gks_json_proc`. <span class="role-badge badge-pipeline">Pipeline table</span>

---

## Output Tables

| Table | Procedure | Description | Role |
|---|---|---|---|
| `temp_rcv_base_data` | `gks_rcv_proc` | Materialized SCV base data with condition and submission level mappings | <span class="role-badge badge-internal">Internal</span> |
| `gks_rcv_layer1_base_agg` | `gks_rcv_proc` | Base aggregation by rcv_accession + group + prop + level (+ tier) | <span class="role-badge badge-pipeline">Pipeline table</span> |
| `gks_rcv_layer2_tier_agg` | `gks_rcv_proc` | Tier aggregation within submission level (somatic only) | <span class="role-badge badge-pipeline">Pipeline table</span> |
| `gks_rcv_layer3_prop_agg` | `gks_rcv_proc` | Submission level aggregation with winner-takes-all (partitioned by rcv_accession) | <span class="role-badge badge-pipeline">Pipeline table</span> |
| `gks_rcv_layer4_group_agg` | `gks_rcv_proc` | Group aggregation across proposition types (germline only) | <span class="role-badge badge-pipeline">Pipeline table</span> |
| `temp_rcv_condition_data` | `gks_rcv_statement_proc` | Condition data resolved from rcv_mapping + gks_scv_condition_sets | <span class="role-badge badge-internal">Internal</span> |
| `temp_rcv_layer{N}_statements` | `gks_rcv_statement_proc` | BASE statement structures for layers 1--4 | <span class="role-badge badge-internal">Internal</span> |
| `temp_rcv_layer{N}_pre` | `gks_rcv_statement_proc` | PRE statement structures with inlined evidence for layers 1--4 | <span class="role-badge badge-internal">Internal</span> |
| `gks_rcv_statement_pre` | `gks_rcv_statement_proc` | Final combined RCV statements (germline L4 + somatic L3) | <span class="role-badge badge-pipeline">Pipeline table</span> |

---

## Dependencies

### gks_rcv_proc

- **Source Tables**: `scv_summary`, `rcv_mapping`, `rcv_accession`, `gks_scv_condition_mapping`
- **Lookup Tables**: `clinvar_statement_types`, `clinvar_clinsig_types`, `clinvar_proposition_types`, `submission_level`
- **UDFs**: `clinvar_ingest.schema_on`, `clinvar_ingest.cleanup_temp_tables`
- **Upstream Procedures**: `gks_scv_statement_proc` (for `gks_scv_condition_mapping`)

### gks_rcv_statement_proc

- **Aggregation Tables**: `gks_rcv_layer1_base_agg`, `gks_rcv_layer2_tier_agg`, `gks_rcv_layer3_prop_agg`, `gks_rcv_layer4_group_agg`
- **Condition Tables**: `rcv_mapping`, `gks_scv_condition_sets`
- **Statement Tables**: `gks_scv_statement_pre`
- **Source Tables**: `scv_summary`
- **Lookup Tables**: `clinvar_statement_categories`, `clinvar_proposition_types`, `submission_level`, `clinvar_clinsig_types`
- **UDFs**: `clinvar_ingest.schema_on`, `clinvar_ingest.cleanup_temp_tables`
- **Upstream Procedures**: `gks_rcv_proc`, `gks_scv_statement_proc`
- **Downstream Consumers**: `gks_json_proc`
