# ClinVar-GKS

ClinVar-GKS provides a standardized, machine-readable representation of [ClinVar](https://www.ncbi.nlm.nih.gov/clinvar/) release data using the [GA4GH Genomic Knowledge Standards](https://www.ga4gh.org/genomic-knowledge-standards/) (GKS). It is developed and maintained by the [ClinGen](https://clinicalgenome.org/) driver project.

## Why ClinVar-GKS

ClinVar is one of the most widely used public archives of human genetic variation and its relationship to disease. However, the native ClinVar XML format presents challenges for programmatic consumption — inconsistent structures, deeply nested records, and representations that do not align with emerging genomic data standards.

ClinVar-GKS addresses these challenges by transforming every ClinVar release into a consistent, semantically rich format built on GA4GH specifications:

- **Normalized variant identifiers** — Every variant receives a computable [VRS](https://vrs.ga4gh.org/) identifier, enabling unambiguous cross-system matching
- **Categorical variant representations** — Variants are represented as [Cat-VRS](https://cat-vrs.readthedocs.io/) categorical variants with defining allele constraints and expressions
- **Structured classification statements** — Every submitted (SCV), aggregate (VCV), and condition-level (RCV) classification is represented as a [VA-Spec](https://va-spec.readthedocs.io/) statement with explicit propositions, evidence, and provenance
- **Semantic consistency** — Classifications, propositions, conditions, genes, and cross-references use standardized structures with typed references

## What It Covers

The pipeline processes the **entirety** of each ClinVar XML release:

- **Every variation** with VRS-normalized alleles and locations
- **Every submitted clinical classification** (SCV) across germline, somatic, and oncogenicity statement types
- **Every aggregate variation classification** (VCV) with multi-layer aggregation
- **Every condition-level aggregate classification** (RCV)

New releases are produced weekly, synchronized with ClinVar's release schedule.

## Who It's For

- **Variant scientists** seeking a clear, consistent representation of ClinVar classifications with explicit propositions, conditions, and evidence
- **Platform engineers** building systems that consume ClinVar data and need a structured, well-documented format for integration
- **GA4GH implementers** using ClinVar-GKS as a real-world validation of VRS, Cat-VRS, and VA-Spec schemas

## How to Get the Data

The latest release is available as a single compressed JSON file:

**Current release:** [`https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/current/`](https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/current/)

See [Data Access](data-access/index.md) for the full release schedule, archive policy, and file format details.

## How It Works

The pipeline runs on **Google BigQuery** using SQL stored procedures, with an external VRS Python processing step. Each release is fully reprocessed from the source ClinVar XML — there is no incremental state between releases.

See the [Pipeline Overview](pipeline/index.md) for the full workflow, or jump to [Getting Started](getting-started.md) for a quick introduction to the output format.

## License

This project is licensed under [CC0 1.0 Universal](https://github.com/clingen-data-model/clinvar-gks/blob/main/LICENSE) (public domain dedication). The output data carries the same terms as the source ClinVar data.
