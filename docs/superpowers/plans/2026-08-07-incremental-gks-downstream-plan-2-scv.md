# Incremental GKS Downstream — Plan 2: gks_scv_condition + gks_scv_statement

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `gks_scv_condition_proc` and `gks_scv_statement_proc` build incrementally (carry forward unchanged per-SCV records, recompute only the impacted SCVs; recompute the global dedup dicts globally), publish their per-release delta datasets, and establish the shared SCV change classifier (`gks_scv_changed` + `gks_scv_change_audit`) that Plan 3's aggregate cascade will consume.

**Architecture:** Reuse the exact patterns Plan 1 shipped and proved: `*_build(on_date, debug, incremental)` internal proc + non-breaking `*_proc`(full)/`*_proc_incremental` wrappers; a resolve-baseline + structural + `gks_pipeline_version` gate fallback guard; `{VFILTER}`-filtered per-record recompute into `{P}.stg_*`; `UNION-CTAS` carry-forward merge with explicit column lists. Global dedup dicts are recomputed globally every release with their delta derived by the `gks_change_log` content diff (spec §2). A shared `gks_scv_changed` proc computes the changed/removed SCV sets + the change audit once, so both SCV procs (and Plan 3) consume a single consistent set. Correctness gated per table by the Plan 1 `gks_oracle_compare` multiset oracle (0 diffs).

**Tech Stack:** BigQuery stored procedures (dynamic SQL); `bash` orchestration (`vrs-to-bq-table.sh`). Deploy: `bq query --project_id=clingen-dev --use_legacy_sql=false < file.sql`.

**Spec:** `docs/superpowers/specs/2026-08-06-incremental-gks-downstream-and-deltas-design.md` (§2 global dicts, §3.1 scv predicate + trait caveat, §3.3 audit, §4 delta, §5 gate, §6 oracle).

**Depends on Plan 1 (already shipped on the parent branch `feat/incremental-gks-catvar-plan1`, deployed to clingen-dev):**
- `clinvar_ingest.gks_pipeline_version(on_date, audit_stamp, gate_key)` + `{S}.gks_pipeline_version` stamp.
- `clinvar_ingest.gks_oracle_compare(schema_a, schema_b, table_name)` — 3-arg canonical-row **multiset** compare (dup-key-safe).
- `clinvar_ingest.gks_change_log(on_date)` — A/U/D manifest; extended here with the 7 new outputs.
- `clinvar_ingest.gks_delta_build(on_date)` — materializes `{S}.delta_<T>`; extended here.
- `run-release.sh` Stage 0 `dataset_diff_on` (produces `{S}.diff_*`, incl. `diff_clinical_assertion`, `diff_trait`, `diff_trait_set`) + version stamp.
- **Reference implementations to copy** (this branch): `src/procedures/gks-catvar-proc.sql` (build/wrapper/guard/{VFILTER}/UNION-CTAS-merge — the exact template), `src/procedures/gks-delta-proc.sql`, `src/procedures/variation-identity-proc.sql`.

**Test release pair:** baseline `2026-07-15`, compare `2026-07-20` (adjust if archived). Project `clingen-dev`. **No unit tests** — a "test" is a `bq query` assertion or a proc that RAISEs; the oracle (`gks_oracle_compare` full-vs-incremental = 0) is the correctness gate.

---

## Output classification (the 7 Plan-2 outputs)

`gks_scv_condition_proc` emits 3; `gks_scv_statement_proc` emits 4. Split exactly like catvar's global-vs-per-record dicts:

