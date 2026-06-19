# ClinvarAssociationProposition

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A proposition describing a statistical or observational association between a variant and a condition. Used for ClinVar submissions classified as "association". Does not imply a causal relationship.

**JSON Schema:** [ClinvarAssociationProposition](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarAssociationProposition){ target=_blank }

**Composed of:**

- [va-spec:ClinicalVariantProposition](va-spec:ClinicalVariantProposition.md)

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `type` | `string` | 0..1 | MUST be "ClinvarAssociationProposition". |
| `predicate` | `string` | 1..1 | The relationship the Proposition describes between the subject variant and object condition. MUST be "isAssociatedWith". |
| `objectCondition` | [Condition](Condition.md) | [iriReference](iriReference.md) | 1..1 | The condition with which the variant is associated. |

