# Incremental vrsify + gks_vrs carry-forward — Implementation Plan

> **For agentic workers:** Successor to `2026-08-03-incremental-variation-identity.md` (superseded). `variation_identity` stays a full rebuild; the incremental win moves here, to the expensive vrs-python step and the `gks_vrs` load.

**Goal:** Send only the variations whose VRS input changed since the prior release through vrs-python (~17K vs ~4.5M for a weekly release), and build `gks_vrs` by carrying the prior release's rows forward for unchanged variations and merging in the newly-normalized changed rows.

**Why this is the real win:** VRS normalization (vrs-python, per variant, hits UTA/SeqRepo/Gene-Normalizer) is the pipeline's dominant cost. The BigQuery `variation_identity` transform is ~2 min (a full rebuild is cheaper than an incremental merge — see the superseded plan's oracle findings). VRS normalization is **per-variation with no cross-variation dependency**, so carrying unchanged results forward is clean and correct.

> **STATUS (2026-08-03): Tasks 1–3 implemented + verified in clingen-dev.**
> - Task 1 `variation_vrs_changed` proc: 2026-07-15→07-20 gives **13,999 changed / 7 removed** (0.31%).
> - Task 2 filtered extract: `vi_extract` = 13,999 rows, schema identical to `variation_identity`.
> - Task 3 `gks_vrs` merge oracle (incremental vs full 07-20 load): **exact row count; the only
>   179 `out`-diffs are on variations with identical `variation_identity` — vrs-python version
>   drift between two historical loads, 0 changed-set gaps.** Merge logic + changed-set completeness confirmed.
> Remaining: Task 4 orchestration/flag threading (load-side fallback already built in) + the
> end-to-end run (needs the local vrs-python stack). The GCS `bq extract` / `bq load` I/O was not
> exercised (writes to the shared bucket / needs a real vrsify output).

---

## Current pipeline (full, per release `<date>` / dataset `{S}`)

| # | Step | Script / proc | I/O |
|---|------|---------------|-----|
| 1 | Build variation identity | `clinvar_ingest.variation_identity(<date>, FALSE)` | → `{S}.variation_identity` (~4.5M rows, 1/variation) |
| 2 | Extract to GCS | `src/scripts/export-vi-table-to-gcs.sh` (`bq extract`) | `{S}.variation_identity` → `gs://clinvar-gks/<date>/dev/vi.json.gz` |
| 3 | **vrsify (expensive)** | `clinvar-gk-python` `misc/clinvar-vrsification <date>` | `vi.json.gz` → `vi-normalized-no-liftover.jsonl.gz` |
| 4 | Location transform | `vrs-to-bq-table.sh` STEP 1 → Cloud Run `vrs-to-vi-location-transformer` | `vi-normalized-no-liftover.jsonl.gz` → `vi-final.jsonl.gz` |
| 5 | Load gks_vrs | `vrs-to-bq-table.sh` STEP 2 (`bq load --replace`, schema `schemas/vrs_output_2_0_1.schema.json`) | `vi-final.jsonl.gz` → `{S}.gks_vrs` |
| 6 | Downstream | `vrs-to-bq-table.sh` STEP 3 (`gks_catvar_proc` … `gks_json_proc`) | reads `{S}.gks_vrs` (joins `vrs.in.variation_id`) |
| 7 | Export/publish | `vrs-to-bq-table.sh` STEP 4 | GCS + public bucket |

`gks_vrs` schema = `{ in: <the variation_identity row>, out: <VRS output> }`, one row per `in.variation_id` (verified: 4,545,909 = distinct).

**vrs-python (clinvar-gk-python) and the Cloud Run transformer need NO changes** — they process whatever `vi.json.gz` contains. Only what we *feed* them, and how we *load* the result, change.

## Incremental design

Insert a **changed-set** computation after step 1, filter step 2's extract to it, and change step 5 from `--replace` to **carry-forward + merge**. Steps 3, 4 shrink automatically.

### The changed set
Diff `{S}.variation_identity` against `{base}.variation_identity` (baseline = nearest existing prior release, resolved via `schema_on(prev_release_date)` — same pattern as `dataset_diff_on`). Per variation, by `TO_JSON_STRING` of the row (canonicalization optional):
- **new / modified** → must be (re)vrsified.
- **removed** (in baseline, gone now) → delete from carried-forward `gks_vrs`.
- **exact_match** → carry the prior `gks_vrs` row forward untouched.

Compare the **whole `variation_identity` row** (it is exactly what becomes `gks_vrs.in`), not a VRS-only subset — so any change that would make `gks_vrs.in` stale re-processes. Over-inclusion is negligible (e.g. the ~124 `mappings`-only cross-variation changes/release; the handful of `ROW_NUMBER` tie-break non-deterministic rows). Optimization (later): skip vrs-python for rows whose *VRS-input* fields are unchanged and only `mappings`/`name` differ — just refresh `gks_vrs.in` and keep the prior `out`.

