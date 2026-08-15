# Proposition Delivery Grouping (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single mixed `proposition` bundle section with four datatype-homogeneous top-level sections (`varcond-proposition`, `vartumor-proposition`, `vartherapy-proposition`, `varcustom-proposition`), each a fully-typed Parquet table + clean bundle section, with all proposition references group-qualified.

**Architecture:** The 3 per-level proposition dict tables (`gks_dict_proposition`/`_rcv_`/`_vcv_`) are **unchanged** — same ids, same JSON. Every proposition *reference* string (8 sites in the 3 statement procs) is rewritten from `#/proposition/{id}` to `#/{group}-proposition/{id}`, where `{group}` comes from **one canonical CASE over the raw gks type**. The 4-way split of the dict rows into 4 sections happens at the **delivery layer** (`export-gks-dicts.sh` + `assemble-gks-dicts.py`) using the *same* CASE. A reference-integrity gate recomputes the group from each target row's type and asserts it matches the pointer prefix.

**Tech Stack:** BigQuery stored procedures (dynamic SQL, `clinvar_ingest.*`), `bq` CLI, bash export scripts, Python assemble script, MkDocs.

**Spec:** `docs/superpowers/specs/2026-08-14-proposition-delivery-grouping-phase2-design.md`

**Branch:** `feat/proposition-delivery-grouping-phase2` (off `main`).

---

## Resolved decisions (were open items in the spec)

- **Canonical group mapping — key on the RAW gks type via one CASE.** The raw gks type is the pre-collapse
  proposition type: `ClinvarRiskFactorProposition`, `VariantPathogenicityProposition`, etc. At each site it
  is obtained as:
  - SCV statement site (`sp`): `COALESCE(sp.customPropositionType, sp.type)` (custom rows carry the raw
    type in `customPropositionType`; standard rows carry it in `type`).
  - SCV evidence-line site (`stp`): `stp.type` (target props are always standard — Diag/Prog/TherapResp).
  - RCV/VCV sites: `cpt.gks_type` after adding a `LEFT JOIN clinvar_ingest.clinvar_proposition_types cpt`
    (the agg tables expose only the `prop_type` *code*, not the gks type — resolve it here so every layer
    keys off the same value).
  - Export/assemble split: `COALESCE(JSON_VALUE(value,'$.customPropositionType'), JSON_VALUE(value,'$.type'))`.

  The CASE body is **byte-identical everywhere**:
  ```sql
  CASE
    WHEN <raw> LIKE 'Clinvar%'                          THEN 'varcustom'
    WHEN <raw> = 'VariantOncogenicityProposition'       THEN 'vartumor'
    WHEN <raw> = 'VariantTherapeuticResponseProposition' THEN 'vartherapy'
    WHEN <raw> IN ('VariantPathogenicityProposition',
                   'VariantClinicalSignificanceProposition',
                   'VariantDiagnosticProposition',
                   'VariantPrognosticProposition')       THEN 'varcond'
    ELSE ERROR(FORMAT('unmapped proposition type for delivery grouping: %t', <raw>))
  END
  ```
  The `ELSE ERROR(...)` makes the mapping **total** and **fail-fast** — a new upstream standard type fails
  the proc/export immediately rather than emitting a `#/-proposition/` pointer. (Refines the spec's
  `= 'CustomProposition'` form to `LIKE 'Clinvar%'` so it unifies the pre- and post-collapse
  representations. Exact `$.type` literals are confirmed live in Task 1.1 before any CASE is written.)
- **Export split mechanism:** replace the whole-table `bq extract` (NDJSON) and per-level
  `extract_parquet_typed` calls with **4 group `EXPORT DATA … AS SELECT … WHERE group=…`** statements for
  NDJSON and **4 typed `EXPORT DATA`** for Parquet, each `UNION ALL` across the levels that carry the
  group. (Parquet already uses `EXPORT DATA AS SELECT`, so this is the natural extension; NDJSON moves off
  `bq extract` because it cannot filter.)
