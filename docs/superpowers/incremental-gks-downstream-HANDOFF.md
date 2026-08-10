# Incremental GKS Downstream + Delta Datasets — HANDOFF / CONTINUATION BRIEF

> **New context: start here.** This is a self-contained brief to resume the incremental-GKS initiative.
> Read this file, then the spec and the three plan docs it references. Everything below reflects work
> completed as of **2026-08-09**. All BigQuery work is on project **`clingen-dev`**.

---

## Mission (one paragraph)

Make **every** downstream `gks_*` BigQuery stored proc build **incrementally** (carry forward the records that
didn't change since the prior weekly release; recompute only the impacted ones), and produce **per-release delta
datasets** (the new/changed/deleted records per output table) so downstream consumers can apply just the changes.
The full dataset is always still built in BigQuery (`full(N) = carry-forward(unchanged from full(N-1)) UNION
recomputed delta`); the delta is the byproduct of incremental compute. Primary justification is the **delta
product** (downstream consumers), not slot-time — most downstream procs are cost-marginal; only
`variation_identity` (already done, pre-initiative) is a large slot-time win.

## Status — 3 of 4 plans DONE, Plan 4 remains

| Plan | Scope | Branch | PR | State |
|---|---|---|---|---|
| Spec | design (all phases) | — | — | `docs/superpowers/specs/2026-08-06-incremental-gks-downstream-and-deltas-design.md` (approved) |
| 1 | `gks_catvar` + **foundations** (version gate, oracle, change-log/delta) | `feat/incremental-gks-catvar-plan1` | **#74** | done, deployed, oracle-green |
| 2 | `gks_scv_condition` + `gks_scv_statement` (+ `gks_scv_changed`) | `feat/incremental-gks-scv-plan2` | **#75** | done, deployed, oracle-green |
| 3 | `gks_rcv`/`gks_vcv` aggregation cascade (+ `gks_rcvvcv_changed`) | `feat/incremental-gks-rcvvcv-plan3` | **#76** | done, deployed, oracle-green |
| **4** | **`gks_json` incremental + R2 delta publishing** | — (not started) | — | **NEXT — see "Plan 4" below** |

**PRs are STACKED**: #74 ← #75 ← #76 (each based on the previous branch, since none are merged yet).
**Merge order: #74 → #75 → #76** (rebasing each onto `main` as the prior merges, or merge the chain).
The plan docs for 1/2/3 are `docs/superpowers/plans/2026-08-0{4,5,6,7,8}-incremental-gks-*.md`.

**All procs are deployed to `clingen-dev`** (deploying is how the oracles ran), so the live `clinvar_ingest`
dataset already has every incremental proc. The git PRs are the source-of-truth for the code.

---

## The reusable architecture (every proc follows this — copy it for Plan 4)

**Per proc**, split into:
- internal `gks_X_build(on_date, debug, incremental)` — shared logic; a per-record/per-parent key filter
  (`{VFILTER}`/`{PFILTER}`) applied only when `incremental`.
- non-breaking wrappers `gks_X_proc(on_date, debug)` (full) and `gks_X_proc_incremental(on_date, debug)`.
- a **structural + version-gate fallback guard**: `eff_incremental = base_ok AND diff_ok AND gate_ok`
  (baseline resolvable + baseline has all outputs + current release has the required `diff_*`/changed-set
  driver tables + `gks_pipeline_version` gate matches). Any failure → full rebuild (always correct).
- **`UNION-CTAS` carry-forward merge** (NOT DELETE+INSERT): `new = ({base}.X WHERE key NOT IN impacted
  AND key IN current) UNION ALL (recomputed impacted)`, with **explicit column lists** (both arms identical
  name/type/order — a mismatch errors loudly = the version-invalidation signal), **NULL-safe LEFT-JOIN
  anti-joins** (never `NOT IN` over a subquery), and a **removed-parent/record exclusion** on the carry-forward arm.

**Global dedup dicts** (keyed by content digest / accession / gene / trait) are the exception: **recomputed
globally every release**; their delta comes from the change-log content diff (they can't cleanly carry forward
because a changed input can add a shared entry or drop the last reference to one).

**Shared foundations (already built — reuse, don't rebuild):**
- `clinvar_ingest.gks_pipeline_version(on_date, audit_stamp, gate_key)` → `{S}.gks_pipeline_version`. Written by
  `run-release.sh`. `audit_stamp = git describe --tags --always --dirty`; `gate_key = git log -1 --format=%H --
  src/procedures src/scripts src/vrsify` (build-path-scoped, so docs-only commits don't force full rebuilds).
  Carry-forward valid only when baseline gate == current gate; the **two-statement gate check** (existence-count
  then compare) avoids a BigQuery analysis-time error when a pre-feature baseline has no stamp.
- `clinvar_ingest.gks_oracle_compare(schema_a, schema_b, table_name)` — **3-arg canonical-row MULTISET** compare
  (dup-key-safe, order-independent via `canonicalize_json`). **THE correctness gate.** Returns
  `(table, a_only, b_only, canonical_diffs)`; `0,0,0` = identical.
- `clinvar_ingest.gks_change_log(on_date)` — A/U/D manifest per tracked output table (two-tier canonicalize diff,
  `GROUP BY pk + ANY_VALUE`). Extend its `tracked` array for new outputs (name + **actual pk column**).
- `clinvar_ingest.gks_delta_build(on_date)` — materializes `{S}.delta_<table>` = A∪U rows (same schema as target;
  D tombstones live only in the manifest). Extend its `tables` array in lockstep with `gks_change_log.tracked`.
- `clinvar_ingest.dataset_diff_on(on_date)` — produces all `{S}.diff_<table>` drivers (wired into `run-release.sh`
  Stage 0). Diff tables are keyed per `src/procedures/dataset-diff-all-proc.sql`.
- Shared changed/impacted-set procs: `gks_scv_changed` (SCV changed/removed + `gks_scv_change_audit`),
  `gks_rcvvcv_changed` (impacted RCV/VCV parent sets). Pattern: single-arg proc, persistent `{S}` tables,
  **all-or-nothing driver gate** (any required `diff_*` missing → everything-changed fallback), uncorrelated
  UNION-DISTINCT arms, NULL-safe anti-joins.

**Pipeline wiring** (`src/scripts/vrs-to-bq-table.sh` `execute_bq_procedures`, current order):
catvar(incr) → `gks_scv_changed` → scv_condition(incr) → scv_statement(incr) → `gks_rcvvcv_changed` →
gks_rcv(incr) → gks_rcv_statement(incr) → gks_vcv(incr) → gks_vcv_statement(incr) → **`gks_json_proc` (still FULL)**
→ `gks_change_log` → `gks_delta_build`. The `--full` override is `GKS_FULL` (set by `run-release.sh --full`;
forces every incremental proc's full wrapper this run while keeping an honest gate for next week).

**End-to-end release:** `src/scripts/run-release.sh YYYY-MM-DD [--full] [--dry-run] [--start-step N]` (5 stages;
Stage 0 dataset_diff + version stamp; Stage 4 = vrs-to-bq-table.sh; Stage 5 = release-gks.sh → R2).

---

## How to work (process) + test setup

- **Process:** superpowers `brainstorming` → `writing-plans` (with a plan-document-reviewer loop) →
  `subagent-driven-development` (fresh subagent per chunk + **two-stage review: spec-compliance then
  code-quality**), each chunk **gated on a 0-diff oracle**, then a final holistic review → stacked PR via
  `finishing-a-development-branch`.
- **Deploy a proc:** `bq query --project_id=clingen-dev --use_legacy_sql=false < src/procedures/<file>.sql`
  (procs are deployed manually; there is NO migration tool).
- **Test release pair:** baseline **`2026-07-15`**, compare **`2026-07-20`** (datasets `clinvar_2026_07_15_v2_5_0`
  / `clinvar_2026_07_20_v2_5_0`; `2026-07-27` also exists). Pick another adjacent existing pair if archived.
- **Oracle harness pattern:** `src/scripts/oracle-*.sh` build full then incremental of a proc into
  `{S}_oracle_full` / `{S}_oracle_incr` scratch datasets and compare each output with the 3-arg
  `gks_oracle_compare`. Same-version baseline is required (rebuild the baseline with the current proc first, since
  a proc change bumps the gate). **Clean up `*_oracle_*` / `*_recon` scratch datasets when done.**
- **Standard oracle prereq call** (stamps + drivers + changed-sets), adapt per proc:
  `CALL dataset_diff_on(DATE '2026-07-20'); CALL gks_pipeline_version(DATE '2026-07-15','seed','GATE1');
  CALL gks_pipeline_version(DATE '2026-07-20','seed','GATE1'); CALL gks_scv_changed(DATE '2026-07-20');
  CALL gks_rcvvcv_changed(DATE '2026-07-20');` then the proc's `_incremental`.

---

## Hard-won lessons (do NOT relearn these the hard way)

1. **The full-vs-incremental oracle is the ONLY thing that finds cross-record impact-set gaps.** Plan/spec/code
   review missed every one. `gks_scv_changed` took ~5 oracle-driven rounds; each downstream oracle exposed
   another input the changed set had to cover. **Always** validate a new incremental proc with a 0-diff oracle on
   a release window that actually exercises the relevant change vectors; never relax the oracle to pass.
2. **`[id,version]`-keyed diffs (clinical_assertion, rcv_accession, variation_archive):** a version bump appears as
   the same id in BOTH `new` AND `removed`. So (a) "removed" must mean **absent from the current base table**, not
   `diff.change_type='removed'`; (b) changed-set = `new ∪ modified` keeps version-bumped rows in; (c) audits must
   compare cur-vs-base on the id, not rely on `change_type='modified'`.
3. **Determinism is required for carry-forward.** Any `ANY_VALUE()` / unordered `STRING_AGG` / untied `ROW_NUMBER`
   over heterogeneous groups makes recompute non-deterministic → breaks the "carried-forward row == recomputed
   row" invariant (and flakes full-vs-full). Fixed across `variation_identity` (ORDER BY on aggregates),
   `gks_rcv_proc` (4 attrs), `gks_vcv_proc` (2 attrs) via a deterministic representative pick (smallest
   `full_scv_id`). Watch for this in `gks_json` (Plan 4) too.
4. **All-or-nothing driver gate, not per-arm skip.** `dataset_diff_all` wraps each table's diff in
   `BEGIN…EXCEPTION…continue`, so a single `diff_*` can be silently absent. A shared changed/impacted-set proc
   must fall back to everything-changed if ANY required driver is missing (per-arm skipping ships a partial set
   that looks valid).
5. **Inline-embedded content needs its own cascade arm.** A per-record output that embeds non-key content (a trait
   name, submitter name, gene context) is impacted when that content changes even if the record's own key didn't.
   Determine what each output embeds inline vs references by `#/...` pointer. (This drove many `gks_scv_changed`
   cascade arms: trait/trait_set/trait_mapping/clinical_assertion_trait(_set)/xref-medgen/rcv_mapping/submitter.)
6. **Over-inclusion is safe; under-inclusion ships stale.** When unsure whether a change vector affects an output,
   include its records in the changed/impacted set — recomputing an unchanged record yields a byte-identical row
   (oracle stays 0). Prefer the broader set.
7. **Background subagents sometimes stall on long BQ oracle jobs** (they return "waiting for a job" without
   finishing). For heavy oracle/reconstruction runs, drive them via a background **bash** command (survives across
   turns, notifies on completion) and read the result, rather than relying on the subagent to poll.

## Known residuals / follow-ups (not blocking; decide in a future plan)

- **`dataset_diff` SKIPs `variation_archive_classification`** (a `release_date` / `SELECT * EXCEPT` bug in
  `dataset-diff-all-proc.sql`). Unrelated to correctness so far (GKS VCV recomputes classification from SCVs), but
  worth fixing in `dataset_diff`.
- **Config-data-only changes** to shared `clinvar_ingest.clinvar_*_types` / `submission_level` /
  `gks_xref_iri_templates` lookups aren't caught per-record and aren't in the build-path `gate_key` (they change
  via `setup-translation-tables.sql`, which IS gated, so *code* changes are covered; pure data edits are the gap).
- **`gks_dict_proposition` (Plan 2) is globally recomputed** (not per-SCV carry-forward) because it embeds a
  variation→gene `geneContextQualifier` not in the SCV changed set. A **variation/gene cascade** in
  `gks_scv_changed` would let it return to per-SCV — deferred; revisit if needed.
- **`gks_dict_allele` (Plan 1) has ~8 pre-existing duplicate keys** (a digest-keyed dict with >1 value/key). The
  multiset oracle handles it; minor spurious manifest churn. A dedup is a possible catvar data-quality fix.
- **Determinism fixes change published values** for heterogeneous somatic RCV/VCV groups (arbitrary →
  deterministic) — expect one-time change-log churn on the first post-merge release.

---

## Plan 4 (NEXT) — `gks_json` incremental + R2 delta publishing

**Two pieces.** Brainstorm/plan it the same way (spec §4 covers the delta product + R2 cadence).

**(A) `gks_json_proc` incremental.** It's still a FULL rebuild (the only downstream proc that is). It assembles the
final bundle JSON from the upstream dict tables. Its outputs (verify: `gks_catvar`, `gks_scv_statement`,
`gks_rcv_statement`, `gks_vcv_statement` — the JSON renders, already tracked in `gks_change_log`) are 1:1 renders
of upstream dicts keyed by the same id. **Impact set = the union of all upstream A/U/D from `gks_change_log`** (it
already has every upstream change) — assemble only changed keys, carry forward the rest. This is the simplest
cascade in the initiative (change-log-driven, no new membership logic). Refactor to build/wrapper/guard +
UNION-CTAS merge like the others; oracle 0,0,0; add its outputs' deltas if not already covered.

**(B) R2 delta publishing.** Currently `src/scripts/upload-gks-to-r2.sh` (+ `release-gks.sh`, `export-gks-dicts.sh`)
publish the full keyed `.json.gz` bundle + Parquet to Cloudflare R2 (`datasets/weekly`, monthly `datasets/`,
`archives/`, `datasets/parquet/`). **Add delta publishing:**
- Export the `{S}.delta_<table>` tables (already built by `gks_delta_build`) → **Parquet + NDJSON directly from BQ**
  (`bq extract` / `EXPORT DATA` — the efficient path, mirroring the full-set formats; never NDJSON→Parquet).
- **Cadence (decided in spec §4): deltas every weekly release; full sets only on the last release of each month**
  (that release's full set promoted to the monthly/archival slot — same weekly→monthly promotion as today). The
  full table is ALWAYS built in BQ (next week's carry-forward baseline); only the R2 *publish* cadence changes.
- **Manifest** = the per-release `gks_change_log` slice (table, pk, change_type A/U/D, baseline_release,
  compare_release) as `manifest.json`. Consumer model = last monthly full + replay contiguous weekly deltas; the
  baseline/compare stamps let a consumer detect a missing week (chain gap).
- Delta payload shape = same schema as the target table, A∪U rows only (D in the manifest). A new R2 layout tree
  for deltas alongside the existing full-set locations.
- Docs: update `docs/` (mkdocs) for the delta product; `mkdocs build --strict` before committing; use the
  `write-docs` skill.

---

## Where everything is

- **Spec:** `docs/superpowers/specs/2026-08-06-incremental-gks-downstream-and-deltas-design.md`
- **Plans:** `docs/superpowers/plans/2026-08-0{4-downstream, 5-vi-v2, 6-plan-1-catvar-and-foundations,
  7-incremental-gks-downstream-plan-2-scv, 8-...plan-3-rcv-vcv}.md`
- **New procs (this initiative):** `gks-pipeline-version-proc.sql`, `gks-oracle-compare-proc.sql`,
  `gks-delta-proc.sql`, `gks-scv-changed-proc.sql`, `gks-rcvvcv-changed-proc.sql` (+ `gks-change-log-proc.sql`,
  `dataset-diff-*` from prior work).
- **Refactored procs (build/wrapper/incremental):** `variation-identity-proc.sql` (pre-initiative template),
  `gks-catvar-proc.sql`, `gks-scv-condition-proc.sql`, `gks-scv-statement-proc.sql`, `gks-rcv-proc.sql`,
  `gks-rcv-statement-proc.sql`, `gks-vcv-proc.sql`, `gks-vcv-statement-proc.sql`. **Use any of these as the copy
  template for Plan 4.**
- **Oracle scripts:** `src/scripts/oracle-{catvar,scv-condition,scv-statement,rcv,rcv-statement,vcv,vcv-statement}.sh`
- **Orchestration:** `src/scripts/run-release.sh`, `src/scripts/vrs-to-bq-table.sh`, `src/scripts/upload-gks-to-r2.sh`.
- **Local memory (if it carries over):** `~/.claude/projects/-Users-lbabb-Development-gks-clinvar-gks/memory/`
  — see `project_incremental_downstream_and_deltas.md` (the running log). This HANDOFF supersedes it as the
  starting point.

## First actions for the new context
1. Read this file + the spec §4.
2. `git log --oneline -15` and `gh pr list` to confirm #74/#75/#76 state (merge them in order if not yet merged).
3. Confirm procs still deployed: `bq query --use_legacy_sql=false "SELECT COUNT(*) FROM clinvar_ingest.INFORMATION_SCHEMA.ROUTINES WHERE routine_name LIKE 'gks_%incremental'"` (expect the incremental wrappers present).
4. Brainstorm/plan **Plan 4** (gks_json incremental + R2 delta publishing) and execute it with the oracle-gated,
   two-stage-review process above. Branch off the Plan 3 branch (or off `main` once #74–#76 merge).
