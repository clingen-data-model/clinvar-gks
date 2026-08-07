# Incremental GKS Downstream — Plan 1: catvar + cross-cutting foundations

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `gks_catvar_proc` build incrementally (carry forward unchanged categorical-variant records, recompute only the impacted ones) and publish per-release catvar delta datasets — while landing the three cross-cutting subsystems every later downstream phase reuses: the git-derived `pipeline_version` gate, the delta payload + `gks_change_log` manifest, and the full-vs-incremental oracle harness.

**Architecture:** Follow the proven `variation_identity` v2 pattern exactly: split each proc into an internal `*_build(on_date, debug, incremental)` with non-breaking `*_proc` (full) / `*_proc_incremental` wrappers, a structural + version-gate fallback guard, a Step-0 changed/removed set, `{VFILTER}`-filtered per-record recompute into `{P}.stg_*` temps, and a `UNION-CTAS` carry-forward merge. Catvar's six global dedup dicts are the exception: globally recomputed every release, with their delta derived by a content diff vs baseline (per the spec §2). Correctness is gated by a per-table full-rebuild == incremental oracle (0 canonical diffs).

**Tech Stack:** BigQuery stored procedures (dynamic SQL: `DECLARE`/`SET`/`REPLACE`/`EXECUTE IMMEDIATE`), `bash` orchestration (`run-release.sh`, `vrs-to-bq-table.sh`), `git` for the version stamp. Procedures are deployed manually with `bq query --use_legacy_sql=false < file.sql`.

**Spec:** `docs/superpowers/specs/2026-08-06-incremental-gks-downstream-and-deltas-design.md` (§1 build primitive, §2 global dicts, §3 impact model, §4 delta product, §5 version gate, §6 oracle).

**Prereqs / conventions (read before starting):**
- Deploy a proc: `bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false < src/procedures/<file>.sql`
- Dynamic-SQL placeholders: `{S}` = `rec.schema_name`; `{CT}` = `temp_create` (`CREATE TEMP TABLE` vs `CREATE OR REPLACE TABLE` when `debug`); `{P}` = `_SESSION` (or `rec.schema_name` when `debug`); `{VFILTER}` = per-variation filter fragment; `{BASE}` = baseline schema.
- The reference implementation for every mechanical pattern below is `src/procedures/variation-identity-proc.sql` (build/wrapper split at lines 19/1102/1110, guard at 54-83, changed-set at 156-210, mode fragments at 90-136, UNION-CTAS merge at 960-1080). **When this plan says "mirror variation_identity", copy that structure literally.**
- Test release pair used throughout: baseline `2026-07-15`, compare `2026-07-20` (the pair the v2 oracle used; ~0.38% of variations changed). Adjust `PROJECT_ID`/dates if the datasets have been archived — pick any adjacent existing release pair from `bq ls`.
- There is **no unit-test framework**; a "test" here is a `bq query` that returns a number we assert on (0 diffs, expected counts) or a proc that `RAISE`s on failure. Write the assertion query first, watch it fail, implement, watch it pass.

---

## Chunk 1: pipeline_version gate foundation

The version gate decides, automatically, whether carry-forward is valid this release. A single git-derived value stamps every release dataset; a build proc compares the current value against the baseline's stamp and falls back to a full rebuild on mismatch. `--full` forces a rebuild regardless.

**Files:**
- Create: `src/procedures/gks-pipeline-version-proc.sql`
- Modify: `src/scripts/run-release.sh` (compute + stamp before the proc stage)

**Design decisions (from spec §5):**
- **`audit_stamp`** = `git describe --tags --always --dirty` — recorded, never gates. Full provenance.
- **`gate_key`** = `git log -1 --format=%H -- src/procedures src/scripts src/vrsify` — the last commit touching build-relevant paths. Only advances when build logic changes; a docs-only commit leaves it unchanged. This is what carry-forward compares.
- Stored once per release dataset in `{S}.gks_pipeline_version` (single row). Baseline gate read from `{base}.gks_pipeline_version`.

- [ ] **Step 1: Write the stamp procedure**

Create `src/procedures/gks-pipeline-version-proc.sql`:

```sql
-- ============================================================================
-- gks_pipeline_version — per-release stamp of the pipeline build version
-- ============================================================================
-- Writes a single-row {S}.gks_pipeline_version for the release active on on_date:
--   audit_stamp  STRING  -- `git describe --tags --always --dirty` (provenance; never gates)
--   gate_key     STRING  -- last commit hash over build-relevant paths (drives carry-forward)
--   computed_at  TIMESTAMP
-- The orchestration layer (run-release.sh) computes both values from git and passes
-- them in. Downstream *_build procs read {base}.gks_pipeline_version.gate_key and
-- compare it to {S}.gks_pipeline_version.gate_key; a mismatch forces a full rebuild.
-- ============================================================================
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_pipeline_version`(on_date DATE, audit_stamp STRING, gate_key STRING)
BEGIN
  FOR rec IN (SELECT s.schema_name FROM `clinvar_ingest.schema_on`(on_date) AS s)
  DO
    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_pipeline_version` AS
      SELECT %T AS audit_stamp, %T AS gate_key, CURRENT_TIMESTAMP() AS computed_at
    """, rec.schema_name, audit_stamp, gate_key);
  END FOR;
END;
```

- [ ] **Step 2: Deploy it**

Run: `bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false < src/procedures/gks-pipeline-version-proc.sql`
Expected: `... procedure clinvar_ingest.gks_pipeline_version ... created/updated` (no error).

- [ ] **Step 3: Write the failing assertion, then verify the stamp round-trips**

Run (compare release 2026-07-20):
```bash
bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false \
  "CALL \`clinvar_ingest.gks_pipeline_version\`(DATE '2026-07-20', 'v-test-audit', 'gate-abc123')"
SCHEMA=$(bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false --format=csv --quiet \
  "SELECT schema_name FROM \`clinvar_ingest.schema_on\`(DATE '2026-07-20')" | tail -1 | tr -d '[:space:]')
bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false --format=csv --quiet \
  "SELECT gate_key FROM \`${SCHEMA}.gks_pipeline_version\`"
```
Expected: `gate-abc123`.

- [ ] **Step 4: Wire computation + stamping into run-release.sh**

