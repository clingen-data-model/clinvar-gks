# VCV Aggregate Classification Refactor Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the VCV aggregation pipeline to handle submission-level-specific classification logic with two new aggregate classification attributes and per-SCV descriptions.

**Architecture:** Three SQL stored procedures are modified: (1) SCV statement proc adds submission_level extension and description to every SCV, (2) VCV proc combines PG+EP into PGEP at Layer 1 with submission-level-specific aggregation logic, (3) VCV statement proc replaces the single `classification` struct with two mutually exclusive attributes — `aggregate_classification_single` and `aggregate_classification_array` — and adds `clinvarReviewStatus` to statement extensions.

**Tech Stack:** BigQuery SQL stored procedures using DECLARE/SET/REPLACE/EXECUTE IMMEDIATE pattern with `{S}`, `{CT}`, `{P}` placeholders.

---

## Design Reference

### Submission Level Codes

| Code | Label (for description template) | Rank | Stars |
|------|----------------------------------|------|-------|
| PG   | practice guideline               | 4    | 4     |
| EP   | expert panel                     | 3    | 3     |
| CP   | assertion criteria provided      | 1    | 1     |
| NOCP | no assertion criteria provided   | 0    | 0     |
| NOCL | no classification provided       | -1   | 0     |
| FLAG | flagged                          | -3   | 0     |

### SCV Classification Extension Format

Every SCV gets a `description` extension in `classification.extensions`:

```json
"classification": {
  "name": "Pathogenic",
  "primaryCoding": {"code": "...", "system": "..."},
  "extensions": [
    {
      "name": "description",
      "value": "for Breast cancer\nClassification is based on the expert panel submission\nMar 2024 by GeneDx"
    }
  ]
}
```

Template:
```
for <condition_name>\nClassification is based on the <submission_level_label> submission\n<evaluated_date> by <submitter_name>
```
Where:
- `<condition_name>` = condition.name for single conditions, or "`N` conditions" (where N is the count) for conditionSets with 2+ conditions
- `<submission_level_label>` = PG→'practice guideline', EP→'expert panel', CP→'assertion criteria provided', NOCP→'no assertion criteria provided', NOCL→'no classification provided', FLAG→'flagged'
- `<evaluated_date>` = FORMAT_DATE('%b %Y', last_evaluated) or '(-)' for null
- `<submitter_name>` = scv submitter name

### SCV Submission Level Extension

Every SCV also gets a `submissionLevel` extension in the statement-level `extensions`:

```json
"extensions": [
  {"name": "clinvarScvId", "value_string": "SCV000123456"},
  {"name": "clinvarScvVersion", "value_string": "1"},
  {"name": "clinvarScvReviewStatus", "value_string": "criteria provided, single submitter"},
  {"name": "submissionLevel", "value_string": "CP"},
  ...
]
```

### VCV Aggregate Classification Structures

Two mutually exclusive attributes replace the current `classification`:

**`aggregate_classification_single`** — used for CP, NOCP, NOCL, FLAG:
```json
{
  "conceptType": "AggregateClassification",
  "name": "Pathogenic/Likely pathogenic",
  "extension": [
    {"name": "conflictingExplanation", "value": "Pathogenic(3); Likely pathogenic(2)"}
  ]
}
```

**`aggregate_classification_array`** — used for PGEP only:
```json
[
  {
    "conceptType": "AggregateClassification",
    "name": "Pathogenic",
    "description": "for Breast cancer\nClassification is based on the expert panel submission\nMar 2024 by GeneDx"
  },
  {
    "conceptType": "AggregateClassification",
    "name": "Likely pathogenic",
    "description": "for Hereditary cancer\nClassification is based on the practice guideline submission\nJan 2023 by NCCN"
  }
]
```

### PGEP Proposition objectClassification

For non-PGEP submission levels, the proposition uses `objectClassification_mappableConcept` (single classification name) as it does today. No changes.

For PGEP, the proposition uses `objectClassification_conceptSet` to represent the **unique** combinations of (classification, condition, submission_level) from contributing SCVs. This array is deduplicated — if multiple submitters have the same classification for the same condition at the same submission level, it appears only once. **No submitter information** is included in the proposition.

```json
"proposition": {
  "type": "VariantAggregateClassificationProposition",
  "id": "12582.G.path.PGEP",
  "subjectVariant": "clinvar:12582",
  "predicate": "hasAggregateClassification",
  "objectClassification_mappableConcept": null,
  "objectClassification_conceptSet": {
    "type": "ConceptSet",
    "concepts": [
      {"conceptType": "Classification", "name": "Pathogenic", "condition": "Breast cancer", "submissionLevel": "expert panel"},
      {"conceptType": "Classification", "name": "Pathogenic", "condition": "Hereditary cancer", "submissionLevel": "practice guideline"}
    ],
    "membershipOperator": "OR"
  },
  "aggregateQualifiers": [...]
}
```

