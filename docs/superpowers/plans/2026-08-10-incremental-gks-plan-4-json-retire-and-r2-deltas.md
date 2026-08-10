# Incremental GKS Plan 4 — `gks_json` Retirement + R2 Delta Publishing Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire the vestigial `gks_json_proc` from the incremental hot path, publish per-release delta artifacts to R2 (weekly deltas + month-end retroactive full), and give the JSON bundle the null/empty cleanup `gks_json` used to provide.

**Architecture:** No new BigQuery compute — `gks_delta_build` already materializes `delta_<dict>` (A∪U rows) and `gks_change_log` holds the A/U/D slice. Plan 4 is a publish-layer + retirement change: (A) drop `gks_json_proc` from the pipeline and from `gks_change_log` tracking; (B) a delta export/assemble/manifest/upload path mirroring the existing full-bundle scripts, with cadence = deltas weekly / full only at month-end (retroactive); (C) a recursive null/empty strip in the assemble layer. Correctness for (B) is gated by a delta-reconstruction oracle (`baseline − D − U_old + delta(A∪U) == current full`, per section, via `gks_oracle_compare`).

**Tech Stack:** BigQuery stored procedures (`bq`), bash orchestration scripts, Python 3.12 (`venv/3.12`, `pytest` 9.0.2, `orjson`), Cloudflare R2 via `aws s3` (profile `r2`), GCS via `gsutil`/`bq extract`/`EXPORT DATA`, DuckDB (Parquet shard merge), MkDocs.

**Spec:** `docs/superpowers/specs/2026-08-09-incremental-gks-plan-4-json-retire-and-r2-deltas-design.md` — read it for rationale; this plan is the executable steps.

**Branch:** `feat/incremental-gks-json-r2delta-plan4` (already created off the Plan 3 branch).

**Project / test pair:** BigQuery project `clingen-dev`. Deploy a proc with
`bq query --project_id=clingen-dev --use_legacy_sql=false < src/procedures/<file>.sql`.
Oracle test pair: baseline **2026-07-15**, compare **2026-07-20**
(`clinvar_2026_07_15_v2_5_0` / `clinvar_2026_07_20_v2_5_0`).

**Global conventions for every task below:**
- Run Python via `venv/3.12/bin/python3` (fallback `python3`).
- After any BQ oracle/verification, **clean up** `*_recon` / `*_oracle_*` scratch datasets.
- Commit after each task with the message shown. Do NOT include "Generated with Claude Code" or "Co-Authored-By" lines (repo convention, `CLAUDE.md`).
- Heavy BQ jobs: drive via a background bash command (survives across turns) rather than polling.

---

## Chunk 1: Retire `gks_json` from the hot path (Piece A)

Piece (A) is mechanical but **internally coupled**: the `gks_change_log` tracked-array edit and the pipeline-call removal must land in the same change, because once `gks_json_proc` stops running, `{S}.gks_catvar` / `gks_scv_statement` / `gks_rcv_statement` / `gks_vcv_statement` are not (re)created and `gks_change_log` would error at analysis time diffing a non-existent table.

### Task 1.1: Remove the 4 JSON-render outputs from `gks_change_log` tracking

**Files:**
- Modify: `src/procedures/gks-change-log-proc.sql:38-41`

- [ ] **Step 1: Edit the `tracked` array** — delete the first four entries (the JSON renders), keeping the dict entries. The array currently starts:

```sql
  DECLARE tracked ARRAY<STRUCT<name STRING, pk STRING>> DEFAULT [
    STRUCT('gks_catvar'        AS name, 'id' AS pk),
    STRUCT('gks_scv_statement',       'id'),
    STRUCT('gks_rcv_statement',       'id'),
    STRUCT('gks_vcv_statement',       'id'),
    -- catvar outputs (Plan 1)
    STRUCT('gks_dict_variation',              'id'),
```

Change it to (the `STRUCT<...>` type annotation must move to the first surviving entry):

```sql
  DECLARE tracked ARRAY<STRUCT<name STRING, pk STRING>> DEFAULT [
    -- catvar outputs (Plan 1). NOTE: the gks_json JSON-render outputs (gks_catvar,
    -- gks_scv_statement, gks_rcv_statement, gks_vcv_statement) were REMOVED in Plan 4 —
    -- gks_json_proc is retired from the hot path, so those tables are no longer built and
    -- must not be diffed here (missing-table analysis error). The published product is the
    -- gks_dict_* set below.
    STRUCT('gks_dict_variation'        AS name, 'id' AS pk),
    STRUCT('gks_dict_sequence_reference',     'key'),
```

Leave every other entry unchanged.

- [ ] **Step 2: Deploy the edited proc**

Run: `bq query --project_id=clingen-dev --use_legacy_sql=false < src/procedures/gks-change-log-proc.sql`
Expected: `Created ...clinvar_ingest.gks_change_log` (no error).

- [ ] **Step 3: Verify change-log runs clean and no longer emits the retired tables**

Run (on the existing compare dataset, which still has the old gks_json tables from a prior run — proves the retired names are simply not looked up):
```bash
bq query --project_id=clingen-dev --use_legacy_sql=false \
 "CALL \`clinvar_ingest.gks_change_log\`(DATE '2026-07-20');
  SELECT COUNTIF(table_name IN ('gks_catvar','gks_scv_statement','gks_rcv_statement','gks_vcv_statement')) AS retired_rows,
         COUNT(DISTINCT table_name) AS tables_with_changes
  FROM \`clinvar_2026_07_20_v2_5_0.gks_change_log\`"
```
Expected (hard assertion): `retired_rows = 0` and no error. `tables_with_changes` is only the tracked tables that had ≥1 A/U/D row this week (≤ 20 — low-churn dicts can legitimately have zero), so do **not** assert `== 20`; the real invariant is that none of the four retired names appear.

- [ ] **Step 4: Commit**

```bash
git add src/procedures/gks-change-log-proc.sql
git commit -m "feat(delta): drop retired gks_json render outputs from gks_change_log tracking"
```

### Task 1.2: Remove the `gks_json_proc` call from the pipeline

**Files:**
- Modify: `src/scripts/vrs-to-bq-table.sh:246-250`

- [ ] **Step 1: Delete the gks_json call block.** Remove exactly these lines (the block between the rcv/vcv loop and the `gks_change_log` call):

```bash
  echo "  - Calling procedure: clinvar_ingest.gks_json_proc..."
  if ! bq --project_id="$PROJECT_ID" query --quiet --use_legacy_sql=false "CALL \`clinvar_ingest.gks_json_proc\`('$release_date', 'all')" > /dev/null; then
    echo "❌ Procedure call FAILED for: clinvar_ingest.gks_json_proc"; return 1;
  fi
  echo "    ✅ Success."

```

So `gks_change_log` now runs immediately after the rcv/vcv loop.

- [ ] **Step 2: Update the surrounding comment.** In the NOTE block near line 70-73, add a line noting `gks_json_proc` is retired (Plan 4) and the dicts are the published product. Verify no other line in this file references `gks_json`:

Run: `grep -n gks_json src/scripts/vrs-to-bq-table.sh`
Expected: only the comment you just added (no `CALL`).

