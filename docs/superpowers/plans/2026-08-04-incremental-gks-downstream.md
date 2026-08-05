# Incremental GKS downstream — Design Plan

> **Status:** design. Builds on the merged incremental-vrsify work (PR #61) and `gks_change_log` (PR #62). Not yet implemented.

**Goal:** Carry forward the `gks_*` records that didn't change since the prior release and recompute only the ones impacted by the release's data changes — extending the "process only the delta" model from vrs-python (`gks_vrs`) down through `gks_catvar`, the SCV/RCV/VCV statements, and the final JSON.

**Why:** these procs process the whole snapshot each run (`gks_rcv_statement` ≈ 11M rows, `gks_vcv_statement` ≈ 9M, `gks_scv_statement` ≈ 6M). A weekly release changes ~0.3% of variations; almost everything else is identical to the prior release.

---

## The hard-won constraint: same-proc-version only

The `gks_change_log` test (07-15 → 07-20) showed **near-total `U` on the statement tables** — but that was **proc-version drift**, not data change: 07-15 was built by older procs, so the `proposition` format differs for every record. `gks_catvar` (stable proc between the two builds) diffed cleanly: **A=13,975 / D=7 / U=3,273**, matching the changed-variation set.

**Therefore incremental carry-forward is valid ONLY when the prior release was built by the same gks-proc version.** This is the same version-invalidation gate as vrs-python:
- gks procs unchanged since the prior release → carry forward the unchanged records.
- any gks proc changed → **full rebuild** of the affected table(s) (its format changed for every record).

A per-table `pipeline_version` stamp (or a manual `incremental` flag the operator sets only when procs are unchanged) gates this. The full path is always correct.

## Impact-propagation model (what to recompute)

Drivers already available: the `dataset_diff_on` `diff_*` tables (per source table) + `variation_vrs_changed` (changed variations) + `gks_change_log` (changed upstream `gks_*` records).

| Output | Key | Recompute the record when… | Cascade difficulty |
|--------|-----|----------------------------|--------------------|
| `gks_catvar` | variation | its `variation_identity`/`gks_vrs` changed → **the changed-variation set** | easy (per-variation) |
| `gks_scv_statement` | SCV `id` | its `clinical_assertion` changed **OR** its variation changed **OR** its condition/trait changed | medium (FK fan-in) |
| `gks_rcv_statement` | RCV `id` | **any contributing SCV changed** OR its `rcv_accession`/classification changed OR its variation/condition changed | hard (aggregation) |
| `gks_vcv_statement` | VCV `id` | **any contributing SCV/RCV changed** OR its `variation_archive_classification` changed OR its variation changed | hard (aggregation) |

**The aggregation cascade is the crux.** A single changed SCV must recompute its parent RCV and VCV *even though those records' own rows didn't change* — because the statement re-aggregates across all its members. This is the same class of trap as the `mappings` cross-variation bug that killed the incremental `variation_identity` attempt: a naive per-key diff misses it. The impact set for aggregates must be computed by mapping the **changed SCV set → affected RCV/VCV parents** (via `rcv_mapping` / `variation_archive` membership), not by diffing the RCV/VCV records directly.

## Architecture: seed-then-merge per table (proven pattern)

Per release `{S}`, for each incremental-eligible table (same-proc-version vs baseline):
1. **Seed** `{S}.gks_X` from the baseline release via zero-copy `CLONE` (carry forward).
2. **Compute the impact set** of keys (per the table's row above).
3. **Recompute** only those keys (run the proc's logic restricted to the impact set → staging).
4. **Merge** (DELETE impacted + removed keys, INSERT recomputed) — keyed on the table's `pk`.

`gks_change_log` records the resulting A/U/D so the *next* release's carry-forward knows exactly what to bring forward vs. recompute, and for auditing.

## Correctness gate (non-negotiable)

Per table, a **full-rebuild == incremental oracle** before trusting it — the `variation_identity` oracle is the reason we know the naive approach hides cross-record bugs. Compare full vs incremental output keyed by pk + `TO_JSON_STRING` (canonicalized); the changed set must miss nothing.

## Phasing

1. **`gks_catvar`** — per-variation, driven directly by the changed-variation set; cleanest, and its change-log already validates the diff. Prove seed-then-merge + oracle here first.
2. **`gks_scv_statement`** — impact set = `diff_clinical_assertion` ∪ SCVs-on-changed-variation ∪ SCVs-on-changed-condition. FK fan-in, no aggregation.
3. **`gks_rcv_statement` / `gks_vcv_statement`** — build the changed-SCV → affected-parent mapping; recompute those aggregates. Hardest; lean on the oracle.
4. **`gks_json_proc`** — assemble only changed records; reference carried-forward for the rest.

## Open questions
- Where to stamp `pipeline_version` (per-table label vs a metadata table) so the same-version gate is automatic rather than operator-asserted.
- Whether the aggregate procs can be cleanly restricted to an impact set of parent keys, or need refactoring to accept a key filter (mirrors the `{VFILTER}` approach used in the variation_identity experiment).
- Cost/benefit per table — **measured (2026-08-05), and it reshaped the priority.** The metric is **execution cost (bytes/slot-time)**, not wall-clock. Incremental wins ⟺ **full-compute > ~2 × output-table size** (the carry-forward floor = read+write the unchanged output once, best done via **UNION-CTAS**, not the scattered-row DELETE+INSERT). Measured per run:
  - **`variation_identity`: 124 GB compute → 0.83 GB output → ~70× win.** The standout — parses content blobs into a tiny output. See `2026-08-05-incremental-variation-identity-v2.md`.
  - `gks_catvar_proc` 25 GB / 9.5 GB → ~1.3× (marginal); `gks_scv_statement` 27 / 13.8 → ~break-even; `gks_rcv/vcv_statement` 12.8/4.4, 10.1/3.6 → ~1.4–1.5× (modest).
  - **Conclusion:** the output-heavy downstream procs are marginal (carrying their large JSON forward ≈ recomputing it), so they stay full rebuilds. **`variation_identity` is where incremental pays off**, and it's pursued in the v2 plan; this downstream plan is deprioritized accordingly.
