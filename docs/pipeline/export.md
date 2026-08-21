# Export & Distribute

The final pipeline step exports the `gks_dict_*` tables from BigQuery, assembles them into a single keyed JSON bundle, exports Parquet files directly from BigQuery, and uploads to Cloudflare R2 for public distribution.

The `gks_dict_*` tables **are** the published product — they are built directly by the statement procedures (steps 5–7) and the change-log step (step 8). The retired `gks_json_proc` is not part of this path; its inlined JSON-render tables were never published. See [Retired: gks_json_proc](#retired-gks_json_proc).

Distribution follows a **full + delta** model:

- The complete **monthly full bundle** (JSON + Parquet) is published once a month via `release-gks.sh` / `upload-gks-to-r2.sh`.
- A **weekly delta** — added and updated records plus a change manifest — is published for every release via `release-gks-delta.sh` / `upload-gks-delta-to-r2.sh`.

---

## Workflow

The export and distribution process uses four steps, executed in sequence. The `release-gks.sh` wrapper runs all four automatically, or each step can be run individually.

### Step 1: Export Dictionaries to GCS

`export-gks-dicts.sh` exports all dictionary and statement tables from BigQuery to Google Cloud Storage in two formats:

- **NDJSON** — sharded, gzip-compressed files for JSON bundle assembly (`gks-dicts/`)
- **Parquet** — Snappy-compressed files exported natively via `bq extract` (`gks-dicts-parquet/`)

```bash
./src/scripts/export-gks-dicts.sh <dataset> <gcs_bucket> [prefix] [--parquet-only]
```

```bash
# Export both NDJSON and Parquet
./src/scripts/export-gks-dicts.sh clinvar_2026_06_14_v2_5_0 clinvar-gks gks-dicts

# Export Parquet only (skip NDJSON)
./src/scripts/export-gks-dicts.sh clinvar_2026_06_14_v2_5_0 clinvar-gks gks-dicts --parquet-only
```

The script exports the following 19 tables:

| Table | NDJSON Output | Parquet Output |
| --- | --- | --- |
| `gks_dict_sequence_reference` | `sequenceReference-*.ndjson.gz` | `sequenceReference.parquet` |
| `gks_dict_location` | `location-*.ndjson.gz` | `location.parquet` |
| `gks_dict_allele` | `allele-*.ndjson.gz` | `allele.parquet` |
| `gks_dict_copy_number_count` | `copyNumberCount-*.ndjson.gz` | `copyNumberCount.parquet` |
| `gks_dict_copy_number_change` | `copyNumberChange-*.ndjson.gz` | `copyNumberChange.parquet` |
| `gks_dict_gene` | `gene-*.ndjson.gz` | `gene.parquet` |
| `gks_dict_variation` | `variation-*.ndjson.gz` | `variation.parquet` |
| `gks_dict_condition` | `condition-*.ndjson.gz` | `condition.parquet` |
| `gks_dict_condition_set` | `conditionSet-*.ndjson.gz` | `conditionSet.parquet` |
| `gks_dict_submitter` | `submitter-*.ndjson.gz` | `submitter.parquet` |
| `gks_dict_proposition` | `proposition-*.ndjson.gz` | `proposition.parquet` |
| `gks_dict_evidence_line` | `evidenceLine-*.ndjson.gz` | `evidenceLine.parquet` |
| `gks_dict_vcv_proposition` | `vcv_proposition-*.ndjson.gz` | `vcv_proposition.parquet` |
| `gks_dict_vcv_evidence_line` | `vcv_evidenceLine-*.ndjson.gz` | `vcv_evidenceLine.parquet` |
| `gks_dict_rcv_proposition` | `rcv_proposition-*.ndjson.gz` | `rcv_proposition.parquet` |
| `gks_dict_rcv_evidence_line` | `rcv_evidenceLine-*.ndjson.gz` | `rcv_evidenceLine.parquet` |
| `gks_dict_scv` | `scv-*.ndjson.gz` | `scv.parquet` |
| `gks_dict_vcv` | `vcv-*.ndjson.gz` | `vcv.parquet` |
| `gks_dict_rcv` | `rcv-*.ndjson.gz` | `rcv.parquet` |

BigQuery `EXTRACT` shards large NDJSON tables across multiple files automatically. Parquet files are exported as single files per table; BigQuery may auto-shard very large tables with numeric suffixes.

### Step 2: Assemble Bundle

`assemble-gks-dicts.py` reads all NDJSON shard files and assembles them into a single keyed JSON bundle file.

```bash
python3 ./src/scripts/assemble-gks-dicts.py <source> <date> [--keep-source] [--copy-to-gcs]
```

`<source>` is a local path or `gs://` URI containing the NDJSON shards. `<date>` is the ClinVar release date (`YYYY-MM-DD`); the output path is derived as `/tmp/clinvar-gks-{date}.json.gz`. By default, source files are deleted after assembly; use `--keep-source` to retain them.

```bash
python3 ./src/scripts/assemble-gks-dicts.py \
  gs://clinvar-gks/gks-dicts/ \
  2026-06-14
```

The script assembles 18 bundle sections in a fixed order: `sequenceReference`, `location`, `allele`, `copyNumberCount`, `copyNumberChange`, `gene`, `variation`, `condition`, `conditionSet`, `submitter`, `varcond-proposition`, `vartumor-proposition`, `vartherapy-proposition`, `varcustom-proposition`, `evidenceLine`, `scv`, `vcv`, `rcv`. Each section is a keyed object where the key is the record's unique identifier. Propositions from SCV, VCV, and RCV are delivered in **four datatype-homogeneous sections** keyed by their (subject, object) signature — `varcond-proposition` (variant×condition), `vartumor-proposition` (variant×tumorType), `vartherapy-proposition` (variant×therapy), `varcustom-proposition` (custom variant×condition); evidence line shards are merged into a single `evidenceLine` section.

Install `orjson` for best performance:

```bash
pip install orjson
```

### Step 3: Download and Merge Parquet from GCS

`release-gks.sh` downloads Parquet shards from GCS, merges them into one file per section using DuckDB, and stages the merged files for upload. BigQuery exports may produce multiple shards per table (e.g., `allele-000000000000.parquet`, `allele-000000000001.parquet`); this step consolidates them into a single `allele.parquet`.

This step is handled automatically by `release-gks.sh` and cannot be run as a standalone script.

#### Parquet Output

The export produces 19 Parquet files — one per dictionary table. Statement and stream passthrough tables (variation, condition, conditionSet, scv, vcv, rcv, evidenceLine) have fully typed columns matching the BigQuery table schema. Key-value tables (sequenceReference, location, allele, gene, submitter, proposition, etc.) export as two string columns (`key`, `value`).

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
| `proposition.parquet` | SCV propositions |
| `vcv_proposition.parquet` | VCV propositions |
| `rcv_proposition.parquet` | RCV propositions |
| `evidenceLine.parquet` | SCV evidence lines |
| `vcv_evidenceLine.parquet` | VCV evidence lines |
| `rcv_evidenceLine.parquet` | RCV evidence lines |
| `scv.parquet` | SCV statements |
| `vcv.parquet` | VCV statements |
| `rcv.parquet` | RCV statements |

See [Parquet Files](../data-access/download.md#parquet-files) for download URLs and query examples.

### Step 4: Upload the Monthly Full to R2

`upload-gks-to-r2.sh` uploads the assembled full bundle and Parquet files to Cloudflare R2. As of the delta distribution model, the full bundle is published **month-end only** — it corresponds to the last release of a month and is uploaded retroactively when the first release of the next month runs.

```bash
./src/scripts/upload-gks-to-r2.sh <export_date> <dataset_version> <bundle_file> [--parquet-dir=DIR] [--dry-run]
```

```bash
# Upload full bundle + Parquet files
./src/scripts/upload-gks-to-r2.sh 2026-06-14 v2_5_0 /tmp/clinvar-gks-2026-06-14.json.gz \
  --parquet-dir=/tmp/clinvar-gks-2026-06-14-parquet

# Preview without uploading
./src/scripts/upload-gks-to-r2.sh 2026-06-14 v2_5_0 /tmp/clinvar-gks-2026-06-14.json.gz --dry-run
```

The script manages the monthly full slots:

- **`datasets/`** — monthly full bundles for the current year (`clinvar-gks_yyyy-mm.json.gz`) plus a stable `clinvar-gks_00-latest.json.gz`
- **`datasets/parquet/`** — Parquet files (one per dictionary table), always overwritten with the latest monthly full
- **`archives/{yyyy}/`** — monthly full bundles from prior years

There is **no weekly full bundle** — weekly changes are published as deltas (see [Step 5](#step-5-publish-the-weekly-delta)). The monthly upload is unconditional; boundary detection now governs only year rollover — when a new year begins, the prior year's monthly full bundles are moved to `archives/{yyyy}/`. After upload, `generate-r2-index.sh` regenerates `index.json`, which lists the monthly `datasets`, the `archives`, and the `deltas`.

### Step 5: Publish the Weekly Delta

`release-gks-delta.sh` publishes the per-release delta for every ClinVar release. It exports the `delta_<dict>` change tables produced by step 8 of the pipeline, assembles a delta bundle (added + updated records, same section structure as the full), merges per-section delta Parquet, builds `manifest.json`, and uploads the delta tree to R2.

```bash
./src/scripts/release-gks-delta.sh <export_date> <dataset_version> [--start-step=N] [--dry-run]
```

```bash
# Publish the weekly delta for a release
./src/scripts/release-gks-delta.sh 2026-07-06 v2_5_0
```

The four internal steps are: export delta tables to GCS, assemble the delta bundle, merge delta Parquet, then build the manifest (`build-delta-manifest.py`) and upload (`upload-gks-delta-to-r2.sh`). The uploader writes:

- **`deltas/<yyyy-mmdd>/`** — the delta bundle (`clinvar-gks-delta_<yyyy-mmdd>.json.gz`), `manifest.json`, and `parquet/<section>.parquet`
- **`deltas/00-latest/`** — a server-side mirror of the most recent delta under stable filenames

`build-delta-manifest.py` derives each section's `added` / `updated` counts and `deleted` primary-key list from the dataset's `gks_change_log`, and records `baseline_release`, `compare_release`, `pipeline_version`, and `counts`. The uploader then resolves `checkpoint_full` — the newest monthly full currently in `datasets/` — so a consumer knows which full bundle the delta chain replays onto. See [Downloads](../data-access/download.md#weekly-deltas) for the manifest shape and the consumer replay model.

---

## Retired: gks_json_proc

`gks_json_proc` previously rendered the statement and dictionary tables into inlined JSON columns. Those render tables were **never published** — the export assembles the bundle directly from the `gks_dict_*` tables — so the procedure has been retired from the hot path. The null/empty stripping it used to perform is now applied during assembly (`assemble-gks-dicts.py`), matching the old `remove_empty` cleanup. `gks_json_proc` is not a live pipeline step and not a downstream consumer of the dictionary tables.

---

## Prerequisites

- **Google Cloud SDK** — `bq` and `gsutil` commands for BigQuery export and GCS operations
- **AWS CLI** — configured with an `r2` profile for Cloudflare R2 access
- **Python 3** — for the assembly script; `orjson` (faster JSON) recommended
- **DuckDB CLI** — for merging Parquet shards into single files per section
- **BigQuery access** — read access to the target dataset in `clingen-dev`

---

## Full Example

Publish the monthly full bundle for June 14, 2026:

```bash
./src/scripts/release-gks.sh 2026-06-14 v2_5_0
```

This runs Steps 1–4: export to GCS, assemble JSON bundle, download and merge Parquet, upload the monthly full to R2.

Publish the weekly delta for the same release:

```bash
./src/scripts/release-gks-delta.sh 2026-06-14 v2_5_0
```

Steps 1 and 2 of the full can also be run individually. Steps 3–4 (Parquet download, shard merging, and upload) are handled internally by `release-gks.sh` — use `--start-step` to resume from a specific step.

```bash
# 1. Export dictionary tables to GCS (NDJSON + Parquet)
./src/scripts/export-gks-dicts.sh clinvar_2026_06_14_v2_5_0 clinvar-gks gks-dicts

# 2. Assemble NDJSON into a single JSON bundle
python3 ./src/scripts/assemble-gks-dicts.py \
  gs://clinvar-gks/gks-dicts/ \
  2026-06-14

# 3-4. Download Parquet, merge shards, upload to R2
./src/scripts/release-gks.sh 2026-06-14 v2_5_0 --start-step=3
```
