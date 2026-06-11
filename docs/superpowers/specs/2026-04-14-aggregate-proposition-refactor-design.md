# Aggregate Proposition Refactor Design

## Goal

Refactor VCV and RCV aggregate propositions to mirror the underlying SCV proposition types instead of using generic aggregate-specific types. Move classification from proposition to statement, move submission level to statement strength, and add objectCondition to VCV propositions.

## Current State

Aggregate (VCV/RCV) statements currently use:

- **Proposition type**: `VariantAggregateClassificationProposition` (VCV) / `VariantAggregateConditionClassificationProposition` (RCV)
- **Predicate**: `hasAggregateClassification` (VCV) / `hasAggregateConditionClassification` (RCV)
- **Proposition attributes**:
  - `objectClassification` (VCV) — MappableConcept with the aggregate classification label
  - `objectConditionClassification` (RCV) — ConceptSet with condition + classification
  - `aggregateQualifiers` — array of AssertionGroup, PropositionType, SubmissionLevel, and optionally ClassificationTier
  - `subjectVariant` — clinvar variation reference
- **Statement-level**:
  - `classification` — already present as a Classification MappableConcept
  - `strength` — hardcoded to `"definitive"`

## Proposed State

### Proposition Changes (VCV + RCV)

The proposition mirrors the underlying SCV proposition type:

- **`type`** — matches the SCV proposition type (e.g., `VariantPathogenicityProposition`, `ClinVarAssociationProposition`)
- **`predicate`** — matches the SCV predicate (e.g., `isCausalFor`, `isOncogenicFor`)
- **`subjectVariant`** — unchanged (e.g., `clinvar:12582`)
- **`objectClassification`** — REMOVED from proposition (classification lives on the statement only)
- **`objectConditionClassification`** — REMOVED from RCV proposition
- **`aggregateQualifiers`** — REMOVED entirely

### VCV objectCondition (New)

VCV propositions gain a new `objectCondition` attribute collecting unique conditions from contributing SCVs:

- **Single unique condition** → the condition as a MappableConcept (a Condition)
- **Multiple unique conditions** → ConceptSet with `"OR"` membershipOperator containing all unique conditions

This applies at all VCV aggregation layers. Each layer carries forward the objectCondition from its contributing child.

### RCV objectCondition

No change. RCV is already scoped to a single condition per accession. The existing condition handling in `temp_rcv_condition_data` remains as-is, but moves to the proposition's `objectCondition` attribute instead of `objectConditionClassification`.

### Statement-Level Changes

- **`classification`** — unchanged (already present as a Classification MappableConcept with optional conflictingExplanation extension)
- **`direction`** — derived from the aggregate classification label:
- **`strength`** — derived from the aggregate classification label:
- **`confidence`** — NEW attribute. Reflects the submission level label at each aggregate layer:
  - Base Grouping: submission level label from `submission_level.label` (e.g., `"criteria provided"`, `"practice guideline"`)
  - Tier Grouping: carried from contributing Base Grouping record
  - Aggregate Contribution: winning submission level's label — requires a new join to `submission_level` on `agg.contributing_submission_level = sl.code` (not currently present in Aggregate Contribution statement queries)
- Non-contributing evidence lines carry confidence from their own layer — each layer sets its own confidence at the BASE step, and the PRE inlining carries it forward automatically

### Single-SCV Passthrough Rule

When a Base Grouping contains exactly one contributing SCV, the aggregate statement inherits the SCV's `direction`, `strength`, and full `proposition` structure identically. The `confidence` is still set to the submission level label. The direction/strength mapping table below only applies when multiple SCVs are aggregated.

### Direction and Strength Mapping (Multiple SCVs)

When multiple SCVs are aggregated, the `direction` and `strength` values are derived from the aggregate classification label (the `agg_label` / `actual_agg_classif_label` value). This mapping is applied at every aggregate layer.

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

Null strength values are omitted from JSON output by `JSON_STRIP_NULLS`.

### SCV Statement Changes

SCV statements also gain the `confidence` attribute. The submission level value currently stored in the `clinvarReviewStatus` extension moves to `confidence` on the SCV statement. This ensures a consistent `confidence` attribute across SCV and aggregate statements.

