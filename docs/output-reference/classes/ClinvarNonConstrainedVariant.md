# ClinvarNonConstrainedVariant

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A ClinVar variant that cannot be mapped to a specific VRS allele or location — haplotypes, genotypes, and other complex or ambiguously defined variants. These rely solely on the ClinVar variation ID and use the generalized Cat-VRS CategoricalVariant without VRS constraints.

**JSON Schema:** [ClinvarNonConstrainedVariant](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarNonConstrainedVariant){ target=_blank }

Some ClinvarNonConstrainedVariant attributes are inherited from `CategoricalVariant`, `ClinvarCategoricalVariantProperties`.

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
| `constraints` | `Constraint`[] (unordered) | 0..m | No VRS constraints — this variant type cannot be mapped to a specific VRS allele or location. The constraints array is empty. |
| `mappings` | `ConceptMapping`[] (unordered) | 0..m | A list of mappings to concepts in terminologies or code systems. Each mapping should include a coding and a relation. |