The concept struct for PGEP needs to be wider than the current `STRUCT<conceptType STRING, name STRING>`. It adds `condition` and `submissionLevel` fields. For non-PGEP layers that use `objectClassification_conceptSet` (currently none do, always NULL), these extra fields will be NULL and stripped by `JSON_STRIP_NULLS`.

### VCV Statement-Level Review Status Extension

Added to VCV statement top-level `extensions` array:
```json
{"name": "clinvarReviewStatus", "value": "<review_status_label>"}
```
Review status values by submission level:
- **PGEP (mixed)**: `"practice guideline and expert panel mix"`
- **PGEP (PG-only)**: `"practice guideline"`
- **PGEP (EP-only)**: `"reviewed by expert panel"`
- **CP (1 submitter)**: `"criteria provided, single submitter"`
- **CP (multiple, concordant)**: `"criteria provided, multiple submitters, no conflicts"`
- **CP (multiple, conflicting)**: `"criteria provided, conflicting classifications"`
- **NOCP**: `"no assertion criteria provided"`
- **NOCL**: `"no classification provided"`
- **FLAG**: `"flagged submission"`

### VCV Layer 1 Aggregation Rules by Submission Level

**PGEP (combined PG + EP):**
- PG and EP submissions are combined into a single "PGEP" grouping
- No concordance/conflict checking
- Collect array of per-SCV classifications (name + description from SCV)
- Strength: "PG" if only PG contributing, "EP" if only EP, "PGEP" if both

**CP:**
- Traditional aggregation with concordance/conflict detection
- Produces single classification label
- Review status may upgrade from "single submitter" to "multiple submitters, no conflicts" or "conflicting classifications"

**NOCP:**
- Traditional aggregation with concordance/conflict detection
- Produces single classification label
- No review status upgrade (stays "no assertion criteria provided")

**FLAG:**
- Always produces: "no classifications from unflagged records"
- No concordance/conflict checking

**NOCL:**
- Passes through as-is (single "not provided" label)
- No concordance/conflict checking

---

## Chunk 1: SCV Statement Changes

### Task 1: Add submission_level extension to SCV statements

**Files:**
- Modify: `src/procedures/gks-scv-statement-proc.sql` — Step 1 (temp_gks_scv) and Step 7 (final output)

The SCV statement proc currently does not capture submission_level. We need to:
1. Add `submission_level` to `temp_gks_scv` by joining `scv_summary.rank` to `submission_level.rank`
2. Add the `submissionLevel` extension to the final SCV statement output

- [ ] **Step 1.1: Add submission_level to temp_gks_scv query**

In `gks-scv-statement-proc.sql`, Step 1 (`query_scv_records`), add a JOIN to `submission_level` and select `sl.code AS submission_level` and `sl.label AS submission_level_label`:

After the existing JOIN to `clinvar_clinsig_types`:
```sql
LEFT JOIN `clinvar_ingest.submission_level` sl
  ON sl.rank = scv.rank
```

Add to the SELECT list (after `scv.classification_comment`):
```sql
sl.code AS submission_level,
sl.label AS submission_level_label,
```

Note: `scv` here refers to `scv_summary` (aliased as `scv` in the FROM clause via `{S}.scv_summary`).

- [ ] **Step 1.2: Add submissionLevel extension to final SCV output**

In Step 7 (`query_statement_scv_pre`), add the `submissionLevel` extension to the `extensions` array. In the `ARRAY_CONCAT(...)` that builds extensions, add after the `submittedScvLocalKey` block:

```sql
IF(
  scv.submission_level IS NULL,
  [],
  [STRUCT('submissionLevel' as name, scv.submission_level as value_string)]
),
```

- [ ] **Step 1.3: Commit**

```bash
git add src/procedures/gks-scv-statement-proc.sql
git commit -m "Add submissionLevel extension to SCV statements"
```

### Task 2: Add description extension to SCV classification

**Files:**
- Modify: `src/procedures/gks-scv-statement-proc.sql` — Step 7 (final output)

The SCV classification currently has `name` and `primaryCoding`. We need to add an `extensions` array containing the formatted description.

- [ ] **Step 2.1: Add condition name to temp_gks_scv or use existing condition data**

The condition name is available in `gks_scv_condition_sets` (via `condition.name` or `conditionSet` members). We need to derive a single condition name string. In Step 7's final SELECT, we can access the condition through the proposition join (`sp`).

