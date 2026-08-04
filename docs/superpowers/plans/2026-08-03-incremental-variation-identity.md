# Incremental variation_identity Implementation Plan

> ## ⚠️ SUPERSEDED (2026-08-03) — implemented, oracle-tested, then reverted
>
> This plan was fully implemented and validated with the full-rebuild-vs-incremental
> oracle (Task 6). The oracle caught two things that static review (two passes) missed:
>
> 1. **Correctness bug:** the `mappings` field has a **cross-variation dependency** —
>    Step 8 keys mappings on the *external xref id* (`x.id as variation_id`), so a
>    variation's mappings are sourced from *other* variations' `variation_xref` rows.
>    Per-variation staging drops the ones belonging to unchanged variations → 124/17350
>    changed variations got wrong (empty) mappings. (4 more diffs were inherent
>    `ROW_NUMBER` tie-break non-determinism, not incremental bugs.)
> 2. **Performance:** incremental was **slower** on BigQuery (~2m51s) than a full rebuild
>    (~2m21s) — the DELETE+INSERT merge over four 4.5M-row seeded tables costs as much as
>    the UDF work it skips. **The BQ transform was never the bottleneck.**
>
> **Decision:** `variation_identity` stays a full rebuild (always correct). The incremental
> effort moves to the actual bottleneck — vrs-python — by re-vrsifying only variations
> whose VRS-relevant fields changed and carrying `gks_vrs` forward. The `dataset-diff`
> engine + `dataset_diff_on` driver are retained. See the successor plan:
> `2026-08-03-incremental-vrsify.md` (to be written). The body below is kept as the record
> of the seed-then-merge design and the oracle that caught the bug.

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `incremental BOOL` mode to `clinvar_ingest.variation_identity` that reprocesses only the variations that changed since the prior release (from the `dataset-diff` outputs) instead of the whole ~4.5M-row snapshot, so the expensive external vrs-python step receives only the ~0.4%-of-variations delta.

**Architecture:** Seed-then-merge. The four persistent outputs (`variation_identity`, `variation_loc`, `variation_hgvs`, `variation_xref`) are seeded (CLONE) from the nearest existing prior release, the changed-variation set is computed from `diff_variation` + a CopyNumber/statement_type SCV cascade, only those variations are recomputed into session staging tables, and the results are DELETE+INSERT-merged into the seeded tables (removed variations are deleted). The existing full-rebuild path is preserved verbatim and is the automatic fallback whenever a usable baseline is absent.

**Tech Stack:** BigQuery stored procedures (dynamic SQL: `DECLARE`/`SET`/`REPLACE`/`EXECUTE IMMEDIATE`), the `clinvar_ingest.dataset_diff*` procs, `schema_on`/`all_schemas` registry TVFs. Deployed manually to `clingen-dev` (no proc-deploy CI). "Tests" are `bq` verification queries with expected output.

---

## Background: what exists today

`variation_identity(on_date, debug)` loops `schema_on(on_date)` and, per release schema `{S}`, runs 8 steps that always **fully rebuild** four persistent tables (plus internal `_SESSION` temps):

| Output table | Key | Built in | Currently |
|---|---|---|---|
| `{S}.variation_loc` | (variation_id, accession, assembly) | Step 2 | `CREATE OR REPLACE TABLE` |
| `{S}.variation_hgvs` | (variation_id, accession) | Step 3 | `CREATE OR REPLACE TABLE` |
| `{S}.variation_xref` | (variation_id, xref) | Step 5 | `CREATE OR REPLACE TABLE` |
| `{S}.variation_identity` | variation_id (one row/variation) | Step 8 | `CREATE OR REPLACE TABLE` |

Sole downstream consumer: `gks_catvar_proc`, which joins all four from `{S}` by `variation_id` (+ accession). So as long as the four tables are complete and correct in `{S}`, catvar is unaffected by how they were produced.

**Inputs the transform reads** (all in `{S}`): `variation` (core; `content` blob) and, only for the CopyNumber `cn` CTE in Step 1, `clinical_assertion_variation` ⋈ `clinical_assertion` (filtered `content LIKE '%CopyNumber%'` and `ca.statement_type IS NOT NULL`).

**Empirically validated (2026-07-15 → 2026-07-20):** 17,350 new/modified variations out of 4,545,909 (0.38%); 7 removed; CopyNumber-SCV cascade contributed 0 that release (mechanism still required in general).

## Confirmed decisions

