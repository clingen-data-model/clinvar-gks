# Aggregate Proposition Refactor Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor VCV/RCV aggregate propositions to mirror underlying SCV types, add classification-derived direction/strength, add `confidence` attribute carrying submission level, and collect objectCondition on VCV propositions.

**Architecture:** Three subsystems change: (1) the `clinvar_proposition_types` lookup table gains GKS type/predicate columns, (2) VCV/RCV statement procs replace generic aggregate propositions with SCV-matching types and add confidence/direction/strength logic, (3) the VCV aggregation proc adds condition collection. SCV statements also gain a `confidence` attribute. The spec is at `docs/superpowers/specs/2026-04-14-aggregate-proposition-refactor-design.md`.

**Tech Stack:** BigQuery SQL stored procedures, MkDocs documentation (Markdown), JSONC example files

---

## Summary of Changes

### Lookup Table

Add `gks_type` and `gks_predicate` columns to `clinvar_proposition_types`:

| code | gks_type | gks_predicate |
| --- | --- | --- |
| path | VariantPathogenicityProposition | isCausalFor |
| onco | VariantOncogenicityProposition | isOncogenicFor |
| sci | VariantClinicalSignificanceProposition | isClinicallySignificantFor |
| drug-resp | ClinVarDrugResponseProposition | isClinvarDrugResponseFor |
| risk | ClinVarRiskFactorProposition | isClinvarRiskFactorFor |
| protective | ClinVarProtectiveProposition | isClinvarProtectiveFor |
| affects | ClinVarAffectsProposition | isClinvarAffectsFor |
| assoc | ClinVarAssociationProposition | isClinvarAssociationFor |
| confers-sens | ClinVarConfersSensitivityProposition | isClinvarConfersSensitivityFor |
| other | ClinVarOtherProposition | isClinvarOtherFor |
| np | ClinVarNotProvidedProposition | isClinvarNotProvidedFor |

### Direction/Strength Mapping (Multi-SCV Aggregations)

| Classification Label | direction | strength |
| --- | --- | --- |
| Pathogenic | supports | definitive |
| Likely pathogenic | supports | likely |
| Uncertain significance | neutral | _(null)_ |
| Likely benign | disputes | likely |
| Benign | disputes | definitive |
| Pathogenic/Likely pathogenic | supports | _(null)_ |
| Benign/Likely benign | disputes | _(null)_ |
| Conflicting classifications of... | neutral | _(null)_ |
| All others | supports | definitive |

**Single-SCV rule:** When `ARRAY_LENGTH(full_scv_ids) = 1`, inherit the SCV's direction/strength identically.

### Key Naming Conventions

- Internal STRUCT field `classification_mappableConcept` stays as-is (the `normalizeAndKeyById` function handles JSON key normalization)
- New internal STRUCT field for confidence: `confidence` (string)
- Proposition STRUCT replaces `objectClassification`/`objectConditionClassification`/`aggregateQualifiers` with `objectCondition` (JSON, for VCV) or `objectCondition` (JSON, for RCV from existing condition data)

---

## Files Affected

### SQL Procedures

| File | Changes |
| --- | --- |
| `src/procedures/gks-scv-statement-proc.sql` | Add `confidence` attribute (submission level label) |
| `src/procedures/gks-vcv-proc.sql` | Add condition collection to Base Grouping |
| `src/procedures/gks-vcv-statement-proc.sql` | Replace proposition, add confidence, derive direction/strength |
| `src/procedures/gks-rcv-statement-proc.sql` | Replace proposition, add confidence, derive direction/strength |

### Documentation

| File | Changes |
| --- | --- |
| `docs/profiles/propositions.md` | Remove Aggregate Proposition Types section |
| `docs/pipeline/vcv-statements/vcv-aggregation-rules.md` | Update Classification Output section |
| `docs/pipeline/vcv-statements/vcv-proc.md` | Update proposition descriptions |
| `docs/pipeline/rcv-statements/rcv-proc.md` | Update proposition descriptions |
| `docs/output-reference/vcv-statements.md` | Update proposition field docs |
| `docs/output-reference/rcv-statements.md` | Update proposition field docs |
| `docs/reference/glossary.md` | Remove aggregate proposition entries |

### Examples

All VCV and RCV example files in `examples/vcv/` and `examples/rcv/`

---

## Chunk 1: Lookup Table and SCV Changes