In `src/scripts/run-release.sh`, after the arg parse / echo header (after line 68) and **before** Stage 4, add a stamp stage. Compute both values from git and call the proc:

```bash
# --- Version stamp: record provenance + the carry-forward gate key -----------------------
# audit_stamp = full git describe (provenance, always). gate_key = last commit touching the
# build-relevant paths (only advances when build logic changes; docs-only commits don't).
AUDIT_STAMP="$(cd "${REPO_ROOT}" && git describe --tags --always --dirty)"
GATE_KEY="$(cd "${REPO_ROOT}" && git log -1 --format=%H -- src/procedures src/scripts src/vrsify)"
if $FULL; then
  # A forced full rebuild deliberately invalidates carry-forward: stamp a unique gate so no
  # baseline can match it this release (the downstream procs then all full-rebuild).
  GATE_KEY="FULL-${AUDIT_STAMP}-$(cd "${REPO_ROOT}" && git rev-parse HEAD)"
fi
echo ">>> stamping pipeline_version audit=${AUDIT_STAMP} gate=${GATE_KEY}"
bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false \
  "CALL \`clinvar_ingest.gks_pipeline_version\`(DATE '${DATE}', '${AUDIT_STAMP}', '${GATE_KEY}')"
```

Place this inside a `if (( START_STEP <= 4 ));` guard (it must run whenever the proc stage runs). Put it immediately before the Stage 4 block (line 99-103).

> **`--dry-run` still stamps.** `--dry-run` only gates Stage 5 (R2 upload). This stamp `CALL` writes `{S}.gks_pipeline_version` to BigQuery even under `--dry-run` — that is intended (the BigQuery-side build is real; only R2 publishing is suppressed). Note it in the run-release header comment so a "dry" run isn't assumed side-effect-free.

Additionally, wire the **diff driver** into the pipeline. `variation_identity_incremental` (Stage 1) and the new incremental catvar both require the `{S}.diff_*` tables, but `dataset_diff_on` is currently **not called anywhere** in the pipeline (only documented as manual usage) — so without this, every incremental proc silently falls back to full. Add a diff stage that runs before Stage 1 (it needs only the ingested `{S}` base tables). Insert immediately after the header echo (line 68), inside `if (( START_STEP <= 1 ));`:

```bash
# --- Stage 0: dataset diff (produces {S}.diff_* — drivers for all incremental procs) ----
# Idempotent (CREATE OR REPLACE). On the first release it emits a warning and writes no
# diff tables, which correctly makes the incremental guards fall back to a full rebuild.
if (( START_STEP <= 1 )); then
  echo ">>> [0] dataset_diff_on (build {S}.diff_* drivers)"
  bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false \
    "CALL \`clinvar_ingest.dataset_diff_on\`(DATE '${DATE}')"
fi
```

> This also fixes a latent gap for the already-merged `variation_identity_incremental`, which needs the same drivers. If it turns out the upstream ClinVar ingest already produces `{S}.diff_*`, this call is a harmless idempotent refresh — verify during execution and keep it either way (belt-and-suspenders; the guard tolerates their presence).

- [ ] **Step 5: Verify run-release stamps a real git value (dry, stage 4 only)**

Run: `PROJECT_ID="${PROJECT_ID:-clingen-dev}" ./src/scripts/run-release.sh 2026-07-20 --start-step 4 --dry-run` — interrupt after the stamp line prints (or let it proceed if the environment is set up). Then:
```bash
bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false --format=csv --quiet \
  "SELECT audit_stamp, gate_key FROM \`${SCHEMA}.gks_pipeline_version\`"
```
Expected: `audit_stamp` matches `git describe --tags --always --dirty`; `gate_key` matches `git log -1 --format=%H -- src/procedures src/scripts src/vrsify`.

- [ ] **Step 6: Commit**

```bash
git add src/procedures/gks-pipeline-version-proc.sql src/scripts/run-release.sh
git commit -m "feat(pipeline): git-derived pipeline_version stamp + gate key"
```

---

## Chunk 2: full-vs-incremental oracle harness

The oracle is the non-negotiable correctness gate (spec §6): for a release, an incremental build must be byte-for-byte (canonically) identical to a full build of the same release from the same-version baseline. Reused by every phase. Model it on the two-tier canonicalize compare already in `gks_change_log` (lines 95-125).

**Files:**
- Create: `src/procedures/gks-oracle-compare-proc.sql`
- Create: `src/scripts/oracle-catvar.sh` (runbook that builds full + incremental into scratch datasets and compares)

- [ ] **Step 1: Write the oracle compare procedure**

Create `src/procedures/gks-oracle-compare-proc.sql`:

```sql
-- ============================================================================
-- gks_oracle_compare — assert two builds of a table are canonically identical
-- ============================================================================
-- Compares `<schema_a>.<table>` vs `<schema_b>.<table>` keyed by <pk> using the
-- same two-tier compare as gks_change_log: cheap TO_JSON_STRING first, then
-- canonicalize_json only on byte-different rows (so array-order noise is ignored).
-- SELECTs a single result row: (table_name, a_only, b_only, canonical_diffs).
-- 0/0/0 == pass. Duplicate-pk tables collapse via GROUP BY + ANY_VALUE (matches
-- gks_change_log's handling of catvar's known dup-id rows).
-- ============================================================================
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_oracle_compare`(
  schema_a STRING, schema_b STRING, table_name STRING, pk STRING)
BEGIN
  DECLARE q STRING;
  SET q = """
    WITH a AS (
      SELECT CAST({PK} AS STRING) AS pk, ANY_VALUE(TO_JSON_STRING(t)) AS h
      FROM `{A}.{T}` t GROUP BY {PK}
    ),
    b AS (
      SELECT CAST({PK} AS STRING) AS pk, ANY_VALUE(TO_JSON_STRING(t)) AS h
      FROM `{B}.{T}` t GROUP BY {PK}
    ),
    joined AS (
      SELECT COALESCE(a.pk, b.pk) AS pk, a.h AS ah, b.h AS bh
      FROM a FULL OUTER JOIN b USING(pk)
    )
    SELECT
      '{T}' AS table_name,
      COUNTIF(bh IS NULL) AS a_only,
      COUNTIF(ah IS NULL) AS b_only,
      COUNTIF(ah IS NOT NULL AND bh IS NOT NULL
              AND `clinvar_ingest.canonicalize_json`(ah) != `clinvar_ingest.canonicalize_json`(bh)) AS canonical_diffs
    FROM joined
  """;
  SET q = REPLACE(q, '{PK}', pk);
  SET q = REPLACE(q, '{A}', schema_a);
  SET q = REPLACE(q, '{B}', schema_b);
  SET q = REPLACE(q, '{T}', table_name);
  EXECUTE IMMEDIATE q;
