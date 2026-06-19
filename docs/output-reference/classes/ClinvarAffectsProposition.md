# ClinvarAffectsProposition

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A proposition describing a variant that affects a condition without implying causality. Used for ClinVar submissions classified as "affects". ClinVar has stopped accepting new submissions with this classification, but historical submissions remain.

**JSON Schema:** [ClinvarAffectsProposition](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarAffectsProposition){ target=_blank }

Some ClinvarAffectsProposition attributes are inherited from [ClinicalVariantProposition](ClinicalVariantProposition.md).

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `id` | `string` | 0..1 | The 'logical' identifier of the Entity in the system of record, e.g. a UUID.  This 'id' is unique within a given system, but may or may not be globally unique outside the system. It is used within a system to reference an object from another. |
| `type` | `string` | 0..1 | MUST be "ClinvarAffectsProposition". |
| `name` | `string` | 0..1 | A primary name for the entity. |
| `description` | `string` | 0..1 | A free-text description of the Entity. |
| `aliases` | `string`[] (unordered) | 0..m | Alternative name(s) for the Entity. |
| `extensions` | `Extension`[] (unordered) | 0..m | A list of extensions to the Entity, that allow for capture of information not directly supported by elements defined in the model. |
| `predicate` | `string` | 1..1 | The relationship the Proposition describes between the subject variant and object condition. MUST be "hasAffectFor". |
| `object` | `object` | 0..1 | An Entity or concept that is related to the subject of a Proposition via its predicate. |
| `subjectVariant` | `MolecularVariation` \| `CategoricalVariant` \| `iriReference` | 0..1 | A variant that is the subject of the Proposition. |
| `geneContextQualifier` | `MappableConcept` \| `iriReference` | 0..1 | Reports a gene impacted by the variant, which may contribute to the association described in the Proposition. |
| `alleleOriginQualifier` | `MappableConcept` \| `iriReference` | 0..1 | Reports whether the Proposition should be interpreted in the context of a heritable "germline" variant, an acquired "somatic" variant in a tumor, or a post-zygotic "mosaic" variant. While these are the most commonly reported allele origins, other more nuanced concepts can be captured  (e.g. "maternal" vs "paternal" allele origin). In practice, populating this field may be complicated by the fact that some sources report allele origin based on the type of tissue that was sequenced to identify the variant, and others use it more generally to specify a category of variant for which the proposition holds. The stated intent of this attribute is the latter. However, if an implementer is not sure about which is reported in their data, it may be safer to create an Extension to hold this information, where they can explicitly acknowledge this ambiguity. |
| `objectCondition` | `Condition` \| `iriReference` | 1..1 | The condition that is affected by the variant. |

