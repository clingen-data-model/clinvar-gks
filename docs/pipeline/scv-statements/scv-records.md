# SCV Records (Step 1)

## Overview

Step 1 of `gks_scv_statement_proc` builds the foundational SCV record table `temp_gks_scv` by extracting and transforming data from `scv_summary` and `clinical_assertion`. This table provides the core classification, submitter, and metadata fields consumed by all subsequent steps (2--7).

---

## Transformations

### Classification and Proposition Type Mapping

Each SCV's classification type and statement type are mapped to a proposition type and predicate by joining to `clinvar_clinsig_types`. This lookup determines how the SCV will be modeled as a VA-Spec proposition -- for example, whether it represents a pathogenicity assertion, an oncogenicity assertion, or a somatic clinical impact assertion.

### Evidence Line Target Proposition (Somatic)

For somatic clinical impact assertions, the step derives the evidence line target proposition type and predicate based on the assertion's clinical impact type:

- **Prognostic** -- maps to better outcome or poor outcome predicates
- **Diagnostic** -- maps to inclusion criteria or exclusion criteria predicates
- **Therapeutic** -- maps to sensitivity or resistance predicates

### Drug Therapy Extraction

Drug therapy names are extracted from the somatic clinical impact JSON field of `clinical_assertion` for therapeutic assertions. These are parsed into an array for use by the target proposition in Step 6.

### Assertion Method Parsing

Assertion method attributes and citations are parsed from the `clinical_assertion` record using the `parseAttributeSet` and `parseCitations` UDFs. These provide the method name, type, and any linked publications that describe the assertion methodology.

### Submission Level

The step joins to the `submission_level` lookup table on rank to resolve the submission level code and label for each SCV. The submission level reflects whether the assertion comes from an expert panel, practice guideline, or other submitter category.

### Submitter Struct

A submitter struct is constructed with the format `clinvar.submitter:{id}`, providing a stable identifier for the submitting organization.

---

## Output Fields

<div class="field-table" markdown>

| Field | Description |
|---|---|
| `id` | SCV accession identifier |
| `version` | SCV version number |
| `proposition_type` | Mapped proposition type from `clinvar_clinsig_types` |
| `predicate` | Mapped predicate from `clinvar_clinsig_types` |
| `evidence_line_target_proposition` | Target proposition type/predicate for somatic clinical impact assertions |
| `submitted_date` | Date the SCV was submitted |
| `created_date` | Date the SCV was created in ClinVar |
| `evaluated_date` | Date the classification was last evaluated |
| `classification_name` | Classification label (e.g., Pathogenic, Likely benign) |
| `classification_code` | Coded classification value |
| `direction` | `supports` or `disputes` |
| `strength` | Evidence strength (somatic assertions only) |
| `submitter` | Submitter struct with `clinvar.submitter:{id}` identifier |
| `submission_level` | Submission level code |
| `submission_level_label` | Human-readable submission level label |
| `drug_therapy` | Array of drug therapy names (somatic therapeutic only) |
| `assertion_method_attributes` | Parsed assertion method attributes from `parseAttributeSet` |
| `assertion_method_citations` | Parsed citations from `parseCitations` |

</div>

---

## Output

**`temp_gks_scv`** -- one row per SCV with core classification and submitter metadata. <span class="role-badge badge-internal">Internal</span>

Consumed by Steps 2--7 for qualifier assembly, proposition construction, and final statement assembly.

---

## Dependencies

- **Source Tables**: `scv_summary`, `clinical_assertion`
- **Lookup Tables**: `clinvar_clinsig_types`, `submission_level`
- **UDFs**: `clinvar_ingest.parseAttributeSet`, `clinvar_ingest.parseCitations`
