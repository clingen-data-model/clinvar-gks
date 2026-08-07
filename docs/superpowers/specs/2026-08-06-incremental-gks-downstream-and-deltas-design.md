# Incremental GKS downstream + per-release delta datasets — Design

> **Status:** design (approved in brainstorming 2026-08-06). Supersedes the deprioritized
> `docs/superpowers/plans/2026-08-04-incremental-gks-downstream.md`. Builds on the merged
> incremental `variation_identity` v2 + vrsify work (PRs #66–#73), `gks_change_log` (PR #62),
> and `dataset_diff_on` (PR #60).

## Goal

Two coupled deliverables:

1. **Make every downstream `gks_*` output table build incrementally** — carry forward the records
   that didn't change since the prior release and recompute only the records impacted by the
   release's data changes. Extends the "process only the delta" model already proven on
   `variation_identity` / `gks_vrs` down through `gks_catvar`, the SCV/RCV/VCV condition &
   statement tables, and the final `gks_json`.
2. **Produce and publish per-release delta datasets to R2** — for every published output table,
   ship the set of new/changed/deleted records so downstream consumers can stay current by
   applying just the changes, without re-downloading the full set every week.

The two are the same mechanism: the delta is the natural byproduct of incremental compute.

## Core posture (settled)

- **Incremental is the default path; the full dataset is *derived* from it.** For each table,
  `full(N) = carry-forward(unchanged rows from full(N-1)) UNION recomputed delta`. The full table
  is **always** built in BigQuery every release (next release's carry-forward reads it as its
  baseline) — the R2 *publish* cadence is a separate decision (see "Delta product & R2").
- **A full rebuild is always available** as a fallback and an explicit operator option; the full
  path is always correct.
- Both the **full set** and the **delta set** are produced every release.

---

## 1. Build primitive

Every incremental-eligible table is built by the same three-part primitive, per release `{S}` with
baseline `{base}` = the prior release resolved via `schema_on(prev_release_date)`:

1. **Compute the impact set** — the set of the table's primary keys whose output *could* have
   changed, derived from upstream change drivers (per-table, §3). This is computed from what *feeds*
   the rows, **not** by diffing the table's own rows (the naive diff is the trap that hid the
   `variation_identity.mappings` cross-record bug).
2. **Recompute only the impact set** → a staged **delta payload** table whose schema is
   **identical to the target table**. This staged table is exactly the `A`∪`U` payload published
   to R2 (§4).
3. **Merge via `UNION-CTAS`** (the proven primitive; **not** `DELETE`+`INSERT`, whose
   scattered-row rewrite penalty made the first incremental attempt slow):

   ```sql
   CREATE OR REPLACE TABLE {S}.gks_X AS
     SELECT <explicit cols> FROM {base}.gks_X WHERE pk NOT IN (SELECT pk FROM impacted_or_removed)
     UNION ALL
     SELECT <explicit cols> FROM {S}.stg_gks_X_delta   -- recomputed impacted (A ∪ U)
   ```

   Removed keys (D tombstones) come from the removed-variation / removed-parent sets and are
   excluded from the carry-forward arm.

The full table and the delta payload fall out of the **same** compute — the delta is the
"recomputed impacted" arm of the UNION, materialized and kept.

### Wrapper structure (per proc, non-breaking)

Mirrors `variation-identity-proc.sql`:

- internal `gks_X_build(on_date, debug, incremental)` — the shared logic, with an impact-set key
  filter (`{KFILTER}` / `{VFILTER}`-style) applied only when `incremental` is true;
- `gks_X(on_date, debug)` — full rebuild wrapper (unchanged public contract);
- `gks_X_incremental(on_date, debug)` — incremental wrapper.

### Structural fallback guard

`gks_X_incremental` falls back to a full rebuild when carry-forward can't be trusted:
baseline unresolvable / first release, required `{base}` output tables absent, required `diff_*`
driver tables absent, **or** the pipeline-version gate trips (§5). The full path is always correct,
so the guard is fail-safe.

---

## 2. Catvar exception — six global dictionaries

`gks_catvar_proc` emits **7 outputs**. Only `gks_dict_variation` is per-variation. The other six are
**globally deduped** dictionaries keyed by content digest / accession / gene, derived from
whole-snapshot temps built off all of `gks_vrs`:

- `gks_dict_sequence_reference` (by refgetAccession)
- `gks_dict_location` (by location id)
- `gks_dict_allele` (by VRS digest)
- `gks_dict_copy_number_count` (by VRS digest)
- `gks_dict_copy_number_change` (by VRS digest)
- `gks_dict_gene` (by gene)

Because a changed variation can *add* a new shared entry or drop the *last reference* to a shared
one, a clean per-variation carry-forward does not apply. **Decision (Approach 1): recompute the six
global dicts globally every release** (they are the cheap part of an already-marginal ~25 GB proc),
and produce **their delta by a `dataset_diff` pass** (freshly-recomputed global dict vs `{base}`,
keyed by digest/accession/gene) → `A`/`U`/`D`. This is correct by construction (a global recompute
cannot miss a dropped reference) and avoids the reference-counting dedup-removal trap.

Only **`gks_dict_variation`** uses the `UNION-CTAS` carry-forward primitive (§1).

---

## 3. Impact model (per table)

Change drivers available: the `variation_identity` changed set (`diff_variation` new|modified ∪
copy-number CAV/CA cascade), `variation_vrs_changed` (`gks_vrs` A/U), `gks_change_log` (upstream
`gks_*` A/U/D), and the `dataset_diff_on` `diff_*` per-source-table tables.

| Table | pk | Impact set = recompute when… |
|---|---|---|
| `gks_catvar` → `gks_dict_variation` | variation_id | `variation_identity` changed set **∪** `gks_vrs` changes **∪ `gene_association` changes**. Six global dicts: global recompute + diff-for-delta (§2). |
| `gks_scv_condition` | scv_id (+condition) | **aggregate-significant SCV set** (§3.1) |
| `gks_scv_statement` | scv_id | **aggregate-significant SCV set** |
| `gks_rcv` / `gks_rcv_statement` | rcv_id | **RCV impact set** (§3.2) |
| `gks_vcv` / `gks_vcv_statement` | vcv_id | **VCV impact set** (§3.2) |
| `gks_json` | record key | union of all upstream A/U/D read directly from `gks_change_log` |

**Known gap to close:** `gene_association` is **not** currently in `dataset_diff_on`'s `diff_*` set.
It **must be added** so catvar can catch gene-only changes.

**`gks_json` is driven directly by `gks_change_log`** — the union of all upstream A/U/D keys *is* its
impact set; it assembles only changed keys and references carried-forward records for the rest.

### 3.1 The aggregate-significant SCV predicate (single source of truth)

The entire downstream cascade collapses to **one driver: the aggregate-significant SCV set**.
Condition/trait changes are **not** a separate driver — a condition change always manifests as an SCV
change (version bump), so it is already captured here.

```
scv_significant_change(scv) :=
      scv is NEW (A)                                   -- added to the aggregate
   OR scv is DELETED (D)                               -- removed from the aggregate
   OR scv.version       != baseline.version            -- any significant SCV edit bumps version
   OR scv.review_status != baseline.review_status      -- can change WITHOUT a version bump
```

Because review status can move independently of version, the predicate diffs **both** `version` and
`review_status` explicitly. This predicate is encoded **once** (a single CTE/view feeding the SCV,
RCV, and VCV impact sets) so a newly-discovered impact vector is a one-line change in one place.

### 3.2 Aggregation cascade — RCV and VCV are independent, parallel aggregates

**RCV and VCV both aggregate directly from SCVs. VCV does NOT depend on RCV** (there is no RCV→VCV
edge). A single changed SCV must recompute its parent RCV/VCV **even though the parent's own row is
byte-identical**, because the statement re-aggregates across members — the same class of trap as the
`mappings` cross-record bug. The parent impact set is therefore computed **membership-first**
(changed child → affected parents), then those parents are recomputed from their **full** membership.

Each aggregate impact set has **triple coverage** (belt-and-suspenders, per the correctness-first
posture):

**RCV impact set** =
- parents with ≥1 **aggregate-significant SCV** (§3.1), evaluated over the **union of current +
  baseline `rcv_mapping`** (catches both the old parent that lost a re-assigned SCV and the new
  parent that gained it), **∪**
- parents whose **own `gks_rcv` / `gks_rcv_statement` record diffs** vs baseline, **∪**
- parents of any **`unexplained`-modified SCV** (§3.3, conservative fold-in).

**VCV impact set** = the same three, via **`variation_archive` membership** instead of `rcv_mapping`.

**SCV re-assignment** (an existing SCV moving to a different RCV/VCV) is **possible but rare**; when
it happens the SCV's `variation_id` changes, so it is *already* aggregate-significant. Combined with
the both-sides membership union and the own-record diff, re-assignment has coverage from three
directions.

### 3.3 SCV change audit — the "unexplained modification" detector

A standing correctness guard that makes the §3.1 predicate self-correcting instead of assumed
complete. Every release, classify each **modified (U) SCV** from `diff_clinical_assertion` by reason:

- `version_changed`? `review_status_changed`? → **explained** (aggregate-significant, handled)
- **neither changed, but the SCV row is byte-different → `unexplained`** ← the alert

Materialize `gks_scv_change_audit(scv_id, baseline_release, compare_release, version_changed,
review_status_changed, unexplained)` and emit a `log()` line with the unexplained count each run.

**Behavior for `unexplained` SCVs: log + conservatively recompute.** They are folded into the
aggregate-significant set (their parents recompute) **and** logged. This turns "might miss an impact"
into "never miss, and measure the frequency" — the log is the evidence trail for whether the
predicate needs to grow. These should be rare, so the extra recomputes are negligible.

---

## 4. Delta product & R2 publishing

### Delta record shape

- **Per-table delta payload** = a file with the **exact same schema as the target table**,
  containing only the recomputed `A`∪`U` rows (the "recomputed impacted" arm of §1's UNION). No
  `change_type` column, no ragged pk-only rows — a consumer upserts it by pk directly; it is
  literally a small version of the table.
- **Manifest** = a per-release slice of `gks_change_log` (`table_name`, `pk`, `change_type` A/U/D,
  `baseline_release`, `compare_release`). Deletes live here (D = pk only, which is what the manifest
  schema is designed for). The manifest also tells a consumer which payload rows were A vs U, and its
  release stamps let a consumer **detect chain gaps**.

### Cadence & consumer model

- **Deltas every weekly release.** Full sets are published to R2 **only on the last release of each
  month** — that release's full set is promoted to the monthly/archival slot (same weekly→monthly
  promotion pattern as today; no separate compaction build).
- **Consumer model:** take the **last monthly full + replay the contiguous weekly deltas since**.
  This is a standard base-plus-incrementals model. The monthly full is the bootstrap/checkpoint for
  new or fallen-behind consumers.
- **Delta-chain integrity is load-bearing:** the weekly deltas between two monthly fulls must be
  contiguous and gap-free; each carries `baseline_release` + `compare_release` stamps so a consumer
  can verify the chain and detect a missed week (which would break replay).

### Formats & layout

Deltas are exported to **Parquet + NDJSON straight from the BQ delta tables** (the efficient path via
`bq extract` / `EXPORT DATA`, mirroring the full-set formats — never via a NDJSON→Parquet round-trip).
`upload-gks-to-r2.sh` gains a delta output alongside its current full-set outputs; the R2 layout adds
a per-release delta tree (one payload file per table + `manifest.json`) alongside the existing
`datasets/weekly`, monthly `datasets/`, `archives/`, and `datasets/parquet/` locations.

---

## 5. Version-invalidation gate & provenance

Carry-forward is valid **only when the prior release was built by the same pipeline method** — the
07-15→07-20 test showed near-total false `U` on the statement tables purely from **proc-version
drift** (not data change), while stable-proc `gks_catvar` diffed cleanly (A=13,975 / D=7 / U=3,273,
matching the changed-variation set).

**Single, git-derived `pipeline_version` for the entire build** (upstream `variation_identity` +
vrsify + every downstream proc + the scripts/processes), computed at deploy/release time by the
orchestration layer (`run-release.sh`) and written to `clinvar_ingest.gks_proc_version`. Rationale:
the operator must be able to trace any release back to the **precise set of routines** that produced
it, for reproduction and audit — a single whole-suite version does this cleanly and subsumes upstream
under the same gate.

- **Audit stamp (always recorded):** `git describe --tags --always --dirty` — e.g.
  `v1.4.2-3-gabc1234` or `abc1234-dirty`. Captures the nearest **release tag** + commits-since +
  **short SHA** + a `-dirty` flag marking an unaudited ad-hoc build (which can be blocked). Stamped
  onto **every** output table and carried in each release's delta manifest.
- **Carry-forward gate (comparison):** keyed on a hash / last-commit of the **build-relevant paths
  only** (`src/procedures/`, `src/scripts/`, `src/vrsify/`), so a docs-/memory-only commit does not
  needlessly force a full rebuild while the recorded audit stamp still reflects true repo HEAD.

At build, each proc reads its current gate value vs the baseline output's stamped gate value:
**match → carry forward; mismatch, or no baseline stamp → full rebuild of everything that release**
(a clean, fully-auditable full rebuild whose delta honestly reads "rebuilt under method X→Y").

`--full` on `run-release.sh` forces a global full rebuild regardless of the gate (backfills,
reprocessing, when in doubt). This is the automatic-safety-net + explicit-override model: the stamp
makes the correctness-critical decision so a forgotten flag can't corrupt output.

### Storage & read-back

Each build stamps its output (a `{S}.gks_pipeline_version(table_name, version, gate_key)` row, or a
table label read back via `INFORMATION_SCHEMA.TABLE_OPTIONS`). Next release reads
`{base}.gks_pipeline_version` for the baseline gate value.

---

## 6. Correctness gate (non-negotiable)

Per table, a **full-rebuild == incremental oracle** before the incremental path is trusted: compare
full vs incremental output keyed by pk + canonicalized JSON (`canonicalize_json`); the changed set
must miss nothing → **0 semantic diffs**. This is the mechanism that caught the `mappings` bug that
two static review passes missed.

Add **total-order tie-breaks / `ORDER BY` to any `STRING_AGG`** and `ROW_NUMBER` pick so the oracle is
literally 0 and cross-release content diffs stay honest (as done for `variation_identity` — otherwise
unordered scalar CSVs like `consq_id` inflate the changed set because `canonicalize_json` cannot
reorder them).

The `gks_scv_change_audit` unexplained count (§3.3) is a standing production check layered on top of
the per-release oracle.

---

## 7. Build order (phasing)

Oracle each phase before moving to the next.

1. **`gks_catvar`** — establishes the global-dict pattern (§2), the novel piece; closest to the
   proven `variation_identity` model, and its change-log already validates the diff. Also close the
   `gene_association` diff-driver gap here.
2. **`gks_scv_condition` + `gks_scv_statement`** — SCV-driven, no aggregation; establishes the
   `scv_significant_change` predicate (§3.1) and the `gks_scv_change_audit` detector (§3.3).
3. **`gks_rcv` / `gks_rcv_statement` + `gks_vcv` / `gks_vcv_statement`** — the parallel aggregation
   cascade (§3.2), the hardest correctness piece; lean hard on the oracle.
4. **`gks_json`** — assembles only changed keys, change-log-driven.

Delta publishing (§4) and the pipeline-version gate (§5) are cross-cutting and land alongside phase 1
so the pattern (payload table + manifest + stamp) is set once and reused by every later phase.

---

## Open items to resolve during planning

- **Exact `{KFILTER}` mechanism** per aggregate proc — whether each proc can be cleanly restricted to
  an impact set of parent keys via a filter parameter, or needs light refactoring (mirrors the
  `{VFILTER}` approach in `variation_identity`).
- **`gene_association` diff wiring** — where to add it to `dataset_diff_on`'s `diff_*` set.
- **Cost measurement per table** post-implementation — confirm the delta-deliverable justification
  holds (downstream procs are cost-marginal to break-even; the delta product, not slot-time, is the
  primary justification for going incremental across all of them).
- **Manifest storage/publish shape** for `manifest.json` (derived from the `gks_change_log` slice).
