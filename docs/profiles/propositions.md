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
