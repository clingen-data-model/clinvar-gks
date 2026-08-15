# Dual Parquet Export Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export Parquet files directly from BigQuery via `bq extract --destination_format=PARQUET`, eliminating the ~600 lines of PyArrow extractor code from `assemble-gks-dicts.py`. The JSON bundle continues to be assembled from NDJSON shards as today.

**Architecture:** The export script gains a second pass that exports each dict table as Parquet to a separate GCS prefix (`gks-parquet/`). The release script downloads the Parquet files from GCS and passes them to the upload script. The assembler loses all PyArrow code — it only produces the JSON bundle. No BQ proc changes needed.

**Tech Stack:** bash, bq CLI, gsutil/gcloud, awscli (R2)

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| Modify | `src/scripts/export-gks-dicts.sh` | Add Parquet export pass for all 18 dict tables to `gks-parquet/` GCS prefix |
| Modify | `src/scripts/assemble-gks-dicts.py` | Remove all PyArrow code (~600 lines): imports, helpers, extractors, schemas, writers, `--parquet-dir` argument |
| Modify | `src/scripts/release-gks.sh` | Download Parquet from GCS after assembly; pass local dir to uploader; remove `--parquet-dir` from assembler args |
| Modify | `src/scripts/upload-gks-to-r2.sh` | No changes needed — already handles `--parquet-dir` |

---

## Current Pipeline Flow

```
Step 1: export-gks-dicts.sh
  BQ tables → bq extract (NDJSON) → gs://clinvar-gks/gks-dicts/

Step 2: assemble-gks-dicts.py
  gs://clinvar-gks/gks-dicts/ → stream NDJSON → JSON bundle + Parquet files (PyArrow)

Step 3: upload-gks-to-r2.sh
  JSON bundle + Parquet dir → R2
```

## Target Pipeline Flow

```
Step 1: export-gks-dicts.sh
  BQ tables → bq extract (NDJSON) → gs://clinvar-gks/gks-dicts/
  BQ tables → bq extract (PARQUET) → gs://clinvar-gks/gks-parquet/

Step 2: assemble-gks-dicts.py
  gs://clinvar-gks/gks-dicts/ → stream NDJSON → JSON bundle (no Parquet)

Step 3: release-gks.sh
  Download gs://clinvar-gks/gks-parquet/*.parquet → /tmp/clinvar-gks-{date}-parquet/

Step 4: upload-gks-to-r2.sh
  JSON bundle + Parquet dir → R2
```

---

## Table-to-Parquet Mapping

BigQuery `bq extract` with `--destination_format=PARQUET` preserves the table schema as-is. This means:

**Stream passthrough tables** (native BQ columns → clean typed Parquet):
- `gks_dict_variation` → `variation.parquet`
- `gks_dict_condition` → `condition.parquet`
- `gks_dict_condition_set` → `conditionSet.parquet`
- `gks_dict_scv` → `scv.parquet`
- `gks_dict_vcv` → `vcv.parquet`
- `gks_dict_rcv` → `rcv.parquet`
- `gks_dict_evidence_line` → `evidenceLine.parquet`
- `gks_dict_vcv_evidence_line` → `vcv_evidenceLine.parquet`
- `gks_dict_rcv_evidence_line` → `rcv_evidenceLine.parquet`

**Stream KV tables** (`key` STRING + `value` JSON STRING → Parquet with 2 string columns):
- `gks_dict_sequence_reference` → `sequenceReference.parquet`
- `gks_dict_location` → `location.parquet`
- `gks_dict_allele` → `allele.parquet`
- `gks_dict_copy_number_count` → `copyNumberCount.parquet`
- `gks_dict_copy_number_change` → `copyNumberChange.parquet`
- `gks_dict_gene` → `gene.parquet`
- `gks_dict_submitter` → `submitter.parquet`
- `gks_dict_proposition` → `proposition.parquet`
- `gks_dict_vcv_proposition` → `vcv_proposition.parquet`
- `gks_dict_rcv_proposition` → `rcv_proposition.parquet`

