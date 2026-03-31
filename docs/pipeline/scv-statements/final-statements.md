# Final Statements (Step 7)

## Overview

Step 7 of `gks_scv_statement_proc` performs the final assembly of complete VA-Spec Statement records into `gks_statement_scv_pre`. This step joins all previously built components -- SCV records, propositions, conditions, citations, and assertion methods -- into the output structure consumed by VCV procedures and the JSON export pipeline.

---

## CTEs

The step uses several CTEs to prepare intermediate data before the final SELECT.

### scv_condition_name

Derives a single human-readable condition name string from `gks_scv_condition_sets` for use in the classification description extension:

- **Single condition** -- uses the condition's `name` field directly
- **ConditionSet with 2+ conditions** -- produces `"N conditions"` (e.g., `"3 conditions"`)
- **No condition** -- falls back to `"unspecified condition"`

### scv_citation / scv_citations

Aggregates citation records with source-specific URL resolution:

| Source | URL Format |
|---|---|
| PubMed | `https://pubmed.ncbi.nlm.nih.gov/{id}` |
| PMC | `https://www.ncbi.nlm.nih.gov/pmc/articles/{id}` |
| DOI | `https://doi.org/{id}` |
| BookShelf | `https://www.ncbi.nlm.nih.gov/books/{id}` |

Citations are collected into an array for the `reportedIn` field of the final statement.

### scv_method

Builds the assertion method record for the `specifiedBy` field. Includes the method type, method name, and a linked citation document when the assertion method references a publication.

---

## Output Record Structure

<div class="field-table" markdown>

| Field | Source | Description |
|---|---|---|
| `id` | SCV | Statement identifier in the format `clinvar.submission:{accession}.{version}` |
| `type` | Static | Always `Statement` |
| `proposition` | Step 5 | Full proposition with variant, condition, and qualifiers |
| `classification` | SCV | Classification struct with name, primaryCoding, and description extension |
| `strength` | SCV | Evidence strength with coded value (somatic assertions only) |
| `direction` | SCV | `supports` or `disputes` |
| `description` | SCV | Classification comment text |
| `contributions` | SCV | Three Contribution entries: submitted, created, and evaluated |
| `specifiedBy` | CTE | Assertion method with linked citation document |
| `reportedIn` | CTE | Array of citation documents |
| `extensions` | SCV | Array of SCV-level extensions (see below) |
| `hasEvidenceLines` | Step 6 | Somatic evidence lines with target proposition and outcome |

</div>

### Extensions

The `extensions` array on each statement includes:

- **clinvarScvId** -- the SCV accession identifier
- **clinvarScvVersion** -- the SCV version number
- **clinvarScvReviewStatus** -- the review status assigned by ClinVar
- **submittedScvClassification** -- the original submitted classification label
- **submittedScvLocalKey** -- the submitter's local key for the assertion
- **submissionLevel** -- the submission level code and label

### Classification Description Extension

The `classification.extensions` array contains a formatted description string assembled from multiple fields:

```
for <condition_name>
Classification is based on the <submission_level_label> submission
<evaluated_date> by <submitter_name>
```

This provides a human-readable summary of the classification context, including the condition, submission level, evaluation date, and submitting organization.

### Somatic Evidence Lines

For somatic clinical impact assertions, the `hasEvidenceLines` field contains evidence line records that wrap the target proposition from Step 6. Each evidence line includes the target proposition (with its somatic-specific predicate and therapy/condition references) and the outcome classification.

---

## Output

**`gks_statement_scv_pre`** -- one row per SCV with the complete VA-Spec Statement record. <span class="role-badge badge-pipeline">Pipeline table</span>

Consumed by `gks_vcv_proc`, `gks_vcv_statement_proc`, and `gks_json_proc` for VCV aggregation and JSON export.

---

## Dependencies

- **Upstream Steps**: Step 1 (`temp_gks_scv`), Step 5 (`temp_gks_scv_proposition`), Step 6 (`temp_gks_scv_target_proposition`)
- **Upstream Procedures**: `gks_scv_condition_proc` (provides `gks_scv_condition_sets`)
- **Downstream Consumers**: `gks_vcv_proc`, `gks_vcv_statement_proc`, `gks_json_proc`
