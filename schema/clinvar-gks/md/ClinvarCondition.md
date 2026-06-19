# ClinvarCondition

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A ClinVar condition (disease, phenotype, or trait) represented as a MappableConcept with ClinVar-specific extensions. The primaryCoding uses MedGen as the canonical coding system with cross-mappings to OMIM, MONDO, Orphanet, HPO, MeSH, and SNOMED CT.

**JSON Schema:** [ClinvarCondition](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarCondition){ target=_blank }

**Composed of:**

- [MappableConcept](MappableConcept.md)
- [ClinvarConditionProperties](ClinvarConditionProperties.md)

