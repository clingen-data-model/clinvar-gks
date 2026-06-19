# ClinvarConflictingDataFromSubmitterProposition

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A proposition for ClinVar submissions where the submitter's data conflicts with other submitters' data for the same variant-condition pair. Used for submissions classified as "conflicting data from submitters".

**JSON Schema:** [ClinvarConflictingDataFromSubmitterProposition](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarConflictingDataFromSubmitterProposition){ target=_blank }

**Composed of:**

- [va-spec:ClinicalVariantProposition](va-spec:ClinicalVariantProposition.md)

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `type` | `string` | 0..1 | MUST be "ClinvarConflictingDataFromSubmitterProposition". |
| `predicate` | `string` | 1..1 | The relationship the Proposition describes between the subject variant and object condition. MUST be "isConflictingDataFromSubmittersFor". |
| `objectCondition` | [Condition](Condition.md) | [iriReference](iriReference.md) | 1..1 | The condition for which conflicting data exists. |