Add a CTE at the top of Step 7 (inside the `query_statement_scv_pre` string, before `scv_citation`):

```sql
scv_condition_name AS (
  SELECT
    scv_id,
    CASE
      WHEN condition.name IS NOT NULL THEN condition.name
      WHEN ARRAY_LENGTH(conditionSet.conditions) >= 2
        THEN FORMAT('%d conditions', ARRAY_LENGTH(conditionSet.conditions))
      ELSE 'unspecified condition'
    END AS condition_name
  FROM `{S}.gks_scv_condition_sets`
),
```

- [ ] **Step 2.2: Modify classification struct to include extensions**

In the final SELECT of Step 7, change the classification struct from:

```sql
STRUCT(
  scv.submitted_classification as name,
  IF(
    scv.classification_code IS NOT NULL,
    STRUCT(scv.classification_code as code, scv.classif_and_strength_code_system as system),
    null
  ) as primaryCoding
) as classification,
```

To:

```sql
STRUCT(
  scv.submitted_classification as name,
  IF(
    scv.classification_code IS NOT NULL,
    STRUCT(scv.classification_code as code, scv.classif_and_strength_code_system as system),
    null
  ) as primaryCoding,
  [STRUCT(
    'description' AS name,
    CONCAT(
      'for ', COALESCE(scn.condition_name, 'unspecified condition'), '\n',
      'Classification is based on the ', COALESCE(scv.submission_level_label, 'unknown'), ' submission', '\n',
      COALESCE(FORMAT_DATE('%b %Y', scv.last_evaluated), '(-)'), ' by ', scv.submitter.name
    ) AS value_string
  )] AS extensions
) as classification,
```

And add the JOIN to the condition name CTE:

```sql
LEFT JOIN scv_condition_name scn
ON
  scn.scv_id = scv.id
```

**Note:** The `\n` in the CONCAT will be a literal newline in the output since this is inside a triple-quoted EXECUTE IMMEDIATE string. Use `\\n` if the newline should be a literal `\n` text in the JSON output, or `\n` if it should be an actual newline character. Based on prior convention in this codebase (see L1 PRE in vcv-statement-proc), use `\\n` for literal newline text in the formatted string.

- [ ] **Step 2.3: Commit**

```bash
git add src/procedures/gks-scv-statement-proc.sql
git commit -m "Add description extension to SCV classification"
```

---

## Chunk 2: VCV Proc Layer 1 Aggregation Changes

### Task 3: Combine PG and EP into PGEP at Layer 1

**Files:**
- Modify: `src/procedures/gks-vcv-proc.sql` — temp_vcv_base_data and Layer 1 BASE AGGREGATION

The current `temp_vcv_base_data` gets `submission_level` from the `submission_level` lookup table via `sl.rank = ss.rank`. PG (rank 4) and EP (rank 3) are currently separate codes. We need to combine them into 'PGEP' for Layer 1 grouping while preserving the original submission_level for the PGEP strength derivation.

- [ ] **Step 3.1: Add original_submission_level and remap to PGEP in base data**

In `gks-vcv-proc.sql`, modify the `temp_vcv_base_data` query. Change:

```sql
sl.code AS submission_level
```

To:

```sql
sl.code AS original_submission_level,
CASE WHEN sl.code IN ('PG', 'EP') THEN 'PGEP' ELSE sl.code END AS submission_level
```

This preserves the original code for downstream strength derivation while grouping PG+EP together.

- [ ] **Step 3.2: Add PGEP submission_level_label to base data**

Also add the submission level label for use in descriptions:

```sql
sl.label AS submission_level_label,
```

- [ ] **Step 3.3: Modify Layer 1 aggregation for PGEP-specific logic**

In the `core_agg` CTE, the GROUP BY already uses `submission_level` which will now be 'PGEP' for combined PG+EP records. This grouping is correct.

Add to `core_agg` SELECT:
```sql
ARRAY_AGG(DISTINCT original_submission_level) AS contributing_submission_levels,
```

In `final_prep`, add PGEP strength derivation:
```sql
CASE
  WHEN submission_level = 'PGEP' THEN
    CASE
      WHEN ARRAY_LENGTH(c.contributing_submission_levels) = 1 AND c.contributing_submission_levels[OFFSET(0)] = 'PG' THEN 'PG'
      WHEN ARRAY_LENGTH(c.contributing_submission_levels) = 1 AND c.contributing_submission_levels[OFFSET(0)] = 'EP' THEN 'EP'
      ELSE 'PGEP'
    END
  ELSE submission_level
END AS pgep_strength,
```

