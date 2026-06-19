# VCV Statements

## Overview

The `vcv` bundle section contains one record per variation-level aggregate classification. Each record is a `Statement` that aggregates individual SCV submissions into a hierarchical summary — combining classifications across submission levels to produce a single variation-level result.

VCV statements use `#/` references for propositions, contributing SCVs, and lower-level VCV groupings. They are produced by the [VCV Procedures](../pipeline/vcv-statements/vcv-proc.md).

---

## Record Structure

Each record is a `Statement` with the following top-level fields:

<div class="field-table" markdown>

| Field | Type | Description |
| --- | --- | --- |
| `id` | string | VCV layer ID — e.g., `VCV000012582.63-G-PATH-CP` |
| `type` | string | Always `Statement` |
| `proposition` | string | `#/proposition/{id}` reference to the aggregate proposition |
| `classification` | object | MappableConcept — the aggregate classification label. See [Classification](#classification) |
| `strength` | object | MappableConcept — the aggregate evidence strength. See [Strength](#strength) |
| `direction` | string | `supports`, `disputes`, or `neutral` — derived from the aggregate classification |
| `confidence` | string | Submission level label (e.g., `criteria provided`, `expert panel`) |
| `extensions` | array of [Extension](#extensions) | ClinVar-specific aggregate metadata (0..*). See [Extensions](#extensions) |
| `evidenceLines` | array | Contributing and non-contributing evidence. See [Evidence Lines](#evidence-lines) |

</div>

---

## Classification

The `classification` field is a MappableConcept with the aggregate classification label:

```json
{
  "conceptType": "Classification",
  "name": "Pathogenic/Likely pathogenic",
  "extensions": [
    {"name": "conflictingExplanation", "value": "Pathogenic(3); Likely pathogenic(2)"}
  ]
}
```

The `extensions` array includes a `conflictingExplanation` when multiple contributing submissions have different clinical significance values. This extension is only present for CP-level aggregations with conflicts.

---

## Strength

The `strength` field is a MappableConcept derived from the aggregate classification:

```json
{
  "conceptType": "Strength",
  "name": "Definitive"
}
```

| Classification | Strength |
| --- | --- |
| Pathogenic, Benign, Oncogenic | Definitive |
| Likely pathogenic, Likely benign, Likely Oncogenic | Likely |
| Tier I (strong clinical significance) | Strong |
| Tier II (potential clinical significance) | Potential |
| Tier IV (benign/likely benign) | Likely |
| Uncertain, Conflicting, Tier III | *null (omitted)* |

For single-SCV aggregations, the strength is passed through from the contributing SCV.

---

## Proposition

VCV propositions are stored in the `proposition` bundle section. Each VCV statement references its proposition via `#/proposition/{id}`.

A resolved VCV proposition contains:

| Field | Type | Description |
| --- | --- | --- |
| `type` | string | Proposition type matching the underlying SCVs (e.g., `VariantPathogenicityProposition`) |
| `id` | string | Proposition ID (e.g., `VCV000012582-G-PATH-CP`) |
| `subjectVariant` | string | `#/variation/clinvar:{id}` reference |
| `predicate` | string | Predicate matching the underlying SCVs (e.g., `isCausalFor`) |
| `objectCondition` | array | Unique condition references from contributing SCVs (`#/condition/` and/or `#/conditionSet/`) |

---

## Evidence Lines

Each VCV statement contains `evidenceLines` — an array of evidence line objects that reference contributing and non-contributing submissions:

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

| Field | Type | Description |
| --- | --- | --- |
| `type` | string | Always `EvidenceLine` |
| `directionOfEvidenceProvided` | string | `supports` or `neutral` |
| `strengthOfEvidenceProvided` | object | MappableConcept — `Contributing` or `Non-contributing` |
| `evidenceItems` | array | `#/scv/` references (at classification layer) or `#/vcv/` references (at priority/aggregate layers) |

Contributing evidence lines use `directionOfEvidenceProvided: "supports"`. Non-contributing evidence lines (lower-ranked submission levels) use `directionOfEvidenceProvided: "neutral"`.

---

## Extensions

Extensions carry aggregate metadata not part of the GA4GH VA-Spec statement model. Each extension follows the GA4GH Extension structure: `{ "name": "<name>", "value": <value> }`. Extensions appear at two structural levels — on the top-level `Statement` and on the `classification` object.

See [VCV Extensions (Pipeline)](../pipeline/vcv-statements/vcv-extensions.md) for details on how these extensions are built during pipeline processing.

### Statement Extensions

<div class="field-table" markdown>

| Extension Name | Value Type | Description |
|---|---|---|
| `clinvarReviewStatus` | `string` | The aggregate review status derived from the submission level and aggregation outcome. Always present. Values: `practice guideline`, `reviewed by expert panel`, `criteria provided, single submitter`, `criteria provided, multiple submitters, no conflicts`, `criteria provided, conflicting classifications`, `no assertion criteria provided`, `no classification provided`, `flagged submission`. |

</div>

### Classification Extensions

Extensions on the `classification` MappableConcept within the Statement.

<div class="field-table" markdown>

| Extension Name | Value Type | Description |
|---|---|---|
| `conflictingExplanation` | `string` | A formatted breakdown of conflicting classification counts (e.g., `Pathogenic(3); Likely pathogenic(2)`). Present only when the classification is conflicting — multiple distinct significance values exist for a conflict-detectable proposition type. |

</div>

---

## Layer Hierarchy

VCV statements are built through a multi-layer aggregation hierarchy. The top-level output is the Aggregate Contribution layer; lower layers appear in the `evidenceItems` of higher layers.

| Layer | ID Format | Aggregates By | Scope |
| --- | --- | --- | --- |
| Classification | `{VCV}.{ver}-{group}-{PROP}-{level}[-{TIER}]` | Classification label within submission level | All |
| Priority | `{VCV}.{ver}-{group}-{PROP}-{level}` | Tier priority within submission level | Somatic only |
| Aggregate Contribution | `{VCV}.{ver}-{group}-{PROP}` | Submission level (winner-takes-all) | All |

Submission level ranking at the Aggregate Contribution layer is `PG > EP > CP > NOCP > NOCL > FLAG`, with only matching submission levels aggregating together at the Classification layer.

See [Aggregation Rules](../pipeline/vcv-statements/vcv-aggregation-rules.md) for detailed submission level logic and [VCV Procedures](../pipeline/vcv-statements/vcv-proc.md) for implementation details.

---

## Examples

Annotated JSONC examples of VCV statement records are available in the repository:

- [VCV statement examples](https://github.com/clingen-data-model/clinvar-gks/tree/main/examples/vcv)