1. **Non-breaking wrapper structure** (BigQuery supports neither routine overloading nor default params, so a 3-arg replace of the 2-arg proc would break existing `CALL variation_identity(date, debug)` callers). Instead:
   - `variation_identity_build(on_date DATE, debug BOOL, incremental BOOL)` — internal, holds ALL logic (full + incremental).
   - `variation_identity(on_date DATE, debug BOOL)` — unchanged public signature, delegates `CALL variation_identity_build(on_date, debug, FALSE)`. Non-breaking.
   - `variation_identity_incremental(on_date DATE, debug BOOL)` — new public entry, delegates `CALL variation_identity_build(on_date, debug, TRUE)`.

   All three live in `src/procedures/variation-identity-proc.sql` and deploy together. (TEMP/`_SESSION` tables created inside the build proc are session-scoped and visible across the `CALL`, so the wrappers add no temp-table complications.)
2. **Seed via table CLONE** (zero-copy) from the baseline release, then copy-on-write DELETE+INSERT for the changed set.
3. **Full rebuild is the fallback**, chosen automatically (not an error) whenever: `incremental = FALSE`, OR no baseline schema resolves, OR the baseline lacks any of the four tables. The full path is byte-for-byte the current logic.
4. **Version-invalidation is operational, not automated (YAGNI):** the caller must not pass `incremental = TRUE` across a change to the transform SQL or the vrs-python version. Documented in the runbook; a later phase may automate a version stamp. Passing `incremental = FALSE` always produces a correct full rebuild.

## Design: how the 8 steps change in incremental mode

Introduce one new placeholder, `{V}` — the **variation work-table prefix** — resolved per-mode:

- **Full mode:** `{V}` = `{S}` (behavior identical to today; steps 2/3/5/8 `CREATE OR REPLACE {S}.*`).
- **Incremental mode:** `{V}` = a session staging prefix (`_SESSION.stg_`), so steps 2/3/5/8 build **only the changed variations' rows** into staging, and a final apply-step merges staging into the seeded `{S}.*`.

Flow in incremental mode (per schema, inside the existing `FOR rec` loop):

1. **Preconditions + baseline** — resolve `base_schema` = `schema_on(prev_release_date)` (same pattern as `dataset_diff_on`). **Fall back to full rebuild** (not an error) unless ALL hold:
   - `base_schema` is non-NULL AND its four `{base}.variation_*` tables all exist;
   - the three driving diff tables (`diff_variation`, `diff_clinical_assertion`, `diff_clinical_assertion_variation`) exist in `{S}`;
   - **baseline consistency:** `base_schema`'s `release_date` == `(SELECT MAX(baseline_release) FROM {S}.diff_variation)` — i.e. the release we CLONE is the exact release the diff was computed against. (Guards the archived-intermediate case where `schema_on` would resolve a *different* surviving baseline than the diff used.)
2. **Seed** `{S}.variation_identity|variation_loc|variation_hgvs|variation_xref` via `CREATE OR REPLACE TABLE {S}.X CLONE {base}.X`.
3. **Build `{P}.changed_variation_ids`** (temp) = `UNION DISTINCT` of:
   - **variation-level:** `diff_variation` where `change_type IN ('new','modified')` → `id`.
   - **copy-number cascade — TWO terms, each resolved via BOTH snapshots.** The Step-1 `cn` aggregate for a variation V is a function of the membership set `{(cav, ca) : cav has CopyNumber, ca.id = cav.clinical_assertion_id, ca.statement_type IS NOT NULL, ca.variation_id = V}`. That membership can change **only** if a participating `cav` row changed OR a participating `ca` row changed — so recomputing every V touched by a changed `cav` or a changed `ca` is provably complete. Both terms:
     - **CAV term:** `diff_clinical_assertion_variation` (`change_type IN ('new','modified','removed')`) → join to `clinical_assertion_variation`+`clinical_assertion` (`statement_type IS NOT NULL`, CopyNumber content) → `ca.variation_id`.
     - **CA term:** `diff_clinical_assertion` (`change_type IN ('new','modified','removed')`, keyed `id`+`version`) → join to its CopyNumber `clinical_assertion_variation` rows and `clinical_assertion` (`statement_type IS NOT NULL`) → `ca.variation_id`. This is the term that catches `statement_type` flips (NULL↔non-NULL, the functional-data segregation at proc lines 55-57) and `clinical_assertion.variation_id` reassignment where the `cav` itself is unchanged.
     - Resolve **each** term via **both** `{S}` (new/modified rows still exist) **and** `{base}` (removed rows are gone from `{S}`; reassignment must recompute the OLD variation via `{base}` and the NEW via `{S}`). Keep only ids present in `{S}.variation`. Do **not** filter on `change_note` — it is NULL for `new`/`removed` (dataset-diff-proc.sql:133-135), so a change_note filter silently drops them. Over-inclusion here is bounded by the count of changed CopyNumber-bearing SCVs (tiny) — it never threatens the ~0.4% win and never corrupts.
   - `{P}.removed_variation_ids` = `diff_variation` where `change_type = 'removed'` → `id` (built separately; these are deleted, not recomputed).