- **Parquet:** 4 typed per-group schema files replace the 3 generic ones. **Drop** the never-populated
  `alleleOrigin` column (YAGNI — add it when upstream emits it). Keep a `data` column (`TO_JSON_STRING`)
  in each for round-trip parity with the current schemas.
- **Test release:** `clinvar_2026_07_20_v2_5_0`, project `clingen-dev`, date `2026-07-20` (the dataset
  Phase 1 validated). All `bq` commands below assume `--project_id=clingen-dev`.

## File Structure

- **Modify** `src/procedures/gks-scv-statement-proc.sql` — reference sites `:713` (evidence-line, `stp`),
  `:784` (statement, `sp`).
- **Modify** `src/procedures/gks-rcv-statement-proc.sql` — reference sites `:112/172/237`; add `cpt` join
  at each.
- **Modify** `src/procedures/gks-vcv-statement-proc.sql` — reference sites `:79/139/204`; add `cpt` join.
- **Create** `src/scripts/parquet-schemas/{varcond,vartumor,vartherapy,varcustom}-proposition.sql`.
- **Delete** `src/scripts/parquet-schemas/{proposition,rcv_proposition,vcv_proposition}.sql`.
- **Modify** `src/scripts/export-gks-dicts.sh` — proposition NDJSON (`:96/100/102`) + Parquet
  (`:129/133/135`) blocks → 4 group exports.
- **Modify** `src/scripts/assemble-gks-dicts.py` — `SECTIONS` line `:70` (1 entry → 4).
- **Modify** `src/scripts/validate-proposition-conformance.sh` — add the reference-integrity gate.
- **Modify** docs — proposition pages + downloads page.

## Deploy / run / verify idiom (used throughout)

```bash
# deploy an edited proc (the file is a single CREATE OR REPLACE PROCEDURE)
bq query --project_id=clingen-dev --use_legacy_sql=false --format=none \
  < src/procedures/gks-scv-statement-proc.sql

# run it for the test release (2nd arg FALSE = non-debug)
bq query --project_id=clingen-dev --use_legacy_sql=false --format=none \
  "CALL \`clinvar_ingest.gks_scv_statement_proc\`('2026-07-20', FALSE)"

# verify with an assertion query against the built dataset clinvar_2026_07_20_v2_5_0
```

---

## Chunk 1: Canonical mapping + SCV reference rewrite

**Files:**
- Modify: `src/procedures/gks-scv-statement-proc.sql:713,784`

- [ ] **Step 1.1: Confirm the live `$.type` literals + total coverage (grounding).**
  Run against the already-built test dataset — this fixes the exact strings the CASE will match and proves
  no proposition escapes the 4 groups:
  ```bash
  bq query --project_id=clingen-dev --use_legacy_sql=false --format=prettyjson '
    WITH allp AS (
      SELECT value FROM `clinvar_2026_07_20_v2_5_0.gks_dict_proposition`
      UNION ALL SELECT value FROM `clinvar_2026_07_20_v2_5_0.gks_dict_rcv_proposition`
      UNION ALL SELECT value FROM `clinvar_2026_07_20_v2_5_0.gks_dict_vcv_proposition`)
    SELECT COALESCE(JSON_VALUE(value,"$.customPropositionType"), JSON_VALUE(value,"$.type")) AS raw_type,
           COUNT(*) n
    FROM allp GROUP BY raw_type ORDER BY raw_type'
  ```
  Expected: every `raw_type` is one of the 11 known values (7 standard `Variant*Proposition` + up to 4 seen
  custom `Clinvar*Proposition` in this release), no NULLs. **Record the exact strings** and reconcile the
  CASE literals to them before Step 1.2.