### Task 1: Add gks_type and gks_predicate to clinvar_proposition_types

**Files:**
- BigQuery lookup table: `clinvar_ingest.clinvar_proposition_types` (managed outside this repo)

- [ ] **Step 1: Run ALTER TABLE to add columns**

This is a one-time BigQuery DDL operation against the `clinvar_ingest` dataset:

```sql
ALTER TABLE `clinvar_ingest.clinvar_proposition_types`
ADD COLUMN IF NOT EXISTS gks_type STRING,
ADD COLUMN IF NOT EXISTS gks_predicate STRING;
```

- [ ] **Step 2: Populate the new columns**

```sql
UPDATE `clinvar_ingest.clinvar_proposition_types` SET
  gks_type = CASE code
    WHEN 'path' THEN 'VariantPathogenicityProposition'
    WHEN 'onco' THEN 'VariantOncogenicityProposition'
    WHEN 'sci' THEN 'VariantClinicalSignificanceProposition'
    WHEN 'drug-resp' THEN 'ClinVarDrugResponseProposition'
    WHEN 'risk' THEN 'ClinVarRiskFactorProposition'
    WHEN 'protective' THEN 'ClinVarProtectiveProposition'
    WHEN 'affects' THEN 'ClinVarAffectsProposition'
    WHEN 'assoc' THEN 'ClinVarAssociationProposition'
    WHEN 'confers-sens' THEN 'ClinVarConfersSensitivityProposition'
    WHEN 'other' THEN 'ClinVarOtherProposition'
    WHEN 'np' THEN 'ClinVarNotProvidedProposition'
  END,
  gks_predicate = CASE code
    WHEN 'path' THEN 'isCausalFor'
    WHEN 'onco' THEN 'isOncogenicFor'
    WHEN 'sci' THEN 'isClinicallySignificantFor'
    WHEN 'drug-resp' THEN 'isClinvarDrugResponseFor'
    WHEN 'risk' THEN 'isClinvarRiskFactorFor'
    WHEN 'protective' THEN 'isClinvarProtectiveFor'
    WHEN 'affects' THEN 'isClinvarAffectsFor'
    WHEN 'assoc' THEN 'isClinvarAssociationFor'
    WHEN 'confers-sens' THEN 'isClinvarConfersSensitivityFor'
    WHEN 'other' THEN 'isClinvarOtherFor'
    WHEN 'np' THEN 'isClinvarNotProvidedFor'
  END
WHERE TRUE;
```

- [ ] **Step 3: Verify**

```sql
SELECT code, gks_type, gks_predicate FROM `clinvar_ingest.clinvar_proposition_types` ORDER BY code;
```

All 11 rows should have non-null `gks_type` and `gks_predicate`.

---

### Task 2: Add confidence attribute to SCV statements

**Files:**
- Modify: `src/procedures/gks-scv-statement-proc.sql`

- [ ] **Step 1: Add `confidence` to the SCV statement output**

In the final SCV statement SELECT (the section that builds the statement structure for `gks_scv_statement_pre`), add a `confidence` field. The value comes from `scv.submission_level_label` (which is `sl.label`, already available from the join to `clinvar_ingest.submission_level` at line 128-129).

Find the section where `direction` and `strength` are set on the statement (around line 578-586). After `strength`, add:

```sql
scv.submission_level_label as confidence,
```

This places the submission level label (e.g., `"criteria provided"`, `"practice guideline"`) as a top-level attribute on every SCV statement.

- [ ] **Step 2: Verify `submission_level_label` is available in the temp_gks_scv table**

Check that the `temp_gks_scv` table (Step 1 of the SCV proc) includes `submission_level_label`. It currently has `sl.label AS submission_level_label` at line 129. Confirm it flows through to the final statement query.

- [ ] **Step 3: Commit**

```bash
git add src/procedures/gks-scv-statement-proc.sql
git commit -m "Add confidence attribute to SCV statements"
```

---

## Chunk 2: VCV Condition Collection

### Task 3: Add condition collection to VCV aggregation proc

**Files:**
- Modify: `src/procedures/gks-vcv-proc.sql`

- [ ] **Step 1: Add condition collection to Base Grouping**

In the `gks_vcv_grouping_base_agg` query (the Base Grouping step), add a new CTE that collects unique condition concepts for each aggregation group. This requires joining `gks_scv_condition_sets` via the SCV IDs.

