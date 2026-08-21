# Data Access

ClinVar-GKS releases are published weekly, synchronized with each ClinVar XML release. Each release includes a gzip-compressed JSON bundle and typed Parquet files (one per bundle section). The files are freely available for download from Cloudflare R2 object storage with no authentication required and no egress fees.

---

## Latest Release

Download the most recent monthly release:

```bash
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/clinvar-gks_00-latest.json.gz
```

Download the most recent weekly release:

```bash
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/weekly/clinvar-gks_00-latest_weekly.json.gz
```

Each JSON release file is a single JSON object containing all bundle sections — variations, statements, propositions, conditions, and supporting reference data. Typed Parquet files (one per bundle section) are also available at `datasets/parquet/` for analytical workloads. See [Output Format](../output-reference/overview.md) for the complete structure and [Downloads](download.md#parquet-files) for the full list of available Parquet files.

---

## Release Schedule

- **Weekly releases** are published to `datasets/weekly/`, one per ClinVar XML release
- **Monthly releases** are created from the first weekly release of each month and published to `datasets/`
- At the start of each month, the previous month's weekly files move to `archives/`
- At the start of each year, the previous year's monthly files move to `archives/`

The stable filenames `clinvar-gks_00-latest.json.gz` and `clinvar-gks_00-latest_weekly.json.gz` always point to the most recent monthly and weekly releases respectively.

---

## Directory Structure

```text
datasets/
  clinvar-gks_00-latest.json.gz         latest monthly release
  clinvar-gks_yyyy-mm.json.gz           monthly releases (current year)

datasets/weekly/
  clinvar-gks_00-latest_weekly.json.gz  latest weekly release
  clinvar-gks_yyyy-mmdd.json.gz         weekly releases (current month)

datasets/parquet/
  {section}.parquet                     typed Parquet files (always latest release)

archives/{yyyy}/
  clinvar-gks_yyyy-mm.json.gz           monthly releases from prior years
```

---

## Release Notes

Pipeline changes that affect the structure or content of the output are documented in the `release_notes/` directory. These notes cover additions, bug fixes, or schema changes specific to the ClinVar-GKS pipeline — they do not replicate ClinVar's own release notes.

---

## File Format

The primary release format is a **gzip-compressed JSON file** (`.json.gz`). Typed Parquet files (one per bundle section) are also produced during assembly for analytical use. The decompressed JSON content is a single JSON object with bundle sections at the root level:

```json
{
  "sequenceReference": { ... },
  "location": { ... },
  "allele": { ... },
  "copyNumberCount": { ... },
  "copyNumberChange": { ... },
  "gene": { ... },
  "variation": { ... },
  "condition": { ... },
  "conditionSet": { ... },
  "submitter": { ... },
  "varcond-proposition": { ... },
  "vartumor-proposition": { ... },
  "vartherapy-proposition": { ... },
  "varcustom-proposition": { ... },
  "evidenceLine": { ... },
  "scv": { ... },
  "vcv": { ... },
  "rcv": { ... }
}
```

Each section is a keyed collection — the key is the object's unique identifier, and the value is the complete object. Objects reference each other using `#/` JSON pointer strings.

See [Output Format](../output-reference/overview.md) for detailed documentation of each section.

---

## What's Next

- [Output Format](../output-reference/overview.md) — the bundle structure and reference patterns
- [Examples](examples.md) — annotated sample records from each section
- [Pipeline Overview](../pipeline/index.md) — how the data is produced from ClinVar XML
