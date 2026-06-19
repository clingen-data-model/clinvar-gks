# SubmittedConditionMapping

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

The submitter's original condition details and how they were mapped to a ClinVar canonical condition. Includes the submitted name, type, MedGen ID, cross-references, and the normalization path (direct match, original medgen match, normalized match, resolution type, mapping details).

**JSON Schema:** [SubmittedConditionMapping](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/SubmittedConditionMapping){ target=_blank }

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `id` | `string` | 0..1 | The submitted trait category assignment identifier (cat_id). |
| `name` | `string` | 0..1 | The condition name as submitted by the submitter. |
| `type` | `string` | 0..1 | The condition type as submitted (e.g., "Disease", "Finding"). |
| `medgen_id` | `string` | 0..1 | The MedGen ID submitted by the submitter, if provided. |
| `xrefs` | `Coding`[] (unordered) | 0..m | Cross-references submitted by the submitter for this condition. |
| `original_medgen_match` | `object` | 0..1 | The original MedGen match when the submitted MedGen ID was remapped to a different canonical MedGen concept. Contains id and name of the original match. Null when no remapping occurred. |
| `direct_match` | `string` | 0..1 | JSON pointer reference to the directly matched condition (e.g., "#/condition/clinvar.trait:123"). Present only when the direct match differs from the normalized match. |
| `normalized_match` | `string` | 0..1 | JSON pointer reference to the final normalized condition (e.g., "#/condition/clinvar.trait:456"). |
| `normalized_resolution` | `string` | 0..1 | How the condition normalization was resolved (e.g., "rcv-tm medgen id", "rcv-tm preferred name", "random trait assignment"). |
| `mapping` | `object` | 0..1 | The mapping details used to resolve the submitted condition to a ClinVar trait, including mapping type, reference field, and value. |

