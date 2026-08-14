# ClinvarOtherProposition

!!! info "Trial Use"

    This data class is at a **trial use** maturity level and may change in future releases. Maturity levels are described in the [GKS Maturity Model](https://vrs.ga4gh.org/en/2.0/appendices/maturity_model.html#maturity-model).

A proposition for ClinVar submissions classified as "other" that do not fit any standard or named classification category. ClinVar has stopped accepting new submissions with this classification, but historical submissions remain.

**JSON Schema:** [ClinvarOtherProposition](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarOtherProposition){ target=_blank }

Some ClinvarOtherProposition attributes are inherited from `ClinvarGermlineCustomProposition`.

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `id` | `string` | 0..1 | The 'logical' identifier of the Entity in the system of record, e.g. a UUID.  This 'id' is unique within a given system, but may or may not be globally unique outside the system. It is used within a system to reference an object from another. |
| `name` | `string` | 0..1 | A primary name for the entity. |
| `description` | `string` | 0..1 | A free-text description of the Entity. |
| `aliases` | `string`[] (unordered) | 0..m | Alternative name(s) for the Entity. |
| `extensions` | `Extension`[] (unordered) | 0..m | A list of extensions to the Entity, that allow for capture of information not directly supported by elements defined in the model. |
| `type` | `string` | 0..1 | MUST be "CustomProposition". |
| `customPropositionType` | `string` | 0..1 | MUST be "ClinvarOtherProposition". |
| `subject` | `MolecularVariation` \| `CategoricalVariant` \| `iriReference` | 0..1 | A variant that is the subject of the Proposition. |
| `predicate` | `string` | 0..1 | The relationship the Proposition describes between the subject variant and object condition. MUST be "isClinvarOtherAssociationFor". |
| `object` | `Condition` \| `ConditionSet` \| `iriReference` | 0..1 | The condition for which the variant is associated. |
| `qualifiers` | `object`[] (unordered) | 0..m | An array of custom qualifier objects that provide additional information about the Proposition. Each qualifier is an object with a required 'name' (string) identifying the qualifier, a required 'value' (a MappableConcept or an IRI reference), and an optional 'description' (string) explaining its meaning. |