- [ ] **Step 3.4: Modify Layer 1 conflict logic for submission-level-specific behavior**

In `final_prep`, the current conflict detection uses `significance_count > 1 AND conflict_detectable`. This needs to be scoped:

- **PGEP**: No conflict detection — skip the conflicting explanation entirely
- **CP/NOCP**: Keep existing conflict detection logic
- **FLAG**: Always produce "no classifications from unflagged records"
- **NOCL**: No conflict detection (pass through)

Modify the `actual_agg_classif_label` CASE expression:

```sql
CASE
  WHEN c.submission_level = 'PGEP' THEN NULL  -- PGEP uses array, not single label
  WHEN c.submission_level = 'FLAG' THEN 'no classifications from unflagged records'
  WHEN cs.significance_count > 1 AND c.conflict_detectable AND c.prop_type != 'sci' THEN
    FORMAT('Conflicting classifications of %s', LOWER(c.prop_label))
  WHEN c.prop_type = 'sci' THEN
    CASE
      WHEN ARRAY_LENGTH(sc.unique_traits) = 1 THEN FORMAT('%s for %s', cs.agg_classif_label, sc.unique_traits[OFFSET(0)])
      WHEN ARRAY_LENGTH(sc.unique_traits) > 1 THEN FORMAT('%s for %d tumor types', cs.agg_classif_label, ARRAY_LENGTH(sc.unique_traits))
      ELSE cs.agg_classif_label
    END
  ELSE cs.agg_classif_label
END AS actual_agg_classif_label
```

Similarly, suppress `agg_label_conflicting_explanation` for PGEP and FLAG:

```sql
CASE
  WHEN c.submission_level IN ('PGEP', 'FLAG') THEN NULL
  ELSE IF(cs.significance_count > 1 AND c.conflict_detectable, cs.agg_string, CAST(NULL AS STRING))
END AS agg_label_conflicting_explanation,
```

- [ ] **Step 3.5: Add PGEP per-SCV classification array data to Layer 1**

For PGEP groupings, we need to carry forward the per-SCV classification details (name + description) so the VCV statement proc can build `aggregate_classification_array`. Add a new column to `gks_vcv_layer1_base_agg`:

```sql
-- In final_prep or a new CTE
CASE
  WHEN c.submission_level = 'PGEP' THEN c.full_scv_ids
  ELSE CAST(NULL AS ARRAY<STRING>)
END AS pgep_scv_ids,
```

The actual per-SCV classification data (name, description) will be resolved in the VCV statement proc by joining back to `gks_scv_statement_pre` using these SCV IDs. This avoids duplicating condition/submitter data in the aggregation tables.

- [ ] **Step 3.6: Add aggregate review status to Layer 1**

Derive the aggregate review status for all submission levels. Add to `core_agg`:

```sql
COUNT(DISTINCT submitter_id) AS unique_submitter_count,
```

Then in `final_prep`:

```sql
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
```

Note: We need `submitter_id` in temp_vcv_base_data. It's already there (`ss.submitter_id`). We need `unique_submitter_count` from `core_agg` passed through to `final_prep`.

- [ ] **Step 3.7: Propagate new columns through final SELECT**

Ensure the final SELECT of Layer 1 includes:
- `pgep_strength`
- `pgep_scv_ids` (or just reuse `full_scv_ids` when submission_level = 'PGEP')
- `aggregate_review_status`
- `contributing_submission_levels`

- [ ] **Step 3.8: Commit**

```bash
git add src/procedures/gks-vcv-proc.sql
git commit -m "Add PGEP combined submission level and per-level classification logic to Layer 1"
```

### Task 4: Propagate new Layer 1 columns through Layers 2-4

**Files:**
- Modify: `src/procedures/gks-vcv-proc.sql` — Layers 2, 3, and 4

The new columns from Layer 1 (`pgep_strength`, `aggregate_review_status`, `contributing_submission_levels`) need to flow through the aggregation layers.

- [ ] **Step 4.1: Layer 2 — propagate PGEP and review status columns**

Layer 2 aggregates by tier within submission level (only for `tier_grouping IS NOT NULL`, which is somatic `sci` proposition type). PGEP submissions are germline, so they won't appear in Layer 2. However, the `aggregate_review_status` and `pgep_strength` need to be available for Layers 3-4.

In the `unified_input` CTE of Layer 3 (which unions Layer 2 output with Layer 1 non-tiered records), ensure the new columns are included.

Add to Layer 2 output SELECT:
```sql
ANY_VALUE(pgep_strength) AS pgep_strength,
ANY_VALUE(aggregate_review_status) AS aggregate_review_status,
```

