# SCV Statements

## Overview

The SCV statement files contain one JSON record per ClinVar submitted clinical assertion (SCV). Each record is a VA-Spec `Statement` that captures a submitter's clinical interpretation of a variant — including the classification, evidence, condition, variant, and method.

Two formats are produced with identical content but different condition/variant embedding strategies:

- **`scv_by_ref.jsonl.gz`** — conditions and variants are referenced by ID with full structures available as separate records
- **`scv_inline.jsonl.gz`** — conditions and variants are embedded inline within each statement record

These files are produced by the [SCV Statements procedure](../pipeline/scv-statements/index.md).

---

## By-Reference Format

In the by-reference format, the `proposition.subjectVariant` field contains a string reference (JSON pointer) to the categorical variant record rather than the full embedded structure. This format is compact and avoids duplicating variant data across thousands of statements that reference the same variant.

## Inline Format

In the inline format, the `proposition.subjectVariant` field contains the full `CategoricalVariant` structure — the same content found in `variation.jsonl.gz` — embedded directly within each statement. Conditions are similarly embedded. This format is self-contained — each record has all the data needed to interpret the statement without cross-referencing other files.

---

## Record Structure

Each record is a VA-Spec `Statement` with the following top-level fields:

<div class="field-table" markdown>

| Field | Type | Description |
| --- | --- | --- |
| `id` | string | SCV accession with version — `clinvar.submission:SCV000123456.1` |
| `type` | string | Always `Statement` |
| `classification` | object | The submitter's clinical classification (e.g., Pathogenic, Tier I) |
| `direction` | string | Whether the evidence `supports` or `disputes` the proposition |
| `strength` | object | Evidence strength (e.g., Strong, Supporting) — present for somatic/therapeutic statements |
| `proposition` | object | The clinical claim — variant, condition, predicate, and qualifiers. See [Proposition](#proposition) |
| `hasEvidenceLines` | array | Evidence lines linking to the proposition with outcome assessments |
| `contributions` | array | Submitter and date information (submitted, created, evaluated) |
| `reportedIn` | array | Supporting publications (PubMed references) |
| `specifiedBy` | object | The classification method/guideline used |
| `description` | string | Free-text interpretation summary (when provided by the submitter) |
| `extensions` | array | ClinVar-specific metadata (SCV ID, version, review status, local key) |

</div>

---

## Proposition

The `proposition` describes the clinical claim being made. Its `type` determines the predicate and qualifier structure:

| Proposition Type | Predicate | Description |
| --- | --- | --- |
| `VariantPathogenicityProposition` | `isCausalFor` | Germline pathogenicity/benignity assertions |
| `VariantClinicalSignificanceProposition` | `isClinicallySignificantFor` | Somatic clinical significance (AMP/ASCO/CAP tiering) |
| `VariantOncogenicityProposition` | `isOncogenicFor` | Oncogenicity assertions |
| `VariantTherapeuticResponseProposition` | `predictsSensitivityTo` | Therapeutic response predictions |

### Proposition Fields

<div class="field-table" markdown>

| Field | Type | Description |
| --- | --- | --- |
| `subjectVariant` | object or string | The variant — inline `CategoricalVariant` or a JSON pointer reference |
| `objectCondition` | object | The disease or condition (for pathogenicity/oncogenicity) |
| `objectTherapy` | object | The therapy (for therapeutic response propositions) |
| `conditionQualifier` | object | The disease context (for therapeutic response propositions) |
| `geneContextQualifier` | object | Gene context with NCBI Gene and HGNC identifiers |
| `predicate` | string | The relationship asserted between variant and condition/therapy |

</div>

---

## Statement Types

For the full mapping between ClinVar assertion types and GKS statement/proposition types, see [Statement Types](../profiles/statement-types.md).

For classification value mappings, see [Classifications](../profiles/classifications.md).
