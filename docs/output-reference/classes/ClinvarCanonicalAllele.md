# ClinvarCanonicalAllele

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A ClinVar canonical allele — the most common variant type. ClinVar identifies each variation by mapping submitted attributes to a GRCh38 genomic allele, which becomes the defining allele constraint. Carries ClinVar-specific extensions (HGVS list, gene list, cytogenetic location, variation type, etc.) alongside the Cat-VRS CanonicalAllele structure.

**JSON Schema:** [ClinvarCanonicalAllele](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarCanonicalAllele){ target=_blank }

Some ClinvarCanonicalAllele attributes are inherited from `CanonicalAllele`, `ClinvarCanonicalAlleleProperties`, `ClinvarCategoricalVariantProperties`.

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `id` | `string` | 0..1 | The 'logical' identifier of the Entity in the system of record, e.g. a UUID.  This 'id' is unique within a given system, but may or may not be globally unique outside the system. It is used within a system to reference an object from another. |
| `name` | `string` | 0..1 | A primary name for the entity. |
| `description` | `string` | 0..1 | A free-text description of the Entity. |
| `aliases` | `string`[] (unordered) | 0..m | Alternative name(s) for the Entity. |
| `extensions` | `ExtensionClinvarHgvsList` \| `ExtensionClinvarGeneList` \| `ExtensionCategoricalVariationType` \| `ExtensionDefiningVrsVariationType` \| `ExtensionClinvarVariationType` \| `ExtensionClinvarSubclassType` \| `ExtensionClinvarCytogeneticLocation` \| `ExtensionVrsPreProcessingIssue` \| `ExtensionsVrsProcessingException`[] (unordered) | 0..m | A list of extensions to the entity. Extensions are not expected to be natively understood, but may be used for pre-negotiated exchange of message attributes between systems. |
| `type` | `string` | 0..1 | MUST be "CategoricalVariant" |
| `members` | `iriReference` \| `ClinvarAllele`[] (unordered) | 0..m | A non-exhaustive list of VRS variation contexts that satisfy the constraints of this categorical variant. |
| `constraints` | `Constraint`[] (unordered) | 0..m |  |
| `mappings` | `ConceptMapping`[] (unordered) | 0..m | A list of mappings to concepts in terminologies or code systems. Each mapping should include a coding and a relation. |
| `definingContext` | `iriReference` \| `ClinvarAllele` | 0..1 |  |