> **Note:** The KV tables will export as raw `key`/`value` columns — no typed extraction. This is a schema regression from the current PyArrow output (which has typed columns like `location_id`, `digest`, etc.). This is acceptable as a first step. A future plan can add BQ views or final-stage tables that flatten KV tables into typed columns for better Parquet schemas.

---

## Chunk 1: Tasks

### Task 1: Add Parquet export to export-gks-dicts.sh

**Files:**
- Modify: `src/scripts/export-gks-dicts.sh`

- [ ] **Step 1: Add a `extract_parquet` function**

Add a new function below the existing `extract` function:

```bash
extract_parquet() {
  local table="$1"
  local basename="$2"
  echo "  Exporting ${table} -> ${basename} (Parquet)"
  bq extract --destination_format PARQUET --compression SNAPPY \
    "${DATASET}.${table}" "${GCS_PARQUET_PATH}/${basename}"
}
```

Note: Parquet does not support wildcard sharding in `bq extract` the same way NDJSON does. Each table exports as a single file. If a table is too large for a single extract, BigQuery will auto-shard with a numeric suffix. Use a single filename (not `*` pattern).

- [ ] **Step 2: Add GCS_PARQUET_PATH variable**

After line 13 (`GCS_PATH="gs://${BUCKET}/${PREFIX}"`), add:

```bash
PARQUET_PREFIX="${PREFIX}-parquet"
GCS_PARQUET_PATH="gs://${BUCKET}/${PARQUET_PREFIX}"
```

This puts Parquet files at `gs://clinvar-gks/gks-dicts-parquet/`.

- [ ] **Step 3: Add Parquet export calls for all 18 tables**

After all existing NDJSON `extract` calls (after line 55), add a new section:

```bash
echo ""
echo "Exporting Parquet files to ${GCS_PARQUET_PATH}"

# Cat-VRS
extract_parquet gks_dict_sequence_reference sequenceReference.parquet
extract_parquet gks_dict_location location.parquet
extract_parquet gks_dict_allele allele.parquet
extract_parquet gks_dict_copy_number_count copyNumberCount.parquet
extract_parquet gks_dict_copy_number_change copyNumberChange.parquet
extract_parquet gks_dict_gene gene.parquet
extract_parquet gks_dict_variation variation.parquet

# Conditions
extract_parquet gks_dict_condition condition.parquet
extract_parquet gks_dict_condition_set conditionSet.parquet

# SCV
extract_parquet gks_dict_submitter submitter.parquet
extract_parquet gks_dict_proposition proposition.parquet
extract_parquet gks_dict_evidence_line evidenceLine.parquet

# VCV/RCV
extract_parquet gks_dict_vcv_proposition vcv_proposition.parquet
extract_parquet gks_dict_vcv_evidence_line vcv_evidenceLine.parquet
extract_parquet gks_dict_rcv_proposition rcv_proposition.parquet
extract_parquet gks_dict_rcv_evidence_line rcv_evidenceLine.parquet

# Statements
extract_parquet gks_dict_scv scv.parquet
extract_parquet gks_dict_vcv vcv.parquet
extract_parquet gks_dict_rcv rcv.parquet
```

- [ ] **Step 4: Update completion message**

Change the final echo to:

```bash
echo "Done. NDJSON exported to ${GCS_PATH}/"
echo "      Parquet exported to ${GCS_PARQUET_PATH}/"
```

- [ ] **Step 5: Test the export**

Run:
```bash
./src/scripts/export-gks-dicts.sh clinvar_2026_06_27_v2_5_0 clinvar-gks gks-dicts
```

Verify both NDJSON and Parquet files exist:
```bash
gsutil ls gs://clinvar-gks/gks-dicts/
gsutil ls gs://clinvar-gks/gks-dicts-parquet/
```

- [ ] **Step 6: Commit**

```bash
git add src/scripts/export-gks-dicts.sh
git commit -m "feat: add Parquet export alongside NDJSON in export script"
```

---

### Task 2: Remove all PyArrow code from assemble-gks-dicts.py

**Files:**
- Modify: `src/scripts/assemble-gks-dicts.py`

This removes ~600 lines of code. The assembler will only produce the JSON bundle.

