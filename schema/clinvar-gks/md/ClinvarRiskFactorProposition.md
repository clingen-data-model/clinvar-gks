# ClinvarRiskFactorProposition

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A proposition describing the role of a variant as a risk factor for a condition. Used for ClinVar submissions classified as "risk factor". ClinVar has stopped accepting new submissions with this classification in favor of standard pathogenicity terms, but historical submissions remain.

**JSON Schema:** [ClinvarRiskFactorProposition](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarRiskFactorProposition){ target=_blank }

**Composed of:**

- [va-spec:ClinicalVariantProposition](va-spec:ClinicalVariantProposition.md)

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `type` | `string` | 0..1 | MUST be "ClinvarRiskFactorProposition". |
| `predicate` | `string` | 1..1 | The relationship the Proposition describes between the subject variant and object condition. MUST be "isRiskFactorFor". |
| `objectCondition` | [Condition](Condition.md) | [iriReference](iriReference.md) | 1..1 | The condition for which the variant is a risk factor. |