- [ ] **Step 3: Commit**

```bash
git add src/scripts/vrs-to-bq-table.sh
git commit -m "feat(delta): retire gks_json_proc from the incremental pipeline (unpublished renders)"
```

### Task 1.3: Correct the stale pipeline docs for the retired step

**Files:**
- Modify: `docs/pipeline/index.md` (step 8 "JSON Output" block, ~lines 56-63)

- [ ] **Step 1: Fix the step-8 description.** The current block wrongly says `gks_json_proc` "Build dictionary tables → gks_dict_* tables" (the dicts are built by the upstream catvar/scv/rcv/vcv procs). Replace the step-8 box content to state the dicts are the published product assembled directly (no `gks_json_proc` step), e.g.:

```
┌──────────────▼───────────────┐
│ 8. Change log + deltas       │  gks_change_log +
│    A/U/D per dict + delta     │  gks_delta_build
│    payloads for publishing    │  → gks_change_log, delta_<dict>
└──────────────┬───────────────┘
```

(Adjust adjacent step numbers/arrows so the diagram stays consistent. `gks_json_proc` is no longer in the flow.)

- [ ] **Step 1b: Sweep remaining stale `gks_json` references.** Also remove/annotate the runnable example `CALL clinvar_ingest.gks_json_proc(CURRENT_DATE(), 'all');` at `docs/pipeline/index.md:113` (drop it or mark it retired). Then confirm no other live doc/script still invokes it:

Run: `grep -rn "gks_json_proc" docs/ src/scripts/ | grep -v "archive/"`
Expected: no `CALL`/invocation lines remain (comments noting the retirement are fine). Optionally tidy the now-stale proc comments in `src/procedures/gks-change-log-proc.sql:58-60` (the "gks_rcv_statement/gks_vcv_statement JSON renders above" phrasing) — those renders are no longer tracked.

- [ ] **Step 2: Validate docs build**

Run: `venv/3.12/bin/python3 -m mkdocs build --strict` (or `mkdocs build --strict`)
Expected: build succeeds, no warnings.

- [ ] **Step 3: Commit**

```bash
git add docs/pipeline/index.md
git commit -m "docs: correct pipeline step 8 for retired gks_json (dicts are the product)"
```

---

## Chunk 2: Bundle JSON null/empty cleanup (Piece C)