**Note:** This is a change to `gks_scv_statement_proc`, not the aggregate procedures. The SCV `direction` and `strength` values remain unchanged (they are already derived from the classification at the SCV level).

## Proposition Type and Predicate Mapping

The `clinvar_proposition_types` lookup table needs two new columns: `gks_type` and `gks_predicate`.

| prop_type code | gks_type | gks_predicate |
|---|---|---|
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

Each `prop_type` maps 1:1 to a single GKS proposition type. These are derived from the existing `clinvar_clinsig_types.final_proposition_type` / `final_predicate` values — all classification codes within a given prop_type share the same proposition type.

## VCV Condition Data Flow

Currently condition data is only collected in VCV for somatic sci propositions (via `gks_scv_condition_mapping` for trait names). The new design requires condition concept collection for ALL proposition types.

### Aggregation Proc Changes

The VCV aggregation proc (`gks_vcv_proc`) needs to:

1. Join `gks_scv_condition_sets` by `scv_id` in the base data or at the Base Grouping step
2. Collect unique condition concepts per aggregation group (keyed by condition `id` to deduplicate)
3. Store the collected conditions array on `gks_vcv_grouping_base_agg`

**Handling compound conditionSets:** Individual SCVs may have either a single `condition` or a `conditionSet` (multiple conditions). When collecting unique conditions across SCVs in a group, individual conditions within a `conditionSet` should be flattened and merged into the unique set — each condition is treated independently, not as an atomic group.

**Pipeline ordering dependency:** `gks_scv_condition_proc` must run before `gks_vcv_proc` (this is already the case in the pipeline, but the dependency is now explicit for VCV).

### Statement Proc Changes

The VCV statement proc (`gks_vcv_statement_proc`) builds the objectCondition:

- **Single condition in array** → output as the MappableConcept directly
- **Multiple conditions in array** → wrap in ConceptSet with `"OR"` membershipOperator
- **No conditions found** → `objectCondition` is NULL, omitted from output by `JSON_STRIP_NULLS`

At each layer, the objectCondition is carried forward from the contributing child (same as classification is today).

### RCV Condition Data Flow

The existing `temp_rcv_condition_data` resolution remains, but the output moves from `objectConditionClassification` (a ConceptSet of condition + classification) to `objectCondition` (just the condition, without the classification). When no condition data exists for an RCV (the `LEFT JOIN` yields NULL), `objectCondition` will be NULL and omitted from output by `JSON_STRIP_NULLS`.

## What Gets Removed

- `VariantAggregateClassificationProposition` type
- `VariantAggregateConditionClassificationProposition` type
- `hasAggregateClassification` predicate
- `hasAggregateConditionClassification` predicate
- `objectClassification` from VCV propositions
- `objectConditionClassification` from RCV propositions
- `aggregateQualifiers` from all propositions
- Hardcoded `"definitive"` strength and `"supports"` direction — replaced with classification-derived values
- **Added**: `confidence` attribute on all aggregate statements (carrying submission level label)

## Example: VCV Germline Pathogenicity (Before → After)

### Before

```json
{
  "type": "Statement",
  "direction": "supports",
  "classification": { "conceptType": "Classification", "name": "Pathogenic/Likely pathogenic" },
  "strength": "definitive",
  "proposition": {
    "type": "VariantAggregateClassificationProposition",
    "predicate": "hasAggregateClassification",
    "subjectVariant": "clinvar:12582",
    "objectClassification": { "conceptType": "Classification", "name": "Pathogenic/Likely pathogenic" },
    "aggregateQualifiers": [
      { "name": "AssertionGroup", "value": "Germline" },
      { "name": "PropositionType", "value": "Pathogenicity" }
    ]
  }
}
```

### After

```json
{
  "type": "Statement",
  "direction": "supports",
  "classification": { "conceptType": "Classification", "name": "Pathogenic/Likely pathogenic" },
  "confidence": "criteria provided",
  "proposition": {
    "type": "VariantPathogenicityProposition",
    "predicate": "isCausalFor",
    "subjectVariant": "clinvar:12582",
    "objectCondition": { "conceptType": "Disease", "name": "Breast cancer", "primaryCoding": { "..." } }
  }
}
```