| Output | Proc | pk column (value) | Nature | Incremental treatment |
|---|---|---|---|---|
| `gks_dict_condition` | condition | `id` (`clinvar.trait:*`) — NOT `key` | **global** (from `trait`) | recompute globally; delta via change-log content diff (driver `diff_trait`) |
| `gks_dict_condition_set` | condition | `id` (`clinvar.traitset:*`) — NOT `key` | **global** (from `trait_set`) | recompute globally; delta via change-log (drivers `diff_trait`+`diff_trait_set`) |
| `gks_scv_condition_sets` | condition | `scv_id` | **per-SCV** | `{VFILTER}` + UNION-CTAS carry-forward on `scv_changed_ids` |
| `gks_dict_submitter` | statement | `key` (`submitter.id`) | **global dedup** (GROUP BY submitter) | recompute globally; delta via change-log |
| `gks_dict_proposition` | statement | `key` (proposition id `{scv}-{code}`) | **per-SCV** (carry-forward filter parses scv from key) | `{VFILTER}` + UNION-CTAS carry-forward on `scv_changed_ids` |
| `gks_dict_evidence_line` | statement | `id` (`clinvar.submission:{scv}.{ver}`) | **per-SCV** | `{VFILTER}` + UNION-CTAS carry-forward on `scv_changed_ids` |
| `gks_dict_scv` | statement | `id` (`clinvar.submission:{scv}.{ver}`) | **per-SCV** | `{VFILTER}` + UNION-CTAS carry-forward on `scv_changed_ids` |

The 3 global dicts stay globally recomputed (unfiltered), exactly as catvar's six. Only the 4 per-SCV tables carry forward.

---

## Impact model — the shared SCV changed set