- [ ] **Step 1: Remove the pyarrow import block (lines 61-67)**

Remove:
```python
# pyarrow is optional — only needed when --parquet-dir is used
try:
    import pyarrow as pa
    import pyarrow.parquet as pq
    _PYARROW_AVAILABLE = True
except ImportError:
    _PYARROW_AVAILABLE = False
```

- [ ] **Step 2: Remove all Parquet helper functions (lines 98-727)**

Remove everything from `PARQUET_BATCH_SIZE = 10_000` through `close_parquet_writers()`. This includes:
- `PARQUET_BATCH_SIZE`, `SIMPLE_COLS`
- All helper functions: `_ref`, `_ref_if`, `_name`, `_exact_pos`, `_range_pos`, `_state_len_min`, `_state_len_max`, `_iris`, `_coding`, `_mappings`, `_extensions`, `_exprs`, `_concept_label`, `_constraints`, `_mappable_concept`, `_contributions`, `_reported_in`, `_specified_by`
- All PyArrow type definitions: `_CODING_TYPE`, `_MAPPING_TYPE`, etc.
- `_COLUMN_TYPES`, `_make_schema`, `SIMPLE_SCHEMA`
- `PARQUET_SECTION_CONFIGS` dict (all 15 section extractors)
- `open_parquet_writers`, `_flush_parquet`, `_add_parquet_record`, `close_parquet_writers`

- [ ] **Step 3: Remove `--parquet-dir` from the `assemble()` function**

In the `assemble()` function signature, remove the `parquet_dir=None` parameter.

Remove all Parquet-related code inside `assemble()`:
- The `parquet_writers = open_parquet_writers(...)` call
- All `_add_parquet_record(...)` calls (in both `stream_passthrough` and `stream_kv` branches)
- The `close_parquet_writers(...)` call in the finally block
- Any Parquet stats logging

- [ ] **Step 4: Remove `--parquet-dir` argparse argument**

In `main()`, remove:
- The `parser.add_argument("--parquet-dir", ...)` line
- The `if args.parquet_dir and not _PYARROW_AVAILABLE:` check
- The `parquet_dir=args.parquet_dir` kwarg in the `assemble()` call

- [ ] **Step 5: Update the module docstring**

Remove the `--parquet-dir` usage example and the `pip install pyarrow` dependency line.

- [ ] **Step 6: Verify the assembler still works**

Run with a small local test if NDJSON shards are available, or verify syntax:
```bash
python3 -c "import ast; ast.parse(open('src/scripts/assemble-gks-dicts.py').read()); print('OK')"
```

- [ ] **Step 7: Commit**

```bash
git add src/scripts/assemble-gks-dicts.py
git commit -m "refactor: remove PyArrow code from assembler — Parquet now exported directly from BigQuery"
```

---

### Task 3: Update release-gks.sh to download Parquet from GCS

**Files:**
- Modify: `src/scripts/release-gks.sh`

- [ ] **Step 1: Add GCS Parquet path variable**

After `GCS_DICTS_PATH` (line 65), add:

```bash
GCS_PARQUET_PREFIX="${GCS_DICTS_PREFIX}-parquet"
GCS_PARQUET_PATH="gs://${GCS_BUCKET}/${GCS_PARQUET_PREFIX}"
```

- [ ] **Step 2: Update the export step (Step 1) to clear Parquet prefix too**

In the Step 1 block, add a clear for the Parquet prefix before export:

```bash
echo "  Clearing ${GCS_PARQUET_PATH}/ ..."
gsutil -m -q rm -r "${GCS_PARQUET_PATH}/" 2>/dev/null || true
```

- [ ] **Step 3: Remove `--parquet-dir` from assembler args**

Change line 118 from:
```bash
ASSEMBLE_ARGS=("${GCS_DICTS_PATH}/" "${EXPORT_DATE}" "--parquet-dir=${PARQUET_DIR}")
```
to:
```bash
ASSEMBLE_ARGS=("${GCS_DICTS_PATH}/" "${EXPORT_DATE}")
```

- [ ] **Step 4: Add Parquet download step between Step 2 and Step 3**