- [ ] **Step 1.2: Write the pre-change assertion (expect it to FAIL post-change if not rewritten).**
  Baseline query — SCV statements + evidence lines still use the old prefix:
  **Note:** the statement/evidence-line dict tables (`gks_dict_scv/rcv/vcv`, `gks_dict_evidence_line`) are
  **native-column** tables — the pointer is a bare top-level `STRING` column named `proposition`, NOT a KV
  `value` JSON column. (Only the proposition *dict* tables `gks_dict_*proposition` are KV with a JSON
  `value`.) So query the bare column:
  ```bash
  bq query --project_id=clingen-dev --use_legacy_sql=false --format=csv '
    SELECT
      (SELECT COUNTIF(proposition LIKE "#/proposition/%")
         FROM `clinvar_2026_07_20_v2_5_0.gks_dict_scv`) AS scv_old,
      (SELECT COUNTIF(proposition LIKE "#/proposition/%")
         FROM `clinvar_2026_07_20_v2_5_0.gks_dict_evidence_line`) AS el_old'
  ```
  Expected NOW: both > 0. After this chunk: both = 0 (SCV rows only; RCV/VCV evidence-line rows carry no
  `proposition`, so `el_old` counts SCV evidence lines).

- [ ] **Step 1.3: Rewrite site `:784` (subject proposition, statement dict).**
  Replace `FORMAT('#/proposition/%s', sp.id) as proposition,` with the group-qualified form using the
  canonical CASE over `COALESCE(sp.customPropositionType, sp.type)`:
  ```sql
  FORMAT('#/%s-proposition/%s',
    CASE
      WHEN COALESCE(sp.customPropositionType, sp.type) LIKE 'Clinvar%' THEN 'varcustom'
      WHEN COALESCE(sp.customPropositionType, sp.type) = 'VariantOncogenicityProposition' THEN 'vartumor'
      WHEN COALESCE(sp.customPropositionType, sp.type) = 'VariantTherapeuticResponseProposition' THEN 'vartherapy'
      WHEN COALESCE(sp.customPropositionType, sp.type) IN
        ('VariantPathogenicityProposition','VariantClinicalSignificanceProposition',
         'VariantDiagnosticProposition','VariantPrognosticProposition') THEN 'varcond'
      ELSE ERROR(FORMAT('unmapped proposition type for delivery grouping: %t', COALESCE(sp.customPropositionType, sp.type)))
    END,
    sp.id) as proposition,
  ```
  (Add a one-line comment above pointing to the canonical mapping in this plan/spec.) Note: this is inside
  an `EXECUTE IMMEDIATE` triple-quoted string — the `%` in `'Clinvar%'` and the `%s`/`%t` in `FORMAT` are
  literal SQL, not escape sequences, so no extra escaping is needed; verify the deploy parses.

- [ ] **Step 1.4: Rewrite site `:713` (target proposition, evidence-line dict).**
  Same CASE but the raw type is simply `stp.type` (target props are never custom):
  ```sql
  FORMAT('#/%s-proposition/%s',
    CASE
      WHEN stp.type = 'VariantTherapeuticResponseProposition' THEN 'vartherapy'
      WHEN stp.type IN ('VariantDiagnosticProposition','VariantPrognosticProposition') THEN 'varcond'
      ELSE ERROR(FORMAT('unmapped target proposition type: %t', stp.type))
    END,
    stp.id) as proposition,
  ```

- [ ] **Step 1.5: Deploy + run the SCV proc.**
  ```bash
  bq query --project_id=clingen-dev --use_legacy_sql=false --format=none < src/procedures/gks-scv-statement-proc.sql
  bq query --project_id=clingen-dev --use_legacy_sql=false --format=none "CALL \`clinvar_ingest.gks_scv_statement_proc\`('2026-07-20', FALSE)"
  ```
  Expected: both succeed (no `unmapped …` ERROR → mapping is total for this release).

- [ ] **Step 1.6: Re-run the Step 1.2 assertion — expect PASS.**
  Expected: `scv_old = 0` and `el_old = 0`, and a spot check shows the new prefixes:
  ```bash
  bq query --project_id=clingen-dev --use_legacy_sql=false --format=csv '
    SELECT REGEXP_EXTRACT(proposition, r"^#/([a-z]+-proposition)/") grp, COUNT(*) n
    FROM `clinvar_2026_07_20_v2_5_0.gks_dict_scv` GROUP BY grp ORDER BY grp'
  ```
  Expected: only `varcond-proposition`, `vartumor-proposition`, `varcustom-proposition` for SCV statements
  (subject props are never TherapeuticResponse); evidence lines add `vartherapy-proposition`.