END;
```

- [ ] **Step 2: Deploy + smoke-test the oracle against a table compared to itself (must be 0/0/0)**

Run:
```bash
bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false < src/procedures/gks-oracle-compare-proc.sql
SCHEMA=$(bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false --format=csv --quiet \
  "SELECT schema_name FROM \`clinvar_ingest.schema_on\`(DATE '2026-07-20')" | tail -1 | tr -d '[:space:]')
bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false \
  "CALL \`clinvar_ingest.gks_oracle_compare\`('${SCHEMA}','${SCHEMA}','gks_dict_variation','id')"
```
Expected: one row `gks_dict_variation, 0, 0, 0`.

- [ ] **Step 3: Write the catvar oracle runbook script**

Create `src/scripts/oracle-catvar.sh` — builds a full catvar into a scratch dataset and an incremental catvar into another, then compares all seven catvar outputs. (Depends on Chunk 3's incremental proc; this script is written now but first *passes* in Chunk 3 Step 8.)

```bash
#!/bin/bash
# oracle-catvar.sh — full-vs-incremental oracle for gks_catvar.
# Builds gks_catvar FULL and INCREMENTAL for the same compare release from the same
# baseline, into two scratch datasets, and asserts 0 canonical diffs on all 7 outputs.
#
# USAGE: ./src/scripts/oracle-catvar.sh <COMPARE_DATE> [PROJECT_ID]
#   Requires: gks_vrs + variation_* + diff_* already built for COMPARE_DATE, and a
#   same-gate baseline release present. Run after Chunk 3 is deployed.
set -o errexit -o nounset -o pipefail
DATE="${1:?compare date YYYY-MM-DD}"
PROJECT_ID="${2:-clingen-dev}"
export CLOUDSDK_CORE_PROJECT="${PROJECT_ID}"

SCHEMA=$(bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv --quiet \
  "SELECT schema_name FROM \`clinvar_ingest.schema_on\`(DATE '${DATE}')" | tail -1 | tr -d '[:space:]')
FULL_DS="${SCHEMA}_oracle_full"
INCR_DS="${SCHEMA}_oracle_incr"

# The seven catvar outputs and their primary keys.
TABLES=(
  "gks_dict_variation:id"
  "gks_dict_sequence_reference:key"
  "gks_dict_location:key"
  "gks_dict_allele:key"
  "gks_dict_copy_number_count:key"
  "gks_dict_copy_number_change:key"
  "gks_dict_gene:key"
)

# Build FULL into a scratch copy: clone the release dataset's inputs are already present;
# run the proc with debug=FALSE against the real schema, then snapshot the 7 tables aside.
# NOTE: gks_catvar writes into {S}; to compare two builds we snapshot after each run.
echo ">>> full build"
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false \
  "CALL \`clinvar_ingest.gks_catvar_proc\`(DATE '${DATE}', FALSE)"
bq mk --project_id="$PROJECT_ID" --dataset --force "${FULL_DS}" 2>/dev/null || true
for t in "${TABLES[@]}"; do n="${t%%:*}"
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false \
    "CREATE OR REPLACE TABLE \`${FULL_DS}.${n}\` CLONE \`${SCHEMA}.${n}\`"
done

echo ">>> incremental build"
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false \
  "CALL \`clinvar_ingest.gks_catvar_proc_incremental\`(DATE '${DATE}', FALSE)"
bq mk --project_id="$PROJECT_ID" --dataset --force "${INCR_DS}" 2>/dev/null || true
for t in "${TABLES[@]}"; do n="${t%%:*}"
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false \
    "CREATE OR REPLACE TABLE \`${INCR_DS}.${n}\` CLONE \`${SCHEMA}.${n}\`"
done

echo ">>> compare"
FAIL=0
for t in "${TABLES[@]}"; do n="${t%%:*}"; pk="${t##*:}"
  OUT=$(bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv --quiet \
    "CALL \`clinvar_ingest.gks_oracle_compare\`('${FULL_DS}','${INCR_DS}','${n}','${pk}')" | tail -1)
  echo "  ${OUT}"
  echo "${OUT}" | awk -F, '{ if ($2+$3+$4 != 0) exit 1 }' || FAIL=1