4. **Recompute changed only:** run Steps 1–8 with Step 1's `var`/`cn` CTEs constrained to `variation_id IN (SELECT variation_id FROM {P}.changed_variation_ids)`, writing/reading the variation work tables via `{V}` (= staging) — see the redirect scope below.
5. **Apply-merge** (new Step 9, incremental-only), for each of the four tables, with **explicit column lists** (never `SELECT *` — positional match would corrupt on any column reorder between the baseline build and the current build; a type change would error):
   ```
   DELETE FROM {S}.X WHERE variation_id IN (changed ∪ removed);
   INSERT INTO {S}.X (col1, col2, ...) SELECT col1, col2, ... FROM {V-staging}.X;  -- removed ids have no staging rows → net delete
   ```
6. Drop staging temps.

**`{V}` redirect scope (critical — this is broader than steps 2/3/5).** In incremental mode, `{V}` replaces `{S}` for EVERY read and write of the three intermediate tables `variation_loc` / `variation_hgvs` / `variation_xref`, because they are built in staging and their *final* values don't land in `{S}` until Step 9. That means:
- **Writes:** Step 2 (`variation_loc`), Step 3 (`variation_hgvs`), Step 5 (`variation_xref`), Step 8 staging of `variation_identity`.
- **Reads:** Step 4's `UPDATE` (reads `variation_loc`/`variation_hgvs`), **Step 7 `temp_variation_members`** (reads `variation_loc`/`variation_hgvs` in all 9 `var_source` branches + final joins, proc lines 499–661), and **Step 8** (reads `variation_xref`, proc line 700). At the time Steps 7–8 run, `{S}.variation_loc/hgvs/xref` are still the *baseline clone* — reading them there yields stale expressions for the very variations being recomputed.
- **MUST stay `{S}` (do NOT redirect):** the source reads `{S}.variation` (proc lines 58, 97, 253), `{S}.clinical_assertion`, `{S}.clinical_assertion_variation` (lines 50–51). The `{V}` substitution must be applied per-table-name, not as a blanket `{S}`→`{V}` replace.

Because staging holds only changed variations, and every intermediate read/write is redirected to staging, Steps 1–8 produce exactly the changed variations' rows for all four tables; Step 9 merges them into the seeded `{S}` copies.

## File structure

- **Modify:** `src/procedures/variation-identity-proc.sql` — add `incremental` param, `{V}` templating, baseline-resolution + fallback guard, changed-set builder, staging redirection, apply-merge step. Keep the full path unchanged when `incremental = FALSE`.
- **Modify:** `src/procedures/readme.md` — document the incremental call, the version-invalidation caution, and the shrunk vrsify handoff.
- **Out of scope for this plan (fast-follow):** the external vrsify handoff scripts (extract only the changed set to `vi.jsonl.gz`; carry forward `gks_vrs`) and threading the changed set into `gks_catvar_proc`. Noted in the final task.

---

## Chunk 1: incremental plumbing + change-set

### Task 1: Baseline resolution + full-rebuild fallback guard

**Files:**
- Modify: `src/procedures/variation-identity-proc.sql` (signature + top-of-loop guard)

- [ ] **Step 1: Verification query (the "test") — the guard's decision for three inputs**

Run against clingen-dev; captures the branch the proc must take.
```bash
bq query --project_id=clingen-dev --use_legacy_sql=false --format=csv "
SELECT '2026-07-20' d,
  (SELECT schema_name FROM \`clinvar_ingest.schema_on\`(DATE '2026-07-20')) cur,
  (SELECT schema_name FROM \`clinvar_ingest.schema_on\`((SELECT prev_release_date FROM \`clinvar_ingest.schema_on\`(DATE '2026-07-20')))) base"
```
Expected: `cur=clinvar_2026_07_20_v2_5_0`, `base=clinvar_2026_07_15_v2_5_0`. (Earliest release → `base` empty → full-rebuild fallback.)