- [ ] **Step 4.2: Layer 3 — carry forward to winner-takes-all**

Layer 3 does submission-level ranking. The winning record's `pgep_strength`, `aggregate_review_status`, and `submission_level` are carried forward. Add these columns to `unified_input`, `ranked_levels`, `winner_takes_all`, and the final SELECT.

Add to final SELECT:
```sql
w.pgep_strength, w.aggregate_review_status,
```

- [ ] **Step 4.3: Layer 4 — carry forward to final aggregation**

Layer 4 does proposition-type ranking for germline. Carry `pgep_strength`, `aggregate_review_status`, and `contributing_submission_level` (already exists) through.

Add to `contributing_props`:
```sql
ANY_VALUE(pgep_strength) AS pgep_strength,
ANY_VALUE(aggregate_review_status) AS aggregate_review_status,
```

- [ ] **Step 4.4: Commit**

```bash
git add src/procedures/gks-vcv-proc.sql
git commit -m "Propagate PGEP strength and review status through VCV layers 2-4"
```

---

## Chunk 3: VCV Statement Proc Changes

### Task 5: Replace classification with aggregate_classification_single and aggregate_classification_array

**Files:**
- Modify: `src/procedures/gks-vcv-statement-proc.sql` — All 4 base layers and all 4 PRE layers

This is the largest change. The current `classification` struct on all VCV statement layers needs to be replaced with two mutually exclusive attributes.

- [ ] **Step 5.1: Modify Layer 1 BASE to use new aggregate classification and proposition attributes**

Replace the current `classification` struct with two mutually exclusive aggregate classification attributes:

```sql
-- For non-PGEP: single aggregate classification
IF(
  agg.submission_level != 'PGEP',
  STRUCT(
    'AggregateClassification' AS conceptType,
    agg.actual_agg_classif_label AS name,
    IF(
      agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
      [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
      CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
    ) AS extension
  ),
  NULL
) AS aggregate_classification_single,

-- For PGEP: array will be populated in L1 PRE
CAST(NULL AS ARRAY<STRUCT<
  conceptType STRING,
  name STRING,
  description STRING
>>) AS aggregate_classification_array,
```

Also update the proposition's `objectClassification_conceptSet` struct type to support PGEP's wider concept fields. Change the CAST(NULL) type from:

```sql
CAST(NULL AS STRUCT<type STRING, concepts ARRAY<STRUCT<conceptType STRING, name STRING>>, membershipOperator STRING>) AS objectClassification_conceptSet,
```

To:

```sql
CAST(NULL AS STRUCT<
  type STRING,
  concepts ARRAY<STRUCT<conceptType STRING, name STRING, condition STRING, submissionLevel STRING>>,
  membershipOperator STRING
>) AS objectClassification_conceptSet,
```

For non-PGEP layers this remains NULL (stripped by `JSON_STRIP_NULLS`). The wider concept struct adds `condition` and `submissionLevel` fields used only by PGEP. The actual PGEP population happens in L1 PRE (Task 6).

For PGEP records, also set `objectClassification_mappableConcept` to NULL since PGEP uses the conceptSet instead.

- [ ] **Step 5.2: Add clinvarReviewStatus to Layer 1 BASE statement extensions**

Add a new top-level `extensions` field to the Layer 1 statement (currently not present). This will contain the `clinvarReviewStatus`:

```sql
IF(
  agg.aggregate_review_status IS NOT NULL,
  [STRUCT('clinvarReviewStatus' AS name, agg.aggregate_review_status AS value)],
  [STRUCT('clinvarReviewStatus' AS name, sl.label AS value)]
) AS extensions,
```

Where `sl.label` is the standard review status label from the submission_level table (already joined).

- [ ] **Step 5.3: Modify Layers 2, 3, 4 BASE similarly**

Apply the same pattern to Layer 2, 3, and 4 base statements. These layers already have `agg_label` and `agg_label_conflicting_explanation`. The PGEP check uses `submission_level` (Layer 2) or `contributing_submission_level` (Layers 3-4).

For Layers 3 and 4, the review status comes from the contributing layer's `aggregate_review_status`.

- [ ] **Step 5.4: Commit base layer changes**

```bash
git add src/procedures/gks-vcv-statement-proc.sql
git commit -m "Replace classification with aggregate_classification_single/array in VCV base layers"
```

### Task 6: Modify L1 PRE to populate aggregate_classification_array for PGEP

**Files:**
- Modify: `src/procedures/gks-vcv-statement-proc.sql` — L1 PRE section