After the existing `somatic_conditions` CTE, add a new CTE:

```sql
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
```

This flattens compound conditionSets into individual conditions and deduplicates across SCVs.

Add a LEFT JOIN to `vcv_conditions` in the `final_prep` CTE (alongside the existing `somatic_conditions` join), and include `COALESCE(vc.unique_conditions, []) as unique_conditions` in the final SELECT.

- [ ] **Step 2: Carry conditions through Tier Grouping**

In the `gks_vcv_grouping_tier_agg` query, the contributing tier's conditions need to be carried forward. Add `unique_conditions` to the `findings` STRUCT and select `sb.findings[OFFSET(0)].unique_conditions as unique_conditions` in the `delta_prep` CTE.

Include `unique_conditions` in the final SELECT of the Tier Grouping table.

- [ ] **Step 3: Carry conditions through Aggregate Contribution**

In the `gks_vcv_aggregate_contribution` query, the `unified_input` CTE already unions Tier Grouping output with non-tiered Base Grouping records. Add `unique_conditions` to both branches of the UNION ALL.

The winning record's `unique_conditions` should be carried through `ranked_levels` → `winner_takes_all` → final SELECT.

Also carry `submission_level_label` through the layers (needed for `confidence` at the Aggregate Contribution level). Currently only `submission_level` (code) is carried. Add `submission_level_label` to the base data query, and propagate it through Base Grouping, Tier Grouping, and Aggregate Contribution.

- [ ] **Step 4: Commit**

```bash
git add src/procedures/gks-vcv-proc.sql
git commit -m "Add condition collection and submission_level_label to VCV aggregation"
```

---

## Chunk 3: VCV Statement Proc Refactor

### Task 4: Replace VCV proposition structure and add confidence/direction/strength

**Files:**
- Modify: `src/procedures/gks-vcv-statement-proc.sql`

This is the largest single task. The proposition STRUCT at each layer (Base Grouping, Tier Grouping, Aggregate Contribution) must be replaced, and direction/strength/confidence must be derived.

- [ ] **Step 1: Add `clinvar_proposition_types` join for gks_type/gks_predicate**

The Base Grouping and Tier Grouping statement queries already join `clinvar_ingest.clinvar_proposition_types` via `cpt`. The new columns `cpt.gks_type` and `cpt.gks_predicate` are now available. No new join needed — just reference the new columns.

The Aggregate Contribution statement query also already joins `cpt`. Same applies.

- [ ] **Step 2: Replace Base Grouping proposition**

Replace the current proposition STRUCT (which uses `VariantAggregateClassificationProposition`, `hasAggregateClassification`, `objectClassification`, `aggregateQualifiers`) with:

```sql
STRUCT(
  cpt.gks_type AS type,
  agg.prop_id AS id,
  FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
  cpt.gks_predicate AS predicate,
  IF(ARRAY_LENGTH(agg.unique_conditions) = 1,
    agg.unique_conditions[OFFSET(0)],
    IF(ARRAY_LENGTH(agg.unique_conditions) > 1,
      TO_JSON(STRUCT(
        'ConceptSet' AS type,
        agg.unique_conditions AS concepts,
        'OR' AS membershipOperator
      )),
      CAST(NULL AS JSON)
    )
  ) AS objectCondition
) AS proposition,
```

- [ ] **Step 3: Replace direction/strength with classification-derived values and add confidence**

Replace the hardcoded `'supports' AS direction, 'definitive' AS strength` with:

```sql
IF(ARRAY_LENGTH(agg.full_scv_ids) = 1,
  -- Single-SCV passthrough: inherit from SCV
  -- (direction/strength come from the clinvar_clinsig_types via the agg table)
  agg.scv_direction,
  -- Multi-SCV: derive from aggregate classification label
  CASE
    WHEN agg.actual_agg_classif_label IN ('Pathogenic', 'Likely pathogenic') THEN 'supports'
    WHEN agg.actual_agg_classif_label IN ('Benign', 'Likely benign') THEN 'disputes'
    WHEN agg.actual_agg_classif_label IN ('Pathogenic/Likely pathogenic') THEN 'supports'
    WHEN agg.actual_agg_classif_label IN ('Benign/Likely benign') THEN 'disputes'
    WHEN agg.actual_agg_classif_label IN ('Uncertain significance') THEN 'neutral'
    WHEN agg.actual_agg_classif_label LIKE 'Conflicting%' THEN 'neutral'
    ELSE 'supports'
  END
) AS direction,

IF(ARRAY_LENGTH(agg.full_scv_ids) = 1,
  agg.scv_strength,
  CASE
    WHEN agg.actual_agg_classif_label IN ('Pathogenic', 'Benign') THEN 'definitive'
    WHEN agg.actual_agg_classif_label IN ('Likely pathogenic', 'Likely benign') THEN 'likely'
    ELSE CAST(NULL AS STRING)
  END
) AS strength,

sl.label AS confidence,
```

