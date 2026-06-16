# Propositions

Each statement type is mapped to a GKS proposition type. Standard GA4GH proposition types are used where they exist. For statement types not covered by the GA4GH specifications, ClinVar-GKS defines custom proposition types.

## Standard GA4GH Proposition Types

| Statement Type | Proposition Type |
| --- | --- |
| Pathogenicity | VariantPathogenicityProposition |
| Oncogenicity | VariantOncogenicityProposition |
| Clinical Significance | VariantClinicalSignificanceProposition |
| Therapeutic Response | VariantTherapeuticResponseProposition |
| Diagnostic | VariantDiagnosticProposition |
| Prognostic | VariantPrognosticProposition |

## ClinVar-GKS Custom Proposition Types

These custom propositions are defined specifically for the ClinVar-GKS dataset to handle non-standard ClinVar submission types that do not have corresponding GA4GH proposition types.

| Statement Type | Proposition Type |
| --- | --- |
| Risk Factor | ClinVarRiskFactorProposition |
| Protective | ClinVarProtectiveProposition |
| Drug Response | ClinVarDrugResponseProposition |
| Other | ClinVarOtherProposition |
| Not Provided | ClinVarNotProvidedProposition |
| Affects | ClinVarAffectsProposition |
| Association | ClinVarAssociationProposition |
| Confers Sensitivity | ClinVarConfersSensitivityProposition |

## Aggregate Propositions

Aggregate (VCV and RCV) statements use the same proposition types and predicates as their underlying SCV submissions. For example, a VCV pathogenicity aggregate uses `VariantPathogenicityProposition` with `isCausalFor`, matching the SCVs it aggregates.

!!! info "Design Consideration: Proposition Normalization"

    In the current v1 release, each SCV statement generates its own proposition instance keyed by `{scv_id}-{PROP_CODE}`. This means two SCVs asserting the exact same subject-predicate-object relationship (e.g., variant X `isCausalFor` condition Y) produce two separate proposition entries in the bundle, even though they represent the same logical assertion.

    A future improvement may normalize propositions so that identical subject-predicate-object combinations are represented as a single shared instance — treating propositions as **value objects** in their own right. Since the proposition is the fundamental component for identifying which statements can be meaningfully compared, honoring that identity in the dataset would allow consumers to directly group and compare all statements that share the same proposition without field-by-field comparison.

    This would require a content-addressable identifier scheme for propositions (e.g., hashing the subject + predicate + object) so that SCV statements can reference a shared proposition by its computed key.

    At the aggregate VCV and RCV level, proposition sharing is less impactful — aggregate propositions build on the shared SCV propositions and further qualify them with review status, submission level, and other aggregation-specific attributes that make exact duplication less common. However, evidence lines within VCV/RCV statements could also benefit from referencing shared propositions rather than embedding layer-specific copies.