- [ ] **Step 2: Refactor to the wrapper structure + add the resolution/guard**

Rename the existing body to internal `variation_identity_build(on_date DATE, debug BOOL, incremental BOOL)`; add public `variation_identity(on_date, debug)` → `CALL …_build(…, FALSE)` and `variation_identity_incremental(on_date, debug)` → `CALL …_build(…, TRUE)` below it. Inside the build proc's `FOR rec` loop, before Step 1, declare `base_schema STRING`, `base_rel DATE`, `cur_rel DATE`, `do_incremental BOOL DEFAULT FALSE`, and resolve the baseline:
```sql
IF incremental THEN
  SET base_schema = (
    SELECT schema_name FROM `clinvar_ingest.schema_on`(
      (SELECT prev_release_date FROM `clinvar_ingest.schema_on`(on_date)))
  );
END IF;
```

- [ ] **Step 3: Implement the full precondition check (all must pass or fall back)**

`do_incremental` is TRUE only if the baseline resolves, its four outputs exist, the three diff tables exist in `{S}`, AND the diff's baseline/compare releases match `{base}`/`{S}`. Guard the NULL-`base_schema` case at the **scripting** level (a NULL `base_schema` would make `REPLACE(sql,'{BASE}',NULL)` yield NULL and `EXECUTE IMMEDIATE NULL` error; SQL-level `AND` short-circuit does NOT protect table-reference resolution). Only when `base_schema` is non-NULL do we assemble and run the check:
```sql
-- Resolve baseline + compare release dates into scalar variables FIRST.
SET base_rel = (SELECT release_date FROM `clinvar_ingest.schema_on`(
                  (SELECT prev_release_date FROM `clinvar_ingest.schema_on`(on_date))));
SET cur_rel  = (SELECT release_date FROM `clinvar_ingest.schema_on`(on_date));

IF NOT incremental OR base_schema IS NULL THEN
  SET do_incremental = FALSE;
ELSE
  -- assemble by substituting ALL FOUR placeholders, then EXECUTE IMMEDIATE ... INTO do_incremental
  EXECUTE IMMEDIATE (SELECT
    REPLACE(REPLACE(REPLACE(REPLACE("""
      SELECT IFNULL((
        ( SELECT COUNT(*) = 4 FROM `{BASE}.INFORMATION_SCHEMA.TABLES`
          WHERE table_name IN ('variation_identity','variation_loc','variation_hgvs','variation_xref') )
        AND
        ( SELECT COUNT(*) = 3 FROM `{S}.INFORMATION_SCHEMA.TABLES`
          WHERE table_name IN ('diff_variation','diff_clinical_assertion','diff_clinical_assertion_variation') )
        AND
        -- baseline+compare consistency: the diff we consume was built for exactly {BASE} -> {S}
        -- (release_date comparability verified: schema_on.release_date, diff baseline/compare_release,
        --  and MAX(release_date) of the tables are all DATE and aligned)
        ( SELECT MAX(baseline_release) = DATE '{BASE_REL}' AND MAX(compare_release) = DATE '{CUR_REL}'
          FROM `{S}.diff_variation` )
      ), FALSE)
    """, '{BASE}', base_schema),
         '{S}', rec.schema_name),
         '{BASE_REL}', CAST(base_rel AS STRING)),
         '{CUR_REL}',  CAST(cur_rel AS STRING)))
  INTO do_incremental;
END IF;
IF incremental AND NOT do_incremental THEN
  SELECT FORMAT('variation_identity: incremental requested but preconditions unmet for %s — full rebuild', rec.schema_name) AS warning;
END IF;
```
`{BASE_REL}`/`{CUR_REL}` are the baseline/compare `release_date`s from `schema_on(prev_release_date)`/`schema_on(on_date)`, resolved into scalars first. (Comparing the diff's stored `baseline_release`/`compare_release` to the resolved release dates closes both the archived-intermediate case and stale-diff-rebuilt-against-a-different-compare case.)

- [ ] **Step 4: Deploy and smoke-test the guard (no behavior change yet)**

Deploy; call `variation_identity(DATE '2026-07-20', TRUE)` (full path, unchanged) to confirm no behavior change, OR just confirm the DDL compiles:
```bash
bq query --project_id=clingen-dev --use_legacy_sql=false < src/procedures/variation-identity-proc.sql
```
Expected: `Created/Replaced clingen-dev.clinvar_ingest.variation_identity` with no error. `incremental=FALSE` path must be unchanged.

- [ ] **Step 5: Commit**
```bash
git add src/procedures/variation-identity-proc.sql
git commit -m "feat(variation-identity): add incremental param with full-rebuild fallback guard"
```

### Task 2: Changed-variation-set builder

**Files:**
- Modify: `src/procedures/variation-identity-proc.sql` (new temp tables `changed_variation_ids`, `removed_variation_ids`)

- [ ] **Step 1: Verification query — the FULL change set (all union terms) for the known release pair**

This must be the exact union the builder implements, including the removed/reassignment cascades resolved via the baseline dataset — not just the new/modified CopyNumber term. (For the 2026-07-15→07-20 pair the cascade terms contribute 0, so the total is still 17350, but the query must exercise every term so a regression in a cascade term is visible.)
```bash
bq query --project_id=clingen-dev --use_legacy_sql=false --format=csv "
WITH cnv_changed AS (  -- ids of clinical_assertion_variation rows that changed either side
  SELECT id FROM \`clinvar_2026_07_20_v2_5_0.diff_clinical_assertion_variation\` WHERE change_type IN ('new','modified','removed')
),
ca_changed AS (       -- ids/versions of clinical_assertion rows that changed either side
  SELECT id, version FROM \`clinvar_2026_07_20_v2_5_0.diff_clinical_assertion\` WHERE change_type IN ('new','modified','removed')
),
changed AS (
  SELECT id AS variation_id FROM \`clinvar_2026_07_20_v2_5_0.diff_variation\` WHERE change_type IN ('new','modified')
  -- CAV term, COMPARE snapshot
  UNION DISTINCT
  SELECT ca.variation_id FROM cnv_changed d
  JOIN \`clinvar_2026_07_20_v2_5_0.clinical_assertion_variation\` cav ON cav.id = d.id
  JOIN \`clinvar_2026_07_20_v2_5_0.clinical_assertion\` ca ON ca.id = cav.clinical_assertion_id AND ca.statement_type IS NOT NULL
  WHERE cav.content LIKE '%CopyNumber%'
  -- CAV term, BASELINE snapshot (removed cav / reassignment)
  UNION DISTINCT
  SELECT ca.variation_id FROM cnv_changed d
  JOIN \`clinvar_2026_07_15_v2_5_0.clinical_assertion_variation\` cav ON cav.id = d.id
  JOIN \`clinvar_2026_07_15_v2_5_0.clinical_assertion\` ca ON ca.id = cav.clinical_assertion_id AND ca.statement_type IS NOT NULL
  WHERE cav.content LIKE '%CopyNumber%'
  -- CA term, COMPARE snapshot (statement_type flip / variation_id reassignment; cav unchanged)
  UNION DISTINCT
  SELECT ca.variation_id FROM ca_changed d
  JOIN \`clinvar_2026_07_20_v2_5_0.clinical_assertion\` ca ON ca.id = d.id AND ca.version = d.version AND ca.statement_type IS NOT NULL
  JOIN \`clinvar_2026_07_20_v2_5_0.clinical_assertion_variation\` cav ON cav.clinical_assertion_id = ca.id
  WHERE cav.content LIKE '%CopyNumber%'
  -- CA term, BASELINE snapshot (removed ca / old variation before reassignment)
  UNION DISTINCT
  SELECT ca.variation_id FROM ca_changed d
  JOIN \`clinvar_2026_07_15_v2_5_0.clinical_assertion\` ca ON ca.id = d.id AND ca.version = d.version AND ca.statement_type IS NOT NULL
  JOIN \`clinvar_2026_07_15_v2_5_0.clinical_assertion_variation\` cav ON cav.clinical_assertion_id = ca.id
  WHERE cav.content LIKE '%CopyNumber%'
)
SELECT COUNT(*) AS changed_variations
FROM changed WHERE variation_id IN (SELECT id FROM \`clinvar_2026_07_20_v2_5_0.variation\`)"
```
Expected for this pair: `changed_variations = 17350`; `removed = 7` (all four cascade terms contribute 0 here). **The cascade terms are NOT exercised by this pair — before trusting them, re-run the Task 6 equivalence oracle on a release pair where copy-number submissions actually changed, or a synthetic fixture.** All four cascade terms (CAV/CA × compare/baseline) must be present in the builder even though they are 0 here.

- [ ] **Step 2: Add the changed-set temp-table builder** (incremental branch only)

Build `{P}.changed_variation_ids` as the `UNION DISTINCT` in the design (variation new/modified + CopyNumber cascade new/modified from `{S}`, + CopyNumber/statement_type removed cascade from `{BASE}`, filtered to ids present in `{S}.variation`). Build `{P}.removed_variation_ids` from `diff_variation` removed. Use the `{CT}`/`{P}` temp conventions.

- [ ] **Step 3: Deploy; assert count matches the oracle query**

Call with `debug=TRUE` so the temp tables persist as `{S}.changed_variation_ids`, then:
```bash
bq query --project_id=clingen-dev --use_legacy_sql=false --format=csv "SELECT COUNT(*) FROM \`clinvar_2026_07_20_v2_5_0.changed_variation_ids\`"
```
Expected: matches Step 1 (17350). Removed table = 7.

- [ ] **Step 4: Commit**
```bash
git add src/procedures/variation-identity-proc.sql
git commit -m "feat(variation-identity): build changed/removed variation-id sets from diff tables"
```

---

## Chunk 2: seed, recompute, merge

### Task 3: Seed the four outputs via CLONE

**Files:**
- Modify: `src/procedures/variation-identity-proc.sql` (new seed step, incremental branch, before Step 1)

- [ ] **Step 1: Verification query — CLONE produces an identical row count**
```bash
bq query --project_id=clingen-dev --use_legacy_sql=false --format=csv "
SELECT (SELECT COUNT(*) FROM \`clinvar_2026_07_15_v2_5_0.variation_identity\`) AS base_rows"
```
Record `base_rows`; the seeded `{S}.variation_identity` must match before any merge.

- [ ] **Step 2: Add the seed step**
```sql
-- incremental branch, per table X in (variation_identity, variation_loc, variation_hgvs, variation_xref):
CREATE OR REPLACE TABLE `{S}.X` CLONE `{BASE}.X`;
```
Assemble with `REPLACE` for `{S}`/`{BASE}` and loop the four names (or four explicit statements).

- [ ] **Step 3: Deploy; assert seeded row count == baseline**

After a `debug=TRUE` incremental run (seed only, merge not yet wired), compare `{S}.variation_identity` count to `base_rows`. Expected: equal.

- [ ] **Step 4: Commit**
```bash
git commit -am "feat(variation-identity): seed outputs from baseline via CLONE in incremental mode"
```

### Task 4: Redirect steps 2/3/5/8 to `{V}` staging + Step 1 filter

**Files:**
- Modify: `src/procedures/variation-identity-proc.sql` (Steps 1–8 templating)

- [ ] **Step 1: Introduce `{V}` and set it per mode (honoring debug so staging is inspectable)**

`{V}` is the prefix for the three intermediate tables in incremental mode. It must honor `debug` so the `debug=TRUE` verification queries below can read the staging tables from the dataset (`_SESSION` temps are invisible to a separate `bq` invocation):
```
{V} = IF(do_incremental,
         IF(debug, rec.schema_name || '.stg_', '_SESSION.stg_'),
         '{S}.'  /* full mode: unchanged */)
```
So full mode keeps `CREATE OR REPLACE TABLE {S}.variation_loc`; incremental debug writes `{S}.stg_variation_loc` (inspectable); incremental non-debug writes `_SESSION.stg_variation_loc`.

- [ ] **Step 2: Apply the `{V}` redirect to ALL intermediate-table reads and writes**

Per the "redirect scope" in the Design section, replace `{S}.` with `{V}` for `variation_loc` / `variation_hgvs` / `variation_xref` in: Step 2 write, Step 3 write, Step 5 write, Step 8 staging write, **Step 4 `UPDATE` reads**, **Step 7 `temp_variation_members` reads (all 9 `var_source` branches + final joins)**, **Step 8 `variation_xref` read**. Leave `{S}.variation` and `{S}.clinical_assertion*` as `{S}` (apply `{V}` per table-name, not as a blanket replace).

**Substitution ordering:** because `{V}`'s full-mode value is `{S}.` (which itself contains `{S}`), the `{V}` `REPLACE` must run **before** the existing `REPLACE(..., '{S}', rec.schema_name)` in each affected step, or the `{S}` inside `{V}` gets consumed early. Also `DECLARE` the new scalars used above: `base_rel DATE`, `cur_rel DATE` (Task 1), and the `{V}` prefix string.

- [ ] **Step 3: Constrain Step 1 to the changed set (incremental only)**

Add to Step 1's `var` CTE (and the `cn` CTE's variation join): `AND v.id IN (SELECT variation_id FROM {P}.changed_variation_ids)` — injected only when `do_incremental` (guard the REPLACE so full mode is untouched).

