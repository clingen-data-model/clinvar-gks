# ClinvarScvStatement

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A ClinVar SCV (submitted clinical variant) statement. Represents a single submitter's assertion about a variant-condition relationship, including their classification, direction, strength, method, and contributions.
Allowable proposition types at SCV level:
Germline classification (9 types): VariantPathogenicityProposition, ClinvarRiskFactorProposition, ClinvarProtectiveProposition, ClinvarDrugResponseProposition, ClinvarAffectsProposition, ClinvarAssociationProposition, ClinvarConfersSensitivityProposition, ClinvarOtherProposition, ClinvarNotProvidedProposition.
Oncogenicity (1 type): VariantOncogenicityProposition.
Somatic clinical impact (1 type): VariantClinicalSignificanceProposition with evidence lines carrying VariantTherapeuticResponseProposition, VariantDiagnosticProposition, or VariantPrognosticProposition.
Conflicting data (1 type): ClinvarConflictingDataFromSubmitterProposition.

**JSON Schema:** [ClinvarScvStatement](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarScvStatement){ target=_blank }

**Composed of:**

- [Statement](Statement.md)
- [ClinvarScvStatementProperties](ClinvarScvStatementProperties.md)

