<p align="center">
  <a href="https://clinicalgenome.org"><img src="docs/assets/images/clingen-logo.svg" alt="ClinGen" height="60"></a>
  &nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://www.ga4gh.org"><img src="docs/assets/images/ga4gh-logo.svg" alt="GA4GH" height="50"></a>
</p>

# ClinVar-GKS

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.18343663.svg)](https://doi.org/10.5281/zenodo.18343663)

ClinVar-GKS is a data transformation pipeline that converts [ClinVar](https://www.ncbi.nlm.nih.gov/clinvar/) release data into [GA4GH GKS](https://www.ga4gh.org/genomic-knowledge-standards/) (Genomic Knowledge Standards) format. Developed and maintained by the [ClinGen](https://clinicalgenome.org/) driver project, it transforms the **entirety** of each ClinVar release — every variation, submitted classification, and aggregate record — into standardized, computable formats.

The pipeline is designed to run automatically with each weekly ClinVar release, producing sibling datasets in GA4GH standard format.

## GA4GH Standards Implemented

- **[VRS](https://vrs.ga4gh.org/)** (Variation Representation Specification) — normalized, computable variant identifiers
- **[Cat-VRS](https://cat-vrs.readthedocs.io/)** (Categorical VRS) — categorical variant representations (canonical alleles)
- **[VA-Spec](https://va-spec.readthedocs.io/)** (Variant Annotation Specification) — variant classification statements

## Output Datasets

Each pipeline run produces JSONL files distributed via Google Cloud Storage:

| File | Description |
| --- | --- |
| `variation` | Cat-VRS categorical variant representations for all ClinVar variations |
| `scv_by_ref` | VA-Spec SCV statements with variations referenced by ID |
| `scv_inline` | VA-Spec SCV statements with full variation objects inline |
| `vcv_by_ref` | VA-Spec VCV aggregate statements with variations referenced by ID |
| `vcv_inline` | VA-Spec VCV aggregate statements with full variation objects inline |

## Data Access

<!-- TODO: Replace this section with current release access information -->

*Information on accessing current releases is coming soon.*

See the [`examples/`](examples/) directory for sample output in each format.

## Pipeline Overview

The pipeline runs on **Google BigQuery** using SQL stored procedures, with an external VRS processing step:

1. **Variation Identity** — extract core variant data from ClinVar XML
2. **VRS Processing** — convert variants to VRS format (external Python tooling)
3. **Cat-VRS Generation** — create categorical variant representations
4. **Condition & Trait Mapping** — map ClinVar conditions to standardized terms
5. **SCV Statement Generation** — produce clinical classification statements
6. **VCV Statement Generation** — produce aggregate classification statements
7. **Export** — distribute output files to Google Cloud Storage

## Documentation

Full documentation is available at **[clingen-data-model.github.io/clinvar-gks](https://clingen-data-model.github.io/clinvar-gks/)**, including pipeline details, GA4GH profile definitions, data access guides, and a schema registry.

## Repository Structure

```text
src/
  procedures/       BigQuery SQL stored procedures
  scripts/          Shell scripts for pipeline operations
  vrs-location-transformer/  Cloud Run service for VRS processing
  gks-registry/     Python tool for GA4GH schema metadata
examples/           Sample output organized by type (cat-vrs, scv, vcv)
schemas/            VRS output JSON schemas
docs/               MkDocs documentation source
```

## Citation

If you use this project, please cite it:

> Babb, L. (2025). *ClinVar-GKS* [Software]. <https://doi.org/10.5281/zenodo.18343663>

See [CITATION.cff](CITATION.cff) for machine-readable citation metadata.

## License

This project is licensed under [CC0 1.0 Universal](LICENSE) (public domain dedication), covering both the code and data outputs. This aligns with FAIR data principles and common practices in the genomics and bioinformatics community.