- [ ] **Step 1.7: Determinism check — dict rows untouched.**
  The proposition dict is not modified by this change; confirm:
  ```bash
  bq query --project_id=clingen-dev --use_legacy_sql=false --format=csv '
    SELECT COUNT(*) n, COUNT(DISTINCT key) k FROM `clinvar_2026_07_20_v2_5_0.gks_dict_proposition`'
  ```
  Expected: matches the pre-change count (record it before Step 1.5).

- [ ] **Step 1.8: Commit.**
  ```bash
  git add src/procedures/gks-scv-statement-proc.sql
  git commit -m "feat(proposition): group-qualify SCV proposition references (varcond/vartumor/vartherapy/varcustom)"
  ```

---

## Chunk 2: RCV reference rewrite (resolve gks_type)

**Files:**
- Modify: `src/procedures/gks-rcv-statement-proc.sql:112,172,237`

- [ ] **Step 2.1: Add `cpt` resolution at each of the 3 reference sites.**
  Each site selects from `gks_*_agg agg` with only `agg.prop_type` (a code) in scope. Add
  `LEFT JOIN \`clinvar_ingest.clinvar_proposition_types\` cpt ON cpt.code = agg.prop_type` to each of the 3
  SELECTs (mirror the join already present in the dict builds at `:375/409/443`), exposing `cpt.gks_type`.

- [ ] **Step 2.2: Rewrite the 3 reference lines** (`:112/172/237`) to the canonical CASE over
  `cpt.gks_type` (note: at RCV the raw type is `cpt.gks_type`, which is `Clinvar*` for custom, so
  `LIKE 'Clinvar%' → varcustom` applies directly):
  ```sql
  FORMAT('#/%s-proposition/%s',
    CASE
      WHEN cpt.gks_type LIKE 'Clinvar%' THEN 'varcustom'
      WHEN cpt.gks_type = 'VariantOncogenicityProposition' THEN 'vartumor'
      WHEN cpt.gks_type = 'VariantTherapeuticResponseProposition' THEN 'vartherapy'
      WHEN cpt.gks_type IN ('VariantPathogenicityProposition','VariantClinicalSignificanceProposition',
                            'VariantDiagnosticProposition','VariantPrognosticProposition') THEN 'varcond'
      ELSE ERROR(FORMAT('unmapped proposition type for delivery grouping: %t', cpt.gks_type))
    END,
    agg.prop_id) AS proposition,
  ```

- [ ] **Step 2.3: Deploy + run.**
  ```bash
  bq query --project_id=clingen-dev --use_legacy_sql=false --format=none < src/procedures/gks-rcv-statement-proc.sql
  bq query --project_id=clingen-dev --use_legacy_sql=false --format=none "CALL \`clinvar_ingest.gks_rcv_statement_proc\`('2026-07-20', FALSE)"
  ```
  Expected: both succeed.

- [ ] **Step 2.4: Assert no old prefix remains in `gks_dict_rcv`.**
  ```bash
  bq query --project_id=clingen-dev --use_legacy_sql=false --format=csv '
    SELECT COUNTIF(proposition LIKE "#/proposition/%") old,
           COUNT(*) total FROM `clinvar_2026_07_20_v2_5_0.gks_dict_rcv`'
  ```
  Expected: `old = 0`. (`proposition` is a bare column on `gks_dict_rcv`, not a KV `value`. RCV groups
  seen: varcond, vartumor, varcustom — no vartherapy at RCV.)

- [ ] **Step 2.5: Commit.**
  ```bash
  git add src/procedures/gks-rcv-statement-proc.sql
  git commit -m "feat(proposition): group-qualify RCV proposition references (resolve gks_type via cpt join)"
  ```

---

## Chunk 3: VCV reference rewrite (resolve gks_type)

**Files:**
- Modify: `src/procedures/gks-vcv-statement-proc.sql:79,139,204`

- [ ] **Step 3.1: Add `cpt` join at the 3 reference sites** (mirror dict builds at `:345/381/417`),
  exposing `cpt.gks_type`.
