# Dataset Diff

Snapshot-to-snapshot delta for ClinVar tables in BigQuery. Given two dataset
snapshots of the **same schema** (a baseline/older and a compare/newer), it
classifies every record as `new`, `removed`, `exact_match`, or `modified`, with
comparison that is **insensitive to array order and JSON key order**.

The UDFs and procedures live in the dedicated **`clinvar_ingest`** dataset. The
`diff_<table>` **output tables are written into the compare (2nd/newer)
snapshot's own dataset** (e.g. `clinvar_2026_07_20_v2_5_0.diff_clinical_assertion`).

## Files (deploy in order)

| File | Creates |
|------|---------|
| `dataset-diff-func.sql` | JS UDFs `canonicalize_json`, `json_changed_keys` in `clinvar_ingest` |
| `dataset-diff-proc.sql` | `clinvar_ingest.dataset_diff` — the generic engine (one table) |
| `dataset-diff-all-proc.sql` | `clinvar_ingest.dataset_diff_all` — driver over the full ClinVar table set |

These procedures are deployed manually (like the other `src/procedures/` procs),
into the `clinvar_ingest` dataset in `clingen-dev`. Deploy the UDFs first, then
the procs:

```bash
bq query --use_legacy_sql=false < src/procedures/dataset-diff-func.sql
bq query --use_legacy_sql=false < src/procedures/dataset-diff-proc.sql
bq query --use_legacy_sql=false < src/procedures/dataset-diff-all-proc.sql
```

## Usage

One table:

```sql
CALL `clinvar_ingest.dataset_diff`(
  'clinvar_2026_07_15_v2_5_0',   -- baseline (older)
  'clinvar_2026_07_20_v2_5_0',   -- compare  (newer)
  'clinical_assertion',          -- table
  ['id','version'],              -- natural key ([] => whole row is the key)
  ['release_date'],              -- ignored columns (always ignore release_date)
  FALSE                          -- use_distinct (TRUE to de-dupe first)
);
```

All tables at once (uses the built-in table→key map):

```sql
CALL `clinvar_ingest.dataset_diff_all`(
  'clinvar_2026_07_15_v2_5_0',
  'clinvar_2026_07_20_v2_5_0'
);
```

Each call (re)creates `<compare_schema>.diff_<table>`, clustered by `change_type`:

| column | meaning |
|--------|---------|
| `record_key` | JSON serialization of the natural key (the row identity) |
| *key columns* | the natural-key columns, expanded (e.g. `id`, `version`) |
| `change_type` | `new` \| `removed` \| `exact_match` \| `modified` |
| `change_note` | for `modified`: comma-separated list of columns that changed; else `NULL` |
| `baseline_release` / `compare_release` | the two snapshots' `release_date`s |

```sql
SELECT change_type, COUNT(*) FROM `clinvar_2026_07_20_v2_5_0.diff_clinical_assertion` GROUP BY 1;
SELECT * FROM `clinvar_2026_07_20_v2_5_0.diff_clinical_assertion` WHERE change_type = 'modified';
```

## How comparison works

**Two-tier fingerprint** — reliable *and* fast:

1. **Cheap tier (runs on every row):** rows are serialized with `TO_JSON_STRING`
   (deterministic, schema-ordered field order). If the two serializations are
   byte-identical, the row is `exact_match` immediately — no further work.
2. **Exact tier (runs only when bytes differ):** `clinvar_ingest.canonicalize_json`
   re-serializes each side into a canonical form where
   - object keys are sorted,
   - array elements are sorted by their own canonical string,
   - any **string value that itself parses as JSON is recursed into** — this
     transparently normalizes ClinVar's `content` blob and the JSON-in-string
     elements of `REPEATED` columns (e.g. `interpretation_comments`).

   If the canonical forms match, the difference was pure ordering → `exact_match`;
   otherwise → `modified`.

Because the expensive JavaScript canonicalizer only touches rows whose raw bytes
already differ, cost is negligible. On `clinical_assertion` (~6.9M rows/snapshot)
only a few hundred rows reach tier 2; the full diff runs in seconds.

For `modified` rows, `json_changed_keys` (same canonicalization) reports which
top-level columns actually changed.

### Ignored columns
`release_date` is the snapshot marker and differs on every release, so it must
always be in `ignore_columns` — otherwise every row would look `modified`.

### Tables with no stable key / duplicates
`trait_mapping` has no per-row key and may contain duplicate rows. It is diffed
with an empty key (the whole non-ignored row is the identity) and `use_distinct
= TRUE`, so each snapshot is de-duplicated before diffing.

## Table → key map (`dataset_diff_all`)

| table | natural key | notes |
|-------|-------------|-------|
| clinical_assertion | id, version | |
| clinical_assertion_observation | id | |
| clinical_assertion_trait | id | |
| clinical_assertion_trait_set | id | |
| clinical_assertion_variation | id | |
| gene | id | |
| gene_association | gene_id, variation_id | |
| rcv_accession | id, version | |
| rcv_accession_classification | rcv_id, statement_type | |
| rcv_mapping | rcv_accession | |
| scv_summary | id, version | |
| submission | id | |
| submitter | id | |
| trait | id | |
| trait_mapping | *(all cols except release_date)* | `use_distinct = TRUE` |
| trait_set | id | |
| variation | id | |
| variation_archive | id, version | |
| variation_archive_classification | vcv_id, statement_type | |

The driver isolates each table (`BEGIN … EXCEPTION WHEN ERROR`), so a missing
table or per-table failure emits a `SKIPPED <table>: <message>` warning and the
run continues with the rest.