**Note:** This requires the Base Grouping aggregation table to carry `scv_direction` and `scv_strength` for single-SCV passthrough. These need to be added to `gks_vcv_grouping_base_agg` in the aggregation proc (Task 3). When `ARRAY_LENGTH(full_scv_ids) = 1`, store the single SCV's direction and strength values. When multiple SCVs exist, these can be NULL.

- [ ] **Step 4: Apply same proposition/direction/strength/confidence changes to Tier Grouping**

Replace the Tier Grouping proposition STRUCT similarly. Tier Grouping always has multiple contributing records, so direction/strength always use the classification-derived mapping (no single-SCV passthrough at this level).

The `confidence` comes from `sl.label` (Tier Grouping already joins `submission_level`).

- [ ] **Step 5: Apply same changes to Aggregate Contribution**

Replace the Aggregate Contribution proposition STRUCT. Use `cpt.gks_type` and `cpt.gks_predicate`. The Aggregate Contribution layer needs a new join to `submission_level` on `agg.contributing_submission_level = sl.code` to get the label for `confidence`.

For direction/strength: use the classification-derived mapping. Single-SCV passthrough does not apply at this layer (it aggregates across submission levels).

objectCondition is carried from the contributing child (already present via `agg.unique_conditions` or from the contributing Base Grouping/Tier Grouping).

- [ ] **Step 6: Update PRE layers to pass through new fields**

