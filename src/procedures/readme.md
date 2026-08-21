-- after a new clinvar release dataset is fully ingested do the 
-- following steps to get the GKS files created
-- 
-- 1. ask Kyle to vrsify the gs://clinvar-gks/YYYY-MM-DD/dev/vi.jsonl.gz file

-- 2. transform the vrs locations to vi compatible form for bigquery processing
--    below by running the gh:clinvar-gks/src/gks-procs/vrs-to-bq-table.sh
--    which will alter the location start/end arrays to denormalized columns
--    for inner/outer start/end attributes in order to be importable to BQ
--    and it will import them into the BQ dataset as table 'gks_vrs'

-- 3. run the following procedures below (change date arg if not the most recent release)
-- CALL `clinvar_ingest.gks_catvar_proc`(CURRENT_DATE(), FALSE);
-- CALL `clinvar_ingest.gks_scv_condition_proc`(CURRENT_DATE(), FALSE);
-- CALL `clinvar_ingest.gks_scv_statement_proc`(CURRENT_DATE(), FALSE);

-- 4. export the gks files to gcs by runing gh:clinvar-gks/src/gks-procs/export-gks-files-to-gcs.sh
--    by default add these files to the gs://clingen-public/clinvar-gks/* bucket
--    with the new filename clinvar_gks_(*)_YYYY_MM_DD_v9_9_8.jsonl.gz where
--    (*) is the name of one of the 3 files.


-- Appendix. UNDER DEVELOPMENT
-- below is a work in progress to get the VCV gks data building
-- CALL `clinvar_ingest.gks_vcv_level_one_proc`(CURRENT_DATE());






# Dataset Diff (snapshot-to-snapshot delta tool)

Order-independent delta between two ClinVar release snapshots, used to identify
`new` / `removed` / `exact_match` / `modified` records per table. See
[`dataset-diff.md`](./dataset-diff.md) for design and usage details.

These are deployed manually into the `clinvar_ingest` dataset (like the other
procs here). Deploy the UDFs first, then the procedures:

```bash
bq query --use_legacy_sql=false < src/procedures/dataset-diff-func.sql       # UDFs: canonicalize_json, json_changed_keys
bq query --use_legacy_sql=false < src/procedures/dataset-diff-proc.sql       # clinvar_ingest.dataset_diff (one table)
bq query --use_legacy_sql=false < src/procedures/dataset-diff-all-proc.sql   # clinvar_ingest.dataset_diff_all (all tables)
bq query --use_legacy_sql=false < src/procedures/dataset-diff-on-proc.sql    # clinvar_ingest.dataset_diff_on (by on_date)
```

Diff one table, or all tables between a baseline (older) and compare (newer) snapshot:

```sql
CALL `clinvar_ingest.dataset_diff_all`('clinvar_2026_07_15_v2_5_0', 'clinvar_2026_07_20_v2_5_0');
```

Or by release date — `dataset_diff_on` resolves the compare snapshot and the nearest
existing prior snapshot automatically (falls back to a warning on the first release):

```sql
CALL `clinvar_ingest.dataset_diff_on`(CURRENT_DATE());
```

Each call writes `<compare_schema>.diff_<table>` into the compare snapshot's own dataset.

# How to build the GKS SCV Statements from a ClinVar Dataset
The example steps below show how to build the GKS SCV Statements
for the `clinvar_2025_03_23_v2_3_1` dataset in the `ClinGen Dev` GCP project

## STEP 1
From BQ Console (NOTE: this example assumes CURRENT_DATE() will resolve to the 2025-03-23 clinvar release)

**Default (incremental)** — carry forward the unchanged variations from the prior
release and re-parse only the changed set:

```
CALL `clinvar_ingest.variation_identity_incremental`(CURRENT_DATE(), FALSE);
```

**Full rebuild** — first release, missing baseline, or after a `variation_identity`
transform change (see version-invalidation below):

```
CALL `clinvar_ingest.variation_identity`(CURRENT_DATE(), FALSE);
```