- [ ] **Step 6.1: Rework L1 PRE to handle PGEP array classification and proposition objectClassification**

The current L1 PRE has `ep_pg_scv_name` CTE that generates formatted explanation strings. This needs to be reworked to populate both `aggregate_classification_array` and `proposition.objectClassification_conceptSet` for PGEP records.

For PGEP records, join to `gks_scv_statement_pre` to get each SCV's classification name and description extension, then build the statement-level array:

```sql
pgep_classifications AS (
  SELECT
    agg.id AS l1_id,
    ARRAY_AGG(
      STRUCT(
        'AggregateClassification' AS conceptType,
        scv_pre.classification.name AS name,
        (SELECT ext.value_string FROM UNNEST(scv_pre.classification.extensions) ext WHERE ext.name = 'description' LIMIT 1) AS description
      )
      ORDER BY scv_pre.id
    ) AS classifications
  FROM `{S}.gks_vcv_layer1_base_agg` agg
  CROSS JOIN UNNEST(agg.full_scv_ids) AS full_scv_id
  JOIN `{S}.gks_scv_statement_pre` scv_pre ON scv_pre.id = FORMAT('clinvar.submission:%s', full_scv_id)
  WHERE agg.submission_level = 'PGEP'
  GROUP BY agg.id
)
```

Then in the L1 PRE SELECT:

```sql
l1.aggregate_classification_single,
COALESCE(pgep.classifications, l1.aggregate_classification_array) AS aggregate_classification_array,
```

- [ ] **Step 6.2: Build PGEP proposition objectClassification_conceptSet in L1 PRE**

For PGEP records, populate `objectClassification_conceptSet` with the **unique** combinations of (classification, condition, submission_level) from contributing SCVs. No submitter info. Deduplicate so identical combos from different submitters appear only once.

Add a CTE:

```sql
pgep_object_concepts AS (
  SELECT
    agg.id AS l1_id,
    STRUCT(
      'ConceptSet' AS type,
      ARRAY_AGG(DISTINCT
        STRUCT(
          'Classification' AS conceptType,
          scv_pre.classification.name AS name,
          COALESCE(
            sp.objectCondition_single.name,
            (SELECT STRING_AGG(c.name, ', ') FROM UNNEST(sp.objectCondition_compound.conditions) c)
          ) AS condition,
          sl.label AS submissionLevel
        )
      ) AS concepts,
      'OR' AS membershipOperator
    ) AS concept_set
  FROM `{S}.gks_vcv_layer1_base_agg` agg
  CROSS JOIN UNNEST(agg.full_scv_ids) AS full_scv_id
  JOIN `{S}.gks_scv_statement_pre` scv_pre ON scv_pre.id = FORMAT('clinvar.submission:%s', full_scv_id)
  JOIN `{S}.scv_summary` ss ON ss.full_scv_id = full_scv_id
  LEFT JOIN `clinvar_ingest.submission_level` sl ON sl.rank = ss.rank
  LEFT JOIN `{S}.gks_scv_condition_sets` scs ON scs.scv_id = ss.id
  LEFT JOIN {P}.temp_gks_scv_proposition sp ON sp.id = ss.id
  WHERE agg.submission_level = 'PGEP'
  GROUP BY agg.id
)
```

Note: The condition name comes from the SCV's proposition (objectCondition_single.name or objectCondition_compound). The submission level label comes from the original SCV's rank (not the combined PGEP code). `ARRAY_AGG(DISTINCT ...)` ensures deduplication.

Then in the L1 PRE SELECT, reconstruct the proposition to use the conceptSet for PGEP:

```sql
STRUCT(
  l1.proposition.type,
  l1.proposition.id,
  l1.proposition.subjectVariant,
  l1.proposition.predicate,
  IF(agg.submission_level != 'PGEP', l1.proposition.objectClassification_mappableConcept, NULL) AS objectClassification_mappableConcept,
  COALESCE(poc.concept_set, l1.proposition.objectClassification_conceptSet) AS objectClassification_conceptSet,
  l1.proposition.aggregateQualifiers
) AS proposition,
```

- [ ] **Step 6.3: Remove old ep_pg_scv_name and explanation extension logic from L1 PRE**

The old `ep_pg_scv_name` CTE and the wide extension type reconstruction in L1 PRE classification are no longer needed. Remove them entirely since PGEP is now handled by `aggregate_classification_array` and the proposition by `pgep_object_concepts`.

- [ ] **Step 6.4: Simplify L1 PRE classification handling**

Since L1 PRE no longer needs to merge explanation extensions into classification, the classification reconstruction can be simplified. The `aggregate_classification_single` and `aggregate_classification_array` pass through directly. The proposition is reconstructed only for PGEP objectClassification switching.

