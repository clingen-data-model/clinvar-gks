# ClinvarConfersSensitivityProposition

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A proposition describing a variant that confers sensitivity to a condition or environmental factor. Used for ClinVar submissions classified as "confers sensitivity". ClinVar has stopped accepting new submissions with this classification, but historical submissions remain.

**JSON Schema:** [ClinvarConfersSensitivityProposition](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarConfersSensitivityProposition){ target=_blank }

**Composed of:**

- [va-spec:ClinicalVariantProposition](va-spec:ClinicalVariantProposition.md)

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `type` | `string` | 0..1 | MUST be "ClinvarConfersSensitivityProposition". |
| `predicate` | `string` | 1..1 | The relationship the Proposition describes between the subject variant and object condition. MUST be "confersSensitivityFor". |
| `objectCondition` | [Condition](Condition.md) | [iriReference](iriReference.md) | 1..1 | The condition or factor to which the variant confers sensitivity. |

