# RCV Statements

## Overview

The RCV statement output contains one JSON record per condition-level aggregate classification. Each record is a `Statement` that aggregates individual SCV submissions for the same variant **and condition** into a hierarchical summary — combining classifications across submission levels to produce a single condition-specific result.

RCV statements differ from VCV statements in two important ways:

1. **Condition-scoped aggregation** — each RCV is scoped to a specific condition (identified by `trait_set_id`), whereas VCV statements aggregate across all conditions for a variant.
2. **Simplified proposition structure** — the proposition uses a single `objectConditionClassification` ConceptSet that always contains exactly **2 concepts**: the condition (sourced directly from the SCV's actual condition or conditionSet) and the aggregate Classification. PG and EP are independent submission levels in RCV.

RCV statements are produced by the [RCV Procedures](../pipeline/rcv-statements/rcv-proc.md) and serialized via the JSON proc. The output table is `gks_rcv_statement`.

---

## Record Structure

Each record is a `Statement` with the following top-level fields:

<div class="field-table" markdown>

| Field | Type | Description |
| --- | --- | --- |
| `id` | string | RCV accession with version and aggregation path — e.g., `RCV001781420.1-G-PATH` |
| `type` | string | Always `Statement` |
| `direction` | string | Always `supports` |
| `strength` | string | Always `definitive` |
| `classification_mappableConcept` | object | Aggregate classification label as MappableConcept. See [Classification](#classification) |
| `proposition` | object | The aggregate proposition with variant, objectConditionClassification, and qualifiers. See [Proposition](#proposition) |
| `extensions` | array | Aggregate metadata — `clinvarReviewStatus` |
| `evidenceLines` | array | Contributing and non-contributing evidence from lower aggregation layers |

</div>

Like VCV, RCV statements use only `classification_mappableConcept` at every layer. PG and EP are independent submission levels.

---

## Classification

RCV statements always use a single `classification_mappableConcept` containing the aggregate classification label. The label format depends on the proposition type and submission level.

### Standard format

For most proposition types (pathogenicity, oncogenicity, association, etc.), the label is the aggregated label from contributing SCVs (e.g., `Pathogenic/Likely pathogenic`, `Conflicting classifications of pathogenicity`).

```json
{
  "classification_mappableConcept": {
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

The condition/tumor name is not included in the classification label because it is already represented in the `objectConditionClassification` ConceptSet within the proposition.

---

## Proposition

The `proposition` describes the condition-specific aggregate classification claim. RCV uses a single `objectConditionClassification` ConceptSet that combines the condition and classification as its two member concepts.

<div class="field-table" markdown>

| Field | Type | Description |
| --- | --- | --- |
| `type` | string | Always `VariantAggregateConditionClassificationProposition` |
| `id` | string | Proposition ID — RCV accession without version, dash-separated (e.g., `RCV001781420-G-PATH-CP`) |
| `subjectVariant` | string | Reference to the categorical variant — `clinvar:{variation_id}` |
| `predicate` | string | Always `hasAggregateConditionClassification` |
| `objectConditionClassification` | object | ConceptSet with exactly 2 concepts: the SCV's condition (or conditionSet) and the classification. See [objectConditionClassification](#objectconditionclassification) |
| `aggregateQualifiers` | array | Context qualifiers — AssertionGroup, PropositionType, SubmissionLevel, ClassificationTier |

</div>

### objectConditionClassification

`objectConditionClassification` is always a ConceptSet with exactly 2 concepts in this order:

1. **Condition** — the actual SCV condition, sourced from `gks_scv_condition_sets`. May be either:
    - A full `Condition` MappableConcept (id, name, conceptType, primaryCoding, mappings)
    - Or a full `ConditionSet` ConceptSet of conditions (id, conditions array, membershipOperator) — for SCVs with multiple conditions
   Extensions are excluded.
2. **Classification** — the aggregate Classification (matching `classification_mappableConcept.name`).

Single condition example:

```json
{
  "objectConditionClassification": {
    "type": "ConceptSet",
    "concepts": [
      {
        "conceptType": "Disease",
        "id": "12345",
        "name": "Hereditary breast and ovarian cancer syndrome",
        "primaryCoding": {"code": "C0677776", "system": "MedGen"},
        "mappings": [...]
      },
      {
        "conceptType": "Classification",
        "name": "Pathogenic/Likely pathogenic"
      }
    ],
    "membershipOperator": "AND"
  }
}
```

Multi-condition example (when the SCV uses a conditionSet):

```json
{
  "objectConditionClassification": {
    "type": "ConceptSet",
    "concepts": [
      {
        "type": "ConceptSet",
        "id": "tsid_999",
        "conditions": [
          {"conceptType": "Disease", "id": "1", "name": "Condition A", "primaryCoding": {...}},
          {"conceptType": "Disease", "id": "2", "name": "Condition B", "primaryCoding": {...}}
        ],
        "membershipOperator": "AND"
      },
      {
        "conceptType": "Classification",
        "name": "Pathogenic"
      }
    ],
    "membershipOperator": "AND"
  }
}
```

This structure is consistent across all 4 layers — RCV uses the same ConceptSet form at every layer regardless of submission level.

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

RCV statements use the same 4-layer aggregation hierarchy as VCV, with condition (`trait_set_id`) as an additional grouping dimension at every layer.

| Layer | ID Format | Aggregates By | Scope |
| --- | --- | --- | --- |
| L4 (Group) | `RCV001781420.1-G` | Statement group | Germline only |
| L3 (Submission Level) | `RCV001781420.1-G-PATH` | Proposition type | All |
| L2 (Tier) | `RCV006254391.1-S-SCI-CP` | Submission level | Somatic only |
| L1 (Base) | `RCV006254391.1-S-SCI-CP-TIER I - STRONG` | Submission level + tier | All |

Germline RCV statements use Layer 4 as the top level. Somatic RCV statements use Layer 3 as the top level.

See [RCV Procedures](../pipeline/rcv-statements/rcv-proc.md) for implementation details.
