# ClinvarProposition

!!! info "Trial Use"

    This data class is at a **trial use** maturity level and may change in future releases. Maturity levels are described in the [GKS Maturity Model](https://vrs.ga4gh.org/en/2.0/appendices/maturity_model.html#maturity-model).

Any proposition type valid in ClinVar-GKS statements. Includes the GA4GH standard proposition types (pathogenicity, oncogenicity, clinical significance) and ClinVar-specific proposition types for submission categories not covered by the GA4GH specifications.

**JSON Schema:** [ClinvarProposition](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarProposition){ target=_blank }

**One of:**

- `VariantPathogenicityProposition`
- `VariantOncogenicityProposition`
- `VariantClinicalSignificanceProposition`
- [ClinvarRiskFactorProposition](ClinvarRiskFactorProposition.md)
- [ClinvarProtectiveProposition](ClinvarProtectiveProposition.md)
- [ClinvarDrugResponseProposition](ClinvarDrugResponseProposition.md)
- [ClinvarAffectsProposition](ClinvarAffectsProposition.md)
- [ClinvarAssociationProposition](ClinvarAssociationProposition.md)
- [ClinvarConfersSensitivityProposition](ClinvarConfersSensitivityProposition.md)
- [ClinvarOtherProposition](ClinvarOtherProposition.md)
- [ClinvarNotProvidedProposition](ClinvarNotProvidedProposition.md)
- [ClinvarConflictingDataFromSubmitterProposition](ClinvarConflictingDataFromSubmitterProposition.md)