done
if (( FAIL )); then echo "❌ ORACLE FAILED"; exit 1; fi
echo "✅ ORACLE PASSED (0 diffs on all catvar tables)"
```

Then `chmod +x src/scripts/oracle-catvar.sh`.

> **Note on the snapshot approach:** because `gks_catvar_proc` writes into `{S}`, the oracle runs full then incremental into the same `{S}`, snapshotting each result aside with `CLONE`. The incremental run overwrites the full run's `{S}` tables — that's fine, we compare the two snapshots. The final state of `{S}` is the incremental build (the intended production output). Leave a comment in the script saying so.

- [ ] **Step 4: Commit**

```bash
git add src/procedures/gks-oracle-compare-proc.sql src/scripts/oracle-catvar.sh
git commit -m "feat(oracle): reusable full-vs-incremental compare proc + catvar runbook"
```

---

## Chunk 3: gks_catvar incremental build

Refactor `gks_catvar_proc` into the build/wrapper/guard structure and make `gks_dict_variation` carry forward while the six global dicts stay globally recomputed. This is the core of Plan 1.

**Files:**
- Modify: `src/procedures/gks-catvar-proc.sql` (whole-file refactor)
- Modify: `src/scripts/vrs-to-bq-table.sh` (call the incremental wrapper for catvar)

**Impact set (spec §3) — do NOT use `variation_vrs_changed` as the base.** `variation_vrs_changed` is a canonical diff of the **`variation_identity` row only** (it drives vrsify). But `gks_dict_variation` reads `variation_hgvs` and `variation_loc` **directly** (`temp_catvar_extension`'s `clinvarHgvsList`: consequence codes, MANE flags, protein expressions; `temp_ctxvar_expression`'s expressions/name). A variation whose `variation.content` changed in a way that alters `variation_hgvs`/`variation_loc` **without** changing the selected fields in the `variation_identity` row is absent from `variation_vrs_changed` → catvar would carry forward a stale record. So the catvar changed set must be the **same broad set `variation_identity` itself recomputes** — `diff_variation(new|modified)` (covers all content-derived loc/hgvs/xref/identity) **∪ the copy-number cascade** (covers the SCV-copy-number path that feeds `gks_vrs` → `temp_ctxvar`) — **∪ `gene_association` changes** (`{S}.diff_gene_association`, any change_type → `variation_id`), **minus** removed (`diff_variation` removed).

This is exactly `variation_identity`'s Step-0 changed/removed set (mirror `variation-identity-proc.sql:156-210`) with a `gene_association` union added. `gks_vrs` changes need no separate driver: within a same-gate release `gks_vrs` changes iff its `variation_identity` row changed, which ⊆ `diff_variation(new|modified) ∪ cn-cascade`.

The six global dicts (`temp_seqref`/`temp_seqloc` → seqref/location; `temp_ctxvar_expression`/gks_vrs → allele/cn_count/cn_change; gene → gene) are **always globally recomputed** — unchanged from today. Only the per-variation temps and the final `gks_dict_variation` are filtered/merged.

- [ ] **Step 1: Write the oracle expectation first (it will fail — no incremental proc yet)**

Run: `./src/scripts/oracle-catvar.sh 2026-07-20`
Expected: FAIL — `CALL gks_catvar_proc_incremental` errors with "not found" (the wrapper doesn't exist yet). This confirms the oracle is wired and the proc is genuinely missing.

- [ ] **Step 2: Refactor the signature into build + wrappers**

In `src/procedures/gks-catvar-proc.sql`, change the top-level procedure from `gks_catvar_proc(on_date, debug)` to the internal build, and append the two wrappers at the bottom. Mirror `variation-identity-proc.sql:19,1102,1110`:

```sql
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_catvar_build`(on_date DATE, debug BOOL, incremental BOOL)
BEGIN
  -- ... existing DECLAREs ...
  -- add incremental control / fallback guard DECLAREs (mirror variation_identity:33-42)
  DECLARE eff_incremental BOOL DEFAULT FALSE;
  DECLARE baseline_schema STRING DEFAULT NULL;
  DECLARE base_ok BOOL DEFAULT FALSE;
  DECLARE diff_ok BOOL DEFAULT FALSE;
  DECLARE gate_ok BOOL DEFAULT FALSE;
  DECLARE vfilter_ctx STRING;       -- per-query changed-set filters ('' in full mode); see Step 4
  DECLARE vfilter_ext STRING;
  DECLARE vfilter_map STRING;
  DECLARE vfilter_dv STRING;
  DECLARE dv_head STRING;           -- gks_dict_variation target (real table vs stg temp)
  -- ... existing temp_create setup ...
```

At the bottom of the file:

```sql
-- Full rebuild (unchanged public signature/behavior)
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_catvar_proc`(on_date DATE, debug BOOL)
BEGIN
  CALL `clinvar_ingest.gks_catvar_build`(on_date, debug, FALSE);
END;

-- Incremental rebuild (carry-forward + merge). Guarded: falls back to full when the
-- baseline is missing/absent tables, diff drivers are missing, or the pipeline gate mismatches.
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_catvar_proc_incremental`(on_date DATE, debug BOOL)
BEGIN
  CALL `clinvar_ingest.gks_catvar_build`(on_date, debug, TRUE);
END;
```

- [ ] **Step 3: Add the resolve-baseline + fallback + version-gate guard**

Inside the `FOR rec IN (... schema_on ...)` loop, `rec` must also select `prev_release_date` (change the FOR to `SELECT s.schema_name, s.prev_release_date FROM clinvar_ingest.schema_on(on_date) AS s`). At the top of the loop body, before Step 1a, add (mirror variation_identity:54-83, plus the gate check):

