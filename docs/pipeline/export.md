# Export & Distribute

The final pipeline step exports dictionary tables from BigQuery, assembles them into a single bundled JSON file, and uploads the result to Cloudflare R2 for public distribution.

This step runs after `gks_json_proc` has built all dictionary and statement tables.

---

## Workflow

The export and distribution process uses three scripts, executed in sequence:

### Step 1: Export Dictionaries to GCS

`export-gks-dicts.sh` exports all dictionary and statement tables from BigQuery to Google Cloud Storage as sharded, gzip-compressed NDJSON files.

```bash
./src/scripts/export-gks-dicts.sh <dataset> <gcs_bucket> [prefix]
```

```bash
# Example
./src/scripts/export-gks-dicts.sh clinvar_2026_06_14_v2_5_0 clinvar-gks gks-dicts
```

The script exports the following tables:

| Table | Output Pattern |
| --- | --- |
| `gks_dict_sequence_reference` | `sequenceReference-*.ndjson.gz` |
| `gks_dict_location` | `location-*.ndjson.gz` |
| `gks_dict_allele` | `allele-*.ndjson.gz` |
| `gks_dict_copy_number_count` | `copyNumberCount-*.ndjson.gz` |
| `gks_dict_copy_number_change` | `copyNumberChange-*.ndjson.gz` |
| `gks_dict_gene` | `gene-*.ndjson.gz` |
| `gks_dict_variation` | `variation-*.ndjson.gz` |
| `gks_dict_condition` | `condition-*.ndjson.gz` |
| `gks_dict_condition_set` | `conditionSet-*.ndjson.gz` |
| `gks_dict_submitter` | `submitter-*.ndjson.gz` |
| `gks_dict_proposition` | `proposition-*.ndjson.gz` |
| `gks_dict_evidence_line` | `evidenceLine-*.ndjson.gz` |
| `gks_dict_vcv_proposition` | `vcv_proposition-*.ndjson.gz` |
| `gks_dict_vcv_evidence_line` | `vcv_evidenceLine-*.ndjson.gz` |
| `gks_dict_rcv_proposition` | `rcv_proposition-*.ndjson.gz` |
| `gks_dict_rcv_evidence_line` | `rcv_evidenceLine-*.ndjson.gz` |
| `gks_dict_scv` | `scv-*.ndjson.gz` |
| `gks_dict_vcv` | `vcv-*.ndjson.gz` |
| `gks_dict_rcv` | `rcv-*.ndjson.gz` |

BigQuery `EXTRACT` shards large tables across multiple files automatically. The assembly step recombines them.

### Step 2: Assemble Bundle

`assemble-gks-dicts.py` reads all NDJSON shard files and assembles them into a single keyed JSON bundle file. When `--parquet-dir` is specified, it also produces typed Parquet files for each bundle section in the same pass — both outputs are co-produced from the source NDJSON in a single iteration.

```bash
python3 ./src/scripts/assemble-gks-dicts.py <source> <date> [--parquet-dir DIR] [--keep-source] [--copy-to-gcs]
```

`<source>` is a local path or `gs://` URI containing the NDJSON shards. `<date>` is the ClinVar release date (`YYYY-MM-DD`); the output path is derived as `/tmp/clinvar-gks-{date}.json.gz`. By default, source files are deleted after assembly; use `--keep-source` to retain them.

```bash
# JSON bundle only
python3 ./src/scripts/assemble-gks-dicts.py \
  gs://clinvar-gks/gks-dicts/ \
  2026-06-14

# JSON bundle + Parquet files
python3 ./src/scripts/assemble-gks-dicts.py \
  gs://clinvar-gks/gks-dicts/ \
  2026-06-14 \
  --parquet-dir /tmp/parquet-output
```

The script assembles 15 bundle sections in a fixed order: `sequenceReference`, `location`, `allele`, `copyNumberCount`, `copyNumberChange`, `gene`, `variation`, `condition`, `conditionSet`, `submitter`, `proposition`, `evidenceLine`, `scv`, `vcv`, `rcv`. Each section is a keyed object where the key is the record's unique identifier. Proposition and evidence line shards from SCV, VCV, and RCV are merged into single `proposition` and `evidenceLine` sections.

#### Parquet Output

When `--parquet-dir` is specified, the assembler emits one typed Parquet file per bundle section during assembly:

| Parquet File | Content |
| --- | --- |
| `sequenceReference.parquet` | VRS sequence references |
| `location.parquet` | Genomic locations |
| `allele.parquet` | VRS alleles |
| `copyNumberCount.parquet` | Copy number count variants |
| `copyNumberChange.parquet` | Copy number change variants |
| `gene.parquet` | Gene MappableConcepts |
| `variation.parquet` | Categorical variants |
| `condition.parquet` | Conditions/traits |
| `conditionSet.parquet` | Condition sets |
| `submitter.parquet` | Submitters |
| `proposition.parquet` | All propositions (SCV+VCV+RCV merged) |
| `evidenceLine.parquet` | All evidence lines (SCV+VCV+RCV merged) |
| `scv.parquet` | SCV statements |
| `vcv.parquet` | VCV statements |
| `rcv.parquet` | RCV statements |

Each Parquet file has a typed schema with named columns extracted from the JSON objects — enabling efficient filtering and aggregation without parsing JSON. Every section includes `id` and `data` columns; most sections also include domain-specific typed columns (e.g., `classification`, `direction`, `proposition_id` for statement sections). See [Parquet Files](../data-access/download.md#parquet-files) for the complete file list and column reference.

Install `orjson` and `pyarrow` for best performance:

```bash
pip install orjson pyarrow
```

### Step 3: Upload to R2

`upload-gks-to-r2.sh` uploads the assembled bundle and optional Parquet files to Cloudflare R2 for public access.

```bash
./src/scripts/upload-gks-to-r2.sh <export_date> <dataset_version> <bundle_file> [--parquet-dir=DIR] [--dry-run]
```

```bash
# Upload bundle + Parquet files
./src/scripts/upload-gks-to-r2.sh 2026-06-14 v2_5_0 /tmp/clinvar-gks-2026-06-14.json.gz \
  --parquet-dir=/tmp/parquet-output

# Preview without uploading
./src/scripts/upload-gks-to-r2.sh 2026-06-14 v2_5_0 /tmp/clinvar-gks-2026-06-14.json.gz --dry-run
```

The script manages four R2 directories:

- **`datasets/weekly/`** — weekly JSON bundles for the current month (`clinvar-gks_yyyy-mmdd.json.gz`) plus a stable `clinvar-gks_00-latest_weekly.json.gz`
- **`datasets/`** — monthly JSON bundles for the current year (`clinvar-gks_yyyy-mm.json.gz`) plus a stable `clinvar-gks_00-latest.json.gz`
- **`datasets/parquet/`** — typed Parquet files (one per bundle section), always overwritten with the latest release
- **`archives/{yyyy}/`** — monthly files from prior years

The script auto-detects month and year boundaries. When a new month begins, the last weekly is promoted to a monthly release and the prior month's weekly files are deleted (not archived). When a new year begins, the prior year's monthly files are moved to `archives/{yyyy}/`.

---

## Prerequisites

- **Google Cloud SDK** — `bq` and `gsutil` commands for BigQuery export and GCS operations
- **AWS CLI** — configured with an `r2` profile for Cloudflare R2 access
- **Python 3** — for the assembly script; `orjson` (faster JSON) and `pyarrow` (Parquet output) recommended
- **BigQuery access** — read access to the target dataset in `clingen-dev`

---

## Full Example

A complete export for the June 14, 2026 release using the individual scripts:

```bash
# 1. Export dictionary tables to GCS
./src/scripts/export-gks-dicts.sh clinvar_2026_06_14_v2_5_0 clinvar-gks gks-dicts

# 2. Assemble into a single bundle + Parquet files
python3 ./src/scripts/assemble-gks-dicts.py \
  gs://clinvar-gks/gks-dicts/ \
  2026-06-14 \
  --parquet-dir /tmp/clinvar-gks-2026-06-14-parquet

# 3. Upload to Cloudflare R2 (auto-detects month/year boundaries)
./src/scripts/upload-gks-to-r2.sh 2026-06-14 v2_5_0 \
  /tmp/clinvar-gks-2026-06-14.json.gz \
  --parquet-dir=/tmp/clinvar-gks-2026-06-14-parquet
```

Or use `release-gks.sh` to run all three steps in sequence:

```bash
./src/scripts/release-gks.sh 2026-06-14 v2_5_0
```
