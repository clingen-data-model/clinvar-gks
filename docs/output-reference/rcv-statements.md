# RCV Statements

## Overview

The RCV statement output contains one JSON record per condition-level aggregate classification. Each record is a `Statement` that aggregates individual SCV submissions for the same variant **and condition** into a hierarchical summary — combining classifications across submission levels to produce a single condition-specific result.

RCV statements differ from VCV statements in that each RCV is scoped to a specific condition (identified by `trait_set_id`), whereas VCV statements aggregate across all conditions for a variant. The proposition uses `objectConditionClassification` — a ConceptSet that combines the condition and classification as its two member concepts.

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
| `classification_mappableConcept` | object | Single aggregate classification label for non-PGEP. See [Classification](#classification) |
| `classification_conceptSet` | object | Single PGEP classification tuple as ConceptSet. See [Classification](#classification) |
| `classification_conceptSetSet` | object | Multiple PGEP classification tuples as nested ConceptSets. See [Classification](#classification) |
| `proposition` | object | The aggregate proposition with variant, objectConditionClassification, and qualifiers. See [Proposition](#proposition) |
| `extensions` | array | Aggregate metadata — `clinvarReviewStatus`. See [Extensions](#extensions) |
| `evidenceLines` | array | Contributing and non-contributing evidence from lower aggregation layers. See [Evidence Lines](#evidence-lines) |

</div>

---

## Classification

RCV statements use the same three mutually exclusive classification attributes as VCV. Exactly one is populated; the others are null (omitted from JSON output via null stripping).

The classification formats (`classification_mappableConcept`, `classification_conceptSet`, `classification_conceptSetSet`) work identically to VCV — see [VCV Classification](vcv-statements.md#classification) for format details.

### Somatic Clinical Impact Labels

For somatic clinical impact (SCI) propositions, the RCV classification label differs from VCV. The RCV label includes the clinical impact assertion type and significance instead of the condition/tumor name:

```
<tier_label> - <assertion_type> - <clinical_significance> (<scv_count>)
```

Examples:

- `Tier I - Strong - diagnostic - supports diagnosis (1)`
- `Tier I - Strong - therapeutic - sensitivity/response (2)`
- `Tier II - Potential - prognostic - poor outcome (1)`

The condition/tumor name is not included in the classification label because it is already represented in the `objectConditionClassification` ConceptSet within the proposition.

---

## Proposition

The `proposition` describes the condition-specific aggregate classification claim. Unlike VCV's separate `objectClassification` fields, RCV uses a unified `objectConditionClassification` that combines the condition and classification into a single ConceptSet.

<div class="field-table" markdown>

| Field | Type | Description |
| --- | --- | --- |
| `type` | string | Always `VariantAggregateConditionClassificationProposition` |
| `id` | string | Proposition ID — RCV accession without version, dash-separated (e.g., `RCV001781420-G-PATH-CP`) |
| `subjectVariant` | string | Reference to the categorical variant — `clinvar:{variation_id}` |
| `predicate` | string | Always `hasConditionClassification` |
| `objectConditionClassification` | object | ConceptSet combining condition + classification. See [objectConditionClassification](#objectconditionclassification) |
| `objectConditionClassification_conceptSetSet` | object | Multiple PGEP classification ConceptSets (deduplicated). See [objectConditionClassification](#objectconditionclassification) |
| `aggregateQualifiers` | array | Context qualifiers — AssertionGroup, PropositionType, SubmissionLevel, ClassificationTier |

</div>

### objectConditionClassification

For non-PGEP submission levels, `objectConditionClassification` is a ConceptSet with two member concepts: the condition (Disease) and the classification:

```json
{
  "objectConditionClassification": {
    "type": "ConceptSet",
    "concepts": [
      {"conceptType": "Disease", "name": "Hereditary breast and ovarian cancer syndrome"},
      {"conceptType": "Classification", "name": "Pathogenic/Likely pathogenic"}
    ],
    "membershipOperator": "AND"
  }
}
```

For multi-condition RCVs, the concepts array includes one entry per condition plus the classification.

For PGEP submissions with a single classification, `objectConditionClassification` is a ConceptSet with Classification, Condition, and SubmissionLevel concepts (same as VCV's PGEP pattern).

For PGEP submissions with multiple classifications, `objectConditionClassification_conceptSetSet` contains nested ConceptSets, each with Classification, Condition, and SubmissionLevel concepts.

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
| L1 (Base) | `RCV006254391.1-S-SCI-CP-tier i - strong` | Submission level + tier | All |

Germline RCV statements use Layer 4 as the top level. Somatic RCV statements use Layer 3 as the top level.

See [RCV Procedures](../pipeline/rcv-statements/rcv-proc.md) for implementation details.
