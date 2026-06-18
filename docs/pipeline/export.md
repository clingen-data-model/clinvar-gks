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
./src/scripts/export-gks-dicts.sh clinvar_2026_06_14_v2_5_0 clingen-dev-clinvar-gks gks-dicts
```

The script exports the following tables:

| Table | Output Pattern |
| --- | --- |
| `gks_dict_sequence_reference` | `sequenceReference-*.ndjson.gz` |
| `gks_dict_location` | `location-*.ndjson.gz` |
| `gks_dict_allele` | `allele-*.ndjson.gz` |
| `gks_dict_gene` | `gene-*.ndjson.gz` |
| `gks_dict_variation` | `variation-*.ndjson.gz` |
| `gks_traits` | `condition-*.ndjson.gz` |
| `gks_trait_sets` | `conditionSet-*.ndjson.gz` |
| `gks_dict_submitter` | `submitter-*.ndjson.gz` |
| `gks_dict_proposition` | `proposition-*.ndjson.gz` |
| `gks_dict_vcv_proposition` | `vcv_proposition-*.ndjson.gz` |
| `gks_dict_rcv_proposition` | `rcv_proposition-*.ndjson.gz` |
| `gks_scv_statement_pre` | `scv-*.ndjson.gz` |
| `gks_vcv_statement_pre` | `vcv-*.ndjson.gz` |
| `gks_rcv_statement_pre` | `rcv-*.ndjson.gz` |

BigQuery `EXTRACT` shards large tables across multiple files automatically. The assembly step recombines them.

### Step 2: Assemble Bundle

`assemble-gks-dicts.py` reads all NDJSON shard files and assembles them into a single keyed JSON file — the release bundle.

```bash
python3 ./src/scripts/assemble-gks-dicts.py <source> <output>
```

Both `<source>` and `<output>` accept local paths or `gs://` URIs. For best performance, run in Google Cloud Shell to avoid downloading shards locally.

```bash
# Stream from GCS, write result to GCS
python3 ./src/scripts/assemble-gks-dicts.py \
  gs://clingen-dev-clinvar-gks/gks-dicts/ \
  gs://clingen-public/clinvar-gks/2026-06-14/release/clinvar-gks-2026-06-14.json.gz
```

The script assembles 12 bundle sections in a fixed order: `sequenceReference`, `location`, `allele`, `gene`, `variation`, `condition`, `conditionSet`, `submitter`, `proposition`, `scv`, `vcv`, `rcv`. Each section is a keyed object where the key is the record's unique identifier.

Install `orjson` for significantly faster JSON processing:

```bash
pip install orjson
```

### Step 3: Upload to R2

`upload-gks-to-r2.sh` downloads the assembled bundle from GCS and uploads it to Cloudflare R2 for public access.

```bash
./src/scripts/upload-gks-to-r2.sh <export_date> <dataset_version> [--dry-run]
```

```bash
# Upload release
./src/scripts/upload-gks-to-r2.sh 2026-06-14 v2_5_0

# Preview without uploading
./src/scripts/upload-gks-to-r2.sh 2026-06-14 v2_5_0 --dry-run
```

The script manages three R2 directories:

- **`datasets/weekly/`** — weekly files for the current month (`clinvar-gks_yyyy-mmdd.json.gz`) plus a stable `clinvar-gks_00-latest_weekly.json.gz`
- **`datasets/`** — monthly files for the current year (`clinvar-gks_yyyy-mm.json.gz`) plus a stable `clinvar-gks_00-latest.json.gz`
- **`archives/{yyyy}/`** — monthly and weekly files from prior years and months

The script auto-detects month and year boundaries. When a new month begins, previous weekly files move to `archives/`. When a new year begins, previous monthly files also move to `archives/`.

---

## Prerequisites

- **Google Cloud SDK** — `bq` and `gsutil` commands for BigQuery export and GCS operations
- **AWS CLI** — configured with an `r2` profile for Cloudflare R2 access
- **Python 3** — for the assembly script; `orjson` recommended but optional
- **BigQuery access** — read access to the target dataset in `clingen-dev`

---

## Full Example

A complete export for the June 14, 2026 release:

```bash
# 1. Export dictionary tables to GCS
./src/scripts/export-gks-dicts.sh clinvar_2026_06_14_v2_5_0 clingen-dev-clinvar-gks gks-dicts

# 2. Assemble into a single bundle (run from Cloud Shell for best performance)
python3 ./src/scripts/assemble-gks-dicts.py \
  gs://clingen-dev-clinvar-gks/gks-dicts/ \
  gs://clingen-public/clinvar-gks/2026-06-14/release/clinvar-gks-2026-06-14.json.gz

# 3. Upload to Cloudflare R2 (auto-detects month/year boundaries)
./src/scripts/upload-gks-to-r2.sh 2026-06-14 v2_5_0
```