> **Incremental `variation_identity` (see [dataset-diff.md](./dataset-diff.md) and
> `docs/superpowers/plans/2026-08-05-incremental-variation-identity-v2.md`):**
> `variation_identity_incremental` re-runs the heavy per-variation content parsing
> (`parseSequenceLocations` / `parseHGVS` / `parseXRefs` / SPDI) only for the variations
> changed since the prior release (`diff_variation` new|modified ∪ the copy-number CAV/CA
> cascade), carries the rest forward, and UNION-CTAS-merges the four outputs. `mappings` is
> recomputed globally from the merged `variation_xref`. Measured **~7.5× slot-time / ~2.1×
> bytes** per weekly release; the full-vs-incremental oracle is byte-identical (0 canonical
> diffs across all four tables).
>
> - **Fallback guard (automatic):** if the baseline release, its four output tables, or the
>   current release's `diff_*` driver tables are missing, `variation_identity_incremental`
>   falls back to a full rebuild — the full path is always correct.
> - **Version-invalidation (operator-asserted):** carry-forward assumes the prior release
>   was built by the **same** `variation_identity` transform. **After any change to this
>   proc, run the full `variation_identity` once** on the next release to reseed; resume
>   `_incremental` afterward. (The guard cannot detect a transform change on its own.)
> - Producing a correct `variation_identity` this way ALSO yields the clean changed-variation
>   set that STEP 2/3 vrsify consumes — see the "Incremental vrsify" note under STEP 3.

## STEP 2
From a terminal, extract `variation_identity` to `gs://clinvar-gks/<date>/dev/vi.jsonl.gz`.
Default is **incremental** — only the variations whose `variation_identity` changed since
the prior release are exported (the rest are carried forward in STEP 4):

```
./src/scripts/export-vi-table-to-gcs.sh 2025-03-23          # incremental (default)
./src/scripts/export-vi-table-to-gcs.sh 2025-03-23 --full   # whole table (first release / version bump)
```

> **Incremental vrsify (the real win — Tasks 1–3 implemented + verified in clingen-dev):**
> - **STEP 2** (`export-vi-table-to-gcs.sh`) computes `variation_vrs_changed` (diff of
>   `variation_identity` vs the prior release) and extracts only that set to `vi.jsonl.gz`.
> - **STEP 3** runs vrs-python on only those (~14K vs 4.5M for a typical weekly release).
> - **gks_vrs load** (`vrs-to-bq-table.sh`, `INCREMENTAL=true` default) carries the prior
>   release's `gks_vrs` forward (CLONE) for unchanged variations and merges in the new
>   vrs-python output for changed ones (keyed on `in.variation_id`), instead of `--replace`.
>   It self-corrects to a full replace when the staged rows are not the changed subset.
>
> Because VRS normalization is per-variation (no cross-variation dependency), diffing
> `variation_identity` between releases is a clean, correct driver for this. This is
> where the ~100x payload reduction lands. **Version-invalidation:** run the extract with
> `--full` and the load with `INCREMENTAL=false` after any vrs-python or `variation_identity`
> transform change (carried-forward results assume the same normalizer + input).

## STEP 3

TODO: doc instructions on how to do this... for now
  ask TONeill to run vrs-python and put output back in same bucket

## STEP 4

run the bash script in the clinvar-ingest-bq-tools github project below
after editing it to ingest the correct bucket name and project

```
clinvar-ingest-bq-tools/gks-procs/create_gks_vrs_table.sh
``` 

This script will create the `gks_vrs` table in the `clinvar_2025_03_23_v2_3_1` dataset

verify in the bq console with the following:

```
select * from `clingen-dev.clinvar_2025_03_23_v2_3_1.gks_vrs` limit 100
```

## STEP 5 
From the BQ console

```
-- create the catvar entries and all the upstream supporting tables
CALL `clinvar_ingest.gks_catvar_proc`(CURRENT_DATE(), FALSE);

-- create the conditions, traits, condition mappings, and condition sets
CALL `clinvar_ingest.gks_scv_condition_proc`(CURRENT_DATE(), FALSE);

-- create the scv records, propositions, and final statement records (gks_dict_scv)
CALL `clinvar_ingest.gks_scv_statement_proc`(CURRENT_DATE(), FALSE);

-- aggregate into VCV and RCV statements (gks_dict_vcv, gks_dict_rcv)
CALL `clinvar_ingest.gks_vcv_proc`(CURRENT_DATE(), FALSE);
CALL `clinvar_ingest.gks_vcv_statement_proc`(CURRENT_DATE(), FALSE);
CALL `clinvar_ingest.gks_rcv_proc`(CURRENT_DATE(), FALSE);
CALL `clinvar_ingest.gks_rcv_statement_proc`(CURRENT_DATE(), FALSE);

-- NOTE: gks_json_proc is retired. Its inlined-render tables were never published;
-- the gks_dict_* tables are the product and are assembled directly at export time.

```