```sql
SET eff_incremental = FALSE;
SET baseline_schema = NULL; SET base_ok = FALSE; SET diff_ok = FALSE; SET gate_ok = FALSE;

IF incremental AND rec.prev_release_date IS NOT NULL THEN
  SET baseline_schema = (SELECT s2.schema_name FROM clinvar_ingest.schema_on(rec.prev_release_date) AS s2 LIMIT 1);
END IF;

IF baseline_schema IS NOT NULL THEN
  -- baseline must have all 7 catvar outputs
  EXECUTE IMMEDIATE FORMAT("""
    SELECT (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES`
            WHERE table_name IN ('gks_dict_variation','gks_dict_sequence_reference','gks_dict_location',
              'gks_dict_allele','gks_dict_copy_number_count','gks_dict_copy_number_change','gks_dict_gene')) = 7
  """, baseline_schema) INTO base_ok;
  -- current release must have the diff drivers: the same three variation_identity uses
  -- (diff_variation / diff_clinical_assertion / diff_clinical_assertion_variation for the
  -- content + copy-number cascade) PLUS diff_gene_association for the gene path.
  EXECUTE IMMEDIATE FORMAT("""
    SELECT (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES`
            WHERE table_name IN ('diff_variation','diff_clinical_assertion',
              'diff_clinical_assertion_variation','diff_gene_association')) = 4
  """, rec.schema_name) INTO diff_ok;

  -- version gate — TWO statements. BigQuery resolves table refs at analysis time and AND
  -- does NOT short-circuit that resolution, so a single combined statement that references
  -- {base}.gks_pipeline_version would ERROR (not return FALSE) when a pre-feature baseline
  -- lacks the stamp — defeating the fail-safe. First check both stamps exist; only then
  -- compare gate_key.
  BEGIN
    DECLARE stamps_exist BOOL DEFAULT FALSE;
    EXECUTE IMMEDIATE FORMAT("""
      SELECT
        (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name='gks_pipeline_version')=1
        AND
        (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name='gks_pipeline_version')=1
    """, baseline_schema, rec.schema_name) INTO stamps_exist;
    IF stamps_exist THEN
      EXECUTE IMMEDIATE FORMAT("""
        SELECT (SELECT gate_key FROM `%s.gks_pipeline_version`)
             = (SELECT gate_key FROM `%s.gks_pipeline_version`)
      """, baseline_schema, rec.schema_name) INTO gate_ok;
    END IF;
  END;

  SET eff_incremental = base_ok AND diff_ok AND gate_ok;
END IF;
```

> Declare `stamps_exist` in an inner `BEGIN...END` block (BigQuery allows nested `DECLARE` inside a `BEGIN` block) or hoist it to the top-level `DECLARE`s — either works; the two-statement structure is what matters.

- [ ] **Step 4: Set mode-dependent fragments**

After the guard, set the per-query alias-correct filter fragments and the `gks_dict_variation` target. Use **distinct variables per query** because each query filters on a different alias (Step 6 lists them); a single generic `vfilter` with a wrong alias will not compile:

```sql
IF eff_incremental THEN
  -- one fragment per consuming query, each with that query's alias for variation_id
  SET vfilter_ctx = 'AND vrs.in.variation_id IN (SELECT variation_id FROM {P}.catvar_changed_ids)'; -- Step 3 temp_ctxvar
  SET vfilter_ext = 'WHERE x.variation_id IN (SELECT variation_id FROM {P}.catvar_changed_ids)';     -- Step 4 outer select
  SET vfilter_map = 'AND m.variation_id IN (SELECT variation_id FROM {P}.catvar_changed_ids)';        -- Step 5 (see note)
  SET vfilter_dv  = 'AND ctx.variation_id IN (SELECT variation_id FROM {P}.catvar_changed_ids)';      -- Step 6 catvar CTE
  SET dv_head = '{CT} {P}.stg_gks_dict_variation';   -- stage changed rows, merge after
ELSE
  SET vfilter_ctx = ''; SET vfilter_ext = ''; SET vfilter_map = ''; SET vfilter_dv = '';
  SET dv_head = 'CREATE OR REPLACE TABLE `{S}.gks_dict_variation`';
END IF;
```

Add `DECLARE vfilter_ctx STRING; DECLARE vfilter_ext STRING; DECLARE vfilter_map STRING; DECLARE vfilter_dv STRING;` to the top-level DECLAREs.

> **Step 4 / 5 filter placement:** `temp_catvar_extension`'s final select is `... FROM cat_ext_item x ... GROUP BY x.variation_id` — insert `vfilter_ext` as the `WHERE` before `GROUP BY` (note it is a full `WHERE`, not an `AND`, since that select has no existing WHERE). `temp_catvar_mappings`'s final select is `... FROM catvar_mappings m GROUP BY m.variation_id` — same: `vfilter_map` must be a `WHERE` there (adjust the `AND`→`WHERE` when the target select has no existing predicate). Verify each target select's existing WHERE/no-WHERE and set the fragment's leading keyword (`AND` vs `WHERE`) accordingly.

> The `{VFILTER}` is applied in the final `gks_dict_variation` assembly (Step 6) on the `catvar` CTE's `variation_id`, and in the per-variation temps (Step 2, 3, 4, 5) so those temps only compute the changed set. Add `{VFILTER}` to: `temp_ctxvar_expression` (filter each UNION arm's source by `variation_id IN changed`), `temp_ctxvar`, `temp_catvar_extension`, `temp_catvar_mappings`. Because those temps are keyed by `variation_id`, the filter is a straightforward `WHERE`/`AND`. The six global dict queries (Steps 1c, 1d, 2b, 2c, 2d, 4b) are **NOT** filtered — they read the whole-snapshot temps (`temp_seqref`, `temp_seqloc`) or `gks_vrs`/`gene` directly and must stay global.

**Important:** the global dicts depend on `temp_seqref`/`temp_seqloc`/`temp_ctxvar_expression`. `temp_seqref`/`temp_seqloc` are built from all of `gks_vrs` (Steps 1a/1b — leave unfiltered). But `temp_ctxvar_expression` feeds BOTH `gks_dict_allele` (global, needs all alleles) AND `gks_dict_variation` (per-variation). **So `temp_ctxvar_expression` must stay GLOBAL** (unfiltered) — filtering it would break `gks_dict_allele`. Only `temp_ctxvar`, `temp_catvar_extension`, `temp_catvar_mappings`, and the final `gks_dict_variation` assembly take `{VFILTER}`. Verify each temp's downstream consumers before filtering it.

- [ ] **Step 5: Add the Step-0 changed/removed set (incremental only)**

Before Step 1a, add (mirror `variation-identity-proc.sql:156-210` for the removed set + cn-cascade; `{BASE}` = `baseline_schema`):

```sql
IF eff_incremental THEN
  -- removed = diff_variation removed
  SET <q> = REPLACE("""
    {CT} {P}.catvar_removed_ids AS
    SELECT id AS variation_id FROM `{S}.diff_variation` WHERE change_type = 'removed'
  """, '{BASE}', baseline_schema);
  -- resolve {CT}/{P}/{S}; EXECUTE IMMEDIATE

  -- changed = diff_variation(new|modified) ∪ copy-number cascade ∪ gene_association changes; minus removed.
  -- The cn_cascade block is copied verbatim from variation-identity-proc.sql:170-203 (it resolves
  -- changed CopyNumber-bearing SCVs over BOTH {S} and {BASE}). Only the final SELECT adds the
  -- gene_association union.
  SET <q> = REPLACE("""
    {CT} {P}.catvar_changed_ids AS
    WITH changed_cav AS (
      SELECT id FROM `{S}.diff_clinical_assertion_variation` WHERE change_type IN ('new','modified','removed')
    ),
    changed_ca AS (
      SELECT id FROM `{S}.diff_clinical_assertion` WHERE change_type IN ('new','modified','removed')
    ),
    cn_cascade AS (
      SELECT DISTINCT ca.variation_id AS variation_id
      FROM `{S}.clinical_assertion_variation` cav
      JOIN `{S}.clinical_assertion` ca ON ca.id = cav.clinical_assertion_id AND ca.statement_type IS NOT NULL
      WHERE cav.content LIKE '%CopyNumber%'
        AND (cav.id IN (SELECT id FROM changed_cav) OR cav.clinical_assertion_id IN (SELECT id FROM changed_ca))
      UNION DISTINCT
      SELECT DISTINCT ca.variation_id AS variation_id
      FROM `{BASE}.clinical_assertion_variation` cav
      JOIN `{BASE}.clinical_assertion` ca ON ca.id = cav.clinical_assertion_id AND ca.statement_type IS NOT NULL
      WHERE cav.content LIKE '%CopyNumber%'
        AND (cav.id IN (SELECT id FROM changed_cav) OR cav.clinical_assertion_id IN (SELECT id FROM changed_ca))
    )
    SELECT variation_id FROM (
      SELECT id AS variation_id FROM `{S}.diff_variation` WHERE change_type IN ('new','modified')
      UNION DISTINCT SELECT variation_id FROM cn_cascade
      UNION DISTINCT
      SELECT DISTINCT variation_id FROM `{S}.diff_gene_association` WHERE change_type IN ('new','modified','removed')
    )
    WHERE variation_id NOT IN (SELECT variation_id FROM {P}.catvar_removed_ids)
  """, '{BASE}', baseline_schema);
  -- resolve {CT}/{P}/{S}; EXECUTE IMMEDIATE
END IF;
```

