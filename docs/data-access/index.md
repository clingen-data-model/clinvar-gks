# Data Access

ClinVar-GKS is distributed as a **monthly full bundle** plus **weekly deltas**, synchronized with ClinVar's XML releases. Each is a gzip-compressed JSON file with typed Parquet (one file per section). The files are freely available for download from Cloudflare R2 object storage with no authentication required and no egress fees.

---

## Latest Release

Download the most recent monthly full bundle:

```bash
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/clinvar-gks_00-latest.json.gz
```

Download the most recent weekly delta and its manifest:

```bash
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/deltas/00-latest/clinvar-gks-delta_00-latest.json.gz
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/deltas/00-latest/manifest.json
```

The full bundle is a single JSON object containing all bundle sections — variations, statements, propositions, conditions, and supporting reference data. A delta uses the same section structure but carries only the records added or updated since its baseline release. Typed Parquet files (one per section) accompany both at `datasets/parquet/` and `deltas/<yyyy-mmdd>/parquet/`. See [Output Format](../output-reference/overview.md) for the complete structure and [Downloads](download.md) for the consumer replay model and the full Parquet list.

---

## Release Schedule

- **Weekly deltas** are published for every ClinVar release under `deltas/<yyyy-mmdd>/`, mirrored at `deltas/00-latest/`
- **Monthly full bundles** are published once a month under `datasets/` — the full corresponds to the last release of a month, published retroactively when the next month's first release runs
- At the start of each year, the previous year's monthly full bundles move to `archives/`

The stable filenames `clinvar-gks_00-latest.json.gz` (monthly full) and `clinvar-gks-delta_00-latest.json.gz` (weekly delta) always point to the most recent full and delta respectively.

---

## Directory Structure

```text
datasets/
  clinvar-gks_00-latest.json.gz              latest monthly full bundle
  clinvar-gks_yyyy-mm.json.gz                monthly full bundles (current year)

datasets/parquet/
  {section}.parquet                          typed Parquet for the latest monthly full

deltas/00-latest/
  clinvar-gks-delta_00-latest.json.gz        latest weekly delta bundle
  manifest.json                              latest delta manifest
  parquet/{section}.parquet                  typed Parquet for the latest delta

deltas/yyyy-mmdd/
  clinvar-gks-delta_yyyy-mmdd.json.gz        weekly delta bundle (added + updated records)
  manifest.json                              per-release change manifest
  parquet/{section}.parquet                  typed Parquet for the changed records

archives/{yyyy}/
  clinvar-gks_yyyy-mm.json.gz                monthly full bundles from prior years
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
  "proposition": { ... },
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
