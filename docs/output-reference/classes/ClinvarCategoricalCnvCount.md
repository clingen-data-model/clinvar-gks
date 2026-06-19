# ClinvarCategoricalCnvCount

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A ClinVar copy number variant with an absolute copy count. Uses a DefiningLocationConstraint with a CopyCountConstraint from Cat-VRS CategoricalCnv.

**JSON Schema:** [ClinvarCategoricalCnvCount](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarCategoricalCnvCount){ target=_blank }

Some ClinvarCategoricalCnvCount attributes are inherited from `CategoricalCnv`, `ClinvarCategoricalVariantProperties`.

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `id` | `string` | 0..1 | The 'logical' identifier of the Entity in the system of record, e.g. a UUID.  This 'id' is unique within a given system, but may or may not be globally unique outside the system. It is used within a system to reference an object from another. |
| `name` | `string` | 0..1 | A primary name for the entity. |
| `description` | `string` | 0..1 | A free-text description of the Entity. |
| `aliases` | `string`[] (unordered) | 0..m | Alternative name(s) for the Entity. |
| `extensions` | `Extension`[] (unordered) | 0..m | ClinVar-specific metadata. See [Variations — Extensions](../cat-vrs.md#extensions) for the complete list of extension names, value types, and custom type definitions. |
| `type` | `string` | 0..1 | MUST be "CategoricalVariant" |
| `members` | `Variation` \| `iriReference`[] (unordered) | 0..m | A non-exhaustive list of VRS Variations that satisfy the constraints of this categorical variant. |
| `constraints` | `DefiningLocationConstraint` \| `CopyCountConstraint`[] (unordered) | 0..m | Defining constraints linking this variant to its resolved VRS location and copy count. Contains a `DefiningLocationConstraint` with a `location` reference to `#/location/{id}` and a `CopyCountConstraint` indicating the absolute copy number or range. See [Variations — Constraints](../cat-vrs.md#constraints). |
| `mappings` | `ConceptMapping`[] (unordered) | 0..m | A list of mappings to concepts in terminologies or code systems. Each mapping should include a coding and a relation. |

