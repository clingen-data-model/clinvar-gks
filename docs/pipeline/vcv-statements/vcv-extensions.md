# VCV Statement Extensions

## Overview

!!! tip "Schema Reference"
    For the canonical extension reference tables (extension names, value types, and descriptions), see [VCV Statements — Extensions](../../output-reference/vcv-statements.md#extensions).

VCV aggregate statement records contain `extensions` arrays at two structural levels — on the top-level `Statement` and on the `classification` object. Extensions carry aggregate review status information and classification context that are not part of the GA4GH VA-Spec statement model but are essential for interpreting the aggregation outcome.

All extensions follow the structure `{ "name": "<extension_name>", "value": <value> }`.

---

## Statement Extensions

Extensions on the top-level VCV `Statement` record.

<div class="field-table" markdown>

| Extension | Type | Description |
|---|---|---|
| `clinvarReviewStatus` | string | The aggregate review status derived from the submission level and aggregation outcome. See [Aggregate Review Status](vcv-aggregation-rules.md#aggregate-review-status) for the complete value table. Always present. |

</div>

### Example

```json
[
  { "name": "clinvarReviewStatus", "value": "criteria provided, multiple submitters, no conflicts" }
]
```

Review status values:

- `practice guideline` — PG
- `reviewed by expert panel` — EP
- `criteria provided, single submitter` — CP with one submitter
- `criteria provided, multiple submitters, no conflicts` — CP concordant
- `criteria provided, conflicting classifications` — CP conflicting
- `no assertion criteria provided` — NOCP
- `no classification provided` — NOCL
- `flagged submission` — FLAG

---

## Classification Extensions

Extensions on the `classification` MappableConcept within the Statement.

<div class="field-table" markdown>

| Extension | Type | Description |
|---|---|---|
| `conflictingExplanation` | string | A formatted breakdown of conflicting classification counts. Present only when the classification is conflicting. |

</div>

### Example

A conflicting CP classification:

```json
{
  "conceptType": "Classification",
  "name": "Conflicting classifications of pathogenicity",
  "extensions": [
    { "name": "conflictingExplanation", "value": "Pathogenic(3); Likely pathogenic(2)" }
  ]
}
```

!!! note
    The `conflictingExplanation` extension is only present when multiple distinct significance values exist for a conflict-detectable proposition type. Non-conflicting classifications and single-submitter aggregations do not include this extension.

A non-conflicting classification has no extensions on the classification object:

```json
{
  "conceptType": "Classification",
  "name": "Pathogenic"
}
```
