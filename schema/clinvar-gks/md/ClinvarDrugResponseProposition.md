# ClinvarDrugResponseProposition

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A proposition describing the role of a variant in modulating drug response. Used for ClinVar submissions classified as "drug response". Distinct from the GA4GH VariantTherapeuticResponseProposition which is used for somatic clinical impact therapeutic response assertions.

**JSON Schema:** [ClinvarDrugResponseProposition](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarDrugResponseProposition){ target=_blank }

**Composed of:**

- [va-spec:ClinicalVariantProposition](va-spec:ClinicalVariantProposition.md)

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `type` | `string` | 0..1 | MUST be "ClinvarDrugResponseProposition". |
| `predicate` | `string` | 1..1 | The relationship the Proposition describes between the subject variant and object condition. MUST be "hasDrugResponseFor". |
| `objectCondition` | [Condition](Condition.md) | [iriReference](iriReference.md) | 1..1 | The condition context in which the drug response is observed. |