- [ ] **Step 6.5: Commit**

```bash
git add src/procedures/gks-vcv-statement-proc.sql
git commit -m "Populate aggregate_classification_array and PGEP proposition objectClassification in L1 PRE"
```

### Task 7: Update L2/L3/L4 PRE layers

**Files:**
- Modify: `src/procedures/gks-vcv-statement-proc.sql` — L2, L3, L4 PRE sections

- [ ] **Step 7.1: Remove explanation rollup CTEs from L2/L3/L4 PRE**

The `l2_explanations`, `l3_explanations`, `l4_explanations` CTEs that rolled up explanation extensions through classification are no longer needed. The PGEP `aggregate_classification_array` flows through as-is via the evidence item inlining.

Remove:
- `l2_explanations` CTE and its LEFT JOIN
- `l3_explanations` CTE and its LEFT JOIN
- `l4_explanations` CTE and its LEFT JOIN

- [ ] **Step 7.2: Update L2/L3/L4 PRE to pass through both aggregate classification attributes**

Replace the classification reconstruction in each PRE layer with simple passthrough of both attributes:

```sql
l2.aggregate_classification_single,
l2.aggregate_classification_array,
```

(Same pattern for L3 and L4 PRE)

- [ ] **Step 7.3: Update L2/L3/L4 PRE extensions to include clinvarReviewStatus**

Ensure the `extensions` field (containing `clinvarReviewStatus`) passes through each PRE layer alongside the other fields.

- [ ] **Step 7.4: Commit**

```bash
git add src/procedures/gks-vcv-statement-proc.sql
git commit -m "Simplify L2/L3/L4 PRE layers with new aggregate classification attributes"
```

### Task 8: Update FINAL combined VCV statement pre

**Files:**
- Modify: `src/procedures/gks-vcv-statement-proc.sql` — FINAL section

- [ ] **Step 8.1: Verify UNION ALL compatibility**

The FINAL section unions L4 PRE with somatic L3 PRE. Ensure both have identical column schemas with the new `aggregate_classification_single`, `aggregate_classification_array`, and `extensions` columns.

- [ ] **Step 8.2: Commit**

```bash
git add src/procedures/gks-vcv-statement-proc.sql
git commit -m "Update final VCV statement pre for new aggregate classification schema"
```

---

## Chunk 4: JSON Serialization and Cleanup

### Task 9: Update JSON proc for new attributes

**Files:**
- Modify: `src/procedures/gks-json-proc.sql` — VCV section

- [ ] **Step 9.1: Verify JSON serialization handles new attributes**

The JSON proc uses `TO_JSON(tv)` with `JSON_STRIP_NULLS(remove_empty => TRUE)` to serialize `gks_vcv_statement_pre` rows. Since `aggregate_classification_single` will be NULL for PGEP records and `aggregate_classification_array` will be NULL for non-PGEP records, `JSON_STRIP_NULLS` should automatically exclude the null attribute from the output. Verify this behavior.

- [ ] **Step 9.2: Commit if changes needed**

```bash
git add src/procedures/gks-json-proc.sql
git commit -m "Update JSON proc for aggregate classification attributes"
```

### Task 10: Update example files and clean up

**Files:**
- Modify: `examples/vcv/VCV000012582.63-G.jsonc`

- [ ] **Step 10.1: Update VCV example to reflect new structure**

Update the example JSON to show the new `aggregate_classification_single` attribute (this example is CP-level, so it uses the single form) and `clinvarReviewStatus` extension.

- [ ] **Step 10.2: Create a PGEP example**

If a suitable PGEP example exists in the data, create a new example file showing `aggregate_classification_array`.

- [ ] **Step 10.3: Update memory file**

Update `project_vcv_ep_pg_fix.md` to reflect the completed refactoring.

- [ ] **Step 10.4: Final commit**

```bash
git add examples/
git commit -m "Update VCV examples for aggregate classification refactor"
```

---

## Chunk 5: Documentation

### Task 11: Document VCV aggregation rules in MkDocs

**Files:**
- Create: `docs/pipeline/vcv-statements/vcv-aggregation-rules.md`
- Modify: `docs/pipeline/vcv-statements/index.md` — remove "Under Construction" placeholder, add overview
- Modify: `docs/profiles/review-status.md` — add aggregate review status rules
- Modify: `mkdocs.yml` — add new page to nav

The VCV statements section is currently placeholder content. This task creates a clear, accessible reference for both technical consumers (developers querying BigQuery) and non-technical consumers (clinical teams interpreting output JSON).

