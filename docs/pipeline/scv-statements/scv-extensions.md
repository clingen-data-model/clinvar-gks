# SCV Statement Extensions

## Overview

SCV statement records contain `extensions` arrays at three structural levels — on the top-level `Statement`, on the `classification` object, and on proposition qualifier objects (`geneContextQualifier`, `modeOfInheritanceQualifier`, `penetranceQualifier`). Extensions carry ClinVar-specific metadata, submitter-provided values, and formatted descriptions that are not part of the GA4GH VA-Spec statement model but are essential for tracing how each SCV was processed.

All extensions follow the structure `{ "name": "<extension_name>", "value": <value> }`, where the value type varies by extension. Most extensions carry simple string values. Extensions with complex value types — structured condition provenance objects — are documented as custom extension structures in a [dedicated section](#custom-extension-structures) below.

---

## Statement Extensions

Extensions on the top-level `Statement` record.

<div class="field-table" markdown>

| Extension | Type | Description |
|---|---|---|
| `clinvarScvId` | string | The ClinVar SCV accession without version (e.g., `SCV001571657`). Always present. |
| `clinvarScvVersion` | string | The version number of the SCV submission (e.g., `2`). Always present. |
| `submittedCondition` | [SubmittedCondition](#submitted-condition) | Submitted condition provenance with normalization details, trait mapping, and `#/condition/` references. Present when the SCV maps to a single condition. See [Submitted Condition](#submitted-condition) below. |
| `submittedConditionSet` | [SubmittedConditionSet](#submitted-condition-set) | Submitted condition set provenance with multiple condition concepts. Present when the SCV maps to multiple conditions. See [Submitted Condition Set](#submitted-condition-set) below. |
| `clinvarScvReviewStatus` | string | The ClinVar review status (e.g., `criteria provided, single submitter`). Present when the SCV has a review status. |
| `submittedScvClassification` | string | The original classification text submitted by the submitter, preserved when it differs from the normalized classification name. |
| `submittedScvLocalKey` | string | The unique local key provided by the submitter for this submission. Present only when the submitter provided a local key. |
| `submissionLevel` | string | The submission level code: `PG`, `EP`, `CP`, `NOCP`, `NOCL`, or `FLAG`. Present when the submission level can be determined. |

</div>

### Example

A typical germline SCV statement extensions array:

```json
[
  { "name": "clinvarScvId", "value": "SCV002769510" },
  { "name": "clinvarScvVersion", "value": "1" },
  {
    "name": "submittedCondition",
    "value": {
      "condition": "#/condition/clinvar.trait:9582",
      "id": "SCV002769510.0",
      "name": "Hemochromatosis",
      "type": "Disease",
      "medgen_id": "C3469186",
      "normalized_match": "#/condition/clinvar.trait:9582",
      "normalized_resolution": "tm reftype xref omim",
      "xrefs": [{ "code": "235200", "system": "OMIM" }],
      "mapping": { "type": "XRef", "ref": "omim", "value": "235200" }
    }
  },
  { "name": "clinvarScvReviewStatus", "value": "criteria provided, single submitter" },
  { "name": "submittedScvLocalKey", "value": "vcgs/unit_1/hg38_NM_000410_3_HFE_c_187C_G" },
  { "name": "submissionLevel", "value": "CP" }
]
```

!!! note
    Only one of `submittedCondition` or `submittedConditionSet` is present per SCV — never both. The `submittedScvClassification` extension is omitted when the submitted classification matches the normalized label exactly.

---

## Classification Extensions

Extensions on the `classification` object within the Statement.

<div class="field-table" markdown>

| Extension | Type | Description |
|---|---|---|
| `description` | string | A formatted multi-line description summarizing the classification context: condition name, submission level, evaluation date, and submitter name. Always present. |

</div>

### Example

```json
{
  "name": "description",
  "value": "for Hemochromatosis\nClassification is based on the criteria provided submission\nMay 2021 by Victorian Clinical Genetics Services, Murdoch Childrens Research Institute"
}
```

The description template is: `for <condition_name>\nClassification is based on the <submission_level_label> submission\n<evaluated_date> by <submitter_name>`. When the condition is a multi-condition set, `<condition_name>` is replaced with `<N> conditions`. The date is formatted as `Mon YYYY` or `(-)` when not available.

---

## Qualifier Extensions

Extensions on proposition qualifier objects, preserving the original submitter-provided values.

<div class="field-table" markdown>

| Extension | Type | Description |
|---|---|---|
| `submittedGeneSymbols` | array&lt;string&gt; | Gene symbols originally submitted by the submitter. Present on `geneContextQualifier` when the submitter provided gene information. May differ from the normalized gene symbol. |
| `submittedModeOfInheritance` | string | Mode of inheritance text as originally submitted. Present on all `modeOfInheritanceQualifier` objects. Preserved alongside the normalized HPO coding. |
| `submittedClassification` | string | Original submitted classification text that triggered the penetrance qualifier derivation. Present on all `penetranceQualifier` objects. |

</div>

### Example

Gene context qualifier with submitted gene symbols:

```json
{
  "conceptType": "gene",
  "name": "KRAS",
  "primaryCoding": { "code": "3845", "name": "KRAS", "system": "https://www.ncbi.nlm.nih.gov/gene/" },
  "extensions": [
    { "name": "submittedGeneSymbols", "value": ["KRAS"] }
  ]
}
```

---

## Custom Extension Structures

Extensions with complex value types use structured objects rather than simple scalars. The structures below define the shape of each custom extension's `value` field.

### Submitted Condition

The `submittedCondition` extension captures the provenance of how a single submitted condition was mapped to the normalized ClinVar trait. Present when the SCV maps to exactly one condition.

<div class="field-table" markdown>

| Field | Type | Description |
|---|---|---|
| `condition` | string | `#/condition/clinvar.trait:{id}` reference to the normalized condition in the bundle |
| `conditionSet` | string | `#/conditionSet/clinvar.traitset:{id}` reference (present when the RCV trait set has one trait but the reference uses the set) |
| `id` | string | The submitted clinical assertion trait ID (e.g., `SCV002769510.0`) |
| `name` | string | The submitted condition name |
| `type` | string | The submitted condition type (e.g., `Disease`, `Finding`) |
| `medgen_id` | string | The submitted or resolved MedGen concept ID |
| `normalized_match` | string | `#/condition/` reference to the matched normalized trait |
| `normalized_resolution` | string | The resolution method used to match the submitted condition (e.g., `tm reftype xref omim`, `random trait assignment`) |
| `xrefs` | array | Submitted cross-references with `code` and `system` |
| `mapping` | object | The trait mapping entry used for resolution: `type`, `ref`, `value` |

</div>

### Submitted Condition Set

The `submittedConditionSet` extension captures provenance for multi-condition submissions. Present when the SCV maps to more than one condition.

<div class="field-table" markdown>

| Field | Type | Description |
|---|---|---|
| `conditionSet` | string | `#/conditionSet/clinvar.traitset:{id}` reference |
| `condition` | string | `#/condition/clinvar.trait:{id}` reference (present when the RCV set resolves to a single trait) |
| `multiple_condition_explanation` | string | ClinVar's explanation for the multi-condition grouping |
| `concepts` | array | Array of individual condition provenance objects, each with the same fields as [Submitted Condition](#submitted-condition) |

</div>
