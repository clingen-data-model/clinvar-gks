# ClinVar-GKS

ClinVar-GKS is a data transformation pipeline that converts [ClinVar](https://www.ncbi.nlm.nih.gov/clinvar/) release data into its [GA4GH GKS](https://www.ga4gh.org/genomic-knowledge-standards/) (Genomic Knowledge Standards) equivalent. It is developed and maintained by the [ClinGen](https://clinicalgenome.org/) driver project.

## What It Does

The pipeline processes the **entirety** of each ClinVar XML release — every variation, submitted classification, and aggregate record — and transforms them into standardized GA4GH formats:

- **[VRS](https://vrs.ga4gh.org/)** (Variation Representation Specification) — normalized, computable variant identifiers
- **[Cat-VRS](https://cat-vrs.readthedocs.io/)** (Categorical VRS) — categorical variant representations (canonical alleles, copy number variants)
- **[VA-Spec](https://va-spec.readthedocs.io/)** (Variant Annotation Specification) — variant classification statements

## Who It's For

- **Implementers** building tools that consume ClinVar data in GA4GH standard format
- **Researchers** who need programmatic access to normalized ClinVar classifications
- **GA4GH specification developers** using ClinVar-GKS as a real-world validation of GKS schemas

## How It Works

The pipeline runs on **Google BigQuery** using SQL stored procedures, with an external VRS Python processing step. It is designed for periodic batch processing, typically running weekly in sync with ClinVar releases.

See the [Pipeline Overview](pipeline/index.md) for the full workflow, or jump to [Getting Started](getting-started.md) to access the output datasets.

## Output Datasets

Each pipeline run produces gzip-compressed JSONL files distributed via Cloudflare R2:

| File | Description |
| --- | --- |
| `variation` | Cat-VRS categorical variant representations for all ClinVar variations |
| `scv_by_ref` | VA-Spec SCV statements with variations referenced by ID |

See [Data Access](data-access/index.md) for download URLs and format details.

## License

This project is licensed under [CC0 1.0 Universal](https://github.com/clingen-data-model/clinvar-gks/blob/main/LICENSE) (public domain dedication).