Resolve `{CT}`/`{P}`/`{S}` exactly as the other queries do (the `{BASE}` REPLACE must come first, before `{S}`, because `{BASE}` values contain no `{S}` token but resolving order matters for safety — follow the variation_identity ordering). Add `catvar_changed_ids`, `catvar_removed_ids`, and `stg_gks_dict_variation` to the `cleanup_temp_tables` list (line 32-35) and, guarded by `IF eff_incremental`, to the `DROP TABLE IF EXISTS _SESSION.*` block (line 974-981) — mirror `variation-identity-proc.sql:1087-1093`.

> The guard's `diff_ok` (Step 3) already requires `diff_variation`, `diff_clinical_assertion`, `diff_clinical_assertion_variation`, and `diff_gene_association` — the exact tables this changed-set query reads — so if any driver is missing the proc falls back to full before reaching here.

- [ ] **Step 6: Apply the per-query filters and `{DVHEAD}` in the per-variation queries**

Each query gets a distinct `{VFILTER}` token replaced with its alias-correct fragment from Step 4 (`vfilter_ctx`/`vfilter_ext`/`vfilter_map`/`vfilter_dv`). Add the token to the query string and a matching `REPLACE(..., '{VFILTER}', <fragment>)` after the existing REPLACEs:

- In `temp_ctxvar_query` (proc Step 3): add `{VFILTER}` to the `ctxvar` CTE's outer WHERE (selects from `gks_vrs vrs`) → `REPLACE(..., '{VFILTER}', vfilter_ctx)` (fragment: `AND vrs.in.variation_id IN (...)`).
- In `temp_catvar_ext_query` (proc Step 4): the final `SELECT ... FROM cat_ext_item x ... GROUP BY x.variation_id` has **no existing WHERE** → add `{VFILTER}` before `GROUP BY` and use `vfilter_ext` (a full `WHERE x.variation_id IN (...)`).
- In `temp_catvar_map_query` (proc Step 5): the final `SELECT ... FROM catvar_mappings m ... GROUP BY m.variation_id` has **no existing WHERE** → add `{VFILTER}` before `GROUP BY` and use `vfilter_map` (a full `WHERE m.variation_id IN (...)`).
- In `dict_variation_query` (proc Step 6): change the head to `{DVHEAD}` (was `CREATE OR REPLACE TABLE \`{S}.gks_dict_variation\``) and add `{VFILTER}` on the `catvar` CTE (`WHERE ctx.variation_id is not null {VFILTER}`) using `vfilter_dv` (an `AND ctx.variation_id IN (...)`). Add `REPLACE(..., '{DVHEAD}', dv_head)` and `REPLACE(..., '{VFILTER}', vfilter_dv)`.