- [ ] **Step 4: Verification — staging holds only the changed set, for all four tables**

`debug=TRUE` incremental run, then confirm each staging table has the changed-set cardinality, NOT 4.5M:
```bash
bq query --project_id=clingen-dev --use_legacy_sql=false --format=csv "
SELECT
  (SELECT COUNT(*)             FROM \`clinvar_2026_07_20_v2_5_0.stg_variation_identity\`) AS stg_identity_rows,
  (SELECT COUNT(DISTINCT variation_id) FROM \`clinvar_2026_07_20_v2_5_0.stg_variation_loc\`) AS stg_loc_vids,
  (SELECT COUNT(DISTINCT variation_id) FROM \`clinvar_2026_07_20_v2_5_0.stg_variation_hgvs\`) AS stg_hgvs_vids,
  (SELECT COUNT(DISTINCT variation_id) FROM \`clinvar_2026_07_20_v2_5_0.stg_variation_xref\`) AS stg_xref_vids"
```
Expected: `stg_identity_rows == 17350`; the loc/hgvs/xref distinct-variation counts are ≤ 17350 (only changed variations, and only those with rows of that type).

- [ ] **Step 4: Commit**
```bash
git commit -am "feat(variation-identity): compute changed variations into staging in incremental mode"
```

### Task 5: Apply-merge staging into seeded outputs + delete removed

