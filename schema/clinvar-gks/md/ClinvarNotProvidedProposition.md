# ClinvarNotProvidedProposition

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A proposition for ClinVar submissions where the submitter did not provide a clinical classification. These submissions still carry variant-condition associations but lack a formal pathogenicity or clinical significance assessment.

**JSON Schema:** [ClinvarNotProvidedProposition](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarNotProvidedProposition){ target=_blank }

**Composed of:**

- [va-spec:ClinicalVariantProposition](va-spec:ClinicalVariantProposition.md)

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `type` | `string` | 0..1 | MUST be "ClinvarNotProvidedProposition". |
| `predicate` | `string` | 1..1 | The relationship the Proposition describes between the subject variant and object condition. MUST be "hasNoProvidedClassificationFor". |
| `objectCondition` | [Condition](Condition.md) | [iriReference](iriReference.md) | 1..1 | The condition for which no classification was provided. |