After the assembler runs and before the upload step, add a new step to download Parquet files from GCS:

```bash
# =====================================================================
# Step 2b: Download Parquet files from GCS
# =====================================================================

echo "=== Step 2b: Downloading Parquet files from GCS ==="
if $DRY_RUN; then
  echo "  [dry-run] Would download ${GCS_PARQUET_PATH}/*.parquet to ${PARQUET_DIR}/"
else
  mkdir -p "${PARQUET_DIR}"
  gsutil -m cp "${GCS_PARQUET_PATH}/*.parquet" "${PARQUET_DIR}/"
  echo "  Downloaded $(ls -1 "${PARQUET_DIR}"/*.parquet 2>/dev/null | wc -l) Parquet files"
fi
echo ""
```

- [ ] **Step 5: Update `--start-step` to account for new step**

The start-step logic needs to handle skipping the Parquet download when resuming from step 3. Wrap the download in:
```bash
if [[ "$START_STEP" -le 2 ]]; then
  ...
fi
```

This keeps it aligned with the assembler step — if you skip the assembler, you also skip the download (the Parquet files should already be in GCS from a prior export).

- [ ] **Step 6: Clean up GCS Parquet shards after upload (unless --keep-source)**

After the upload step completes, before the local cleanup:

```bash
if ! $DRY_RUN && ! $KEEP_SOURCE; then
  echo "  Cleaning up GCS Parquet files..."
  gsutil -m -q rm -r "${GCS_PARQUET_PATH}/" 2>/dev/null || true
fi
```

- [ ] **Step 7: Commit**

```bash
git add src/scripts/release-gks.sh
git commit -m "feat: download Parquet from GCS instead of generating via PyArrow"
```

---

### Task 4: Validate end-to-end

- [ ] **Step 1: Run a full dry-run**

```bash
./src/scripts/release-gks.sh 2026-06-27 v2_5_0 --dry-run
```

Verify the output shows all three steps including Parquet download.

- [ ] **Step 2: Run the export step only**

```bash
./src/scripts/export-gks-dicts.sh clinvar_2026_06_27_v2_5_0 clinvar-gks gks-dicts
```

Verify both NDJSON and Parquet files in GCS:
```bash
gsutil ls gs://clinvar-gks/gks-dicts/ | head -5
gsutil ls gs://clinvar-gks/gks-dicts-parquet/ | head -5
```

- [ ] **Step 3: Verify Parquet file count matches expectations**

```bash
gsutil ls gs://clinvar-gks/gks-dicts-parquet/*.parquet | wc -l
```

Expected: 19 files (18 tables + possible auto-sharding for large tables).

Note: `bq extract` to Parquet may auto-shard large tables (e.g., `allele` with ~17M rows) into multiple files like `allele.parquet`, `allele-000000000001.parquet`, etc. The upload script's glob `*.parquet` handles this naturally. If sharding occurs, the section will have multiple Parquet files in R2 — consumers can use tools like DuckDB's `read_parquet('*.parquet')` to read them.

- [ ] **Step 4: Spot-check a Parquet file**

Download one and inspect with DuckDB or Python:
```bash
gsutil cp gs://clinvar-gks/gks-dicts-parquet/gene.parquet /tmp/
python3 -c "
import pyarrow.parquet as pq
t = pq.read_table('/tmp/gene.parquet')
print(t.schema)
print(t.num_rows)
print(t.to_pandas().head(3))
"
```

- [ ] **Step 5: Commit any fixes**

If any issues found, fix and commit.

---

## Chunk 2: Future Improvements (not in scope)

These are documented for future reference but are NOT part of this plan:

1. **Typed Parquet for KV tables**: Create BQ views that flatten `key`/`value` into typed columns, then export those views as Parquet. This would restore the typed column schemas that the PyArrow extractors provided.

2. **Parquet versioning in R2**: Currently all Parquet files go to `datasets/parquet/` and are overwritten each release. Consider versioned paths like `datasets/parquet/{date}/`.

3. **Remove NDJSON export**: If the JSON bundle format is eventually retired, the NDJSON export step could be removed entirely, leaving only Parquet.
