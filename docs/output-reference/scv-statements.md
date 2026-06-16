# SCV Statements

## Overview

The `scv` bundle section contains one record per ClinVar submitted clinical assertion (SCV). Each record is a VA-Spec `Statement` that captures a submitter's clinical interpretation of a variant — including the classification, evidence, condition, variant, and method.

SCV statements use `#/` references to link to propositions, submitters, and conditions in their respective bundle sections rather than embedding full objects inline.

This section is produced by the [SCV Statements procedure](../pipeline/scv-statements/index.md).

---

## Record Structure

Each record is a VA-Spec `Statement` with the following top-level fields:

<div class="field-table" markdown>

| Field | Type | Description |
| --- | --- | --- |
| `id` | string | SCV accession with version — `clinvar.submission:SCV000123456.1` |
| `type` | string | Always `Statement` |
| `proposition` | string | `#/proposition/{id}` reference to the classification proposition |
| `classification` | object | MappableConcept — the submitter's clinical classification. See [Classification](#classification) |
| `strength` | object | MappableConcept — the evidence strength. See [Strength](#strength) |
| `direction` | string | Whether the evidence `supports`, `disputes`, or is `neutral` toward the proposition |
| `confidence` | string | Submission level label (e.g., `criteria provided`, `practice guideline`) |
| `description` | string | Free-text interpretation summary (when provided by the submitter) |
| `contributions` | array | Submitter and date information with `#/submitter/` references. See [Contributions](#contributions) |
| `specifiedBy` | object | The classification method/guideline used |
| `reportedIn` | array | Supporting publications (PubMed, DOI references) |
| `extensions` | array | ClinVar-specific metadata. See [Extensions](#extensions) |
| `hasEvidenceLines` | array | Evidence lines for somatic clinical impact assertions. See [Evidence Lines](#evidence-lines) |

</div>

---

## Classification

The `classification` field is a MappableConcept with the submitted clinical significance:

```json
{
  "conceptType": "Classification",
  "name": "Pathogenic",
  "primaryCoding": {
    "code": "pathogenic",
    "system": "ACMG Guidelines, 2015"
  },
  "extensions": [
    {
      "name": "description",
      "value": "for Hemochromatosis\nClassification is based on the criteria provided submission\nMay 2021 by Victorian Clinical Genetics Services"
    }
  ]
}
```

The `primaryCoding` provides the machine-readable classification code and system from the `clinvar_clinsig_types` lookup table. The `extensions` array contains a human-readable description summarizing the condition, submission level, evaluation date, and submitter.

---

## Strength

The `strength` field is a MappableConcept indicating the evidence strength:

```json
{
  "conceptType": "Strength",
  "name": "Definitive",
  "primaryCoding": {
    "code": "definitive",
    "system": "ACMG Guidelines, 2015"
  }
}
```

The `primaryCoding` is present when the strength can be mapped to a specific code in the classification system.

---

## Contributions

The `contributions` array records the submitter and key dates. Each contribution references the submitter via `#/submitter/`:

```json
[
  {
    "type": "Contribution",
    "contributor": "#/submitter/clinvar.submitter:500104",
    "date": "2022-12-24",
    "activityType": "submitted"
  },
  {
    "type": "Contribution",
    "contributor": "#/submitter/clinvar.submitter:500104",
    "date": "2022-12-24",
    "activityType": "created"
  },
  {
    "type": "Contribution",
    "contributor": "#/submitter/clinvar.submitter:500104",
    "date": "2021-05-06",
    "activityType": "evaluated"
  }
]
```

---

## Proposition

SCV propositions are stored in the `proposition` bundle section, referenced by `#/proposition/{id}`. The proposition ID combines the SCV accession with an uppercase proposition type code:

```text
SCV001234567-PATH
```

A resolved proposition contains:

| Field | Type | Description |
| --- | --- | --- |
| `id` | string | Proposition ID (e.g., `SCV001234567-PATH`) |
| `type` | string | Proposition type (e.g., `VariantPathogenicityProposition`) |
| `predicate` | string | The relationship asserted (e.g., `isCausalFor`) |
| `subjectVariant` | string | `#/variation/clinvar:{id}` reference |
| `objectCondition` | string | `#/condition/clinvar.trait:{id}` or `#/conditionSet/clinvar.traitset:{id}` reference |
| `geneContextQualifier` | object | Gene context with NCBI Gene and HGNC identifiers (when applicable) |
| `modeOfInheritanceQualifier` | object | Mode of inheritance with HPO coding (when submitted) |
| `penetranceQualifier` | object | Penetrance qualifier (for low-penetrance/risk factor classifications) |

### Proposition Types

| Proposition Type | Code | Predicate | Description |
| --- | --- | --- | --- |
| `VariantPathogenicityProposition` | `PATH` | `isCausalFor` | Germline pathogenicity/benignity |
| `VariantOncogenicityProposition` | `ONCO` | `isOncogenicFor` | Oncogenicity |
| `VariantClinicalSignificanceProposition` | `SCI` | `isClinicallySignificantFor` | Somatic clinical impact |
| `ClinvarAssociationProposition` | `ASSOC` | `isAssociatedWith` | Association |
| `ClinvarRiskFactorProposition` | `RF` | `isRiskFactorFor` | Risk factor |
| `ClinvarDrugResponseProposition` | `DR` | `hasDrugResponseFor` | Drug response |
| `ClinvarProtectiveProposition` | `PROT` | `isProtectiveFor` | Protective |
| `ClinvarAffectsProposition` | `AFF` | `hasAffectFor` | Affects |
| `ClinvarConfersSensitivityProposition` | `SENS` | `confersSensitivityFor` | Confers sensitivity |
| `ClinvarOtherProposition` | `OTH` | `isClinvarOtherAssociationFor` | Other |
| `ClinvarNotProvidedProposition` | `NP` | `hasNoProvidedClassificationFor` | Not provided |
| `ClinvarConflictingDataFromSubmitterProposition` | `CONF` | `isConflictingDataFromSubmittersFor` | Conflicting data |

For somatic clinical impact, target propositions (evidence line propositions) use these codes: `PROG` (Prognostic), `DIAG` (Diagnostic), `TR` (Therapeutic Response).

See [Propositions](../profiles/propositions.md) for the full profile documentation.

---

## Evidence Lines

Evidence lines appear on somatic clinical impact (SCI) statements. Each evidence line carries a target proposition, direction, outcome, and condition extensions:

```json
{
  "type": "EvidenceLine",
  "proposition": "#/proposition/SCV004565358-TR",
  "directionOfEvidenceProvided": "supports",
  "evidenceOutcome": {
    "conceptType": "Outcome",
    "name": "tier 1"
  },
  "extensions": [ ... ]
}
```

The `evidenceOutcome` is a MappableConcept with `conceptType: "Outcome"` indicating the tier classification for the target proposition.

---

## Extensions

The `extensions` array carries ClinVar-specific metadata:

| Extension Name | Value Type | Description |
| --- | --- | --- |
| `clinvarScvId` | string | SCV accession without version (e.g., `SCV002769510`) |
| `clinvarScvVersion` | string | SCV version number |
| `submittedCondition` / `submittedConditionSet` | object | Submitted condition provenance with normalization details, trait mapping, and `#/condition/` references |
| `clinvarScvReviewStatus` | string | ClinVar review status (e.g., `criteria provided, single submitter`) |
| `submittedScvClassification` | string | Original submitted classification (when it differs from the normalized label) |
| `submittedScvLocalKey` | string | Submitter's local key for the record |
| `submissionLevel` | string | Submission level code (e.g., `CP`, `EP`, `PG`) |

See [SCV Extensions](../pipeline/scv-statements/scv-extensions.md) for the complete extension reference.

---

## Examples

Annotated JSONC examples of SCV statement records are available in the repository:

- [SCV statement examples](https://github.com/clingen-data-model/clinvar-gks/tree/main/examples/scv) — pathogenicity, oncogenicity, somatic clinical impact, therapeutic response, and other statement types