**Per-SCV recompute set** `scv_changed_ids` =
`diff_clinical_assertion(new|modified)` **∪ trait-driven SCVs** (SCVs whose referenced trait/traitset changed — for `gks_scv_condition_sets`' normalized fields), **minus** `diff_clinical_assertion(removed)`.
`scv_removed_ids` = `diff_clinical_assertion(removed)`.

Why `new|modified` (not the tighter version/review-status predicate): every per-SCV output is derived from that one SCV's own record, so any byte-modified SCV can change its own output — recompute it. The `version`/`review_status` refinement is **not** needed to shrink Plan 2's per-SCV recompute (it's for Plan 3's *aggregate* cascade). We still compute it, as the audit classifier below, because Plan 3 consumes it.

**Trait-driven SCVs** (the trait-content cascade, spec §3.1 caveat): a `trait`/`trait_set` edit changes `gks_scv_condition_sets`' normalized fields (`normalized_match`/`normalized_resolution`/`mapping`) with **no** SCV version bump. So `scv_changed_ids` must add the SCVs that reference a changed trait/traitset. **The per-SCV trait linkage is the clinvar trait id embedded in the condition pointers, NOT the submitted `medgen_id`** (which is a different keyspace — a submitted MedGen `C……` id — that will never match `diff_trait.id`). `diff_trait`/`diff_trait_set` are keyed on `trait.id`/`trait_set.id` (clinvar ids). So parse the clinvar ids out of `gks_scv_condition_sets`' `#/condition/clinvar.trait:{id}` (`normalized_match`/`direct_match`/`condition`) and `#/conditionSet/clinvar.traitset:{id}` (`conditionSet`) fields and match those. **This is the single biggest correctness risk in Plan 2** — exact fields verified in Chunk 1 Step 3, and the join MUST cover BOTH the single-condition shape (`extensions.value_submitted_condition`, a non-array struct) AND the multi-condition shape (`extensions.value_submitted_condition_set.concepts[]`); a concepts-only `UNNEST` silently drops every single-condition SCV. The oracle must exercise a window where `diff_trait` is non-empty (Chunks 2/3 check this and fall back to a synthetic check if the natural window has no trait churn).

> **Only `gks_dict_proposition` is pointer-insulated from trait content** (its `objectCondition` is a stable `#/condition…` pointer). **`gks_dict_scv` and `gks_dict_evidence_line` ARE trait-dependent** — they embed the full `extensions.value_submitted_condition(_set)` struct from `gks_scv_condition_sets`, which carries the trait-derived `normalized_match`/`normalized_resolution`/`mapping` fields (a trait edit changes them with no SCV version bump). So the trait cascade is **load-bearing for four tables** (`gks_scv_condition_sets` + `gks_dict_scv` + `gks_dict_evidence_line`, and trivially for proposition since it shares the set). Folding trait-driven SCVs into the ONE shared `scv_changed_ids` recomputes all of them correctly — do NOT later "optimize" scv/evidence_line out of the trait cascade on a mistaken trait-insulation assumption.

**Change audit** `gks_scv_change_audit` (spec §3.3, the Plan-3 classifier): for each `diff_clinical_assertion(modified)` SCV, classify by reason using `scv_summary` version/review_status vs baseline:

```
scv_significant_change(scv) := is A ∨ is D ∨ version != baseline.version ∨ review_status != baseline.review_status
```

Materialize `{S}.gks_scv_change_audit(scv_id, baseline_release, compare_release, version_changed BOOL, review_status_changed BOOL, unexplained BOOL)` where `unexplained` = modified but neither version nor review_status changed. Emit a `log()`/SELECT of the unexplained count. Unexplained SCVs are already in `scv_changed_ids` (they're `modified`), so they are recomputed — "log + conservatively recompute" (spec §3.3) holds for free.

---

## Chunk 1: shared SCV changed-set + audit (`gks_scv_changed`)

**Files:** Create `src/procedures/gks-scv-changed-proc.sql`.

- [ ] **Step 1: Write the changed-set + audit proc**

Create `clinvar_ingest.gks_scv_changed(on_date DATE)` (single-arg, like `gks_change_log`/`variation_vrs_changed`; writes persistent `{S}` tables, no debug/temp mode). Resolve baseline via `schema_on(prev_release_date)`. If baseline missing or `diff_clinical_assertion` absent → write `scv_changed_ids` = ALL scv ids from `{S}.scv_summary` and empty `scv_removed_ids` (first-run: everything changed) and an empty audit; RETURN. Otherwise:

- `{S}.scv_removed_ids(scv_id)` = `SELECT id FROM {S}.diff_clinical_assertion WHERE change_type='removed'`.
- `{S}.gks_scv_change_audit`: join `{S}.diff_clinical_assertion WHERE change_type='modified'` → `{S}.scv_summary` cur + `{base}.scv_summary` base on id; compute `version_changed = cur.version IS DISTINCT FROM base.version`, `review_status_changed = cur.review_status IS DISTINCT FROM base.review_status`, `unexplained = NOT version_changed AND NOT review_status_changed`; stamp baseline/compare release dates (via `schema_on`).
- `{S}.scv_changed_ids(scv_id)` = `diff_clinical_assertion(new|modified)` ∪ trait-driven (Step 3), minus `scv_removed_ids`.

Emit a final `SELECT COUNT(*) AS unexplained_scv FROM {S}.gks_scv_change_audit WHERE unexplained` (surfaced in job output). (Use the name `gks_scv_change_audit` consistently everywhere.)

- [ ] **Step 2: Verify SCV source fields exist**

Confirm `scv_summary` has `id`, `version`, `review_status`: `bq query --format=csv --quiet "SELECT column_name FROM \`clinvar_2026_07_20_v2_5_0.INFORMATION_SCHEMA.COLUMNS\` WHERE table_name='scv_summary' AND column_name IN ('id','version','review_status')"` → expect 3 rows. (temp_gks_scv reads these — confirmed in gks-scv-statement-proc.sql:45-96.)

- [ ] **Step 3: Ground + implement the trait-driven-SCV join (KEY RISK)**

Inspect `gks_scv_condition_sets` for the trait linkage: `bq show --schema --format=prettyjson clinvar_2026_07_20_v2_5_0.gks_scv_condition_sets`, and read `gks-scv-condition-proc.sql:885-968` (the `gks_scv_condition_sets` assembly). **Do NOT join on `medgen_id`** — that is the submitted MedGen concept id (`C…`), a different keyspace from `diff_trait.id` (clinvar trait id). The correct per-SCV linkage is the **clinvar trait id embedded in the condition pointers**: `#/condition/clinvar.trait:{id}` in the `condition`/`direct_match`/`normalized_match` fields (proc lines ~893/909/913) and `#/conditionSet/clinvar.traitset:{id}` in `conditionSet` (proc line ~892). Parse the id out (e.g. `REGEXP_EXTRACT(field, r'clinvar\\.trait:(.+)$')`) and match to `diff_trait.id` / `diff_trait_set.id`.

**Cover BOTH SCV shapes** (a concepts-only UNNEST silently drops single-condition SCVs):
- multi-condition: `extensions.value_submitted_condition_set.concepts[]` (proc ~927-932) — `UNNEST` the concepts.
- single-condition: `extensions.value_submitted_condition` (non-array struct, proc ~942-947) — read directly, no UNNEST.

```
SELECT DISTINCT cs.scv_id
FROM `{base}.gks_scv_condition_sets` cs
WHERE EXISTS (                                  -- multi-condition concepts
        SELECT 1 FROM UNNEST(cs.extensions.value_submitted_condition_set.concepts) c
        WHERE REGEXP_EXTRACT(c.<trait-id-bearing field>, r'clinvar\\.trait:(.+)$')
              IN (SELECT id FROM `{S}.diff_trait` WHERE change_type IN ('new','modified','removed'))
      )
   OR REGEXP_EXTRACT(cs.extensions.value_submitted_condition.<trait-id-bearing field>, r'clinvar\\.trait:(.+)$')
        IN (SELECT id FROM `{S}.diff_trait` WHERE change_type IN ('new','modified','removed'))   -- single-condition
   OR REGEXP_EXTRACT(cs.<conditionSet field>, r'clinvar\\.traitset:(.+)$')
        IN (SELECT id FROM `{S}.diff_trait_set` WHERE change_type IN ('new','modified','removed'))
```
Fill in the exact field names from the schema (the `#/condition/clinvar.trait:` value may live in `condition`, `direct_match`, or `normalized_match` — pick whichever actually holds the clinvar trait pointer; check which is populated). Guard: if `diff_trait`/`diff_trait_set` are absent, skip this arm. Document the chosen fields in a comment.

- [ ] **Step 4: Deploy + sanity-check**

```bash
bq query --project_id=clingen-dev --use_legacy_sql=false < src/procedures/gks-scv-changed-proc.sql
bq query --project_id=clingen-dev --use_legacy_sql=false "CALL \`clinvar_ingest.gks_scv_changed\`(DATE '2026-07-20')"
SCHEMA=clinvar_2026_07_20_v2_5_0
bq query --project_id=clingen-dev --use_legacy_sql=false --format=csv \
  "SELECT
     (SELECT COUNT(*) FROM \`${SCHEMA}.scv_changed_ids\`) AS changed,
     (SELECT COUNT(*) FROM \`${SCHEMA}.scv_removed_ids\`) AS removed,
     (SELECT COUNT(*) FROM \`${SCHEMA}.gks_scv_change_audit\` WHERE unexplained) AS unexplained,
     (SELECT COUNT(*) FROM \`${SCHEMA}.diff_clinical_assertion\` WHERE change_type IN ('new','modified')) AS diff_ca_new_mod,
     (SELECT COUNT(*) FROM \`${SCHEMA}.diff_trait\`) AS diff_trait_rows"
```
Sanity: `changed >= diff_ca_new_mod` (trait-driven may add more), `removed` matches `diff_clinical_assertion removed`. Report `unexplained` and `diff_trait_rows` (the latter tells us whether the oracle window exercises the trait cascade).

- [ ] **Step 5: Commit** — `git add src/procedures/gks-scv-changed-proc.sql && git commit -m "feat(scv): shared scv_changed set + change audit classifier"`

---

## Chunk 2: incremental gks_scv_condition

**Files:** Modify `src/procedures/gks-scv-condition-proc.sql`.

Refactor into `gks_scv_condition_build(on_date, debug, incremental)` + wrappers `gks_scv_condition_proc`(full)/`gks_scv_condition_proc_incremental`, mirroring `gks-catvar-proc.sql` exactly (build/wrapper split, guard, mode fragments, {VFILTER}, UNION-CTAS merge, cleanup/DROP).

- [ ] **Step 1: Oracle expectation (fails — no incremental wrapper yet).** Write an oracle runbook `src/scripts/oracle-scv-condition.sh` (copy `src/scripts/oracle-catvar.sh`; TABLES = `gks_dict_condition gks_dict_condition_set gks_scv_condition_sets`; calls `gks_scv_condition_proc` full then `gks_scv_condition_proc_incremental`, snapshots via CLONE, compares with 3-arg `gks_oracle_compare`). `chmod +x`; running it now fails on the missing `_incremental` wrapper (expected).

- [ ] **Step 2: Build/wrapper split + guard.** Internal `gks_scv_condition_build(on_date, debug, incremental)`; wrappers at the bottom. FOR loop selects `prev_release_date`. Guard `eff_incremental = base_ok AND diff_ok AND gate_ok` (mirror gks-catvar-proc.sql:75-122): `base_ok` = baseline has all 3 condition outputs; `diff_ok` = current release has `diff_clinical_assertion`, `diff_trait`, `diff_trait_set` AND `{S}.scv_changed_ids`/`scv_removed_ids` exist (produced by `gks_scv_changed`, which Chunk 4 wires to run first); `gate_ok` = two-statement `gks_pipeline_version` compare.

- [ ] **Step 3: Mode fragments.** `vfilter_cs` = per-SCV filter for `gks_scv_condition_sets` (alias-correct on its `scv_id`), `cs_head` = `{CT} {P}.stg_gks_scv_condition_sets` (incremental) vs `CREATE OR REPLACE TABLE \`{S}.gks_scv_condition_sets\`` (full). The two global dicts (`gks_dict_condition`, `gks_dict_condition_set`) are **never** filtered — always globally recomputed. Verify which temps feed the global dicts vs only `gks_scv_condition_sets` before filtering any temp (mirror catvar's "temp_ctxvar_expression stays global" analysis).

  **Verified temp dependencies (bake these in, confirm against the proc):** `gks_dict_condition` is built directly from `{S}.trait` (proc :42-121, no temps) — global, untouched. `gks_dict_condition_set` is fed by **BOTH** `temp_gks_scv_trait_sets` (proc :291) and `temp_all_rcv_traits` (proc :285,308) — **both must stay global (unfiltered)**. The exclusive per-SCV chain that feeds ONLY `gks_scv_condition_sets` is `temp_scv_trait_name_xrefs` → `temp_scv_trait_mappings` → `temp_scv_trait_assignment_stage1` → `..._stage2`; those may be filtered. The `{VFILTER}` for the final STEP 10 `gks_scv_condition_sets` write goes on the **outer FROM alias `gsts.scv_id`** (proc :962), NOT by filtering `temp_gks_scv_trait_sets`. Filter ONLY the exclusive chain + the final write; leave everything feeding `gks_dict_condition_set` global.

- [ ] **Step 4: Apply `{VFILTER}`/`{CS_HEAD}`.** Add `{VFILTER}` to the `gks_scv_condition_sets` assembly (filter on `scv_id IN (SELECT scv_id FROM {P}.scv_changed_ids)` — note `{P}` resolves to `_SESSION`; but `scv_changed_ids` is a persistent `{S}` table, so reference `{S}.scv_changed_ids` directly, not `{P}`) and any exclusively-feeding temps. Change the `gks_scv_condition_sets` head to `{CS_HEAD}`. Confirm the two global dict queries are untouched.

> The changed-set tables live in `{S}` (persistent, written by `gks_scv_changed`), unlike catvar's session-temp `catvar_changed_ids`. So the filter fragment references `\`{S}.scv_changed_ids\``, and the merge reads `{S}.scv_changed_ids`/`{S}.scv_removed_ids`. No Step-0 changed-set block is needed inside this proc (it's precomputed).

- [ ] **Step 5: UNION-CTAS merge `gks_scv_condition_sets`** (incremental only), explicit column list from `bq show --schema --format=prettyjson clinvar_2026_07_20_v2_5_0.gks_scv_condition_sets`: carry forward `{base}` rows whose `scv_id NOT IN (scv_changed_ids ∪ scv_removed_ids)`, UNION ALL `{P}.stg_gks_scv_condition_sets`. Mirror gks-catvar-proc.sql:1155-1175.

- [ ] **Step 6: Deploy + oracle (with trait-cascade coverage check).**
```bash
bq query --project_id=clingen-dev --use_legacy_sql=false < src/procedures/gks-scv-condition-proc.sql
# drivers + same-gate stamps + shared changed-set:
bq query --project_id=clingen-dev --use_legacy_sql=false \
  "CALL \`clinvar_ingest.dataset_diff_on\`(DATE '2026-07-20');
   CALL \`clinvar_ingest.gks_pipeline_version\`(DATE '2026-07-15','seed','GATE1');
   CALL \`clinvar_ingest.gks_pipeline_version\`(DATE '2026-07-20','seed','GATE1');
   CALL \`clinvar_ingest.gks_scv_changed\`(DATE '2026-07-20')"
./src/scripts/oracle-scv-condition.sh 2026-07-20
```
MUST print 0,0,0 on all 3 tables. **Trait-cascade coverage:** if Chunk 1 Step 4 reported `diff_trait_rows > 0`, this oracle genuinely exercises the trait-driven arm. If `diff_trait_rows = 0` (no trait churn in this window), the oracle can't prove the trait cascade — ADD a synthetic check: pick any trait id, confirm the SCVs referencing it (via the Step-3 join) all appear in `scv_changed_ids` when that id is treated as changed; document the residual coverage gap in the commit message. Do NOT relax the oracle.

- [ ] **Step 7: Commit** — `git add src/procedures/gks-scv-condition-proc.sql src/scripts/oracle-scv-condition.sh && git commit -m "feat(scv): incremental gks_scv_condition (carry-forward condition_sets, global condition dicts recomputed)"`

---

## Chunk 3: incremental gks_scv_statement

**Files:** Modify `src/procedures/gks-scv-statement-proc.sql`.

Same refactor pattern. 4 outputs: `gks_dict_submitter` is **global dedup** (unfiltered, recomputed); `gks_dict_proposition`, `gks_dict_evidence_line`, `gks_dict_scv` are **per-SCV** (carry-forward on `scv_changed_ids`).

- [ ] **Step 1: Oracle runbook** `src/scripts/oracle-scv-statement.sh` (copy pattern; TABLES = `gks_dict_submitter gks_dict_proposition gks_dict_evidence_line gks_dict_scv`; full vs `_incremental`). `chmod +x`.

- [ ] **Step 2: Build/wrapper split + guard.** `gks_scv_statement_build(on_date, debug, incremental)` + wrappers. Guard: `base_ok` = baseline has all 4 statement outputs; `diff_ok` = `{S}.scv_changed_ids`/`scv_removed_ids` present (+ `diff_clinical_assertion`, `diff_trait`, `diff_trait_set`); `gate_ok` = pipeline_version compare. **Include `diff_trait`/`diff_trait_set` in `diff_ok`**: `gks_dict_scv` and `gks_dict_evidence_line` embed the trait-derived submitted-condition struct (see the impact-model note), so statement correctness depends on `scv_changed_ids` being trait-complete — which requires those diff drivers to have been present when `gks_scv_changed` ran. Requiring them here keeps the guard honest and consistent with the condition chunk.

- [ ] **Step 3: Mode fragments + {VFILTER}.** The per-SCV temps (`temp_gks_scv`, `temp_gks_scv_proposition`, `temp_gks_scv_target_proposition`, qualifiers, `temp_scv_*`) are keyed by scv id — filter them to `{S}.scv_changed_ids` so only changed SCVs are computed. **`gks_dict_submitter` must stay global**: it GROUPs BY submitter over `temp_gks_scv` — if `temp_gks_scv` is filtered to changed SCVs, the submitter dict would lose submitters that only appear on unchanged SCVs. So EITHER (a) build `gks_dict_submitter` from an UNFILTERED submitter scan (a separate small full scan of `scv_summary`/`clinical_assertion` for submitter identity), OR (b) keep `temp_gks_scv` global and filter only downstream per-SCV assemblies. **Prefer (b) minimally**: keep the temps that feed `gks_dict_submitter` global, and apply `{VFILTER}` at the per-SCV final assemblies (`gks_dict_proposition`, `gks_dict_evidence_line`, `gks_dict_scv`) + their exclusive upstream temps. Verify each temp's consumers (like catvar's temp_ctxvar_expression analysis) before filtering. Set `{DP_HEAD}`/`{DEL_HEAD}`/`{DSCV_HEAD}` to stg temps (incremental) vs real tables (full).

> This is the trickiest chunk: `gks_dict_submitter` (global) and the 3 per-SCV dicts all derive from `temp_gks_scv`. Keep `temp_gks_scv` global (unfiltered) — it is the shared source — and push `{VFILTER}` only into the three per-SCV output assemblies (and any temp feeding ONLY them, e.g. `temp_scv_citations`/`temp_scv_method`/`temp_scv_condition_names`/proposition temps). The submitter dict then still sees all submitters. Over-computing per-SCV *temps* globally is acceptable if pushing the filter down is unsafe — but the three FINAL per-SCV writes MUST be filtered so carry-forward works.

- [ ] **Step 4: UNION-CTAS merge** the 3 per-SCV outputs (incremental only), explicit column lists via `bq show --schema`. Carry forward `{base}` rows whose scv is NOT in `scv_changed_ids ∪ scv_removed_ids`, UNION ALL the stg tables. Recover the scv id from each output's pk **by parsing the pk string** (both `{base}` and staged rows have only the output columns — no separate scv_id column unless you add one):
  - `gks_dict_scv` / `gks_dict_evidence_line`: id = `clinvar.submission:{scv}.{ver}` → `SPLIT(SPLIT(id, ':')[OFFSET(1)], '.')[OFFSET(0)]` yields `{scv}`.
  - `gks_dict_proposition`: key = `{scv_id}-{PROP_CODE}` → `SPLIT(key, '-')[OFFSET(0)]` yields `{scv_id}` (exact: scv_id contains no hyphen and is the first token even if a PROP_CODE contains hyphens). The stored value dropped `scv_id` (`EXCEPT(scv_id)`), and `{base}.gks_dict_proposition` has only `key`/`value` — so the id-parse is the ONLY workable carry-forward filter; do not attempt a `{base}` scv_id join.
  Carry-forward predicate per table: `WHERE <parsed scv id> NOT IN (SELECT scv_id FROM {S}.scv_changed_ids UNION DISTINCT SELECT scv_id FROM {S}.scv_removed_ids)`. The id/count checks in Step 5 catch a mis-keyed merge.

- [ ] **Step 5: Correctness checks + oracle.** Add a row-count/id sanity check (each per-SCV output's id set should cover exactly the SCVs present this release). Deploy, ensure `gks_scv_changed`/drivers/stamps exist (as Chunk 2 Step 6), run `./src/scripts/oracle-scv-statement.sh 2026-07-20` → 0,0,0 on all 4 tables. **Trait-cascade coverage (same as Chunk 2 Step 6):** because `gks_dict_scv`/`gks_dict_evidence_line` are trait-dependent, if the window's `diff_trait` is empty the oracle can't prove their trait cascade — apply the same synthetic check (a trait-referencing SCV must appear in `scv_changed_ids`) and document any residual gap. Debug impact set/filter if nonzero; do NOT relax.

- [ ] **Step 6: Commit** — `git add src/procedures/gks-scv-statement-proc.sql src/scripts/oracle-scv-statement.sh && git commit -m "feat(scv): incremental gks_scv_statement (carry-forward per-scv dicts, global submitter dict recomputed)"`

---

## Chunk 4: deltas + pipeline wiring

**Files:** Modify `src/procedures/gks-change-log-proc.sql`, `src/procedures/gks-delta-proc.sql`, `src/scripts/vrs-to-bq-table.sh`.

- [ ] **Step 1: Extend `gks_change_log` tracked array** with the 7 Plan-2 outputs, each with its ACTUAL pk column: `gks_dict_condition`(**id**), `gks_dict_condition_set`(**id**), `gks_scv_condition_sets`(scv_id), `gks_dict_submitter`(key), `gks_dict_proposition`(key), `gks_dict_evidence_line`(id), `gks_dict_scv`(id). (Keep Plan 1's entries.) ⚠️ `gks_dict_condition`/`gks_dict_condition_set` are structured `id`+columns tables (NO `key` column — verified `gks-scv-condition-proc.sql:90,294`); the pk MUST be `id` or the `CAST({PK} AS STRING)` interpolation errors on a missing column. Deploy.

- [ ] **Step 2: Extend `gks_delta_build` `tables` array** with the same 7 (name + pk) — using the SAME pk columns as Step 1 (`gks_dict_condition`→`id`, `gks_dict_condition_set`→`id`, `gks_scv_condition_sets`→`scv_id`, `gks_dict_submitter`→`key`, `gks_dict_proposition`→`key`, `gks_dict_evidence_line`→`id`, `gks_dict_scv`→`id`), mirroring Chunk 4 of Plan 1. Update the header note (mirrors the catvar+scv subset of `tracked`). Deploy.

- [ ] **Step 3: Build + reconstruction test.** Build change-log + deltas for 2026-07-20; run the reconstruction oracle (`full == (baseline minus U,D) UNION (A/U delta)`, 3-arg `gks_oracle_compare`) for one global dict (`gks_dict_condition`), the trait-driven per-SCV table (`gks_scv_condition_sets`), and one statement per-SCV table (`gks_dict_scv`). All → 0,0,0. Create/clean `${SCHEMA}_recon` scratch dataset.

- [ ] **Step 4: Wire the pipeline.** In `src/scripts/vrs-to-bq-table.sh` `execute_bq_procedures`: (a) call `gks_scv_changed` once, BEFORE the scv procs; (b) replace the `gks_scv_condition_proc` / `gks_scv_statement_proc` entries in `BIGQUERY_PROCEDURES` (or the loop) with the `_incremental` wrappers, honoring a `SCV_FULL`/reusing `CATVAR_FULL`-style flag for `--full` (propagate the same force-full flag Plan 1 added, generalized — e.g. a single `GKS_FULL` env the procs' full wrappers key off, OR call the full wrappers when `CATVAR_FULL=true`). Keep the existing change-log + delta calls (already added in Plan 1 Chunk 4) — they now also cover the scv outputs via the extended arrays. `bash -n`.

> Order in `execute_bq_procedures`: catvar(incr) → **gks_scv_changed** → gks_scv_condition(incr) → gks_scv_statement(incr) → rcv/vcv(full, Plan 3) → gks_json_proc → gks_change_log → gks_delta_build.

- [ ] **Step 5: Commit** — `git add src/procedures/gks-change-log-proc.sql src/procedures/gks-delta-proc.sql src/scripts/vrs-to-bq-table.sh && git commit -m "feat(delta): scv change-log + delta payloads; wire scv incremental into pipeline"`

---

## Done criteria (Plan 2)
- [ ] `gks_scv_condition_proc_incremental` and `gks_scv_statement_proc_incremental` build all 7 outputs; both oracles report **0 diffs** on every table vs a full build.
- [ ] Trait-content cascade handled: `gks_scv_condition_sets` recomputes SCVs whose referenced trait/traitset changed (oracle-verified, or synthetic-checked + documented if the window has no trait churn).
- [ ] `gks_scv_changed` produces `scv_changed_ids`/`scv_removed_ids`/`gks_scv_change_audit`; the audit classifies modified SCVs (version/review-status/unexplained) for Plan 3.
- [ ] `gks_change_log` + `gks_delta_build` cover the 7 new outputs; reconstruction verified (0,0,0) incl. a global dict, `gks_scv_condition_sets`, and `gks_dict_scv`.
- [ ] The 3 global dedup dicts (condition, condition_set, submitter) remain globally recomputed; only the 4 per-SCV tables carry forward.
- [ ] Pipeline wires `gks_scv_changed` before the scv procs and calls the incremental wrappers; `--full` forces full via the propagated flag (honest gate preserved).

## Deferred to Plan 3 / follow-ups
- `gks_rcv`/`gks_rcv_statement` + `gks_vcv`/`gks_vcv_statement` — the aggregate cascade, which CONSUMES `gks_scv_change_audit` (`scv_significant_change` = A∨D∨version≠∨review_status≠, membership-first over union of current+baseline `rcv_mapping`/`variation_archive`).
- `gks_json` + R2 delta publishing (Plan 4).
- `gks_scv_condition_sets` `trait_mapping` (unkeyed diff) + `gks_xref_iri_templates` (config table, not a `diff_*` source) coverage — spec open item; if the Chunk-1 trait-driven join can't reach these, note the residual.
