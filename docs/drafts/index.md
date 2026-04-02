# Under Construction

This section contains documentation and designs that are actively being developed. Content here is subject to change and may not reflect the current production pipeline.

Use this section to follow our progress, review draft designs, and understand what changes are coming.

---

## In Progress

### Profile Schemas and Documentation

Per-profile reference pages with downloadable JSON Schema (draft 2020-12) files for all ClinVar-GKS output types. Each profile page will include the full JSON shape, field descriptions, ClinVar content mapping, classification values, and inline examples.

**Profiles planned:**

- SCV Pathogenicity (G.01)
- SCV Oncogenicity (O.10)
- SCV Somatic Clinical Impact (S.11-S.14)
- SCV Other Profiles (G.02-G.09)
- VCV Germline Aggregate
- VCV Somatic Aggregate
- Categorical Variant (Canonical Allele)

**Status:** Planning complete. Implementation in progress on `feature/profile-schemas-and-docs` branch.

### VCV Aggregate Classification Refactor

Restructured VCV aggregate classification using a 3-way attribute split:

- `classification_mappableConcept` — single-label aggregation (CP, NOCP, NOCL, FLAG)
- `classification_conceptSet` — single PGEP classification tuple as a ConceptSet AND-group
- `classification_conceptSetSet` — multiple PGEP classification tuples as nested ConceptSets

The same 3-way split applies to `objectClassification` in the proposition. Each ConceptSet AND-group contains Classification, Condition, and SubmissionLevel concepts.

**Status:** Merged to main. See [Aggregation Rules](../pipeline/vcv-statements/vcv-aggregation-rules.md) for details.

---

## Draft Pages

Pages linked below are early drafts. They may contain incomplete information or placeholder content.

- [VCV Aggregation Rules](../pipeline/vcv-statements/vcv-aggregation-rules.md) — submission level logic, ConceptSet classification schema
- [ID References](../output-reference/id-references.md) — cross-file reference resolution guide

---

## Known Issues Being Addressed

- PGEP submission level not yet in the `submission_level` lookup table — ranking uses inline CASE expression with hardcoded rank 5
- SCV `submissionLevel` extension value uses the code (e.g., "CP") rather than the full label — may change to match VCV convention
- VCV somatic examples need additional validation against production data
- JSON Schema files for output validation not yet published
