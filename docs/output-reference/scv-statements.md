# SCV Statements

## Overview

The `scv` bundle section contains one record per ClinVar submission (SCV). Each record is a VA-Spec `Statement` that captures a submitter's interpretation of a variant — including the classification, evidence, condition, variant, and method.

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
| `classification` | object | MappableConcept — the submitter's classification. See [Classification](#classification) |
| `strength` | object | MappableConcept — the evidence strength. See [Strength](#strength) |
| `direction` | string | Whether the evidence `supports`, `disputes`, or is `neutral` toward the proposition |
| `confidence` | string | Submission level label (e.g., `criteria provided`, `practice guideline`) |
| `description` | string | Free-text interpretation summary (when provided by the submitter) |
| `contributions` | array | Submitter and date information with `#/submitter/` references. See [Contributions](#contributions) |
| `specifiedBy` | object | The classification method/guideline used |
| `reportedIn` | array | Supporting publications (PubMed, DOI references) |
| `extensions` | array of [Extension](#extensions) | ClinVar-specific metadata (0..*). See [Extensions](#extensions) |
| `hasEvidenceLines` | array | Evidence lines for somatic clinical impact assertions. See [Evidence Lines](#evidence-lines) |

</div>

---

## Classification

The `classification` field is a MappableConcept with the submitted classification:

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
| `ClinvarConfersSensitivityProposition` | `CS` | `confersSensitivityFor` | Confers sensitivity |
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

Extensions carry ClinVar-specific metadata not part of the GA4GH VA-Spec statement model. Each extension follows the GA4GH Extension structure: `{ "name": "<name>", "value": <value> }`. Extensions appear at three structural levels — on the top-level `Statement`, on the `classification` object, and on proposition qualifier objects.

See [SCV Extensions (Pipeline)](../pipeline/scv-statements/scv-extensions.md) for details on how these extensions are built during pipeline processing.

### Statement Extensions

<div class="field-table" markdown>

| Extension Name | Value Type | Description |
|---|---|---|
| `clinvarScvId` | `string` | The ClinVar SCV accession without version (e.g., `SCV001571657`). Always present. |
| `clinvarScvVersion` | `string` | The version number of the SCV submission (e.g., `2`). Always present. |
| `submittedCondition` | [SubmittedCondition](#submittedcondition) | Submitted condition provenance with normalization details, trait mapping, and `#/condition/` references. Present when the SCV maps to a single condition. |
| `submittedConditionSet` | [SubmittedConditionSet](#submittedconditionset) | Submitted condition set provenance with multiple condition concepts. Present when the SCV maps to multiple conditions. |
| `clinvarScvReviewStatus` | `string` | The ClinVar review status (e.g., `criteria provided, single submitter`). Present when the SCV has a review status. |
| `submittedScvClassification` | `string` | The original classification text submitted by the submitter, preserved when it differs from the normalized classification name. |
| `submittedScvLocalKey` | `string` | The unique local key provided by the submitter for this submission. Present only when the submitter provided a local key. |
| `submissionLevel` | `string` | The submission level code: `PG`, `EP`, `CP`, `NOCP`, `NOCL`, or `FLAG`. Present when the submission level can be determined. |

</div>

!!! note
    Only one of `submittedCondition` or `submittedConditionSet` is present per SCV — never both. The `submittedScvClassification` extension is omitted when the submitted classification matches the normalized label exactly.

### Classification Extensions

Extensions on the `classification` MappableConcept within the Statement.

<div class="field-table" markdown>

| Extension Name | Value Type | Description |
|---|---|---|
| `description` | `string` | A formatted multi-line description summarizing the classification context: condition name, submission level, evaluation date, and submitter name. Always present. |

</div>

The description template is: `for <condition_name>\nClassification is based on the <submission_level_label> submission\n<evaluated_date> by <submitter_name>`.

### Qualifier Extensions

Extensions on proposition qualifier objects (`geneContextQualifier`, `modeOfInheritanceQualifier`, `penetranceQualifier`), preserving the original submitter-provided values.

<div class="field-table" markdown>

| Extension Name | Value Type | Description |
|---|---|---|
| `submittedGeneSymbols` | array of `string` | Gene symbols originally submitted by the submitter. Present on `geneContextQualifier` when the submitter provided gene information. May differ from the normalized gene symbol. |
| `submittedModeOfInheritance` | `string` | Mode of inheritance text as originally submitted. Present on all `modeOfInheritanceQualifier` objects. Preserved alongside the normalized HPO coding. |
| `submittedClassification` | `string` | Original submitted classification text that triggered the penetrance qualifier derivation. Present on all `penetranceQualifier` objects. |

</div>

### SubmittedCondition

The `submittedCondition` extension captures the provenance of how a single submitted condition was mapped to the normalized ClinVar trait. Present when the SCV maps to exactly one condition.

<div class="field-table" markdown>

| Field | Type | Description |
|---|---|---|
| `condition` | `string` | `#/condition/clinvar.trait:{id}` reference to the normalized condition in the bundle. |
| `conditionSet` | `string` | `#/conditionSet/clinvar.traitset:{id}` reference (present when the RCV trait set has one trait but the reference uses the set). |
| `id` | `string` | The submitted clinical assertion trait ID (e.g., `SCV002769510.0`). |
| `name` | `string` | The submitted condition name. |
| `type` | `string` | The submitted condition type (e.g., `Disease`, `Finding`). |
| `medgen_id` | `string` | The submitted or resolved MedGen concept ID. |
| `normalized_match` | `string` | `#/condition/` reference to the matched normalized trait. |
| `normalized_resolution` | `string` | The resolution method used to match the submitted condition (e.g., `tm reftype xref omim`, `random trait assignment`). |
| `xrefs` | array | Submitted cross-references with `code` and `system`. |
| `mapping` | object | The trait mapping entry used for resolution: `type`, `ref`, `value`. |

</div>

### SubmittedConditionSet

The `submittedConditionSet` extension captures provenance for multi-condition submissions. Present when the SCV maps to more than one condition.

<div class="field-table" markdown>

| Field | Type | Description |
|---|---|---|
| `conditionSet` | `string` | `#/conditionSet/clinvar.traitset:{id}` reference. |
| `condition` | `string` | `#/condition/clinvar.trait:{id}` reference (present when the RCV set resolves to a single trait). |
| `multiple_condition_explanation` | `string` | ClinVar's explanation for the multi-condition grouping. |
| `concepts` | array | Array of individual condition provenance objects, each with the same fields as [SubmittedCondition](#submittedcondition). |

</div>

---

## Examples

Annotated JSONC examples of SCV statement records are available in the repository:

- [SCV statement examples](https://github.com/clingen-data-model/clinvar-gks/tree/main/examples/scv) — pathogenicity, oncogenicity, somatic clinical impact, therapeutic response, and other statement types
