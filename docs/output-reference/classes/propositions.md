# Propositions

A proposition defines what a statement asserts — the relationship between a variant and a condition. Each proposition follows the subject-predicate-object pattern from the GA4GH [VA-Spec](https://va-spec.ga4gh.org/) specification:

- **Subject** (`subjectVariant`) — a reference to a ClinVar variation via `#/variation/clinvar:{id}`
- **Predicate** — the relationship type (e.g., `isCausalFor`, `isOncogenicFor`)
- **Object** (`objectCondition`) — a condition, disease, or phenotype

The [ClinvarProposition](ClinvarProposition.md) union type encompasses all 12 proposition types valid in ClinVar-GKS.

---

## Proposition Types

ClinVar-GKS uses 12 proposition types: 3 from the GA4GH VA-Spec standard and 9 defined specifically for ClinVar submission categories.

### GA4GH Standard Types

These types are defined in the [VA-Spec](https://va-spec.ga4gh.org/) and used directly:

| Code | Type | Predicate | Description |
| --- | --- | --- | --- |
| `PATH` | VariantPathogenicityProposition | `isCausalFor` | Germline pathogenicity/benignity |
| `ONCO` | VariantOncogenicityProposition | `isOncogenicFor` | Oncogenicity classification |
| `SCI` | VariantClinicalSignificanceProposition | `isClinicallySignificantFor` | Somatic clinical impact |

### ClinVar-Specific Types

These types handle ClinVar submission categories not covered by the GA4GH specifications. Several are no longer accepted as new submissions by ClinVar, but historical submissions remain in the dataset.

| Code | Type | Predicate | Description | Active? |
| --- | --- | --- | --- | --- |
| `RF` | [ClinvarRiskFactorProposition](ClinvarRiskFactorProposition.md) | `isRiskFactorFor` | Risk factor | No |
| `PROT` | [ClinvarProtectiveProposition](ClinvarProtectiveProposition.md) | `isProtectiveFor` | Protective | No |
| `DR` | [ClinvarDrugResponseProposition](ClinvarDrugResponseProposition.md) | `hasDrugResponseFor` | Drug response | Yes |
| `AFF` | [ClinvarAffectsProposition](ClinvarAffectsProposition.md) | `hasAffectFor` | Affects | No |
| `ASSOC` | [ClinvarAssociationProposition](ClinvarAssociationProposition.md) | `isAssociatedWith` | Association | No |
| `CS` | [ClinvarConfersSensitivityProposition](ClinvarConfersSensitivityProposition.md) | `confersSensitivityFor` | Confers sensitivity | No |
| `OTH` | [ClinvarOtherProposition](ClinvarOtherProposition.md) | `isClinvarOtherAssociationFor` | Other | No |
| `NP` | [ClinvarNotProvidedProposition](ClinvarNotProvidedProposition.md) | `hasNoProvidedClassificationFor` | Not provided | Yes |
| `CONF` | [ClinvarConflictingDataFromSubmitterProposition](ClinvarConflictingDataFromSubmitterProposition.md) | `isConflictingDataFromSubmittersFor` | Conflicting data | Yes |

---

## Somatic Evidence Line Propositions

Somatic clinical impact (SCI) statements carry evidence lines with their own target propositions. These 3 types appear only on [ClinvarSomaticEvidenceLine](ClinvarSomaticEvidenceLine.md) objects, not as top-level statement propositions:

| Code | Type | Predicates |
| --- | --- | --- |
| `TR` | VariantTherapeuticResponseProposition | `predictsSensitivityTo`, `predictsResistanceTo` |
| `DIAG` | VariantDiagnosticProposition | `isDiagnosticInclusionCriterionFor`, `isDiagnosticExclusionCriterionFor` |
| `PROG` | VariantPrognosticProposition | `associatedWithBetterOutcomeFor`, `associatedWithWorseOutcomeFor` |

---

## Inherited Attributes

All ClinVar proposition types inherit from the VA-Spec `ClinicalVariantProposition`, which provides:

- `subjectVariant` — the variant being classified
- `geneContextQualifier` — the gene impacted by the variant
- `alleleOriginQualifier` — germline, somatic, or mosaic origin

See the individual class pages for the complete information model including all inherited fields.