### Fallback to full (never produce a partial result)
Do a **full run** (extract all, `--replace` load) when any of: no baseline resolves (first release / archived prior), `{base}.gks_vrs` is missing, or a **version change** invalidates carry-forward — i.e. the vrs-python version OR the `variation_identity` transform changed since the baseline was built (carried-forward `out` assumes the same normalizer + same input transform). This is operational: incremental is opt-in per run; the full path is always correct.

---

## Tasks

### Task 1: Changed-set + removed-set BQ step
**Files:** Create `src/procedures/variation-vrs-changed-proc.sql` — `clinvar_ingest.variation_vrs_changed(on_date DATE)`.

- [ ] Resolve `base_schema = schema_on(prev_release_date)`. If NULL, write `{S}.variation_vrs_changed` = ALL `variation_id`s and `{S}.variation_vrs_removed` = empty, and set a `full` marker (first run → everything).
- [ ] Else build:
  - `{S}.variation_vrs_changed` = `variation_id`s where `TO_JSON_STRING(cur) != TO_JSON_STRING(base)` (FULL OUTER JOIN on `variation_id`; includes new + modified).
  - `{S}.variation_vrs_removed` = `variation_id`s in `{base}.variation_identity` not in `{S}.variation_identity`.
- [ ] **Verify** (bq): counts for 2026-07-15→07-20 are sane — changed ≈ the diff_variation new/modified order of magnitude, removed matches. Cross-check a few `variation_id`s by hand.

### Task 2: Filtered extract
**Files:** Modify `src/scripts/export-vi-table-to-gcs.sh` (parameterize date/dataset; add incremental mode).

- [ ] Replace the hardcoded `bq extract` with, in incremental mode, an `EXPORT DATA` that filters to the changed set:
  `EXPORT DATA OPTIONS(uri='gs://clinvar-gks/<date>/dev/vi.json.gz→shards', format='JSON', compression='GZIP') AS SELECT vi.* FROM {S}.variation_identity vi JOIN {S}.variation_vrs_changed c USING(variation_id)`
  (`bq extract` can't filter; `EXPORT DATA` shards — compose to `vi.json.gz` like `vrs-to-bq-table.sh` step 4 does, or adjust the vrsification input to accept shards.) Full mode keeps the whole-table extract.
- [ ] **Verify**: the exported line count == changed-set count; spot-check the NDJSON shape matches what `clinvar-vrsification` expects.

### Task 3: gks_vrs carry-forward + merge load
**Files:** Modify `src/scripts/vrs-to-bq-table.sh` `load_vrs_data()` (STEP 2).

- [ ] Incremental mode: (a) seed `{S}.gks_vrs` via `CREATE OR REPLACE TABLE {S}.gks_vrs CLONE {base}.gks_vrs`; (b) `bq load` `vi-final.jsonl.gz` into staging `{S}.gks_vrs_changed` (same schema); (c) `MERGE`/DELETE+INSERT into `{S}.gks_vrs` keyed on `in.variation_id`: delete `variation_vrs_changed ∪ variation_vrs_removed`, insert staging; drop staging. Full mode keeps `--replace`.
- [ ] **Verify (acceptance oracle)**: on 2026-07-20, compare the incremental `gks_vrs` to a full `--replace` load — the `out` (VRS) for every variation must match, and row count == full. VRS is per-variation, so this must be exact (modulo the same non-determinism variation_identity already has). Investigate any `out` mismatch (a carry-forward bug).

### Task 4: Orchestration + fallback wiring
**Files:** `vrs-to-bq-table.sh` (a new pre-step or flag), `src/procedures/readme.md`.

- [ ] Wire the changed-set step (Task 1) before the extract, thread an `--incremental` flag through extract + load, and implement the full-run fallback (no baseline / missing `{base}.gks_vrs` / version bump).
- [ ] Document the version-invalidation rule (bump vrs-python or the `variation_identity` transform ⇒ run full) and the first-run behavior.

### Task 5 (fast-follow, separate plan): incremental downstream
Thread the changed set into `gks_catvar_proc` and the SCV/RCV/VCV procs so they too process only affected records. Out of scope here.

---

## Risks & gates
1. **Version invalidation** — carried-forward `out` assumes the same vrs-python version AND the same `variation_identity` transform. Any change ⇒ full run. (Operational; full path always correct.)
2. **Removed variations** must be deleted from `gks_vrs`, or stale VRS leaks forward.
3. **Baseline consistency** — the `{base}.gks_vrs` we clone must be from the same release the changed set was diffed against (assert baseline release; else full).
4. **variation_identity non-determinism** (`ROW_NUMBER` tie-breaks, unordered `ARRAY_AGG`/`STRING_AGG`) makes a few variations look "changed" every release → harmless extra re-vrsification. Optional hardening: add total-order tie-breaks / `ORDER BY` to make the transform deterministic, shrinking the changed set to true changes.
5. **Extract sharding** — `EXPORT DATA` shards; ensure `clinvar-vrsification` consumes the composed single file (or teach it to read shards). Match the compose approach already in `vrs-to-bq-table.sh`.
6. **No silent partials** — if the changed set is empty because a diff/baseline was missing (not because nothing changed), that must trigger the full fallback, never a no-op load that leaves `gks_vrs` stale.