Extract the strip into an importable module (`assemble-gks-dicts.py` has hyphens and can't be imported), TDD it, then wire it into the assembler. Applies to BOTH the full and delta bundles. JSON only — Parquet untouched.

**Semantics (match `JSON_STRIP_NULLS(remove_empty => TRUE)` for our data shapes):** recursively (1) drop object keys whose value is `null`, `{}`, or `[]` (after stripping); (2) strip the internals of array elements but **keep** array elements (SQL arrays never contain NULL elements — `CLAUDE.md` gotcha — and dropping non-empty elements would change array length); (3) preserve falsy scalars `0`, `false`, `""`. This is a deliberately conservative divergence from `JSON_STRIP_NULLS` (which may drop empty-object array elements); the cleanup is publish-only so it cannot affect the delta/oracle correctness.

### Task 2.1: TDD the strip function

**Files:**
- Create: `src/scripts/gks_json_cleanup.py`
- Create: `src/scripts/tests/test_gks_json_cleanup.py`

- [ ] **Step 1: Write the failing test**

```python
# src/scripts/tests/test_gks_json_cleanup.py
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gks_json_cleanup import strip_empty


def test_drops_empty_array_field():
    assert strip_empty({"name": "Benign", "extensions": []}) == {"name": "Benign"}


def test_drops_null_and_empty_object_fields():
    assert strip_empty({"a": None, "b": {}, "c": 1}) == {"c": 1}


def test_recurses_into_nested_objects():
    assert strip_empty({"x": {"y": [], "z": "k"}}) == {"x": {"z": "k"}}


def test_object_that_becomes_empty_is_dropped():
    assert strip_empty({"outer": {"inner": []}}) == {}


def test_preserves_falsy_scalars():
    assert strip_empty({"n": 0, "b": False, "s": ""}) == {"n": 0, "b": False, "s": ""}


def test_keeps_array_elements_but_strips_their_internals():
    assert strip_empty({"items": [{"k": "v", "e": []}, {"k": "w"}]}) == {
        "items": [{"k": "v"}, {"k": "w"}]
    }


def test_top_level_list_is_cleaned_elementwise():
    assert strip_empty([{"a": []}, {"b": 2}]) == [{}, {"b": 2}]


def test_idempotent_on_clean_input():
    clean = {"name": "x", "items": [{"k": "v"}]}
    assert strip_empty(clean) == clean
    assert strip_empty(strip_empty(clean)) == clean
```

- [ ] **Step 2: Run to verify it fails**

Run: `venv/3.12/bin/python3 -m pytest src/scripts/tests/test_gks_json_cleanup.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'gks_json_cleanup'`.

- [ ] **Step 3: Implement the module**

```python
# src/scripts/gks_json_cleanup.py
"""Recursively drop null / empty-array / empty-object values from a decoded JSON
value, matching JSON_STRIP_NULLS(remove_empty => TRUE) for our data shapes.

Used by assemble-gks-dicts.py so the published bundle (full + delta) has the same
cleanup gks_json_proc used to apply. Publish-layer only — never touches BigQuery
tables, so it cannot affect delta/change-log/oracle correctness.

Rules:
  * dict: drop keys whose stripped value is None, {} or [].
  * list: strip each element's internals but KEEP elements (SQL arrays hold no NULL
    elements; dropping non-empty elements would change array length).
  * scalars: returned unchanged (0 / False / "" are preserved).
"""


def _is_empty(v):
    return v is None or (isinstance(v, (dict, list)) and len(v) == 0)


def strip_empty(value):
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            sv = strip_empty(v)
            if not _is_empty(sv):
                out[k] = sv
        return out
    if isinstance(value, list):
        return [strip_empty(v) for v in value]
    return value
```

- [ ] **Step 4: Run to verify it passes**

Run: `venv/3.12/bin/python3 -m pytest src/scripts/tests/test_gks_json_cleanup.py -v`
Expected: 8 passed.

- [ ] **Step 5: Commit**

```bash
git add src/scripts/gks_json_cleanup.py src/scripts/tests/test_gks_json_cleanup.py
git commit -m "feat(publish): add JSON null/empty strip (remove_empty parity) + tests"
```

### Task 2.2: Wire the strip into `assemble-gks-dicts.py`

**Files:**
- Modify: `src/scripts/assemble-gks-dicts.py` (imports; `stream_passthrough`; `stream_kv`)

The assembler currently passes the raw NDJSON line through for `value_field is None` sections and re-serializes only KV values. To apply cleanup uniformly we must parse → strip → re-serialize the record in both paths. This trades the raw-line optimization for correctness (acceptable: full assembly is now monthly, delta is small).

- [ ] **Step 1: Add the import** near the top (after the orjson try/except block):

```python
from gks_json_cleanup import strip_empty
```
Add `import os, sys` if not present and, before the import, ensure the script dir is importable:
```python
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
```

- [ ] **Step 2: Clean the passthrough path.** Change `stream_passthrough` so the emitted value is the stripped record (not the raw line):

```python
def stream_passthrough(filepath, key_field):
    """Yield (key_json, value_json) pairs; the value is the record with null/empty
    values stripped (remove_empty parity)."""
    with open_local_file(filepath) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json_loads(line)
            cleaned = strip_empty(rec)
            yield json_dumps_key(rec[key_field]), json_dumps_key(cleaned)
```
(Note: `json_dumps_key` uses orjson/stdlib `dumps`; it serializes any JSON value, not just keys — the name is historical.)

- [ ] **Step 3: Clean the KV path.** In `stream_kv`, strip the value before emitting. The value may be a JSON string (KV dicts store `value` as a JSON string) or an object:

```python
def stream_kv(filepath, key_field, value_field):
    with open_local_file(filepath) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json_loads(line)
            key_json = json_dumps_key(rec[key_field])
            raw = rec[value_field]
            obj = json_loads(raw) if isinstance(raw, str) else raw
            value_json = json_dumps_key(strip_empty(obj))
            yield key_json, value_json
```

(KV-dict sections are already `remove_empty`-clean in SQL, so `strip_empty` is a no-op there — idempotent — but this keeps one uniform contract.)

- [ ] **Step 4: Update the assemble() writer for stream_passthrough.** The `value_field is None` branch in `assemble()` currently writes `f"    {key_json}: {raw_json}"`. Since `stream_passthrough` now yields `(key_json, value_json)` exactly like `stream_kv`, unify both branches to write `f"    {key_json}: {value_json}"`. Verify by reading the two loops in `assemble()` (~lines 219-240) and collapsing them to a single value-emitting loop over whichever streamer applies.

- [ ] **Step 5: Smoke-test on a tiny local sample**

```bash
mkdir -p /tmp/gks-clean-test
printf '%s\n' '{"id":"clinvar:1","type":"CategoricalVariant","name":"x","members":[],"mappings":[{"relation":"exactMatch","coding":{"iris":[]}}]}' \
  | gzip > /tmp/gks-clean-test/variation-000000000000.ndjson.gz
venv/3.12/bin/python3 src/scripts/assemble-gks-dicts.py /tmp/gks-clean-test/ 2026-07-20 --keep-source
gunzip -c /tmp/clinvar-gks-2026-07-20.json.gz
```
Expected: the emitted `variation` entry has **no** `"members":[]` and no `"iris":[]` (empties stripped), but keeps `type`/`name`/`relation`/`coding`. Clean up `/tmp/gks-clean-test` and `/tmp/clinvar-gks-2026-07-20.json.gz`.

- [ ] **Step 6: Commit**

```bash
git add src/scripts/assemble-gks-dicts.py
git commit -m "feat(publish): apply JSON null/empty strip during bundle assembly (full + delta)"
```

---

## Chunk 3: Delta export + assemble + manifest + reconstruction oracle (Piece B, part 1)

Produce the weekly delta artifacts from the already-built `delta_<dict>` tables and prove them correct with the reconstruction oracle before touching R2 (Chunk 4).

**Section → delta table(s) map** (mirrors `assemble-gks-dicts.py` `SECTIONS`; merged sections union 3 tables under one basename):

| Section | Basename | Delta table(s) | key |
|---|---|---|---|
| sequenceReference | `sequenceReference` | `delta_gks_dict_sequence_reference` | key |
| location | `location` | `delta_gks_dict_location` | key |
| allele | `allele` | `delta_gks_dict_allele` | key |
| copyNumberCount | `copyNumberCount` | `delta_gks_dict_copy_number_count` | key |
| copyNumberChange | `copyNumberChange` | `delta_gks_dict_copy_number_change` | key |
| gene | `gene` | `delta_gks_dict_gene` | key |
| variation | `variation` | `delta_gks_dict_variation` | id |
| condition | `condition` | `delta_gks_dict_condition` | id |
| conditionSet | `conditionSet` | `delta_gks_dict_condition_set` | id |
| submitter | `submitter` | `delta_gks_dict_submitter` | key |
| proposition | `proposition` / `vcv_proposition` / `rcv_proposition` | `delta_gks_dict_proposition`, `delta_gks_dict_vcv_proposition`, `delta_gks_dict_rcv_proposition` | key |
| evidenceLine | `evidenceLine` / `vcv_evidenceLine` / `rcv_evidenceLine` | `delta_gks_dict_evidence_line`, `delta_gks_dict_vcv_evidence_line`, `delta_gks_dict_rcv_evidence_line` | id |
| scv | `scv` | `delta_gks_dict_scv` | id |
| vcv | `vcv` | `delta_gks_dict_vcv` | id |
| rcv | `rcv` | `delta_gks_dict_rcv` | id |

### Task 3.1: Add `--delta` mode to `export-gks-dicts.sh`

**Files:**
- Modify: `src/scripts/export-gks-dicts.sh`

The delta tables have **identical schema** to their base dicts (`delta_<T>` = `SELECT src.*`), so the same NDJSON extract and typed-Parquet SQL work unchanged apart from the source table name. Every `parquet-schemas/*.sql` references exactly one `{DATASET}.gks_dict_*` table (verified), so a `.gks_dict_` → `.delta_gks_dict_` substitution is safe.

- [ ] **Step 1: Add a `--delta` flag + table-name helper.** In the flag parse loop add `--delta) DELTA=true ;;` (default `DELTA=false`). Add a helper that maps a base table to the source table:

```bash
src_table() {           # $1 = base dict table, e.g. gks_dict_scv
  if $DELTA; then echo "delta_$1"; else echo "$1"; fi
}
```

- [ ] **Step 2: Route NDJSON + raw-Parquet extracts through `src_table`.** Change `extract` and `extract_parquet` call sites so the BQ source is `$(src_table <table>)` while the output basename stays the section name. E.g. `extract "$(src_table gks_dict_scv)" scv.ndjson.gz`. Keep output basenames unchanged (so assembly is identical).

- [ ] **Step 3: Route typed-Parquet through the delta substitution.** In `extract_parquet_typed`, after the `{DATASET}` substitution, add (delta mode only):

```bash
  if $DELTA; then
    sql="${sql//.gks_dict_/.delta_gks_dict_}"
  fi
```

- [ ] **Step 4: Confirm the GCS prefix already parameterizes output — no change needed.** `export-gks-dicts.sh:14` already takes the 3rd positional `PREFIX="${3:-gks-dicts}"` and derives both `GCS_PATH` and `PARQUET_PREFIX`/`GCS_PARQUET_PATH` from it, so delta runs just pass `gks-deltas` as the prefix (Task 3.2 does this). Do **not** add a 4th positional or `--gcs-prefix=` (would collide with the new `--delta` flag in the `for arg` loop). Keep only the `--delta` / `src_table` / typed-substitution edits from Steps 1-3.

- [ ] **Step 5: Manual verify (delta export to a scratch GCS prefix)**

```bash
src/scripts/export-gks-dicts.sh clinvar_2026_07_20_v2_5_0 clinvar-gks gks-deltas-test --delta
gsutil ls gs://clinvar-gks/gks-deltas-test/ | head
gsutil ls gs://clinvar-gks/gks-deltas-test-parquet/ | head
```
Expected: NDJSON + Parquet shards named by section (`scv-*.ndjson.gz`, `proposition-*` from 3 tables, etc.), containing only A∪U rows. Clean up: `gsutil -m rm -r gs://clinvar-gks/gks-deltas-test/ gs://clinvar-gks/gks-deltas-test-parquet/`.

- [ ] **Step 6: Commit**

```bash
git add src/scripts/export-gks-dicts.sh
git commit -m "feat(delta): --delta export mode over delta_<dict> tables (NDJSON + typed Parquet)"
```

### Task 3.2: Delta orchestrator `release-gks-delta.sh`

**Files:**
- Create: `src/scripts/release-gks-delta.sh`

Mirrors `release-gks.sh` steps 1-3 but on delta tables and with a different output name + GCS prefix; adds a manifest step (Task 3.3); hands the delta dir to the delta uploader (Task 4.2). This task creates the export+assemble+manifest orchestration; the upload call is stubbed until Chunk 4.

- [ ] **Step 1: Write the script.** Full content:

```bash
#!/bin/bash
# Release the per-release GKS DELTA: export delta_<dict> tables, assemble a delta
# bundle, merge delta Parquet, build manifest.json, upload the delta tree to R2.
#
# Usage: ./release-gks-delta.sh <export_date> <dataset_version> [--start-step=N] [--dry-run]
set -e
[[ $# -lt 2 ]] && { echo "Usage: $0 <export_date> <dataset_version> [--start-step=N] [--dry-run]"; exit 1; }
EXPORT_DATE="$1"; DATASET_VERSION="$2"; shift 2
[[ "$EXPORT_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "ERROR: bad date '${EXPORT_DATE}'"; exit 1; }

DRY_RUN=false; START_STEP=1
for arg in "$@"; do case "$arg" in
  --dry-run) DRY_RUN=true ;;
  --start-step=*) START_STEP="${arg#--start-step=}" ;;
  *) echo "ERROR: unknown arg '${arg}'"; exit 1 ;;
esac; done

GCS_BUCKET="clinvar-gks"
GCS_DELTAS_PREFIX="gks-deltas"
GCS_DELTAS_PATH="gs://${GCS_BUCKET}/${GCS_DELTAS_PREFIX}"
GCS_DELTAS_PARQUET_PATH="gs://${GCS_BUCKET}/${GCS_DELTAS_PREFIX}-parquet"
DATE_US="${EXPORT_DATE//-/_}"
BQ_DATASET="clinvar_${DATE_US}_${DATASET_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON="python3"; [[ -x "${PROJECT_ROOT}/venv/3.12/bin/python3" ]] && PYTHON="${PROJECT_ROOT}/venv/3.12/bin/python3"

DELTA_BUNDLE="/tmp/clinvar-gks-delta-${EXPORT_DATE}.json.gz"
DELTA_PARQUET_DIR="/tmp/clinvar-gks-delta-${EXPORT_DATE}-parquet"
MANIFEST_FILE="/tmp/clinvar-gks-delta-${EXPORT_DATE}-manifest.json"

echo "=== ClinVar-GKS DELTA release ${EXPORT_DATE} (dataset ${BQ_DATASET}) ==="
$DRY_RUN && echo "  Mode: DRY RUN"

# Step 1: export delta tables -> GCS
if (( START_STEP <= 1 )); then
  echo "=== [1/4] export delta tables ==="
  if $DRY_RUN; then
    echo "  [dry-run] export-gks-dicts.sh ${BQ_DATASET} ${GCS_BUCKET} ${GCS_DELTAS_PREFIX} --delta"
  else
    gsutil -m -q rm -r "${GCS_DELTAS_PATH}/" 2>/dev/null || true
    gsutil -m -q rm -r "${GCS_DELTAS_PARQUET_PATH}/" 2>/dev/null || true
    "${SCRIPT_DIR}/export-gks-dicts.sh" "${BQ_DATASET}" "${GCS_BUCKET}" "${GCS_DELTAS_PREFIX}" --delta
  fi
fi

# Step 2: assemble delta NDJSON -> delta bundle (with cleanup)
if (( START_STEP <= 2 )); then
  echo "=== [2/4] assemble delta bundle ==="
  if $DRY_RUN; then
    echo "  [dry-run] assemble-gks-dicts.py ${GCS_DELTAS_PATH}/ ${EXPORT_DATE} --delta-name"
  else
    "${PYTHON}" "${SCRIPT_DIR}/assemble-gks-dicts.py" "${GCS_DELTAS_PATH}/" "${EXPORT_DATE}" --output "${DELTA_BUNDLE}"
  fi
fi

# Step 3: download + merge delta Parquet shards -> per-section parquet
if (( START_STEP <= 3 )); then
  echo "=== [3/4] merge delta Parquet ==="
  if $DRY_RUN; then
    echo "  [dry-run] download+merge ${GCS_DELTAS_PARQUET_PATH}/ -> ${DELTA_PARQUET_DIR}/"
  else
    mkdir -p "${DELTA_PARQUET_DIR}"; SH="${DELTA_PARQUET_DIR}/_gcs"; mkdir -p "${SH}"
    gsutil -m cp "${GCS_DELTAS_PARQUET_PATH}/*.parquet" "${SH}/" 2>/dev/null || echo "  (no delta parquet shards)"
    for first in "${SH}"/*-000000000000.parquet; do
      [ -f "$first" ] || continue
      base="$(basename "$first" | sed 's/-000000000000\.parquet//')"
      duckdb -c "COPY (SELECT * FROM read_parquet('${SH}/${base}-*.parquet')) TO '${DELTA_PARQUET_DIR}/${base}.parquet' (FORMAT PARQUET, COMPRESSION SNAPPY);"
    done
    rm -rf "${SH}"
  fi
fi

# Step 4: build manifest + upload delta tree (upload wired in Chunk 4)
if (( START_STEP <= 4 )); then
  echo "=== [4/4] manifest + upload ==="
  MANIFEST_ARGS=("${EXPORT_DATE}" "${DATASET_VERSION}" "${MANIFEST_FILE}")
  if $DRY_RUN; then
    echo "  [dry-run] build-delta-manifest.py ${MANIFEST_ARGS[*]}"
  else
    "${PYTHON}" "${SCRIPT_DIR}/build-delta-manifest.py" "${MANIFEST_ARGS[@]}"
  fi
  UPLOAD_ARGS=("${EXPORT_DATE}" "${DELTA_BUNDLE}" "${MANIFEST_FILE}" "--parquet-dir=${DELTA_PARQUET_DIR}")
  $DRY_RUN && UPLOAD_ARGS+=("--dry-run")
  "${SCRIPT_DIR}/upload-gks-delta-to-r2.sh" "${UPLOAD_ARGS[@]}"
fi

if ! $DRY_RUN; then rm -f "${DELTA_BUNDLE}" "${MANIFEST_FILE}"; rm -rf "${DELTA_PARQUET_DIR}"; fi
echo "=== DELTA release ${EXPORT_DATE} complete ==="
```

- [ ] **Step 2: Add an `--output` option to `assemble-gks-dicts.py`.** Currently the output path is derived from the date (`/tmp/clinvar-gks-{date}.json.gz`). Add an optional `--output PATH` arg that overrides `derive_output_path`. Keep the default behavior when absent. (This lets the delta bundle be named `clinvar-gks-delta-{date}.json.gz`.) Update the module docstring/Usage block (lines ~8, 11-22) to document `--output`.

- [ ] **Step 3: `chmod +x` + syntax check**

Run: `chmod +x src/scripts/release-gks-delta.sh && bash -n src/scripts/release-gks-delta.sh && venv/3.12/bin/python3 -c "import ast; ast.parse(open('src/scripts/assemble-gks-dicts.py').read())"`
Expected: no syntax errors. (Don't `bash -n` the `.py` — it's Python; the `ast.parse` is the real check.)

- [ ] **Step 4: Commit**

```bash
git add src/scripts/release-gks-delta.sh src/scripts/assemble-gks-dicts.py
git commit -m "feat(delta): release-gks-delta.sh orchestrator + assemble --output override"
```

### Task 3.3: Manifest builder `build-delta-manifest.py`

**Files:**
- Create: `src/scripts/build-delta-manifest.py`

Reads `{dataset}.gks_change_log` for the release via `bq query`, maps `table_name` → bundle section, and emits `manifest.json` per the spec shape (per-section `added`/`updated` counts + `deleted` pk lists; `baseline_release`/`compare_release`/`pipeline_version`; `checkpoint_full` left resolvable by the uploader or discovered from R2). Deletes live only here.

- [ ] **Step 1: Write the script.** Full content:

```python
#!/usr/bin/env python3
"""Build manifest.json for a GKS delta release from {dataset}.gks_change_log.

Usage: build-delta-manifest.py <release_date> <dataset_version> <output_path>
"""
import json
import subprocess
import sys

# dict table_name -> bundle section (mirrors assemble-gks-dicts.py SECTIONS)
TABLE_SECTION = {
    "gks_dict_sequence_reference": "sequenceReference",
    "gks_dict_location": "location",
    "gks_dict_allele": "allele",
    "gks_dict_copy_number_count": "copyNumberCount",
    "gks_dict_copy_number_change": "copyNumberChange",
    "gks_dict_gene": "gene",
    "gks_dict_variation": "variation",
    "gks_dict_condition": "condition",
    "gks_dict_condition_set": "conditionSet",
    "gks_dict_submitter": "submitter",
    "gks_dict_proposition": "proposition",
    "gks_dict_vcv_proposition": "proposition",
    "gks_dict_rcv_proposition": "proposition",
    "gks_dict_evidence_line": "evidenceLine",
    "gks_dict_vcv_evidence_line": "evidenceLine",
    "gks_dict_rcv_evidence_line": "evidenceLine",
    "gks_dict_scv": "scv",
    "gks_dict_vcv": "vcv",
    "gks_dict_rcv": "rcv",
}
PROJECT = "clingen-dev"


def bq_json(sql):
    out = subprocess.run(
        ["bq", "query", f"--project_id={PROJECT}", "--use_legacy_sql=false",
         "--format=json", "--quiet", "--nouse_cache", sql],
        capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout or "[]")


def main():
    if len(sys.argv) != 4:
        sys.exit("Usage: build-delta-manifest.py <release_date> <dataset_version> <output_path>")
    release, version, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    ds = f"clinvar_{release.replace('-', '_')}_{version}"

    rows = bq_json(
        f"SELECT table_name, change_type, pk, "
        f"CAST(baseline_release AS STRING) AS baseline_release, "
        f"CAST(compare_release AS STRING) AS compare_release "
        f"FROM `{ds}.gks_change_log` "
        f"WHERE table_name IN ({','.join(repr(t) for t in TABLE_SECTION)})"
    )

    pv = bq_json(f"SELECT ANY_VALUE(audit_stamp) AS a FROM `{ds}.gks_pipeline_version`")
    pipeline_version = pv[0]["a"] if pv and pv[0].get("a") else None

    baseline = compare = None
    sections = {}
    for r in rows:
        sec = TABLE_SECTION[r["table_name"]]
        s = sections.setdefault(sec, {"added": 0, "updated": 0, "deleted": []})
        ct = r["change_type"]
        if ct == "A":
            s["added"] += 1
        elif ct == "U":
            s["updated"] += 1
        elif ct == "D":
            s["deleted"].append(r["pk"])
        baseline = baseline or r["baseline_release"]
        compare = compare or r["compare_release"]

    totals = {"A": 0, "U": 0, "D": 0}
    for s in sections.values():
        totals["A"] += s["added"]; totals["U"] += s["updated"]; totals["D"] += len(s["deleted"])

    manifest = {
        "release": release,
        "baseline_release": baseline,   # null on the first release
        "compare_release": compare or release,
        "pipeline_version": pipeline_version,
        "checkpoint_full": None,        # filled by the uploader from current R2 monthly state
        "sections": dict(sorted(sections.items())),
        "counts": totals,
    }
    with open(out_path, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=False)
    print(f"  wrote {out_path}: {totals}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Verify against the compare dataset**

```bash
venv/3.12/bin/python3 src/scripts/build-delta-manifest.py 2026-07-20 v2_5_0 /tmp/manifest-test.json
cat /tmp/manifest-test.json | python3 -m json.tool | head -40
```
Expected: valid JSON; `baseline_release` = `2026-07-15`; per-section counts; `deleted` lists (possibly empty); `counts` A/U/D populated. The section keys match the bundle sections. Clean up `/tmp/manifest-test.json`.

- [ ] **Step 3: Commit**

```bash
git add src/scripts/build-delta-manifest.py
git commit -m "feat(delta): manifest.json builder from gks_change_log slice"
```

### Task 3.4: Delta-reconstruction oracle (THE correctness gate for Piece B)

**Files:**
- Create: `src/scripts/oracle-delta-reconstruction.sh`

Proves `baseline − D − U_old + delta(A∪U) == current full`, per dict, via `gks_oracle_compare`. Reconstruct each dict under its own name in a `_recon` dataset and compare to the compare-release full dict. The merged sections' 3 tables are each reconstructed and compared independently (disjoint key spaces).

- [ ] **Step 1: Write the oracle script.** Full content:

```bash
#!/bin/bash
# oracle-delta-reconstruction.sh — prove the published delta reconstructs the full set.
# For each tracked dict: recon = (baseline WHERE pk NOT IN deletes AND pk NOT IN delta-keys)
#                                UNION ALL delta_<T>;  compare recon vs compare-release full.
# Requires gks_change_log + gks_delta_build to have run for COMPARE.
# Usage: ./oracle-delta-reconstruction.sh <baseline_date> <compare_date> <version>
set -euo pipefail
BASE="${1:?baseline date}"; COMP="${2:?compare date}"; VER="${3:?version}"
PROJECT="clingen-dev"
BDS="clinvar_${BASE//-/_}_${VER}"
CDS="clinvar_${COMP//-/_}_${VER}"
RECON="clinvar_${COMP//-/_}_${VER}_recon"

bq --project_id="$PROJECT" mk -f --dataset "$RECON" >/dev/null 2>&1 || true

# base dict table -> (pk expr). Merged sections listed per underlying table.
declare -A PK=(
  [gks_dict_sequence_reference]=key [gks_dict_location]=key [gks_dict_allele]=key
  [gks_dict_copy_number_count]=key [gks_dict_copy_number_change]=key [gks_dict_gene]=key
  [gks_dict_submitter]=key [gks_dict_proposition]=key [gks_dict_vcv_proposition]=key
  [gks_dict_rcv_proposition]=key
  [gks_dict_variation]=id [gks_dict_condition]=id [gks_dict_condition_set]=id
  [gks_dict_evidence_line]=id [gks_dict_vcv_evidence_line]=id [gks_dict_rcv_evidence_line]=id
  [gks_dict_scv]=id [gks_dict_vcv]=id [gks_dict_rcv]=id
)

FAIL=0
for T in "${!PK[@]}"; do
  K="${PK[$T]}"
  # reconstruct into RECON.<T>
  bq --project_id="$PROJECT" query --quiet --use_legacy_sql=false "
    CREATE OR REPLACE TABLE \`${RECON}.${T}\` AS
    SELECT * FROM \`${BDS}.${T}\` b
    WHERE CAST(b.${K} AS STRING) NOT IN (
            SELECT pk FROM \`${CDS}.gks_change_log\` WHERE table_name='${T}' AND change_type='D')
      AND CAST(b.${K} AS STRING) NOT IN (
            SELECT CAST(${K} AS STRING) FROM \`${CDS}.delta_${T}\`)
    UNION ALL
    SELECT * FROM \`${CDS}.delta_${T}\`
  " >/dev/null
  # compare recon vs compare full via the 3-arg canonical multiset oracle.
  # gks_oracle_compare is a PROCEDURE (CALL, not a table function); with --format=csv the
  # last line is the data row: table_name,a_only,b_only,canonical_diffs.
  OUT=$(bq --project_id="$PROJECT" query --quiet --use_legacy_sql=false --format=csv \
    "CALL \`clinvar_ingest.gks_oracle_compare\`('${RECON}','${CDS}','${T}')" | tail -1)
  echo "  ${OUT}"
  echo "${OUT}" | awk -F, '{ if ($2+$3+$4 != 0) exit 1 }' || { echo "  ❌ MISMATCH on ${T}"; FAIL=1; }
done

bq --project_id="$PROJECT" rm -r -f -d "$RECON" >/dev/null 2>&1 || true
if (( FAIL )); then echo "❌ delta reconstruction oracle FAILED"; exit 1; fi
echo "✅ delta reconstruction oracle: all sections 0,0,0"
```

Note: `gks_oracle_compare` is a **procedure** whose trailing `SELECT` emits `(table_name, a_only,
b_only, canonical_diffs)` — invoke it exactly as `oracle-catvar.sh:60-63` does (CALL + `--format=csv`
+ `tail -1` + the `awk` sum-of-columns-2..4 check). Confirmed against `src/procedures/gks-oracle-compare-proc.sql`.

- [ ] **Step 2: Ensure prerequisites, then run the oracle.** The compare release must have `gks_change_log` + `delta_*` (build them if not fresh):

```bash
bq query --project_id=clingen-dev --use_legacy_sql=false \
 "CALL \`clinvar_ingest.gks_change_log\`(DATE '2026-07-20');
  CALL \`clinvar_ingest.gks_delta_build\`(DATE '2026-07-20')"
chmod +x src/scripts/oracle-delta-reconstruction.sh
src/scripts/oracle-delta-reconstruction.sh 2026-07-15 2026-07-20 v2_5_0
```
Expected: every section prints `0,0,0`; final `✅ delta reconstruction oracle: all sections 0,0,0`. If any section mismatches, STOP — the delta/change-log layer is wrong for that dict; do not proceed. (Per initiative lesson: never relax the oracle to pass.) The `_recon` dataset is auto-dropped.

- [ ] **Step 3: Commit**

```bash
git add src/scripts/oracle-delta-reconstruction.sh
git commit -m "test(delta): delta-reconstruction oracle (baseline - D - U_old + delta == full)"
```

---

## Chunk 4: Cadence + delta upload + index + orchestration (Piece B, part 2)

Publish the delta tree to R2 weekly, switch the full bundle to month-end-only (retroactive), and wire it into `run-release.sh`. Test with `--dry-run` (no R2 writes) before any live publish.

**Authored first** (both uploaders call it): Task 4.1 (`generate-r2-index.sh`) → Task 4.2 (delta uploader) → Task 4.3 (month-end full uploader) → Task 4.4 (cadence) → Task 4.5 (dry-run).

### Task 4.1: Shared `generate-r2-index.sh`

**Files:**
- Create: `src/scripts/generate-r2-index.sh`

One `index.json` generator listing `datasets` (monthly), `archives`, and `deltas`, reflecting current R2 state. Called by both uploaders (Tasks 4.2, 4.3) so the index is consistent regardless of which ran. **Author this before the uploaders** — they invoke it under `set -e`, so it must exist for their dry-runs.

- [ ] **Step 1: Write it.** Reuse the R2 config + `r2_ls`/`r2_ls_with_size`/`r2_upload` helpers. Sections:
  - `datasets.monthly`: `build_file_array "datasets/" "${LATEST_MONTHLY}"` (drop the weekly section entirely).
  - `archives`: unchanged per-year discovery.
  - `deltas`: list `deltas/` release dirs; for each, include `{release, path, manifest: "deltas/<r>/manifest.json"}` and (optional) its `baseline_release`/`compare_release`/`checkpoint_full` by fetching the manifest (or leave to consumers). Keep it lean: list release dirs + manifest paths + mark `deltas/00-latest`.
  - Write `index.json` (`application/json`).
  - Honor `--dry-run` (print, no writes).

- [ ] **Step 2: Syntax check**

Run: `chmod +x src/scripts/generate-r2-index.sh && bash -n src/scripts/generate-r2-index.sh`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add src/scripts/generate-r2-index.sh
git commit -m "feat(delta): shared R2 index generator (monthly + archives + deltas)"
```

### Task 4.2: `upload-gks-delta-to-r2.sh` (delta tree + index)

**Files:**
- Create: `src/scripts/upload-gks-delta-to-r2.sh`

Uploads `deltas/<YYYY-MMDD>/{clinvar-gks-delta_<date>.json.gz, manifest.json, parquet/<section>.parquet}` + refreshes `deltas/00-latest/`, then regenerates `index.json` (Task 4.1). Resolves `checkpoint_full` = the newest `datasets/clinvar-gks_YYYY-MM.json.gz` monthly full currently in R2 and patches it into the manifest before upload.

- [ ] **Step 1: Write the uploader.** Reuse the R2 config + `r2_upload`/`r2_ls`/`r2_copy` helpers from `upload-gks-to-r2.sh` (copy the config block + helpers; factor to a shared file only if convenient). Full behavior:
  - Args: `<export_date> <delta_bundle> <manifest_file> [--parquet-dir=DIR] [--dry-run]`.
  - `PREFIX="deltas/${YEAR}-${MMDD}"`.
  - Resolve `checkpoint_full`: `r2_ls "datasets/clinvar-gks_"` filtered to `YYYY-MM.json.gz` (exclude `00-latest`), take the lexically-last → patch `manifest.checkpoint_full = {path, release}` via a tiny `python3 -c` in-place edit (or `jq` if available; prefer `python3` for portability). If none exists yet (initial rollout), leave `null` and log a warning.
  - Upload bundle → `${PREFIX}/clinvar-gks-delta_${YEAR}-${MMDD}.json.gz`; manifest → `${PREFIX}/manifest.json` (`application/json`); each `parquet-dir/*.parquet` → `${PREFIX}/parquet/<section>.parquet` (`application/vnd.apache.parquet`).
  - Refresh `deltas/00-latest/`: copy the three artifact kinds to `deltas/00-latest/…` (overwrite).
  - Call `generate-r2-index.sh` (Task 4.1) at the end.
  - Honor `--dry-run` (print, no writes) exactly like `upload-gks-to-r2.sh`.

- [ ] **Step 2: Syntax check**

Run: `chmod +x src/scripts/upload-gks-delta-to-r2.sh && bash -n src/scripts/upload-gks-delta-to-r2.sh`
Expected: no errors.

- [ ] **Step 3: Dry-run through the delta orchestrator** (uses Chunk-3 artifacts; no R2 writes)

```bash
src/scripts/release-gks-delta.sh 2026-07-20 v2_5_0 --dry-run
```
Expected: prints the export/assemble/manifest/upload plan including the `deltas/2026-0720/…` targets; no `aws s3` writes occur.

- [ ] **Step 4: Commit**

```bash
git add src/scripts/upload-gks-delta-to-r2.sh
git commit -m "feat(delta): upload-gks-delta-to-r2.sh (delta tree + 00-latest + checkpoint resolve)"
```

### Task 4.3: Switch `upload-gks-to-r2.sh` to month-end full-only

**Files:**
- Modify: `src/scripts/upload-gks-to-r2.sh`

The full bundle is no longer published weekly. This script becomes the **monthly full** uploader: upload to the monthly slot (`datasets/clinvar-gks_YYYY-MM.json.gz` + `datasets/00-latest.json.gz`) + `datasets/parquet/` + year-rollover archive. Remove the weekly-file writes and the promote-from-weekly logic.

- [ ] **Step 1: Remove weekly publishing.** Delete the "Always: upload weekly file" block (weekly dated file + `LATEST_WEEKLY`) and the `cleanup_prior_weeklies` call/flow. Keep `archive_yearly`.

- [ ] **Step 2: Replace `promote_monthly` with a direct monthly upload.** Instead of copying a (now-absent) weekly file, upload the passed bundle directly to `datasets/clinvar-gks_${YEAR}-${MM}.json.gz` and `datasets/${LATEST_MONTHLY}`. The caller passes the last-of-month release's assembled full bundle (Task 4.4 targets `Mₙ`).

- [ ] **Step 3: Fix month/year boundary detection.** `detect_boundaries` currently derives the prior month from `datasets/weekly/` filenames, which are gone. This uploader now always publishes the passed bundle **unconditionally to the monthly slot** (the caller only invokes it for the retroactive month-end full — Task 4.4), so the only remaining use of boundary detection is **year-rollover archiving**: list `datasets/clinvar-gks_YYYY-MM.json.gz` monthly filenames, and if the newest existing monthly's year differs from the release being published, run `archive_yearly` (move prior-year monthlies to `archives/{yyyy}/`) before uploading. No weekly-derived detection remains.

- [ ] **Step 4: Delegate `index.json` to the shared generator** (Task 4.1) — remove the inline `generate_index` (which listed weekly) and call `generate-r2-index.sh`.

- [ ] **Step 5: Syntax check + dry-run**

```bash
bash -n src/scripts/upload-gks-to-r2.sh
src/scripts/upload-gks-to-r2.sh 2026-07-27 v2_5_0 /tmp/does-not-exist.json.gz --dry-run
```
Expected: no syntax errors; dry-run prints monthly-slot + parquet + index targets (no weekly, no promote-from-weekly), no writes.

- [ ] **Step 6: Commit**

```bash
git add src/scripts/upload-gks-to-r2.sh
git commit -m "feat(delta): full bundle publishes to monthly slot only (weekly full retired)"
```

### Task 4.4: Cadence wiring in `run-release.sh` Stage 5

**Files:**
- Modify: `src/scripts/run-release.sh:141-158`

Every run publishes the current release's **delta**. When a month boundary is detected (current release month ≠ previous release month via `schema_on(prev_release_date)`), FIRST publish the **prior** release's full to the monthly slot.

- [ ] **Step 1: Replace the Stage-5 body.** After deriving `DATASET_VERSION` (keep that logic), replace the single `release-gks.sh` call with:

```bash
  # Resolve previous release + month-boundary (retroactive monthly full).
  PREV_DATE="$(bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false --format=csv --quiet \
    "SELECT CAST(prev_release_date AS STRING) FROM \`clinvar_ingest.schema_on\`(DATE '${DATE}')" \
    | tail -n1 | tr -d '[:space:]')"

  DELTA_ARGS=("${DATE}" "${DATASET_VERSION}"); $DRY_RUN && DELTA_ARGS+=("--dry-run")

  if [[ -n "${PREV_DATE}" && "${PREV_DATE:0:7}" != "${DATE:0:7}" ]]; then
    echo ">>> [5/5] month boundary: publishing retroactive monthly FULL for ${PREV_DATE}"
    PREV_US="${PREV_DATE//-/_}"
    PREV_DS="$(bq ls --project_id="${PROJECT_ID}" --max_results=10000 | awk '{$1=$1;print}' | grep "^clinvar_${PREV_US}_" | head -n1)"
    PREV_VER="${PREV_DS#clinvar_"${PREV_US}"_}"
    FULL_ARGS=("${PREV_DATE}" "${PREV_VER}"); $DRY_RUN && FULL_ARGS+=("--dry-run")
    "${REPO_ROOT}/src/scripts/release-gks.sh" "${FULL_ARGS[@]}"
  fi

  echo ">>> [5/5] publishing weekly DELTA for ${DATE}"
  "${REPO_ROOT}/src/scripts/release-gks-delta.sh" "${DELTA_ARGS[@]}"
```

- [ ] **Step 2: Syntax check**

Run: `bash -n src/scripts/run-release.sh`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add src/scripts/run-release.sh
git commit -m "feat(delta): Stage 5 cadence — weekly delta + retroactive monthly full at boundary"
```

### Task 4.5: End-to-end dry-run

- [ ] **Step 1: Weekly (non-boundary) dry-run** — pick an adjacent pair in the same month:

```bash
src/scripts/run-release.sh 2026-07-20 --dry-run --start-step=5
```
Expected: no monthly full (same month as prev 2026-07-15); one delta publish for 2026-07-20; no R2 writes.

- [ ] **Step 2: Boundary dry-run** — a first-of-month release (prev release in the prior month), if one exists in BQ (e.g. an early-August release vs a late-July prev):

```bash
src/scripts/run-release.sh <first-of-month-date> --dry-run --start-step=5
```
Expected: a retroactive monthly FULL publish for the prior (last-of-July) release, THEN the delta publish for the boundary release. No R2 writes.

- [ ] **Step 3: Commit** (only if any fixes were needed; otherwise skip). Nothing to commit if dry-runs pass clean.

---

## Chunk 5: Documentation (comprehensive pass)

The mkdocs site is behind on the whole incremental model (Plans 1–3, already merged) as well as Plan 4 — treat this as a **full audit + rebring-up-to-speed**, not just a delta-product addendum. Use the `write-docs` skill for every page. This chunk is larger than a single task; execute it as an audit → per-area edits → validate loop.

### Task 5.1: Audit — inventory impacted pages

**Files:** read-only survey of `docs/` + `mkdocs.yml`.

- [ ] **Step 1: Inventory.** List every page and grep for content now stale under the incremental + delta + retired-`gks_json` model. At minimum: `docs/pipeline/` (the whole flow — incremental procs, change-log/delta, retired gks_json, run-release stages), any **downloads/distribution/data-access** page (the R2 layout, the new deltas tree, cadence, consumer replay model), architecture/overview pages, and `mkdocs.yml` nav. Produce a short checklist of pages × what's wrong. Cross-reference the standing "docs rework needed" memo (Parquet-pipeline drift) and fold that in.

- [ ] **Step 2: Commit the audit checklist** (as a scratch note in the PR description or a `docs/` TODO comment — no separate commit needed if folded into 5.2).

### Task 5.2: Pipeline + architecture pages

- [ ] **Step 1:** Rewrite `docs/pipeline/` for the current model: incremental build (carry-forward + UNION-CTAS), `dataset_diff` drivers, `gks_change_log` + `gks_delta_build`, the version gate, `run-release.sh` stages, and the retired `gks_json` step (dicts are the product). Remove/repoint every `gks_json_proc` reference.
- [ ] **Step 2:** `mkdocs build --strict` (clean). **Step 3:** commit.

### Task 5.3: Downloads / distribution / consumer pages

- [ ] **Step 1:** Document the delta product end to end: R2 layout (`datasets/` monthly full, `datasets/parquet/`, `deltas/<YYYY-MMDD>/{bundle,manifest.json,parquet/}`, `deltas/00-latest/`, `archives/`, `index.json`), `manifest.json` shape, the **cadence** (deltas weekly / full only at month-end, retroactive), the **consumer model** (last monthly full + replay contiguous weekly deltas; chain-gap detection via `baseline_release`/`compare_release` + `checkpoint_full`), and the one-time bundle-cleanup content change. Update `src/scripts/r2-readme.txt` (bucket overview) to match.
- [ ] **Step 2:** `mkdocs build --strict` (clean). **Step 3:** commit `docs: R2 delta product, cadence, consumer model + downloads`.

### Task 5.4: Sweep remaining impacted content + final validate

- [ ] **Step 1:** Grep the whole `docs/` tree for residual stale references (`gks_json`, "full rebuild every release", weekly-full-bundle language, any pre-incremental phrasing) and fix. Update `mkdocs.yml` nav if pages were added.
- [ ] **Step 2:** `venv/3.12/bin/python3 -m mkdocs build --strict` — clean build, no warnings. **Step 3:** commit.

---

## Final: holistic review + PR

- [ ] Run the full test suite: `venv/3.12/bin/python3 -m pytest src/scripts/tests/ -v` (cleanup tests pass).
- [ ] Re-run the delta-reconstruction oracle on the test pair → all sections `0,0,0`.
- [ ] Confirm scratch datasets/GCS prefixes are cleaned up (`*_recon`, `gks-deltas-test*`).
- [ ] Use superpowers:requesting-code-review for a holistic pass, then superpowers:finishing-a-development-branch → stacked PR (base = Plan 3 branch, per the initiative's stacked-PR model; merge order #74 → #75 → #76 → this).

## Production rollout (fresh-start, AFTER build + PR) — user-directed 2026-08-10

Run only after Chunks 1–5 are built, oracle-green, dry-run-clean, and reviewed. This is a **live public
R2** operation — destructive and outward-facing; get explicit user confirmation at the wipe step.

**Target releases (verified in `clingen-dev`):** first FULL = **2026-06-27** (last June release); first
delta = **2026-07-06** (first July release; baseline/checkpoint = 06-27); then build forward 07-15, 07-20,
07-27, … to current.

- [ ] **R1: Point the Chunk-3 reconstruction oracle at the real first pair.** Run
  `oracle-delta-reconstruction.sh 2026-06-27 2026-07-06 v2_5_0` → all sections `0,0,0` before publishing
  anything. (Prereq: `gks_change_log` + `gks_delta_build` for 2026-07-06 with baseline 2026-06-27.)
- [ ] **R2: Back up the current bucket first (irreversible wipe ahead).** Snapshot everything under
  `s3://clinvar-gks/` to a dated backup (a `pre-plan4-backup-YYYYMMDD/` R2 prefix or a GCS copy) so the
  current `datasets/`, `archives/`, `README.txt`, `index.json` are recoverable. **Confirm scope with the
  user** (complete wipe incl. `archives/`, or preserve `archives/`?).
- [ ] **R3: Wipe R2** (after explicit user OK) — remove all live objects so the new layout starts clean.
- [ ] **R4: Publish the June-27 FULL as the bootstrap monthly.** Full-mode publish of 2026-06-27
  (`release-gks.sh 2026-06-27 v2_5_0`, i.e. the month-end/full path) → `datasets/clinvar-gks_2026-06.json.gz`
  + `datasets/00-latest.json.gz` + `datasets/parquet/`. Dry-run first, then live. Verify the bundle is
  cleaned (no null/empty leaks).
- [ ] **R5: Publish the July-06 DELTA.** `release-gks-delta.sh 2026-07-06 v2_5_0` (dry-run then live) →
  `deltas/2026-0706/{bundle, manifest.json, parquet/}` + `deltas/00-latest/`; `index.json` lists it;
  `manifest.checkpoint_full` = the June-27 monthly. **Consumer-side acceptance:** apply the published 07-06
  delta onto the published 06-27 full → byte-equals the 07-06 full dict set (the BQ oracle already proves
  this; spot-check the published artifacts too).
- [ ] **R6: Build forward** — run the weekly delta for 07-15, 07-20, 07-27 in order; confirm the delta
  chain is contiguous (`baseline_release[i] == compare_release[i-1]`). At the first release of the NEXT
  month, confirm the retroactive July monthly full publishes automatically (Task 4.4 path). Continue to
  current.

## Notes / risks carried from the spec
- **Initial rollout:** until the first month-end monthly full exists, `checkpoint_full` is `null`; the first-ever delta equals the full set (baseline `null`), so a new consumer can bootstrap from it. Document this.
- **One-time content churn:** the first cleaned bundle differs from prior bundles (empties stripped) — expected, not a regression.
- **`gks_oracle_compare` return shape:** verify the exact columns/order against `src/procedures/gks-oracle-compare-proc.sql` when writing Task 3.4's `SELECT`.
- **Out of scope:** deleting `gks-json-proc.sql`; Parquet empty-cleanup; the `variation_archive_classification` diff SKIP and config-data-gate residuals.