- [ ] **Step 3.2: Rewrite the 3 reference lines** (`:79/139/204`) to the identical canonical CASE over
  `cpt.gks_type` from Step 2.2.
- [ ] **Step 3.3: Deploy + run.**
  ```bash
  bq query --project_id=clingen-dev --use_legacy_sql=false --format=none < src/procedures/gks-vcv-statement-proc.sql
  bq query --project_id=clingen-dev --use_legacy_sql=false --format=none "CALL \`clinvar_ingest.gks_vcv_statement_proc\`('2026-07-20', FALSE)"
  ```
- [ ] **Step 3.4: Assert no old prefix in `gks_dict_vcv`** (same query as 2.4 over `gks_dict_vcv`).
  Expected: `old = 0`.
- [ ] **Step 3.5: Commit.**
  ```bash
  git add src/procedures/gks-vcv-statement-proc.sql
  git commit -m "feat(proposition): group-qualify VCV proposition references (resolve gks_type via cpt join)"
  ```

---

## Chunk 4: Export split into 4 typed groups

**Files:**
- Create: `src/scripts/parquet-schemas/varcond-proposition.sql`, `vartumor-proposition.sql`,
  `vartherapy-proposition.sql`, `varcustom-proposition.sql`
- Delete: `src/scripts/parquet-schemas/proposition.sql`, `rcv_proposition.sql`, `vcv_proposition.sql`
- Modify: `src/scripts/export-gks-dicts.sh` (proposition NDJSON + Parquet blocks)

- [ ] **Step 4.1: Write the 4 typed Parquet schema files.**
  Each `SELECT`s from the 3 dict tables `UNION ALL`, filtered to its group by the canonical CASE, and
  exposes that group's real columns. The group filter (reused in each file) is a WHERE over
  `COALESCE(JSON_VALUE(value,'$.customPropositionType'), JSON_VALUE(value,'$.type'))`. Columns:
  - `varcond-proposition.sql`: `key AS id, JSON_VALUE(value,'$.type') AS type, JSON_VALUE(value,'$.predicate') AS predicate, REGEXP_REPLACE(JSON_VALUE(value,'$.subjectVariant'), r'^#/[^/]+/','') AS subject_variant_id, REGEXP_REPLACE(JSON_VALUE(value,'$.objectCondition'), r'^#/[^/]+/','') AS object_condition_id, JSON_VALUE(value,'$.geneContextQualifier.name') AS gene_context_name, JSON_VALUE(value,'$.penetranceQualifier.name') AS penetrance, JSON_VALUE(value,'$.modeOfInheritanceQualifier.name') AS mode_of_inheritance, TO_JSON_STRING(value) AS data`
  - `vartumor-proposition.sql`: `id, type, predicate, subject_variant_id, object_tumor_type_id (from $.objectTumorType), data`
  - `vartherapy-proposition.sql`: `id, type, predicate, subject_variant_id, object_therapy_id (from $.objectTherapy), condition_qualifier (TO_JSON_STRING(JSON_QUERY(value,'$.conditionQualifier'))), data`
  - `varcustom-proposition.sql`: `id, JSON_VALUE(value,'$.customPropositionType') AS custom_proposition_type, predicate, REGEXP_REPLACE(JSON_VALUE(value,'$.subject'),…) AS subject_id, REGEXP_REPLACE(JSON_VALUE(value,'$.object'),…) AS object_id, TO_JSON_STRING(JSON_QUERY(value,'$.qualifiers')) AS qualifiers, gene_context_name (COALESCE of $.geneContextQualifier.name and the qualifiers[] entry, per Phase-1 proposition.sql), data`

  Confirm every JSON path against a sampled row per group before finalizing (paths verified live, like Phase 1).
  Keep the `{DATASET}` placeholder — the exporter substitutes it.

