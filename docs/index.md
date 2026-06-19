# ClinVar-GKS

ClinVar-GKS provides a standardized, machine-readable representation of [ClinVar](https://www.ncbi.nlm.nih.gov/clinvar/) release data using the [GA4GH Genomic Knowledge Standards](https://www.ga4gh.org/genomic-knowledge-standards/) (GKS). It is developed and maintained by the [ClinGen](https://clinicalgenome.org/) driver project.

## Why ClinVar-GKS

ClinVar is one of the most widely used public archives of human genetic variation and its relationship to disease. However, the native ClinVar XML format presents challenges for programmatic consumption — inconsistent structures, deeply nested records, and representations that do not align with emerging genomic data standards.

ClinVar-GKS addresses these challenges by transforming every ClinVar release into a consistent, semantically rich format built on GA4GH specifications:

- **Normalized variant identifiers** — Every variant receives a computable [VRS](https://vrs.ga4gh.org/) identifier, enabling unambiguous cross-system matching
- **Categorical variant representations** — Variants are represented as [Cat-VRS](https://cat-vrs.readthedocs.io/) categorical variants with defining allele constraints and expressions
- **Structured classification statements** — Every submitted (SCV), aggregate (VCV), and condition-level (RCV) classification is represented as a [VA-Spec](https://va-spec.ga4gh.org/) statement with explicit propositions, evidence, and provenance
- **Semantic consistency** — Classifications, propositions, conditions, genes, and cross-references use standardized structures with typed references

## What It Covers

The pipeline processes the **entirety** of each ClinVar XML release — every variation, submitted classification, and aggregate record is represented. While 100% of variant, SCV, VCV, and RCV records from the corresponding ClinVar XML release are included, some data types within ClinVar are not yet part of the v1 release.

| ClinVar Data Type | v1 Status |
| --- | --- |
| Variation Aggregate Classifications (VCVs) | Included |
| Variation-Condition Aggregate Classifications (RCVs) | Included |
| Germline and Somatic Submissions (SCVs) | Included |
| Variations (incl. Genes, HGVS, SPDI and VCF extensions) | Included |
| [Submitters](https://www.ncbi.nlm.nih.gov/clinvar/docs/submitter_list/) | Included |
| Aggregate & Case-level observations ([example](https://www.ncbi.nlm.nih.gov/clinvar/variation/1185392/#new-submission-germline)) | Planned |
| Functional data submissions ([example](https://www.ncbi.nlm.nih.gov/clinvar/variation/548447/#new-submission-functional-data)) | Planned |

Items marked **Planned** are not currently included in the v1 release. If this data is requested by the community, it will be added as demand indicates.

!!! note "Functional Data Submissions"
    Functional data is submitted to ClinVar as an SCV and may or may not be associated with a germline or somatic classification record. Functional data SCVs are excluded from the v1 release regardless of whether they are linked to a classification SCV. They will be included in a future release when functional data support is added.

Feedback and feature requests are welcome via the [GitHub issue tracker](https://github.com/clingen-data-model/clinvar-gks/issues).

New releases are produced within a day or two after ClinVar's XML releases and are intended to be synchronized with ClinVar's release dates.

## Who It's For

- **Variant scientists** seeking a clear, consistent representation of ClinVar classifications with explicit propositions, conditions, and evidence
- **Platform engineers** building systems that consume ClinVar data and need a structured, well-documented format for integration
- **GA4GH implementers** using ClinVar-GKS as a real-world validation of VRS, Cat-VRS, and VA-Spec schemas

---

## Getting Started

### Download the Latest Release

The latest ClinVar-GKS release is available as a single compressed JSON file:

```bash
# Download the latest monthly release
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/clinvar-gks_00-latest.json.gz

# Decompress
gunzip clinvar-gks_00-latest.json.gz
```

### What's in the File

The release file is a single JSON object with **bundle sections** at the root level. Each section is a keyed collection of objects — the key is the object's unique identifier, and the value is the object itself.

```json
{
  "sequenceReference": { "SQ.abc123": { ... } },
  "location":          { "ga4gh:SL.xyz789": { ... } },
  "allele":            { "ga4gh:VA.def456": { ... } },
  "gene":              { "ncbigene:3077": { ... } },
  "variation":         { "clinvar:10": { ... } },
  "condition":         { "clinvar.trait:9580": { ... } },
  "conditionSet":      { "clinvar.traitset:1234": { ... } },
  "submitter":         { "clinvar.submitter:500139": { ... } },
  "proposition":       { "SCV001234567-PATH": { ... } },
  "scv":               { "clinvar.submission:SCV001234567.1": { ... } },
  "vcv":               { "VCV000012582.63-G-PATH-CP": { ... } },
  "rcv":               { "RCV000012345.8-G-PATH-CP": { ... } }
}
```

Objects reference each other using `#/` JSON pointer strings. For example, an allele references its location as `"#/location/ga4gh:SL.xyz789"`, and an SCV statement references its proposition as `"#/proposition/SCV001234567-PATH"`.

See [Output Format](output-reference/overview.md) for the full structure and reference patterns.

### Quick Example

To find the classification statements for a specific variant, start with the variation ID. ClinVar variation 10 (the HFE p.His63Asp variant) has the key `clinvar:10` in the `variation` section:

```json
{
  "variation": {
    "clinvar:10": {
      "id": "clinvar:10",
      "type": "CategoricalVariant",
      "name": "NM_000410.4(HFE):c.187C>G (p.His63Asp)",
      "members": ["#/allele/ga4gh:VA.ELQCnIBGqaTl0AEE0Az18XZ2cgIHAQIY"],
      "constraints": [ ... ],
      "extensions": [ ... ],
      "mappings": [ ... ]
    }
  }
}
```

The SCV statements for this variant reference it via `#/variation/clinvar:10` in their propositions. To find them, look for entries in the `proposition` section where `subjectVariant` matches, then find the corresponding `scv` entries that reference those propositions.

### Key Concepts

**Statements** are the core unit of ClinVar-GKS. Each statement represents a clinical classification — either submitted (SCV), aggregated per variation (VCV), or aggregated per condition (RCV). Statements carry:

- A **classification** — the clinical significance label (e.g., Pathogenic, Likely benign)
- A **proposition** — what the classification asserts (variant X causes condition Y)
- **Direction** and **strength** — whether the evidence supports, disputes, or is neutral toward the proposition
- **Evidence lines** — links to the contributing submissions or lower-level aggregations
- **Extensions** — provenance metadata including submitted conditions, review status, and submission details

**Propositions** define the relationship being classified — a variant's causal role for a condition, its oncogenic potential, or its clinical impact. Each proposition has a type (e.g., `VariantPathogenicityProposition`), a predicate (e.g., `isCausalFor`), a subject variant, and an object condition.

**Conditions** represent the diseases or phenotypes that classifications are made against. Single conditions reference `#/condition/clinvar.trait:{id}`, while multi-condition sets reference `#/conditionSet/clinvar.traitSet:{id}`.

---

## Data Access

ClinVar-GKS releases are published weekly as a single gzip-compressed JSON file, synchronized with each ClinVar XML release. The files are freely available for download from Cloudflare R2 object storage with no authentication required and no egress fees.

### Release Schedule

- **Weekly releases** are published to `datasets/weekly/`, one per ClinVar XML release
- **Monthly releases** are created from the first weekly release of each month and published to `datasets/`
- At the start of each month, the previous month's weekly files move to `archives/`
- At the start of each year, the previous year's monthly files move to `archives/`

The stable filenames `clinvar-gks_00-latest.json.gz` and `clinvar-gks_00-latest_weekly.json.gz` always point to the most recent monthly and weekly releases respectively.

### Downloads

Download the most recent monthly release:

```bash
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/clinvar-gks_00-latest.json.gz
```

Download the most recent weekly release:

```bash
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/weekly/clinvar-gks_00-latest_weekly.json.gz
```

### Directory Structure

```text
datasets/
  clinvar-gks_00-latest.json.gz         latest monthly release
  clinvar-gks_yyyy-mm.json.gz           monthly releases (current year)

datasets/weekly/
  clinvar-gks_00-latest_weekly.json.gz  latest weekly release
  clinvar-gks_yyyy-mmdd.json.gz         weekly releases (current month)

archives/{yyyy}/
  clinvar-gks_yyyy-mm.json.gz           monthly releases from prior years

archives/{yyyy}/weekly/
  clinvar-gks_yyyy-mmdd.json.gz         weekly releases from prior months
```

### Release Notes

Pipeline changes that affect the structure or content of the output are documented in the `release_notes/` directory. These notes cover additions, bug fixes, or schema changes specific to the ClinVar-GKS pipeline — they do not replicate ClinVar's own release notes.

---

## How It Works

The pipeline runs on **Google BigQuery** using SQL stored procedures, with an external VRS Python processing step. Each release is fully reprocessed from the source ClinVar XML — there is no incremental state between releases.

See the [Pipeline Overview](pipeline/index.md) for the full workflow.

---

## Next Steps

- [Output Format](output-reference/overview.md) — detailed guide to the bundle format
- [Variations](output-reference/cat-vrs.md) — how ClinVar variations are represented
- [SCV Statements](output-reference/scv-statements.md) — submitted classification statements
- [Data Model](output-reference/classes/index.md) — class hierarchy and schema reference
- [Pipeline Overview](pipeline/index.md) — how the data is produced from ClinVar XML
- [Examples](data-access/examples.md) — annotated JSON examples

## License

This project is licensed under [CC0 1.0 Universal](https://github.com/clingen-data-model/clinvar-gks/blob/main/LICENSE) (public domain dedication). The output data carries the same terms as the source ClinVar data.
