# Incremental GKS Downstream — Plan 3: gks_rcv + gks_vcv (aggregation cascade)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the four RCV/VCV procs (`gks_rcv_proc`, `gks_rcv_statement_proc`, `gks_vcv_proc`, `gks_vcv_statement_proc` — 12 outputs total) build incrementally by recomputing only the RCV/VCV **parents** impacted by this release's changes and carrying the rest forward, and publish their per-release delta datasets. This is the **aggregation cascade** — the spec's single hardest correctness case: a changed SCV forces recompute of its parent RCV/VCV *even though the parent's own row is byte-identical*, because the statement re-aggregates across members.

**Architecture:** Reuse the shipped patterns (Plans 1–2): `*_build(on_date, debug, incremental)` + non-breaking `*_proc`(full)/`*_proc_incremental` wrappers; resolve-baseline + structural + `gks_pipeline_version` gate guard; `{PFILTER}`-filtered recompute into `{P}.stg_*`; `UNION-CTAS` carry-forward merge with explicit column lists + NULL-safe anti-joins. A shared `gks_rcvvcv_changed` computes the impacted-RCV and impacted-VCV parent sets ONCE (membership-first from Plan 2's `gks_scv_changed` outputs), consumed by all 4 procs. Correctness gated per output by the `gks_oracle_compare` multiset oracle (0 diffs).

**Tech Stack:** BigQuery stored procedures (dynamic SQL); `bash` orchestration. Deploy: `bq query --project_id=clingen-dev --use_legacy_sql=false < file.sql`.

**Spec:** `docs/superpowers/specs/2026-08-06-incremental-gks-downstream-and-deltas-design.md` (§3.2 RCV/VCV independent parallel aggregates + membership-first impact set; §5 gate; §6 oracle; §4 delta).

**Depends on Plans 1–2 (shipped on the ancestor branches, deployed to clingen-dev):**
- `gks_pipeline_version`, `gks_oracle_compare` (3-arg multiset), `gks_change_log`, `gks_delta_build`, `dataset_diff_on`.
- **`gks_scv_changed`** → `{S}.scv_changed_ids`, `{S}.scv_removed_ids`, `{S}.gks_scv_change_audit` (the SCV change classifier). This is the driver Plan 3 consumes.
- `GKS_FULL` force-full flag in `run-release.sh`/`vrs-to-bq-table.sh`.
- **Reference implementations to mirror** (this branch lineage): `src/procedures/gks-scv-changed-proc.sql` (shared-changed-set pattern, all-or-nothing driver gate, cascade arms), `src/procedures/gks-scv-condition-proc.sql` / `gks-catvar-proc.sql` (build/wrapper/guard/{VFILTER}/UNION-CTAS-merge), `src/procedures/gks-delta-proc.sql`.

**Test release pair:** baseline `2026-07-15`, compare `2026-07-20`, project `clingen-dev`. **No unit tests** — the oracle (`gks_oracle_compare` full-vs-incremental = 0) is the gate.

---

## Output classification (the 12 Plan-3 outputs)

All 12 are **parent-keyed** (per RCV or per VCV) — there are NO global-dedup dicts in this plan. Every output carries `rcv_accession` (RCV side) or `vcv_accession`/`variation_id` (VCV side) either as a column or embedded in its `id`, so all 12 are carry-forward candidates keyed on the parent.

| Proc | Outputs | Parent key column |
|---|---|---|
| `gks_rcv_proc` | `gks_rcv_classification_agg`, `gks_rcv_priority_agg`, `gks_rcv_aggregate_contribution` | `rcv_accession` (column present) |
| `gks_rcv_statement_proc` | `gks_dict_rcv_evidence_line`, `gks_dict_rcv_proposition`, `gks_dict_rcv` | `rcv_accession` (column if present, else parse from `id`) |
| `gks_vcv_proc` | `gks_vcv_classification_agg`, `gks_vcv_priority_agg`, `gks_vcv_aggregate_contribution` | `vcv_accession` (column present) |
| `gks_vcv_statement_proc` | `gks_dict_vcv_evidence_line`, `gks_dict_vcv_proposition`, `gks_dict_vcv` | `vcv_accession` (column if present, else parse from `id`) |

The `_agg` tables are intermediate (feed the statements); they are carried forward for compute savings and correctness, but the **published delta product** is the statement/dict outputs (evidence_line, proposition, dict_rcv/dict_vcv) plus the existing `gks_rcv_statement`/`gks_vcv_statement` JSON renders from `gks_json_proc` (already tracked in `gks_change_log`). Chunk 6 decides exactly which get `delta_*` payloads.

---

## Impact model — shared `gks_rcvvcv_changed`

**RCV and VCV are INDEPENDENT parallel aggregates over SCVs** (spec §3.2 — VCV does NOT read RCV). Two impacted-parent sets, computed once and shared by all 4 procs.

**Member-SCV driver = `scv_changed_ids ∪ scv_removed_ids`** (from `gks_scv_changed`). Both are needed: a *removed* SCV's old parent must recompute (it lost a member), and `scv_changed_ids` already folds in every content/trait/version driver Plan 2 hardened. Using the full `scv_changed_ids` (not just the `version/review_status` aggregate-significant subset from the audit) is deliberate **safe over-inclusion**: an SCV that's in `scv_changed_ids` for a reason that doesn't change the aggregate (e.g. submitter rename — the agg counts `submitter_id`, not name) recomputes its parent to a byte-identical row → oracle stays 0. Do NOT try to shrink to the audit subset — that reintroduces the under-inclusion trap Plan 2 hit five times.

**`{S}.rcv_impacted_ids(rcv_accession)`** =
- RCVs with ≥1 member SCV in `(scv_changed_ids ∪ scv_removed_ids)`, membership via the **UNION of current `{S}.rcv_mapping` and baseline `{base}.rcv_mapping`** `scv_accessions` (so an SCV re-assigned to a different RCV recomputes BOTH the old and new parent) **∪**
- RCVs whose membership changed: `diff_rcv_mapping` (non-exact) → `rcv_accession` **∪**
- RCVs whose own accession record changed: `diff_rcv_accession` (non-exact, new|modified) → `id` **∪**
- (belt-and-suspenders) RCVs whose own `gks_rcv_aggregate_contribution` row diffs vs baseline
— **minus** removed RCVs (`diff_rcv_accession` removed, or absent from `{S}.rcv_accession`).

**`{S}.vcv_impacted_ids(vcv_accession)`** =
- VCVs whose variation has ≥1 member SCV in `(scv_changed_ids ∪ scv_removed_ids)`. VCV membership = SCVs sharing the VCV's `variation_id` (VCV ⋈ SCV on `variation_id` via `variation_archive`). Resolve the changed SCVs' `variation_id` over the **UNION of current + baseline `scv_summary`** (a removed SCV's variation only exists in baseline), then map `variation_id → variation_archive.id` over current+baseline `variation_archive` **∪**
- VCVs whose `variation_archive` record changed: `diff_variation_archive` (non-exact) → `id` **∪**
- (belt-and-suspenders) VCVs whose own `gks_vcv_aggregate_contribution` row diffs vs baseline
— **minus** removed VCVs (`diff_variation_archive` removed / absent from `{S}.variation_archive`).

**All-or-nothing driver gate** (mirror `gks_scv_changed`): required diff drivers = `diff_rcv_mapping`, `diff_rcv_accession`, `diff_variation_archive` (+ the changed-set tables from `gks_scv_changed`). If any is missing (or baseline missing), fall back to **everything-impacted** (`rcv_impacted_ids` = all `{S}.rcv_accession.id`; `vcv_impacted_ids` = all `{S}.variation_archive.id`) — safe (incremental degrades to full).

> **Config-table limitation (documented, same class as Plan 2's `gks_xref_iri_templates`):** the aggregation reads shared `clinvar_ingest.clinvar_clinsig_types` / `clinvar_proposition_types` / `clinvar_statement_types` / `submission_level` lookup tables. A change to that config *data* (without a `src/` change) is not caught per-parent and not caught by the build-path `gate_key`. These are loaded by `setup-translation-tables.sql` (in `src/procedures`), so a *code* change to them trips the gate → full rebuild. Config-data-only edits are a known residual; note it, don't solve it here.

---

## Chunk 1: shared `gks_rcvvcv_changed`

**Files:** Create `src/procedures/gks-rcvvcv-changed-proc.sql`.

- [ ] **Step 1: Verify the drivers + membership tables exist and their keys.** Confirm `diff_rcv_mapping`, `diff_rcv_accession`, `diff_variation_archive` are produced by `dataset_diff_all` (check `src/procedures/dataset-diff-all-proc.sql` for their `keys`) and present in `{S}`. Confirm `rcv_mapping` has `rcv_accession` + `scv_accessions` (array); `rcv_accession` has `id`; `variation_archive` has `id` + `variation_id`; `scv_summary` has `id` + `variation_id`.

- [ ] **Step 2: Write the proc** `clinvar_ingest.gks_rcvvcv_changed(on_date DATE)` (single-arg, persistent `{S}` tables, mirror `gks_scv_changed`'s structure). Resolve baseline via `schema_on(prev_release_date)`. All-or-nothing gate: if baseline missing OR any required driver/changed-set table missing → `rcv_impacted_ids` = all `{S}.rcv_accession.id`, `vcv_impacted_ids` = all `{S}.variation_archive.id`; RETURN. Otherwise build `{S}.rcv_impacted_ids(rcv_accession)` and `{S}.vcv_impacted_ids(vcv_accession)` exactly per the Impact model above (uncorrelated UNION-DISTINCT arms; anti-join out removed; NULL-safe). Document each arm in a comment.

- [ ] **Step 3: Deploy + sanity-check.**
```bash
bq query --project_id=clingen-dev --use_legacy_sql=false < src/procedures/gks-rcvvcv-changed-proc.sql
bq query --project_id=clingen-dev --use_legacy_sql=false \
  "CALL \`clinvar_ingest.dataset_diff_on\`(DATE '2026-07-20');
   CALL \`clinvar_ingest.gks_scv_changed\`(DATE '2026-07-20');
   CALL \`clinvar_ingest.gks_rcvvcv_changed\`(DATE '2026-07-20')"
S=clinvar_2026_07_20_v2_5_0
bq query --project_id=clingen-dev --use_legacy_sql=false --format=csv \
  "SELECT
     (SELECT COUNT(*) FROM \`${S}.rcv_impacted_ids\`) rcv_impacted,
     (SELECT COUNT(*) FROM \`${S}.rcv_accession\`) rcv_total,
     (SELECT COUNT(*) FROM \`${S}.vcv_impacted_ids\`) vcv_impacted,
     (SELECT COUNT(*) FROM \`${S}.variation_archive\`) vcv_total,
     (SELECT COUNT(*) FROM \`${S}.rcv_impacted_ids\` a JOIN \`${S}.rcv_impacted_ids\` b USING(rcv_accession) GROUP BY 1 HAVING COUNT(*)>1 LIMIT 1) dup_check"
```
Assert: impacted < total (a weekly release impacts a fraction), no dupes, no nulls. Report the impacted/total ratios for both.

- [ ] **Step 4: Commit** — `git add src/procedures/gks-rcvvcv-changed-proc.sql && git commit -m "feat(rcvvcv): shared impacted-RCV/VCV parent sets (membership-first cascade)"`

---

## Chunk 2: incremental `gks_rcv_proc` (3 agg outputs)

**Files:** Modify `src/procedures/gks-rcv-proc.sql`; Create `src/scripts/oracle-rcv.sh`.

- [ ] **Step 1: Oracle runbook** `src/scripts/oracle-rcv.sh` (copy `src/scripts/oracle-scv-condition.sh`; TABLES = `gks_rcv_classification_agg gks_rcv_priority_agg gks_rcv_aggregate_contribution`; full `gks_rcv_proc` then `gks_rcv_proc_incremental`; 3-arg `gks_oracle_compare`; `chmod +x`).

- [ ] **Step 2: Build/wrapper split + guard.** `gks_rcv_build(on_date,debug,incremental)` + wrappers. FOR loop selects `prev_release_date`. Guard `eff_incremental = base_ok AND diff_ok AND gate_ok`: base_ok = baseline has the 3 rcv agg outputs; diff_ok = `{S}.rcv_impacted_ids` present (+ `rcv_mapping`, `scv_summary`, `rcv_accession`); gate_ok = two-statement `gks_pipeline_version` compare.

- [ ] **Step 3: Filter the base temp to impacted parents.** In `temp_rcv_base_data` (the `rcv_mapping ⋈ scv_summary ⋈ rcv_accession` expansion), add `{PFILTER}` = `AND rm.rcv_accession IN (SELECT rcv_accession FROM \`{S}.rcv_impacted_ids\`)` (incremental) / `''` (full). This restricts ALL 3 agg queries (they read only `temp_rcv_base_data` + `{S}.gks_scv_condition_sets`) to impacted RCVs. **The `somatic_conditions` CTE joins `{S}.gks_scv_condition_sets`** — that's fine (it's keyed by scv_id of impacted RCVs' members). No global dict here, so all 3 agg outputs are per-parent.

- [ ] **Step 4: UNION-CTAS carry-forward merge** for each of the 3 agg outputs (incremental only). Each has a `rcv_accession` column → carry forward `{base}` rows `WHERE rcv_accession NOT IN (SELECT rcv_accession FROM {S}.rcv_impacted_ids)` (NULL-safe anti-join), UNION ALL the freshly-recomputed rows (which are already restricted to impacted via the base filter). Change each `CREATE OR REPLACE TABLE {S}.gks_rcv_*` to a `{HEAD}`-switch (stg temp in incremental, real table in full) OR — simpler here since the agg queries write directly to `{S}` — recompute to `{P}.stg_*` then merge. Use explicit column lists (`bq show --schema`). Removed RCVs are excluded from carry-forward (they're not in `{S}.rcv_impacted_ids` but ARE gone from `{base}`... note: carry-forward reads `{base}`, so a removed RCV would be carried forward unless excluded — add `AND rcv_accession IN (SELECT id FROM {S}.rcv_accession)` to the carry-forward arm, or exclude via a removed set). Verify against the oracle.

- [ ] **Step 5: Deploy + oracle.**
```bash
bq query --project_id=clingen-dev --use_legacy_sql=false < src/procedures/gks-rcv-proc.sql
bq query --project_id=clingen-dev --use_legacy_sql=false \
  "CALL \`clinvar_ingest.dataset_diff_on\`(DATE '2026-07-20');
   CALL \`clinvar_ingest.gks_pipeline_version\`(DATE '2026-07-15','seed','GATE1');
   CALL \`clinvar_ingest.gks_pipeline_version\`(DATE '2026-07-20','seed','GATE1');
   CALL \`clinvar_ingest.gks_scv_changed\`(DATE '2026-07-20');
   CALL \`clinvar_ingest.gks_rcvvcv_changed\`(DATE '2026-07-20')"
./src/scripts/oracle-rcv.sh 2026-07-20
```
MUST print 0,0,0 on all 3 agg tables. If nonzero on any: the RCV impact set (Chunk 1) is missing a parent, or the merge/removed handling is wrong — diagnose whether it's Chunk 1 (impacted set) vs the merge; do NOT relax. Report per-table diffs if BLOCKED.

- [ ] **Step 6: Commit** — `git add src/procedures/gks-rcv-proc.sql src/scripts/oracle-rcv.sh && git commit -m "feat(rcv): incremental gks_rcv agg layers (carry-forward unimpacted RCVs)"`

---

## Chunk 3: incremental `gks_rcv_statement_proc` (3 outputs)

**Files:** Modify `src/procedures/gks-rcv-statement-proc.sql`; Create `src/scripts/oracle-rcv-statement.sh`.

The 3 statement outputs are built FROM the 3 agg tables (+ a condition resolution via `rcv_mapping ⋈ gks_scv_condition_sets`). Same impacted-RCV set drives them.

- [ ] **Step 1: Oracle runbook** `src/scripts/oracle-rcv-statement.sh` (TABLES = `gks_dict_rcv_evidence_line gks_dict_rcv_proposition gks_dict_rcv`).
- [ ] **Step 2: Build/wrapper split + guard** (base_ok = 3 statement outputs; diff_ok = `rcv_impacted_ids` present; gate). 
- [ ] **Step 3: Filter to impacted RCVs.** Each output reads `FROM {S}.gks_rcv_*_agg agg` — add `{PFILTER}` = `WHERE agg.rcv_accession IN (SELECT rcv_accession FROM {S}.rcv_impacted_ids)` (or `AND` if the query has a WHERE). The condition-resolution CTE (reads `rcv_mapping ⋈ gks_scv_condition_sets`) — filter it to impacted RCVs too. Confirm the statement outputs reference variation/condition by **pointer** (`#/proposition`, `#/evidenceLine`, `#/condition`) not inline content (so no extra cascade beyond the impacted-RCV set is needed) — VERIFY by reading the assembly; if any inline non-pointer content from a per-SCV/trait source appears, flag it (that would need the impacted set to already cover it, which it does via scv_changed_ids membership).
- [ ] **Step 4: UNION-CTAS merge** the 3 outputs. Carry-forward key = `rcv_accession` (retain the column in staging if the output doesn't already carry it, OR parse from `id`/`prop_id`). Explicit column lists, NULL-safe anti-join, exclude removed RCVs.
- [ ] **Step 5: Deploy + oracle** (`./src/scripts/oracle-rcv-statement.sh 2026-07-20` → 0,0,0 on all 3). Prereqs: run `gks_rcv_proc_incremental` first (statements read its agg tables).
- [ ] **Step 6: Commit** — `feat(rcv): incremental gks_rcv_statement (carry-forward unimpacted RCVs)`

---

## Chunk 4: incremental `gks_vcv_proc` (3 agg outputs)

**Files:** Modify `src/procedures/gks-vcv-proc.sql`; Create `src/scripts/oracle-vcv.sh`.

Mirror Chunk 2 exactly, VCV side. `temp_vcv_base_data` = `scv_summary ⋈ variation_archive ON variation_id`. `{PFILTER}` = `AND va.id IN (SELECT vcv_accession FROM {S}.vcv_impacted_ids)`. The 3 agg outputs carry `vcv_accession` → carry-forward by it (exclude removed VCVs via `AND vcv_accession IN (SELECT id FROM {S}.variation_archive)`). Oracle `src/scripts/oracle-vcv.sh` (TABLES = the 3 vcv agg tables) → 0,0,0.

- [ ] Steps 1-6 as Chunk 2, VCV side. Commit `feat(vcv): incremental gks_vcv agg layers (carry-forward unimpacted VCVs)`.

---

## Chunk 5: incremental `gks_vcv_statement_proc` (3 outputs)

**Files:** Modify `src/procedures/gks-vcv-statement-proc.sql`; Create `src/scripts/oracle-vcv-statement.sh`.

Mirror Chunk 3, VCV side. Outputs `gks_dict_vcv_evidence_line`, `gks_dict_vcv_proposition`, `gks_dict_vcv` built from the vcv agg tables; filter to `vcv_impacted_ids`; carry-forward by `vcv_accession`. Oracle → 0,0,0 (prereq: `gks_vcv_proc_incremental` first). Commit `feat(vcv): incremental gks_vcv_statement (carry-forward unimpacted VCVs)`.

---

## Chunk 6: deltas + pipeline wiring

**Files:** Modify `src/procedures/gks-change-log-proc.sql`, `src/procedures/gks-delta-proc.sql`, `src/scripts/vrs-to-bq-table.sh`.

- [ ] **Step 1: Extend `gks_change_log` `tracked`** with the published RCV/VCV outputs: `gks_dict_rcv_evidence_line`(id), `gks_dict_rcv_proposition`(id), `gks_dict_rcv`(id), `gks_dict_vcv_evidence_line`(id), `gks_dict_rcv_proposition`… wait — use each output's actual pk column: verify via `bq show --schema` (likely `id` for the dict/evidence/proposition tables). (`gks_rcv_statement`/`gks_vcv_statement` JSON renders are already tracked.) Decide whether the 3 `_agg` layers per side get tracked/delta'd — DEFAULT: do NOT publish the intermediate `_agg` tables as deltas (they're internal); publish only the dict/evidence/proposition outputs + the existing statement JSON renders. Document the choice.
- [ ] **Step 2: Extend `gks_delta_build` `tables`** with the same published RCV/VCV outputs (same pks). Header note.
- [ ] **Step 3: Reconstruction test** for one RCV output (`gks_dict_rcv`, pk `id`) and one VCV output (`gks_dict_vcv`, pk `id`): `full == (baseline − U,D) UNION (A/U delta)` via 3-arg `gks_oracle_compare` → 0,0,0. Scratch `${S}_recon`.
- [ ] **Step 4: Wire the pipeline.** In `vrs-to-bq-table.sh` `execute_bq_procedures`, after the scv procs and BEFORE `gks_json_proc`: call `gks_rcvvcv_changed` once, then the 4 rcv/vcv procs via their `_incremental` wrappers honoring `GKS_FULL` (remove the 4 from the `BIGQUERY_PROCEDURES` full loop). Required order: catvar(incr) → gks_scv_changed → scv_condition(incr) → scv_statement(incr) → **gks_rcvvcv_changed → gks_rcv(incr) → gks_rcv_statement(incr) → gks_vcv(incr) → gks_vcv_statement(incr)** → gks_json_proc → gks_change_log → gks_delta_build. (rcv before rcv_statement; vcv before vcv_statement; rcvvcv_changed before all four.) `bash -n`.
- [ ] **Step 5: Commit** — `feat(delta): rcv/vcv change-log + delta payloads; wire rcv/vcv incremental into pipeline`

---

## Done criteria (Plan 3)
- [ ] All 4 rcv/vcv `_proc_incremental` wrappers build their outputs; every oracle reports **0 diffs** vs full (12 outputs across 4 oracle scripts).
- [ ] `gks_rcvvcv_changed` produces `rcv_impacted_ids` / `vcv_impacted_ids` membership-first (over current+baseline membership, from `scv_changed_ids ∪ scv_removed_ids`), behind an all-or-nothing driver gate.
- [ ] RCV and VCV remain **independent** (VCV never reads RCV).
- [ ] change-log + delta cover the published rcv/vcv outputs; reconstruction verified (0,0,0) for `gks_dict_rcv` + `gks_dict_vcv`.
- [ ] Pipeline wires `gks_rcvvcv_changed` before the 4 procs; incremental wrappers called; `GKS_FULL` forces full.

## Deferred / follow-ups
- Plan 4: `gks_json` incremental (assemble only changed keys) + **R2 delta publishing** (export `delta_*` → Parquet/NDJSON, weekly deltas / monthly full, `manifest.json`).
- Config-data-only changes to `clinvar_*_types`/`submission_level` lookups (not a `src/` change) aren't caught per-parent — known residual (same class as Plan 2's `gks_xref_iri_templates`).
- Variation/gene cascade in `gks_scv_changed` (deferred from Plan 2) — if a future need arises for `gks_dict_proposition` per-SCV carry-forward; not required by Plan 3 (rcv/vcv aggregate over SCV membership, and variation/gene changes on a member surface via `scv_changed_ids`).
