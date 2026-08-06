# Pipeline Overview

The ClinVar-GKS pipeline transforms ClinVar XML release data into GA4GH GKS format through a series of BigQuery stored procedures with an external VRS Python processing step.

The two most expensive stages — [Variation Identity](variation-identity/index.md) and [VRS Processing](vrs-processing.md) — support **incremental** processing: they recompute only the variations that changed since the prior release and carry the rest forward, driven by the release-to-release diff (`dataset_diff_on`). The remaining stored procedures currently run as full rebuilds each release.

## Pipeline Steps

The pipeline executes in the following order. Each step is a BigQuery stored procedure unless otherwise noted.

```
┌──────────────────────────────┐
│ 1. Variation Identity        │  variation_identity[_incremental]
│    Extract & normalize       │  → variation_identity table
│    variant data              │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 2. VRS Processing            │  External: vrs-python
│    Export → VRS Python →     │  → gks_vrs table
│    Import back to BigQuery   │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 3. Cat-VRS Generation        │  gks_catvar_proc
│    Canonical alleles &       │  → gks_catvar table
│    categorical variants      │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 4. Conditions & Traits       │  gks_scv_condition_proc
│    Map traits, build         │  → condition mapping &
│    conditions & condition    │    condition set tables
│    sets                      │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 5. SCV Statements            │  gks_scv_statement_proc
│    Build SCV records,        │  → gks_dict_scv table
│    propositions & statements │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 6. VCV Statements            │  gks_vcv_proc +
│    Aggregate SCVs into       │  gks_vcv_statement_proc
│    variant-level statements  │  → gks_dict_vcv table
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 7. RCV Statements            │  gks_rcv_proc +
│    Aggregate SCVs into       │  gks_rcv_statement_proc
│    condition-level statements│  → gks_dict_rcv table
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 8. JSON Output               │  gks_json_proc
│    Build dictionary tables   │  → gks_dict_* tables
│    for bundle assembly       │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 9. Export & Distribute       │  export-gks-dicts.sh
│    Export NDJSON + Parquet    │  assemble-gks-dicts.py
│    to GCS, assemble JSON     │  release-gks.sh
│    bundle, upload to R2      │  → R2 public bucket
└──────────────────────────────┘
```

## Running the Pipeline

### Single-command run

The whole release can be run end-to-end with the `run-release.sh` orchestrator, which chains variation identity, the GCS export, vrsification, and the transform/load/procedures/publish stages:

```bash
./src/scripts/run-release.sh YYYY-MM-DD              # incremental (default)
./src/scripts/run-release.sh YYYY-MM-DD --full       # full rebuild / reseed
./src/scripts/run-release.sh YYYY-MM-DD --start-step 4   # resume from a stage (1-4)
```

`--full` propagates version-invalidation across every stage; use it for the first release or after a `variation_identity` transform change or a vrsify-pin bump. The vrsify stage (stage 3) requires local SeqRepo / UTA / gene-normalizer services — see [`src/vrsify/README.md`](https://github.com/clingen-data-model/clinvar-gks/tree/main/src/vrsify) — so on hosts without them, run the BigQuery-side stages with `--start-step` and run vrsify separately.

The individual stages are documented below.

### Step 1: Variation Identity

From the BigQuery console — incremental by default, full rebuild when reseeding (see [Incremental Rebuild](variation-identity/index.md#incremental-rebuild)):

```sql
-- default: recompute only changed variations, carry the rest forward
CALL `clinvar_ingest.variation_identity_incremental`(CURRENT_DATE(), FALSE);

-- full rebuild: first release, or after a variation_identity transform change
CALL `clinvar_ingest.variation_identity`(CURRENT_DATE(), FALSE);
```

### Step 2: VRS Processing

Export, process externally with vrs-python, and load back — incremental by default (only changed variations are vrsified; unchanged `gks_vrs` results carry forward). See [VRS Processing](vrs-processing.md).

### Step 3: Cat-VRS through JSON Output

From the BigQuery console:

```sql
CALL `clinvar_ingest.gks_scv_condition_proc`(CURRENT_DATE(), FALSE);
CALL `clinvar_ingest.gks_scv_statement_proc`(CURRENT_DATE(), FALSE);
CALL `clinvar_ingest.gks_vcv_proc`(CURRENT_DATE(), FALSE);
CALL `clinvar_ingest.gks_vcv_statement_proc`(CURRENT_DATE(), FALSE);
CALL `clinvar_ingest.gks_rcv_proc`(CURRENT_DATE(), FALSE);
CALL `clinvar_ingest.gks_rcv_statement_proc`(CURRENT_DATE(), FALSE);
CALL `clinvar_ingest.gks_json_proc`(CURRENT_DATE(), 'all');
```

### Step 4: Export & Distribute

```bash
# Run the full release pipeline (export, assemble, download Parquet, upload to R2)
./src/scripts/release-gks.sh 2026-06-14 v2_5_0
```

Steps 1 and 2 can also be run individually. Steps 3–4 (Parquet download, shard merging, and upload) are handled internally by `release-gks.sh` — use `--start-step` to resume from a specific step.

```bash
# 1. Export dictionary tables to GCS (NDJSON + Parquet)
./src/scripts/export-gks-dicts.sh clinvar_2026_06_14_v2_5_0 clinvar-gks gks-dicts

# 2. Assemble NDJSON into JSON bundle
python3 ./src/scripts/assemble-gks-dicts.py gs://clinvar-gks/gks-dicts/ 2026-06-14

# 3-4. Download Parquet, merge shards, upload to R2
./src/scripts/release-gks.sh 2026-06-14 v2_5_0 --start-step=3
```

See [Export](export.md) for details on each step.

## Documentation Tracks

The pipeline documentation serves two audiences:

- **Pipeline** (this section) — documents how data flows through BigQuery stored procedures, including internal table schemas, transformation logic, and step-by-step workflows. Each step is tagged as <span class="role-badge badge-pipeline">Pipeline table</span>, <span class="role-badge badge-artifact">JSON artifact</span>, or <span class="role-badge badge-internal">Internal</span> to indicate its role
- **[Output Reference](../output-reference/index.md)** — documents the JSON output files from a consumer perspective, covering record structure, field meanings, and usage guidance

---

## Detailed Documentation

Each pipeline step has its own documentation page:

- [Variation Identity](variation-identity/index.md) — variant extraction, normalization, VRS class assignment
- [VRS Processing](vrs-processing.md) — external VRS Python step
- [Cat-VRS](cat-vrs/index.md) — categorical variant generation
- [Conditions & Traits](conditions-and-traits/index.md) — condition mapping, traits, condition sets
- [SCV Statements](scv-statements/index.md) — SCV records, propositions, final statements
- [VCV Statements](vcv-statements/index.md) — aggregate variant-level VCV statements
- [RCV Statements](rcv-statements/index.md) — aggregate condition-level RCV statements
- [Export & Distribute](export.md) — export to GCS, assemble bundle, upload to R2
