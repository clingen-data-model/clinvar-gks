# RCV Statements

## Overview

The RCV statement output contains one JSON record per condition-level aggregate classification. Each record is a `Statement` that aggregates individual SCV submissions for the same variant **and condition** into a hierarchical summary — combining classifications across submission levels to produce a single condition-specific result.

RCV statements differ from VCV statements in two important ways:

1. **Condition-scoped aggregation** — each RCV is scoped to a specific condition (identified by `trait_set_id`), whereas VCV statements aggregate across all conditions for a variant.
2. **Condition-only proposition object** — the proposition uses `objectCondition` containing just the condition (sourced directly from the SCV's actual condition or conditionSet), without a classification wrapped alongside it. PG and EP are independent submission levels in RCV.

RCV statements are produced by the [RCV Procedures](../pipeline/rcv-statements/rcv-proc.md) and serialized via the JSON proc. The output table is `gks_rcv_statement`.

---

## Record Structure

Each record is a `Statement` with the following top-level fields:

<div class="field-table" markdown>

| Field | Type | Description |
| --- | --- | --- |
| `id` | string | RCV accession with version and aggregation path — e.g., `RCV001781420.1-G-PATH` |
| `type` | string | Always `Statement` |
| `confidence` | string | The submission level label (e.g., `"expert panel"`, `"assertion criteria provided"`) |
| `direction` | string | Derived from the aggregate classification label; passed through from the contributing SCV for single-SCV aggregations |
| `strength` | string | Derived from the aggregate classification label; passed through from the contributing SCV for single-SCV aggregations |
| `classification` | object | Aggregate classification label as MappableConcept. See [Classification](#classification) |
| `proposition` | object | The aggregate proposition with variant, objectCondition, and SCV-matching type/predicate. See [Proposition](#proposition) |
| `extensions` | array | Aggregate metadata — `clinvarReviewStatus` |
| `evidenceLines` | array | Contributing and non-contributing evidence from lower aggregation layers |

</div>

Like VCV, RCV statements use only `classification` at every layer. PG and EP are independent submission levels.

---

## Classification

RCV statements always use a single `classification` containing the aggregate classification label. The label format depends on the proposition type and submission level.

### Standard format

For most proposition types (pathogenicity, oncogenicity, association, etc.), the label is the aggregated label from contributing SCVs (e.g., `Pathogenic/Likely pathogenic`, `Conflicting classifications of pathogenicity`).

```json
{
  "classification": {
    "conceptType": "Classification",
    "name": "Pathogenic/Likely pathogenic",
    "extension": [
      {"name": "conflictingExplanation", "value": "Pathogenic(3); Likely pathogenic(2)"}
    ]
  }
}
```

### Somatic Clinical Impact format

For somatic clinical impact (SCI) propositions, the RCV label includes the clinical impact assertion type and significance instead of the condition/tumor name:

```text
<tier_label> - <assertion_type> - <clinical_significance> (<scv_count>)
```

Examples:

- `Tier I - Strong - diagnostic - supports diagnosis (1)`
- `Tier I - Strong - therapeutic - sensitivity/response (2)`
- `Tier II - Potential - prognostic - poor outcome (1)`

The condition/tumor name is not included in the classification label because it is already represented in the `objectCondition` field within the proposition.

---

## Proposition

The `proposition` describes the condition-specific aggregate classification claim. It uses an SCV-matching proposition `type` and `predicate` (from `clinvar_proposition_types`) and carries an `objectCondition` containing just the condition.

<div class="field-table" markdown>

| Field | Type | Description |
| --- | --- | --- |
| `type` | string | SCV-matching proposition type from `clinvar_proposition_types.gks_type` — e.g., `VariantPathogenicityProposition` |
| `id` | string | Proposition ID — RCV accession without version, dash-separated (e.g., `RCV001781420-G-PATH-CP`) |
| `subjectVariant` | string | Reference to the categorical variant — `clinvar:{variation_id}` |
| `predicate` | string | SCV-matching predicate from `clinvar_proposition_types.gks_predicate` — e.g., `isCausalFor` |
| `objectCondition` | object | The condition for this RCV, sourced from `gks_scv_condition_sets`. See [objectCondition](#objectcondition) |

</div>

### objectCondition

`objectCondition` is the actual SCV condition, sourced from `gks_scv_condition_sets`. It may be either:

- A full `Condition` MappableConcept (id, name, conceptType, primaryCoding, mappings) — for SCVs with a single condition
- A full `ConditionSet` ConceptSet of conditions (id, conditions array, membershipOperator) — for SCVs with multiple conditions

Extensions are excluded. The classification is **not** included in `objectCondition` — it lives on the statement-level `classification` field.

Single condition example:

```json
{
  "objectCondition": {
    "conceptType": "Disease",
    "id": "12345",
    "name": "Hereditary breast and ovarian cancer syndrome",
    "primaryCoding": {"code": "C0677776", "system": "MedGen"},
    "mappings": [...]
  }
}
```

Multi-condition example (when the SCV uses a conditionSet):

```json
{
  "objectCondition": {
    "type": "ConceptSet",
    "id": "tsid_999",
    "conditions": [
      {"conceptType": "Disease", "id": "1", "name": "Condition A", "primaryCoding": {...}},
      {"conceptType": "Disease", "id": "2", "name": "Condition B", "primaryCoding": {...}}
    ],
    "membershipOperator": "AND"
  }
}
```

This structure is consistent across all aggregation steps — RCV uses the same condition-only form at every level regardless of submission level.

---

## Extensions

RCV statements carry the same extension as VCV:

| Extension | Type | Description |
| --- | --- | --- |
| `clinvarReviewStatus` | string | The aggregate review status reflecting submission level and aggregation outcome |

---

## Evidence Lines

Evidence lines work identically to VCV — see [VCV Evidence Lines](vcv-statements.md#evidence-lines). At the top layer, evidence items contain fully inlined sub-statements. At the bottom layer (L1), evidence items are ID-only references to individual SCV submissions.

---

## Layer Hierarchy

RCV statements use the same 2-layer aggregation hierarchy as VCV, with condition (`trait_set_id`) as an additional grouping dimension at every layer.

| Layer | ID Format | Aggregates By | Scope |
| --- | --- | --- | --- |
| Aggregate Contribution | `RCV001781420.1-G-PATH` | Proposition type | All |
| Tier Grouping | `RCV006254391.1-S-SCI-CP` | Submission level | Somatic only |
| Base Grouping | `RCV006254391.1-S-SCI-CP-TIER I - STRONG` | Submission level + tier | All |

Both germline and somatic RCV statements use the Aggregate Contribution Layer as the top level.

See [RCV Procedures](../pipeline/rcv-statements/rcv-proc.md) for implementation details.