- [ ] **Step 4.2: Rewrite the proposition NDJSON export (was `:96/100/102`).**
  Replace the 3 whole-table `extract` calls with 4 group `EXPORT DATA` statements. Add a helper (or inline)
  that runs `EXPORT DATA OPTIONS(uri='${GCS_PATH}/<group>-proposition-*.ndjson.gz', format='JSON', compression='GZIP', overwrite=true) AS SELECT key, value FROM (<union of the 3 dict tables> WHERE <canonical group CASE> = '<group>')`. (`GCS_PATH` is the NDJSON base at `export-gks-dicts.sh:22`; Parquet uses `GCS_PARQUET_PATH` at `:24`.) Output basenames: `varcond-proposition`, `vartumor-proposition`, `vartherapy-proposition`, `varcustom-proposition`. (Evidence-line NDJSON exports at `:97/101/103` are unchanged.)

- [ ] **Step 4.3: Rewrite the proposition Parquet export (was `:129/133/135`).**
  Replace the 3 `extract_parquet_typed proposition.parquet proposition.sql` (+ vcv/rcv) calls with 4:
  `extract_parquet_typed varcond-proposition.parquet varcond-proposition.sql` … for each group.

- [ ] **Step 4.4: Run the export for the test release (dict tables already built by Chunks 1–3).**
  The script's arg contract is `<dataset> <gcs_bucket> [prefix] [--parquet-only]` (`export-gks-dicts.sh:12-14`)
  — the first arg is the **full dataset name**, not the date:
  ```bash
  ./src/scripts/export-gks-dicts.sh clinvar_2026_07_20_v2_5_0 <gcs_bucket> [prefix]
  ```
  Expected: 4 `*-proposition-*.ndjson.gz` shard sets and 4 `*-proposition-*.parquet` sets appear in GCS; no
  `proposition-*`/`vcv_proposition-*`/`rcv_proposition-*` proposition shards remain.

- [ ] **Step 4.5: Row-count equivalence.**
  Sum of the 4 groups' row counts == total propositions across the 3 dict tables (no loss, no dup):
  ```bash
  bq query --project_id=clingen-dev --use_legacy_sql=false --format=csv '
    SELECT (SELECT COUNT(*) FROM `clinvar_2026_07_20_v2_5_0.gks_dict_proposition`)
         + (SELECT COUNT(*) FROM `clinvar_2026_07_20_v2_5_0.gks_dict_rcv_proposition`)
         + (SELECT COUNT(*) FROM `clinvar_2026_07_20_v2_5_0.gks_dict_vcv_proposition`) AS total'
  ```
  Compare to the shard/parquet row totals.

- [ ] **Step 4.6: Commit.**
  ```bash
  git add src/scripts/parquet-schemas/ src/scripts/export-gks-dicts.sh
  git commit -m "feat(export): split proposition export into 4 typed group files (varcond/vartumor/vartherapy/varcustom)"
  ```

---

## Chunk 5: Assemble — 4 bundle sections

**Files:**
- Modify: `src/scripts/assemble-gks-dicts.py:70`

- [ ] **Step 5.1: Replace the single `proposition` SECTIONS entry with 4.**
  ```python
  ("varcond-proposition",   "varcond-proposition-*.ndjson.gz",   "key", "value"),
  ("vartumor-proposition",  "vartumor-proposition-*.ndjson.gz",  "key", "value"),
  ("vartherapy-proposition","vartherapy-proposition-*.ndjson.gz","key", "value"),
  ("varcustom-proposition", "varcustom-proposition-*.ndjson.gz", "key", "value"),
  ```
  (Single glob each — Chunk 4 already unions the levels into one basename per group.)

- [ ] **Step 5.2: Assemble the bundle for the test release** (per the script's arg contract) and verify the
  4 keys exist and `proposition` does not:
  ```bash
  python3 -c "import json,gzip,sys; b=json.load(gzip.open(sys.argv[1])); \
    print('proposition' in b, sorted(k for k in b if k.endswith('-proposition')))" /tmp/clinvar-gks-2026-07-20.json.gz
  ```
  Expected: `False ['varcond-proposition','varcustom-proposition','vartherapy-proposition','vartumor-proposition']`.

- [ ] **Step 5.3: Bundle-equivalence — union of the 4 sections' id-sets == old proposition id-set.**
  Compare the union of the 4 new sections' keys against a snapshot of the old single-section keys (dump
  keys of the 3 dict tables). Expected: exact set equality; each id in exactly one section.