The PRE layers inline evidence from the layer below. They currently pass through `classification_mappableConcept`, `proposition`, `extensions`, `evidenceLines`. Add `confidence` to the passthrough list. Also `direction` and `strength` are already passed through (they're top-level columns on the statement).

Check each PRE query (Grouping Base PRE, Grouping Tier PRE, Aggregate Contribution PRE) and ensure they SELECT and pass through `confidence`, `direction`, `strength` from the BASE table.

Also update the inlining TO_JSON STRUCTs (where lower-layer statements are inlined as evidence items) to include `confidence`.

- [ ] **Step 7: Remove unused joins**

If `clinvar_statement_categories` (aliased `csc`) was only used for `aggregateQualifiers`, and `aggregateQualifiers` is now removed, check whether `csc` is still needed. If the `clinvar_clinsig_types` join (aliased `cct`, used for tier labels) is still needed. Remove any joins that are no longer referenced.

- [ ] **Step 8: Commit**

```bash
git add src/procedures/gks-vcv-statement-proc.sql
git commit -m "Replace VCV proposition structure, add confidence/direction/strength"
```

---

### Task 5: Add scv_direction and scv_strength to VCV aggregation for single-SCV passthrough

**Files:**
- Modify: `src/procedures/gks-vcv-proc.sql`

- [ ] **Step 1: Add direction and strength columns to temp_vcv_base_data**

The base data query needs to carry each SCV's direction and strength values from `clinvar_clinsig_types`. These are `cct.direction` (already available via the join) and the strength name. Check if `clinvar_clinsig_types` has a strength field — if not, it may need to be derived from the classification.

Actually, looking at the SCV proc, strength comes from `cct.strength_name` and `cct.strength_code`. The VCV base data already joins `clinvar_clinsig_types` as `cct`. Add:

```sql
cct.direction as scv_direction,
cct.strength_name as scv_strength_name,
```

to the `temp_vcv_base_data` SELECT.

- [ ] **Step 2: Carry through to Base Grouping**

In the `core_agg` CTE of Base Grouping, use `ANY_VALUE(scv_direction) as scv_direction` and `ANY_VALUE(scv_strength_name) as scv_strength_name`. These are safe to use with ANY_VALUE because when `ARRAY_LENGTH(full_scv_ids) = 1`, there's only one SCV. When multiple SCVs exist, the values won't be used (the classification-derived mapping takes over).

Carry through `final_prep` and the final SELECT of `gks_vcv_grouping_base_agg`.

- [ ] **Step 3: Commit**

```bash
git add src/procedures/gks-vcv-proc.sql
git commit -m "Add SCV direction/strength to VCV base data for single-SCV passthrough"
```

---

## Chunk 4: RCV Statement Proc Refactor

### Task 6: Replace RCV proposition structure and add confidence/direction/strength

**Files:**
- Modify: `src/procedures/gks-rcv-statement-proc.sql`

Same pattern as Task 4 but for RCV. Key differences:
- RCV uses `objectCondition` from the existing `temp_rcv_condition_data` (condition_concept) instead of collecting from SCVs
- RCV currently wraps condition + classification in an AND ConceptSet as `objectConditionClassification`. The refactor puts just the condition in `objectCondition`
- RCV proposition type was `VariantAggregateConditionClassificationProposition` — now matches SCV type

- [ ] **Step 1: Replace Base Grouping proposition**

Replace the current proposition STRUCT. The objectCondition comes from `rcd.condition_concept` (already joined via `temp_rcv_condition_data`). No AND ConceptSet wrapping — just the condition directly:

```sql
STRUCT(
  cpt.gks_type AS type,
  agg.prop_id AS id,
  FORMAT('clinvar:%s', agg.variation_id) AS subjectVariant,
  cpt.gks_predicate AS predicate,
  rcd.condition_concept AS objectCondition
) AS proposition,
```

- [ ] **Step 2: Replace direction/strength and add confidence**

Same classification-derived mapping as VCV Task 4 Step 3. RCV also needs single-SCV passthrough support. The RCV aggregation proc (`gks_rcv_proc`) needs `scv_direction` and `scv_strength_name` added similarly to VCV Task 5.

Add `confidence` as `sl.label`.

- [ ] **Step 3: Apply same changes to Tier Grouping and Aggregate Contribution**

Same pattern as VCV. Tier Grouping uses classification-derived mapping only. Aggregate Contribution needs new `submission_level` join for confidence.

- [ ] **Step 4: Update PRE layers**

Same as VCV Task 4 Step 6 — pass through `confidence` in all PRE layers and in the TO_JSON inlining STRUCTs.

- [ ] **Step 5: Commit**

```bash
git add src/procedures/gks-rcv-statement-proc.sql
git commit -m "Replace RCV proposition structure, add confidence/direction/strength"
```

---

### Task 7: Add scv_direction and scv_strength to RCV aggregation

**Files:**
- Modify: `src/procedures/gks-rcv-proc.sql`

- [ ] **Step 1: Add direction/strength columns to temp_rcv_base_data and Base Grouping**

Same pattern as VCV Task 5 — add `cct.direction as scv_direction` and `cct.strength_name as scv_strength_name` to the base data, carry through to Base Grouping with `ANY_VALUE`.

Also carry `submission_level_label` through the layers (same as VCV Task 3 Step 3).

- [ ] **Step 2: Commit**

```bash
git add src/procedures/gks-rcv-proc.sql
git commit -m "Add SCV direction/strength and submission_level_label to RCV aggregation"
```

---

## Chunk 5: Documentation Updates

### Task 8: Update propositions doc

**Files:**
- Modify: `docs/profiles/propositions.md`

- [ ] **Step 1: Remove the "Aggregate Proposition Types" section**

Delete the section at lines 31-38 that defines `VariantAggregateClassificationProposition` and `VariantAggregateConditionClassificationProposition`. Replace with a note that aggregate statements use the same proposition types as their underlying SCVs.

- [ ] **Step 2: Commit**

```bash
git add docs/profiles/propositions.md
git commit -m "Remove aggregate proposition types from propositions doc"
```

---

### Task 9: Update VCV and RCV pipeline docs

**Files:**
- Modify: `docs/pipeline/vcv-statements/vcv-aggregation-rules.md`
- Modify: `docs/pipeline/vcv-statements/vcv-proc.md`
- Modify: `docs/pipeline/rcv-statements/rcv-proc.md`
- Modify: `docs/output-reference/vcv-statements.md`
- Modify: `docs/output-reference/rcv-statements.md`
- Modify: `docs/reference/glossary.md`

- [ ] **Step 1: Update vcv-aggregation-rules.md**

Update the "Classification Output" section to reflect:
- `classification` stays on the statement
- `objectClassification` removed from proposition
- `aggregateQualifiers` removed
- New `confidence` attribute
- Direction/strength derived from classification (with mapping table)

- [ ] **Step 2: Update vcv-proc.md**

Update the "Layers 1-3 BASE" section. For each layer's proposition description:
- Replace `VariantAggregateClassificationProposition` with `cpt.gks_type`
- Replace `hasAggregateClassification` with `cpt.gks_predicate`
- Replace `objectClassification` with `objectCondition`
- Remove `aggregateQualifiers`
- Add `confidence` to statement fields
- Update direction/strength description

- [ ] **Step 3: Update rcv-proc.md**

Same changes as Step 2 but for RCV:
- Replace `VariantAggregateConditionClassificationProposition` / `hasAggregateConditionClassification`
- Replace `objectConditionClassification` with `objectCondition` (just the condition)
- Remove `aggregateQualifiers`
- Add `confidence`

- [ ] **Step 4: Update output-reference docs**

In `docs/output-reference/vcv-statements.md` and `docs/output-reference/rcv-statements.md`:
- Update proposition field documentation
- Add `confidence` field documentation
- Update direction/strength documentation to explain classification-derived mapping
- Remove `objectClassification`/`objectConditionClassification`/`aggregateQualifiers` docs

- [ ] **Step 5: Update glossary**

In `docs/reference/glossary.md`:
- Remove entries for `VariantAggregateClassificationProposition`, `VariantAggregateConditionClassificationProposition`
- Remove `Aggregate Qualifiers` entry
- Add `confidence` entry

- [ ] **Step 6: Run mkdocs build --strict**

```bash
cd /Users/lbabb/Development/gks/clinvar-gks && mkdocs build --strict
```

- [ ] **Step 7: Commit**

```bash
git add docs/
git commit -m "Update documentation for aggregate proposition refactor"
```

---

## Chunk 6: Example File Updates

### Task 10: Update VCV example files

**Files:**
- Modify: all files in `examples/vcv/`

- [ ] **Step 1: Update each VCV example**

For each VCV example file, update:
- `proposition.type` → use the SCV-matching type (e.g., `VariantPathogenicityProposition`)
- `proposition.predicate` → use the SCV-matching predicate (e.g., `isCausalFor`)
- Remove `proposition.objectClassification`
- Remove `proposition.aggregateQualifiers`
- Add `proposition.objectCondition` (single MappableConcept or ConceptSet with OR)
- Change `strength` from `"definitive"` to the classification-derived value
- Change `direction` per the mapping table
- Add `confidence` with submission level label
- Update comments to reflect new structure

- [ ] **Step 2: Commit**

```bash
git add examples/vcv/
git commit -m "Update VCV example files for proposition refactor"
```

---

### Task 11: Update RCV example files

**Files:**
- Modify: all files in `examples/rcv/`

- [ ] **Step 1: Update each RCV example**

Same pattern as Task 10 but for RCV:
- Replace `objectConditionClassification` (AND ConceptSet of condition + classification) with `objectCondition` (just the condition)
- Change proposition type/predicate to SCV-matching
- Remove `aggregateQualifiers`
- Add `confidence`
- Update direction/strength

- [ ] **Step 2: Commit**

```bash
git add examples/rcv/
git commit -m "Update RCV example files for proposition refactor"
```

---

## Chunk 7: Validation

### Task 12: Final validation

- [ ] **Step 1: Run mkdocs build --strict**

```bash
cd /Users/lbabb/Development/gks/clinvar-gks && mkdocs build --strict
```

- [ ] **Step 2: Grep for stale references**

```bash
grep -rn -E "VariantAggregateClassificationProposition|VariantAggregateConditionClassificationProposition|hasAggregateClassification|hasAggregateConditionClassification|objectClassification|objectConditionClassification|aggregateQualifiers" \
  --include="*.sql" --include="*.md" --include="*.jsonc" \
  src/ docs/ examples/
```

Any hits (excluding `archive/` and `docs/superpowers/`) indicate missed updates.

- [ ] **Step 3: Verify SQL consistency**

For each modified SQL procedure:
1. All DECLARE'd variables are used
2. All joins reference existing columns
3. New columns (`confidence`, `objectCondition`, etc.) are propagated through all layers
4. PRE layer TO_JSON STRUCTs include all new fields

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "Final validation fixes for aggregate proposition refactor"
```