The leading keyword (`AND` vs `WHERE`) of each fragment matches whether its target select already has a WHERE — verify against the current proc before wiring (Step 4's note covers the `WHERE`-vs-`AND` distinction for ext/map).

- [ ] **Step 7: Add the UNION-CTAS merge for gks_dict_variation (incremental only)**

After Step 6 (the `dict_variation_query` EXECUTE), before the validation, add (mirror variation_identity:960-1080; use an **explicit column list**, not `SELECT *`, so schema drift errors loudly):

```sql
IF eff_incremental THEN
  SET <merge_q> = REPLACE("""
    CREATE OR REPLACE TABLE `{S}.gks_dict_variation` AS
    SELECT id, type, name, constraints, members, extensions, mappings
    FROM `{BASE}.gks_dict_variation`
    WHERE SPLIT(id, ':')[OFFSET(1)] NOT IN (
      SELECT variation_id FROM {P}.catvar_changed_ids
      UNION DISTINCT SELECT variation_id FROM {P}.catvar_removed_ids
    )
    UNION ALL
    SELECT id, type, name, constraints, members, extensions, mappings
    FROM {P}.stg_gks_dict_variation
  """, '{BASE}', baseline_schema);
  -- resolve {P}/{S}; EXECUTE IMMEDIATE
END IF;
```

> Confirm the exact column list against the deployed `gks_dict_variation` schema: `bq show --schema --format=prettyjson "${SCHEMA}.gks_dict_variation"`. The list above matches the Step-6 SELECT (`id,type,name,constraints,members,extensions,mappings`) — verify and correct if the proc changes.

> The `gks_dict_variation.id` is `clinvar:<variation_id>`; the carry-forward filter strips the prefix with `SPLIT(id,':')[OFFSET(1)]` to match the `variation_id` sets (mirrors the validation at line 961).

- [ ] **Step 8: Keep the exact-id validation — it now also proves the merge is complete**

The existing validation (lines 956-972) asserts `gks_dict_variation`'s id set exactly equals `variation.id` with one row each. **Leave it in place** — after the incremental merge it becomes a built-in completeness check: if carry-forward + changed staging misses or double-counts any variation, this `RAISE`s. No change needed beyond ensuring it runs in both modes (it already runs unconditionally at the end of the loop).

- [ ] **Step 9: Deploy and run the oracle**

Run:
```bash
bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false < src/procedures/gks-catvar-proc.sql
# ensure drivers exist for the compare release: dataset_diff_on produces ALL diff_* tables
# (diff_variation, diff_clinical_assertion, diff_clinical_assertion_variation,
# diff_gene_association) that catvar's changed-set query + guard require; plus a matching
# stamped gate on BOTH baseline and compare so the version gate passes.
bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false \
  "CALL \`clinvar_ingest.dataset_diff_on\`(DATE '2026-07-20');
   CALL \`clinvar_ingest.gks_pipeline_version\`(DATE '2026-07-15','seed','GATE1');
   CALL \`clinvar_ingest.gks_pipeline_version\`(DATE '2026-07-20','seed','GATE1')"
./src/scripts/oracle-catvar.sh 2026-07-20
```
Expected: `✅ ORACLE PASSED (0 diffs on all catvar tables)`. If any table shows nonzero, debug the impact set / filter for that table before proceeding (do NOT relax the oracle).

- [ ] **Step 10: Point the pipeline at the incremental wrapper**

In `src/scripts/vrs-to-bq-table.sh`, the `BIGQUERY_PROCEDURES` array (lines 64-72) calls `gks_catvar_proc` with `(date, FALSE)` in the loop (line 179). Catvar now needs the incremental wrapper. Simplest, lowest-risk change: special-case catvar in `execute_bq_procedures` — call `gks_catvar_proc_incremental` for catvar, leave the rest full (they become incremental in Plans 2-4). Replace the `'clinvar_ingest.gks_catvar_proc'` entry and add a branch, or before the loop:

```bash
# catvar is incremental (Plan 1); its build proc self-guards + falls back to full.
echo "  - Calling procedure: clinvar_ingest.gks_catvar_proc_incremental..."
bq --project_id="$PROJECT_ID" query --quiet --use_legacy_sql=false \
  "CALL \`clinvar_ingest.gks_catvar_proc_incremental\`('$release_date', FALSE)" > /dev/null \
  || { echo "❌ gks_catvar_proc_incremental FAILED"; return 1; }
```
and remove `'clinvar_ingest.gks_catvar_proc'` from the `BIGQUERY_PROCEDURES` array so it isn't also called full.

- [ ] **Step 11: Commit**

```bash
git add src/procedures/gks-catvar-proc.sql src/scripts/vrs-to-bq-table.sh
git commit -m "feat(catvar): incremental gks_catvar (carry-forward gks_dict_variation, global dicts recomputed)"
```

---

## Chunk 4: catvar delta datasets (manifest + payloads)

Produce the per-release catvar delta: the `gks_change_log` manifest slice (A/U/D incl. tombstones) and same-schema `A`∪`U` payload tables. This is the deliverable that justifies the whole initiative, and the pattern every later phase reuses.

**Files:**
- Modify: `src/procedures/gks-change-log-proc.sql` (track catvar dict tables)
- Create: `src/procedures/gks-delta-proc.sql` (`gks_delta_build` — materialize `{S}.delta_*` payloads)

- [ ] **Step 1: Extend gks_change_log to track the catvar dict tables**

In `src/procedures/gks-change-log-proc.sql`, add to the `tracked` array (lines 37-42) the seven catvar outputs with their pks (dicts key on `key`, variation on `id`):

```sql
DECLARE tracked ARRAY<STRUCT<name STRING, pk STRING>> DEFAULT [
  STRUCT('gks_catvar'        AS name, 'id' AS pk),
  STRUCT('gks_scv_statement',       'id'),
  STRUCT('gks_rcv_statement',       'id'),
  STRUCT('gks_vcv_statement',       'id'),
  -- catvar outputs (Plan 1)
  STRUCT('gks_dict_variation',              'id'),
  STRUCT('gks_dict_sequence_reference',     'key'),
  STRUCT('gks_dict_location',               'key'),
  STRUCT('gks_dict_allele',                 'key'),
  STRUCT('gks_dict_copy_number_count',      'key'),
  STRUCT('gks_dict_copy_number_change',     'key'),
  STRUCT('gks_dict_gene',                   'key')
];
```

The existing proc logic already handles A/U/D via two-tier canonicalize compare and first-run-all-A, per pk. No other change needed. This yields, for the six global dicts, exactly the content-diff-vs-baseline A/U/D the spec §2 requires; for `gks_dict_variation` it validates the carry-forward merge.

- [ ] **Step 2: Deploy + verify the manifest captures catvar deletes and changes**

Run:
```bash
bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false < src/procedures/gks-change-log-proc.sql
bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false \
  "CALL \`clinvar_ingest.gks_change_log\`(DATE '2026-07-20')"
bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false --format=csv \
  "SELECT table_name, change_type, COUNT(*) n FROM \`${SCHEMA}.gks_change_log\`
   WHERE table_name LIKE 'gks_dict_%' GROUP BY 1,2 ORDER BY 1,2"
```
Expected: nonzero A/U (and possibly D) rows for the catvar dict tables; `gks_dict_variation` A+U count should match `catvar_changed_ids` count from the incremental build (sanity: they describe the same change set).

- [ ] **Step 3: Write the delta payload builder**

Create `src/procedures/gks-delta-proc.sql`:

```sql
-- ============================================================================
-- gks_delta_build — materialize per-table delta payloads from gks_change_log
-- ============================================================================
-- For each tracked table, writes {S}.delta_<table> = the FULL current rows whose pk
-- is A or U in {S}.gks_change_log (same schema as the target table — a consumer
-- upserts it by pk directly). D tombstones are NOT payload rows; they live in the
-- manifest (gks_change_log) only. Requires gks_change_log to have been built first.
--
-- `tables` mirrors gks_change_log's tracked set (name + pk expression). Keep in sync.
-- ============================================================================
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_delta_build`(on_date DATE)
BEGIN
  DECLARE tables ARRAY<STRUCT<name STRING, pk STRING>> DEFAULT [
    STRUCT('gks_dict_variation'          AS name, 'id' AS pk),
    STRUCT('gks_dict_sequence_reference',     'key'),
    STRUCT('gks_dict_location',               'key'),
    STRUCT('gks_dict_allele',                 'key'),
    STRUCT('gks_dict_copy_number_count',      'key'),
    STRUCT('gks_dict_copy_number_change',     'key'),
    STRUCT('gks_dict_gene',                   'key')
  ];
  DECLARE i INT64 DEFAULT 0;
  DECLARE t STRUCT<name STRING, pk STRING>;
  DECLARE q STRING;

  FOR rec IN (SELECT s.schema_name FROM `clinvar_ingest.schema_on`(on_date) AS s)
  DO
    SET i = 0;
    WHILE i < ARRAY_LENGTH(tables) DO
      SET t = tables[OFFSET(i)];
      SET i = i + 1;
      SET q = """
        CREATE OR REPLACE TABLE `{S}.delta_{T}` AS
        SELECT src.*
        FROM `{S}.{T}` src
        WHERE CAST({PK} AS STRING) IN (
          SELECT pk FROM `{S}.gks_change_log`
          WHERE table_name = '{T}' AND change_type IN ('A','U')
        )
      """;
      SET q = REPLACE(q, '{PK}', t.pk);
      SET q = REPLACE(q, '{T}', t.name);
      SET q = REPLACE(q, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE q;
    END WHILE;
  END FOR;
END;
```

> `src.*` gives the delta payload the exact target-table schema (spec §4). For `gks_dict_variation` the pk expression is `id`; the change_log stored `id` as the pk, so `CAST(id AS STRING) IN (SELECT pk ...)` matches directly (no prefix stripping — both sides use the full `clinvar:<id>` value).

- [ ] **Step 4: Deploy + write the reconstruction assertion (the delta correctness test)**

The delta is correct iff `carry-forward(baseline minus D minus A/U) UNION delta_T == full T`. Assert it with the oracle proc against a reconstructed table. Run:
```bash
bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false < src/procedures/gks-delta-proc.sql
bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false \
  "CALL \`clinvar_ingest.gks_delta_build\`(DATE '2026-07-20')"
BASE=$(bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false --format=csv --quiet \
  "SELECT schema_name FROM \`clinvar_ingest.schema_on\`((SELECT prev_release_date FROM \`clinvar_ingest.schema_on\`(DATE '2026-07-20')))" | tail -1 | tr -d '[:space:]')
# reconstruct gks_dict_location from baseline + delta and compare to full current
bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false \
  "CREATE OR REPLACE TABLE \`${SCHEMA}_recon.gks_dict_location\` AS
     SELECT * FROM \`${BASE}.gks_dict_location\`
     WHERE key NOT IN (SELECT pk FROM \`${SCHEMA}.gks_change_log\`
                       WHERE table_name='gks_dict_location' AND change_type IN ('U','D'))
     UNION ALL
     SELECT * FROM \`${SCHEMA}.delta_gks_dict_location\`"
bq query --project_id="${PROJECT_ID:-clingen-dev}" --use_legacy_sql=false \
  "CALL \`clinvar_ingest.gks_oracle_compare\`('${SCHEMA}','${SCHEMA}_recon','gks_dict_location','key')"
```
Expected: `gks_dict_location, 0, 0, 0` (baseline carry-forward minus U/D, plus the A/U delta, reconstructs the full table). Repeat the reconstruction check for `gks_dict_variation` (its carry-forward filter uses `id`). If nonzero, the delta or the change-log pk handling is wrong — fix before proceeding.

> Create the `${SCHEMA}_recon` scratch dataset first (`bq mk --dataset --force`). Clean up scratch datasets (`${SCHEMA}_recon`, `${SCHEMA}_oracle_*`) at the end.

- [ ] **Step 5: Wire delta production into the pipeline**

In `src/scripts/vrs-to-bq-table.sh`, `execute_bq_procedures`, after the existing `gks_json_proc` call (line 186-189) — actually after all catvar/statement procs and the change-log — add the change-log + delta build. `gks_change_log` must run after all tracked tables are built; `gks_delta_build` after the change log. Add at the end of `execute_bq_procedures` (before the final success echo):

```bash
echo "  - Calling procedure: clinvar_ingest.gks_change_log..."
bq --project_id="$PROJECT_ID" query --quiet --use_legacy_sql=false \
  "CALL \`clinvar_ingest.gks_change_log\`('$release_date')" > /dev/null \
  || { echo "❌ gks_change_log FAILED"; return 1; }
echo "  - Calling procedure: clinvar_ingest.gks_delta_build..."
bq --project_id="$PROJECT_ID" query --quiet --use_legacy_sql=false \
  "CALL \`clinvar_ingest.gks_delta_build\`('$release_date')" > /dev/null \
  || { echo "❌ gks_delta_build FAILED"; return 1; }
```

> R2 publishing of the delta tables (export `delta_*` → Parquet/NDJSON, weekly cadence, manifest.json) is **Plan 4** — not in scope here. Plan 1 stops at the delta tables existing in BigQuery, oracle-verified.

- [ ] **Step 6: Commit**

```bash
git add src/procedures/gks-change-log-proc.sql src/procedures/gks-delta-proc.sql src/scripts/vrs-to-bq-table.sh
git commit -m "feat(delta): catvar change-log manifest + same-schema delta payloads"
```

---

## Done criteria (Plan 1)

- [ ] `gks_catvar_proc_incremental` builds the seven catvar outputs and the oracle (`oracle-catvar.sh`) reports **0 canonical diffs** on all seven vs a full build.
- [ ] The version gate auto-falls-back to full rebuild on gate mismatch / missing baseline / missing drivers; `--full` forces a rebuild (unique gate).
- [ ] `{S}.gks_change_log` carries A/U/D for the seven catvar tables; `{S}.delta_*` payloads exist with the target schema and **reconstruct the full table** (baseline carry-forward ∪ delta == full) per the oracle.
- [ ] `run-release.sh` stamps `gks_pipeline_version`; `vrs-to-bq-table.sh` calls catvar incrementally and builds the change-log + delta.
- [ ] No change to the six global dicts' computation (still globally recomputed); their delta comes from the change-log content diff.

## Deferred to later plans (do NOT do here)

- Plan 2: `gks_scv_condition` (incl. the two global condition dicts driven by `diff_trait`/`diff_trait_set`) + `gks_scv_statement`; the `scv_significant_change` predicate + `gks_scv_change_audit`.
- Plan 3: `gks_rcv`/`gks_rcv_statement` + `gks_vcv`/`gks_vcv_statement` (aggregation cascade, membership-first impact sets).
- Plan 4: `gks_json` + R2 delta publishing (export `delta_*` → Parquet/NDJSON, weekly deltas / monthly full, `manifest.json` from the change-log slice).
- Open items from spec: `gks_scv_condition_sets` `trait_mapping`/`gks_xref_iri_templates` coverage; cost measurement per table.
