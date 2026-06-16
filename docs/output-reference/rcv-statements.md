# RCV Statements

## Overview

The `rcv` bundle section contains one record per condition-level aggregate classification. Each record is a `Statement` that aggregates individual SCV submissions for the same variant **and condition** into a hierarchical summary — combining classifications across submission levels to produce a single condition-specific result.

RCV statements differ from VCV statements in one important way: **condition-scoped aggregation** — each RCV is scoped to a specific condition (identified by `trait_set_id`), whereas VCV statements aggregate across all conditions for a variant.

RCV statements use `#/` references for propositions, contributing SCVs, and lower-level RCV groupings. They are produced by the [RCV Procedures](../pipeline/rcv-statements/rcv-proc.md).

---

## Record Structure

Each record is a `Statement` with the following top-level fields:

<div class="field-table" markdown>

| Field | Type | Description |
| --- | --- | --- |
| `id` | string | RCV layer ID — e.g., `RCV001781420.1-G-PATH-CP` |
| `type` | string | Always `Statement` |
| `proposition` | string | `#/proposition/{id}` reference to the aggregate proposition |
| `classification` | object | MappableConcept — the aggregate classification label. See [Classification](#classification) |
| `strength` | object | MappableConcept — the aggregate evidence strength |
| `direction` | string | `supports`, `disputes`, or `neutral` — derived from the aggregate classification |
| `confidence` | string | Submission level label (e.g., `criteria provided`, `expert panel`) |
| `extensions` | array | Aggregate metadata — `clinvarReviewStatus` |
| `evidenceLines` | array | Contributing and non-contributing evidence. See [Evidence Lines](#evidence-lines) |

</div>

The `classification`, `strength`, `direction`, and `confidence` fields follow the same structure and rules as [VCV Statements](vcv-statements.md).

---

## Classification

RCV statements use the same MappableConcept classification as VCV:

```json
{
  "conceptType": "Classification",
  "name": "Pathogenic/Likely pathogenic",
  "extensions": [
    {"name": "conflictingExplanation", "value": "Pathogenic(3); Likely pathogenic(2)"}
  ]
}
```

For somatic clinical impact (SCI) propositions, the classification label may include the tier, assertion type, and clinical significance.

---

## Proposition

RCV propositions are stored in the `proposition` bundle section. Each RCV statement references its proposition via `#/proposition/{id}`.

A resolved RCV proposition contains:

| Field | Type | Description |
| --- | --- | --- |
| `type` | string | Proposition type matching the underlying SCVs (e.g., `VariantPathogenicityProposition`) |
| `id` | string | Proposition ID (e.g., `RCV001781420-G-PATH-CP`) |
| `subjectVariant` | string | `#/variation/clinvar:{id}` reference |
| `predicate` | string | Predicate matching the underlying SCVs (e.g., `isCausalFor`) |
| `objectCondition` | string | `#/condition/clinvar.trait:{id}` or `#/conditionSet/clinvar.traitset:{id}` reference — the specific condition for this RCV |

The key difference from VCV propositions: the `objectCondition` references the specific condition for this RCV accession, sourced from the representative SCV's condition mapping. VCV propositions may carry multiple condition references from contributing SCVs.

---

## Evidence Lines

Evidence lines work identically to VCV. Each evidence line references contributing or non-contributing submissions:

```json
{
  "type": "EvidenceLine",
  "directionOfEvidenceProvided": "supports",
  "strengthOfEvidenceProvided": {
    "conceptType": "Strength",
    "name": "Contributing"
  },
  "evidenceItems": [
    "#/scv/clinvar.submission:SCV001571657.2",
    "#/scv/clinvar.submission:SCV000329383.7"
  ]
}
```

At the Classification layer, evidence items reference SCVs via `#/scv/`. At the Priority and Aggregate Contribution layers, evidence items reference lower-level RCV groupings via `#/rcv/`.

See [VCV Evidence Lines](vcv-statements.md#evidence-lines) for the full field reference.

---

## Layer Hierarchy

RCV statements use the same multi-layer aggregation hierarchy as VCV, with condition (`trait_set_id`) as an additional grouping dimension at every layer.

| Layer | ID Format | Aggregates By | Scope |
| --- | --- | --- | --- |
| Classification | `{RCV}.{ver}-{group}-{PROP}-{level}[-{TIER}]` | Classification label within submission level | All |
| Priority | `{RCV}.{ver}-{group}-{PROP}-{level}` | Tier priority within submission level | Somatic only |
| Aggregate Contribution | `{RCV}.{ver}-{group}-{PROP}` | Submission level (winner-takes-all) | All |

Submission level ranking is `PG > EP > CP > NOCP > NOCL > FLAG`.

See [RCV Procedures](../pipeline/rcv-statements/rcv-proc.md) for implementation details.

---

## Examples

Annotated JSONC examples of RCV statement records are available in the repository:

- [RCV statement examples](https://github.com/clingen-data-model/clinvar-gks/tree/main/examples/rcv)
