# RCV Statement Extensions

## Overview

RCV aggregate statement records contain `extensions` arrays at two structural levels — on the top-level `Statement` and on the `classification` object. Extensions carry aggregate review status information and classification context that are not part of the GA4GH VA-Spec statement model but are essential for interpreting the aggregation outcome.

RCV extensions follow the same patterns as [VCV extensions](../vcv-statements/vcv-extensions.md). The key structural difference is that RCV statements are scoped to a specific condition — the condition reference is on the proposition (via `#/condition/` or `#/conditionSet/`), not embedded in the extensions.

All extensions follow the structure `{ "name": "<extension_name>", "value": <value> }`.

---

## Statement Extensions

Extensions on the top-level RCV `Statement` record.

<div class="field-table" markdown>

| Extension | Type | Description |
|---|---|---|
| `clinvarReviewStatus` | string | The aggregate review status derived from the submission level and aggregation outcome. Same value set as VCV. Always present. |

</div>

### Example

```json
[
  { "name": "clinvarReviewStatus", "value": "criteria provided, conflicting classifications" }
]
```

See [VCV Statement Extensions](../vcv-statements/vcv-extensions.md#statement-extensions) for the full list of review status values.

---

## Classification Extensions

Extensions on the `classification` MappableConcept within the Statement.

<div class="field-table" markdown>

| Extension | Type | Description |
|---|---|---|
| `conflictingExplanation` | string | A formatted breakdown of conflicting classification counts. Present only when the classification is conflicting. |

</div>

### Example

A conflicting RCV classification:

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
    The `conflictingExplanation` extension follows the same rules as VCV — present only when multiple distinct significance values exist for a conflict-detectable proposition type.

---

## SCI Classification Label Format

For somatic clinical impact (SCI) propositions, the RCV aggregate classification label includes the tier, assertion type, and clinical significance:

```text
<tier_label> - <assertion_type> - <clinical_significance> (<scv_count>)
```

Examples:

- `Tier I - Strong - diagnostic - supports diagnosis (1)`
- `Tier I - Strong - therapeutic - sensitivity/response (2)`
- `Tier II - Potential - prognostic - poor outcome (1)`

The condition/tumor name is not included in the classification label because it is already represented in the proposition's `objectCondition` reference.
