# ClinvarNonConstrainedVariant

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A ClinVar variant that cannot be mapped to a specific VRS allele or location — haplotypes, genotypes, and other complex or ambiguously defined variants. These rely solely on the ClinVar variation ID and use the generalized Cat-VRS CategoricalVariant without VRS constraints.

**JSON Schema:** [ClinvarNonConstrainedVariant](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarNonConstrainedVariant){ target=_blank }

Some ClinvarNonConstrainedVariant attributes are inherited from [CategoricalVariant](CategoricalVariant.md), [ClinvarCategoricalVariantProperties](ClinvarCategoricalVariantProperties.md).

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `id` | `string` | 0..1 | The 'logical' identifier of the Entity in the system of record, e.g. a UUID.  This 'id' is unique within a given system, but may or may not be globally unique outside the system. It is used within a system to reference an object from another. |
| `name` | `string` | 0..1 | A primary name for the entity. |
| `description` | `string` | 0..1 | A free-text description of the Entity. |
| `aliases` | `string`[] (unordered) | 0..m | Alternative name(s) for the Entity. |
| `extensions` | [ExtensionClinvarHgvsList](ExtensionClinvarHgvsList.md) \| [ExtensionClinvarGeneList](ExtensionClinvarGeneList.md) \| [ExtensionCategoricalVariationType](ExtensionCategoricalVariationType.md) \| [ExtensionDefiningVrsVariationType](ExtensionDefiningVrsVariationType.md) \| [ExtensionClinvarVariationType](ExtensionClinvarVariationType.md) \| [ExtensionClinvarSubclassType](ExtensionClinvarSubclassType.md) \| [ExtensionClinvarCytogeneticLocation](ExtensionClinvarCytogeneticLocation.md) \| [ExtensionVrsPreProcessingIssue](ExtensionVrsPreProcessingIssue.md) \| [ExtensionsVrsProcessingException](ExtensionsVrsProcessingException.md)[] (unordered) | 0..m | A list of extensions to the entity. Extensions are not expected to be natively understood, but may be used for pre-negotiated exchange of message attributes between systems. |
| `type` | `string` | 0..1 | MUST be "CategoricalVariant" |
| `members` | [Variation](Variation.md) \| [iriReference](iriReference.md)[] (unordered) | 0..m | A non-exhaustive list of VRS Variations that satisfy the constraints of this categorical variant. |
| `constraints` | [Constraint](Constraint.md)[] (unordered) | 0..m |  |
| `mappings` | [ConceptMapping](ConceptMapping.md)[] (unordered) | 0..m | A list of mappings to concepts in terminologies or code systems. Each mapping should include a coding and a relation. |