**Files:**
- Modify: `src/procedures/variation-identity-proc.sql` (new Step 9, incremental only)

- [ ] **Step 1: Add the DELETE+INSERT apply for each of the four tables (explicit column lists)**
```sql
-- for each X (variation_identity, variation_loc, variation_hgvs, variation_xref):
DELETE FROM `{S}.X`
WHERE variation_id IN (
  SELECT variation_id FROM {P}.changed_variation_ids
  UNION DISTINCT SELECT variation_id FROM {P}.removed_variation_ids
);
INSERT INTO `{S}.X` (col1, col2, ..., colN)
SELECT col1, col2, ..., colN FROM {V-staging}.X;
```
Removed ids have no staging rows → net delete. **Use explicit, matching column lists** (enumerate each table's columns) rather than `SELECT *`: positional `SELECT *` silently corrupts if the current build's column order differs from the baseline clone's, and errors on a type change. Enumerating columns makes any schema drift an explicit, visible failure — which is the desired behavior (drift means the version-invalidation assumption is broken; the caller should full-rebuild).

- [ ] **Step 2: Drop staging temps** (mirror the existing end-of-loop temp cleanup).

- [ ] **Step 3: Verification — merged table is internally consistent**
```bash
bq query --project_id=clingen-dev --use_legacy_sql=false --format=csv "
SELECT COUNT(*) total, COUNT(DISTINCT variation_id) distinct_vid
FROM \`clinvar_2026_07_20_v2_5_0.variation_identity\`"
```
Expected: `total == distinct_vid` (one row per variation, no dup/leak from the merge).

- [ ] **Step 4: Commit**
```bash
git commit -am "feat(variation-identity): merge changed staging rows and delete removed in incremental mode"
```

---

## Chunk 3: correctness oracle + docs

### Task 6: Full-rebuild-equals-incremental oracle (the acceptance test)

**Files:** none (validation only)

Because the seed CLONE overwrites `{S}`, the two runs cannot share `{S}` — snapshot each result to a scratch dataset **before** the next run.

- [ ] **Step 0: Rebuild the BASELINE with the current transform (removes version drift)**

The incremental run carries forward unchanged rows from the baseline CLONE. If `{base}` (`clinvar_2026_07_15`) was built by an *older* transform/vrs-python version, those carried rows differ from a fresh full 07-20 rebuild for reasons unrelated to incremental logic, producing false oracle failures. So first `CALL variation_identity(DATE '2026-07-15', FALSE)` (full rebuild of the baseline with the current code) before Steps 1–3.

- [ ] **Step 1: Produce the full-rebuild ground truth**

Full-rebuild the compare release: `CALL variation_identity(DATE '2026-07-20', FALSE)`. Immediately snapshot all four outputs to scratch (CLONE): `scratch.vi_full`, `scratch.vloc_full`, `scratch.vhgvs_full`, `scratch.vxref_full`.

- [ ] **Step 2: Produce the incremental result**

Ensure the diff tables exist (`CALL dataset_diff_on(DATE '2026-07-20')`), then `CALL variation_identity_incremental(DATE '2026-07-20', FALSE)` (baseline `clinvar_2026_07_15`). Snapshot the four outputs to `scratch.*_incr`.

- [ ] **Step 3: Assert row-for-row equality via key + serialized-payload (ARRAY-safe)**

`EXCEPT DISTINCT SELECT *` is invalid here — `variation_identity.range_copies`/`mappings` and `variation_hgvs.expr` are non-groupable ARRAY/STRUCT columns. Compare a key + `TO_JSON_STRING` of the row instead:
```bash
bq query --project_id=clingen-dev --use_legacy_sql=false --format=csv "
WITH f AS (SELECT variation_id AS k, TO_JSON_STRING(t) AS h FROM \`scratch.vi_full\` t),
     i AS (SELECT variation_id AS k, TO_JSON_STRING(t) AS h FROM \`scratch.vi_incr\` t)
SELECT
  (SELECT COUNT(*) FROM (SELECT k,h FROM f EXCEPT DISTINCT SELECT k,h FROM i)) AS full_not_incr,
  (SELECT COUNT(*) FROM (SELECT k,h FROM i EXCEPT DISTINCT SELECT k,h FROM f)) AS incr_not_full,
  (SELECT COUNT(*) FROM f) AS full_rows, (SELECT COUNT(*) FROM i) AS incr_rows"
```
Expected: **`full_not_incr = 0` AND `incr_not_full = 0` AND `full_rows = incr_rows`.** Any nonzero → a change-set or merge bug; join `f`/`i` on `k` where `f.h != i.h` (or `k` present on one side only) to get the offending `variation_id`s — a one-sided key usually means a missed cascade; a differing `h` on a shared key means stale intermediate reads (redirect scope) or a merge error.

Repeat for `variation_loc`/`variation_hgvs`/`variation_xref`. Those are multi-row-per-variation, so compare on the full natural key + `TO_JSON_STRING(t)`. **Also assert non-distinct `COUNT(*)` equality** (`full_rows = incr_rows`) for each — `EXCEPT DISTINCT` collapses duplicates, so a merge bug that leaves 2 identical rows on one side and 1 on the other would report 0 differences; the raw row-count check catches that.

- [ ] **Step 4: Record the result** in the plan/PR (counts + timing: full vs incremental wall-clock and the vrsify payload reduction).

### Task 7: Runbook + handoff docs

**Files:**
- Modify: `src/procedures/readme.md`

- [ ] **Step 1: Document** the incremental call (`variation_identity_incremental(CURRENT_DATE(), FALSE)`; the unchanged full path stays `variation_identity(CURRENT_DATE(), FALSE)`), the automatic full-rebuild fallback, and the **version-invalidation caution** (do not run `variation_identity_incremental` across transform/vrs-python version changes — run the full `variation_identity` instead).

- [ ] **Step 2: Note the vrsify handoff change** (fast-follow, not in this plan): the `bq extract` for `vi.jsonl.gz` should filter to the changed set, and `gks_vrs` should be carried forward + merged rather than fully rebuilt — this is where the ~0.4% delta becomes the actual compute win.

- [ ] **Step 3: Commit**
```bash
git commit -am "docs(variation-identity): document incremental mode and vrsify handoff"
```

---

## Risks & correctness gates (must hold)

1. **Cascade completeness** — a variation byte-identical in `variation` can still change output via a changed CopyNumber SCV or a `statement_type` flip. The change-set MUST union `diff_clinical_assertion_variation` and `diff_clinical_assertion`, resolving *removed* rows through the **baseline** dataset. Task 6's oracle is what proves this is complete.
2. **Removed records** — must be deleted from all four tables, else stale identities leak forward.
3. **No usable baseline** (first run, archived prior, missing table) — MUST fall back to full rebuild, never emit a partial result. Never infer "nothing changed" from absent diffs.
4. **Version invalidation** — carried-forward rows assume identical transform + vrs-python version. Operationally gated (Task 7); `incremental=FALSE` is always safe.
5. **Diff freshness** — incremental assumes `dataset_diff_on(on_date)` (or `dataset_diff_all`) has already produced the `diff_*` tables in `{S}` for this baseline→compare pair. Add a precondition check (diff tables exist) or call `dataset_diff_on` first.