- [ ] **Step 5.4: Commit.**
  ```bash
  git add src/scripts/assemble-gks-dicts.py
  git commit -m "feat(assemble): replace single proposition section with 4 group sections"
  ```

---

## Chunk 6: Reference-integrity validation gate

**Files:**
- Modify: `src/scripts/validate-proposition-conformance.sh`

- [ ] **Step 6.1: Update the 3-table UNION** (`:19-21`) to keep working (dict tables unchanged, so this
  still holds — just confirm it runs).

- [ ] **Step 6.2: Add the reference-integrity check.** For every statement (`gks_dict_scv/rcv/vcv`) and
  evidence line (`gks_dict_evidence_line`), extract the pointer group prefix and the referenced id **from
  the bare `proposition` STRING column** (these are native-column tables — do NOT use `JSON_VALUE(value,…)`
  on the pointer side; only the *target* side, the `gks_dict_*proposition` KV tables, uses
  `JSON_VALUE(value,'$.customPropositionType'/'$.type')`), join to the proposition dict, recompute the
  canonical group from the target row's raw type, and assert equality.
  Assertions (all must be 0):
  - `leftover_old_ref_BAD`: any `$.proposition` still `LIKE '#/proposition/%'`.
  - `dangling_ref_BAD`: pointer id not found in any proposition dict.
  - `misrouted_ref_BAD`: pointer group prefix ≠ canonical group recomputed from the target row's
    `COALESCE($.customPropositionType,$.type)`.
  - `unknown_group_BAD`: any proposition whose raw type maps to none of the 4 groups.
  Use the same CASE as the procs (copy it into the SQL).

- [ ] **Step 6.3: Run the full gate on the test release.**
  ```bash
  ./src/scripts/validate-proposition-conformance.sh 2026-07-20 v2_5_0
  ```
  Expected: every `*_BAD = 0`.

- [ ] **Step 6.4: Commit.**
  ```bash
  git add src/scripts/validate-proposition-conformance.sh
  git commit -m "feat(validate): add proposition reference-integrity gate (group prefix == recomputed group)"
  ```

---

## Chunk 7: Docs

**Files:**
- Modify: proposition-related pages under `docs/` + the downloads page (locate with
  `grep -rn "proposition" docs/`).

- [ ] **Step 7.1: Update the bundle/section documentation** to describe the 4 top-level proposition keys
  (replacing `proposition`), the (subject,object) signature per group, and the group→section mapping.
- [ ] **Step 7.2: Add a breaking-change note** on the downloads/changelog page: `proposition` section is
  removed; consumers move to the 4 `*-proposition` keys; RCV/VCV Parquet columns are per-group now.
- [ ] **Step 7.3: Validate docs.**
  ```bash
  mkdocs build --strict
  ```
  Expected: clean build.
- [ ] **Step 7.4: Commit.**
  ```bash
  git add docs/
  git commit -m "docs: document 4 proposition delivery-group sections (breaking bundle change)"
  ```

---

## Final acceptance (after all chunks)

- All statement + evidence-line proposition references are group-qualified; **zero** `#/proposition/`
  remain (Chunk 6 gate = all-zero).
- Bundle has exactly 4 `*-proposition` sections, no `proposition`; union of ids == old set; each id in one
  section (Chunk 5).
- Each group's Parquet exposes typed columns for a sampled row of each `$.type` (Chunk 4).
- `mkdocs build --strict` clean.

## Notes / caveats (carry to PR)

- **Breaking bundle-contract change** — `proposition` section removed; 4 new top-level keys. RCV/VCV
  Parquet `object_condition_id` remains scalar (Phase-1 change).
- **Incremental-rebase caveat** — if this ever rebases onto the Plan 3/4 incremental line: (a) the delta
  section map / oracle section list must also carry the 4 keys, and (b) the proc-side reference rewrite
  produces a one-time full-statement delta churn on cutover. (Same class as the Phase-1 VCV synthetic
  producer.)
- **`gks_json_proc`** (vestigial, retired by Plan 4 which is not on this branch) does not emit or consume
  proposition sections — out of scope, confirmed by grep.