- [ ] **Step 11.1: Create VCV Aggregation Rules page**

Create `docs/pipeline/vcv-statements/vcv-aggregation-rules.md` covering:

1. **Overview** — What VCV aggregation does (combines individual SCV submissions into aggregate variant-level classifications) and why submission levels matter.

2. **Submission Levels** — Table of all 6 codes (PG, EP, CP, NOCP, NOCL, FLAG) with their labels, star ratings, and brief descriptions. Explain that PG and EP are combined into PGEP for aggregation.

3. **SCV Description** — How every SCV gets a formatted description in its classification extensions, with the template and field definitions. Include an example.

4. **Aggregation by Submission Level** — One subsection per level group:
   - **PGEP**: No conflict detection. Per-SCV classifications preserved as an array (`aggregate_classification_array`). Explain strength derivation (PG-only / EP-only / mixed).
   - **CP**: Concordance/conflict detection. Single aggregate label (`aggregate_classification_single`). Review status upgrades. Include examples of concordant vs conflicting.
   - **NOCP**: Same aggregation as CP but no review status upgrade.
   - **FLAG**: Fixed classification "no classifications from unflagged records". No aggregation logic.
   - **NOCL**: Passthrough. Fixed "not provided" label.

5. **Aggregate Classification Output** — Show the two mutually exclusive JSON attributes with examples:
   - `aggregate_classification_single` example (CP concordant, CP conflicting)
   - `aggregate_classification_array` example (PGEP with multiple SCVs)

6. **Review Status** — Table showing all possible `clinvarReviewStatus` values and when each applies.

7. **Layer Hierarchy** — Brief explanation of L1→L2→L3→L4 with a diagram or table showing what each layer aggregates and which submission levels participate at each layer.

Keep the tone accessible: use plain language with JSON examples. Avoid SQL implementation details — link to `vcv-proc.md` for those.

- [ ] **Step 11.2: Update VCV Statements index page**

Replace the placeholder content in `docs/pipeline/vcv-statements/index.md` with:
- A brief overview of VCV statement generation
- Links to the aggregation rules page and procedures page
- Summary of the 4-layer hierarchy

- [ ] **Step 11.3: Update review-status.md with aggregate review status**

Add a new section to `docs/profiles/review-status.md` documenting the aggregate review status values:
- CP-specific review status upgrades (single submitter → multiple submitters, no conflicts → conflicting)
- PGEP combined review status
- Standard pass-through for NOCP, NOCL, FLAG

- [ ] **Step 11.4: Add new page to mkdocs.yml nav**

In `mkdocs.yml`, update the VCV Statements nav section:

```yaml
    - VCV Statements:
      - pipeline/vcv-statements/index.md
      - Aggregation Rules: pipeline/vcv-statements/vcv-aggregation-rules.md
      - VCV Procedures: pipeline/vcv-statements/vcv-proc.md
```

- [ ] **Step 11.5: Validate docs build**

```bash
mkdocs build --strict
```

- [ ] **Step 11.6: Commit**

```bash
git add docs/pipeline/vcv-statements/ docs/profiles/review-status.md mkdocs.yml
git commit -m "Document VCV aggregation rules and review status logic"
```

---

## Confirmed Design Decisions

1. **PGEP at Layer 2**: Confirmed — PGEP is germline-only with no `tier_grouping`, so it bypasses Layer 2 entirely (Layer 2 only processes `tier_grouping IS NOT NULL`). No changes needed in Layer 2 for PGEP.

2. **NOCL behavior**: Confirmed — NOCL records always produce "not provided" as their `actual_agg_classif_label` without modification.

3. **FLAG aggregation**: Confirmed — FLAG should never do conflict detection. Explicit submission_level gating in the CASE expression ensures this, independent of `conflict_detectable`.

4. **SCV description extension type**: Confirmed — use `value_string` (not `value`) to match the existing SCV extension convention. VCV statement-level extensions use `value`.

5. **Review status for all submission levels**: Confirmed — all submission levels get a `clinvarReviewStatus` extension:
   - **PGEP**: `"practice guideline and expert panel mix"`
   - **PG-only PGEP**: `"practice guideline"` (when only PG SCVs contribute)
   - **EP-only PGEP**: `"reviewed by expert panel"` (when only EP SCVs contribute)
   - **CP**: Derived from aggregation (`"criteria provided, single submitter"` / `"criteria provided, multiple submitters, no conflicts"` / `"criteria provided, conflicting classifications"`)
   - **NOCP**: `"no assertion criteria provided"`
   - **NOCL**: `"no classification provided"`
   - **FLAG**: `"flagged submission"`