Note: `strength` is omitted because "Pathogenic/Likely pathogenic" maps to null strength. `direction` is `"supports"` per the mapping table.

### After (multiple conditions)

```json
{
  "proposition": {
    "type": "VariantPathogenicityProposition",
    "predicate": "isCausalFor",
    "subjectVariant": "clinvar:12582",
    "objectCondition": {
      "type": "ConceptSet",
      "membershipOperator": "OR",
      "concepts": [
        { "conceptType": "Disease", "name": "Breast cancer", "primaryCoding": { "..." } },
        { "conceptType": "Disease", "name": "Ovarian cancer", "primaryCoding": { "..." } }
      ]
    }
  }
}
```

## Example: RCV Germline Pathogenicity (Before → After)

### Before

```json
{
  "type": "Statement",
  "direction": "supports",
  "classification": { "conceptType": "Classification", "name": "Pathogenic" },
  "strength": "definitive",
  "proposition": {
    "type": "VariantAggregateConditionClassificationProposition",
    "predicate": "hasAggregateConditionClassification",
    "subjectVariant": "clinvar:12582",
    "objectConditionClassification": {
      "type": "ConceptSet",
      "membershipOperator": "AND",
      "concepts": [
        { "conceptType": "Disease", "name": "Breast cancer" },
        { "conceptType": "Classification", "name": "Pathogenic" }
      ]
    },
    "aggregateQualifiers": [
      { "name": "AssertionGroup", "value": "Germline" },
      { "name": "PropositionType", "value": "Pathogenicity" }
    ]
  }
}
```

### After

```json
{
  "type": "Statement",
  "direction": "supports",
  "strength": "definitive",
  "classification": { "conceptType": "Classification", "name": "Pathogenic" },
  "confidence": "criteria provided",
  "proposition": {
    "type": "VariantPathogenicityProposition",
    "predicate": "isCausalFor",
    "subjectVariant": "clinvar:12582",
    "objectCondition": { "conceptType": "Disease", "name": "Breast cancer", "primaryCoding": { "..." } }
  }
}
```

Note: `direction` is `"supports"` and `strength` is `"definitive"` because "Pathogenic" maps to supports/definitive.

## Files Affected

### Lookup Table
- `clinvar_proposition_types` — add `gks_type` and `gks_predicate` columns

### SQL Procedures
- `src/procedures/gks-scv-statement-proc.sql` — add `confidence` attribute (submission level label); remove submission level from `clinvarReviewStatus` extension
- `src/procedures/gks-vcv-proc.sql` — add condition collection to base data and Base Grouping; carry conditions through Tier Grouping and Aggregate Contribution
- `src/procedures/gks-vcv-statement-proc.sql` — replace proposition structure at all layers (type, predicate, objectCondition); add confidence; derive direction/strength from classification (with single-SCV passthrough); remove aggregateQualifiers
- `src/procedures/gks-rcv-proc.sql` — no structural changes needed (conditions already scoped by RCV)
- `src/procedures/gks-rcv-statement-proc.sql` — replace proposition structure at all layers (type, predicate, objectCondition from existing condition data); change strength to submission level label; remove aggregateQualifiers and objectConditionClassification
- `src/procedures/gks-json-proc.sql` — no changes needed (operates on generic JSON serialization via `JSON_STRIP_NULLS(TO_JSON(...))`)

### Documentation
- `docs/profiles/propositions.md` — remove Aggregate Proposition Types section
- `docs/pipeline/vcv-statements/vcv-aggregation-rules.md` — update Classification Output section
- `docs/pipeline/vcv-statements/vcv-proc.md` — update proposition descriptions at all layers
- `docs/pipeline/rcv-statements/rcv-proc.md` — update proposition descriptions at all layers
- `docs/output-reference/vcv-statements.md` — update proposition field documentation
- `docs/output-reference/rcv-statements.md` — update proposition field documentation
- `docs/reference/glossary.md` — remove aggregate proposition entries, update related terms

### Examples
- All VCV examples in `examples/vcv/` — update proposition structures
- All RCV examples in `examples/rcv/` — update proposition structures

### Schemas (if applicable)
- Any JSON schemas that define the aggregate proposition structure
