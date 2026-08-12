# ClinVar CustomProposition Conformance (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the BigQuery statement procs emit proposition data that conforms to the va-spec `1.1.0-ballot.2026-07.2` schema — reshaping the 10 ClinVar **custom** proposition types to the `CustomProposition` model and fixing two standard-type object-field non-conformances — plus the schema completion (`ClinvarUndefinedProposition`) and an interim Parquet/validation update.

**Architecture:** Branch each proposition-struct assembly on `gks_type LIKE 'Clinvar%'`. Custom types emit `{type:"CustomProposition", customPropositionType, subject, object, predicate, qualifiers[]}`; standard types keep `{type:<specific>, subjectVariant, objectCondition, …typed qualifiers}`. Build one wide `STRUCT` per proposition with `IF(is_custom,…,NULL)` on the divergent fields, then `JSON_STRIP_NULLS(TO_JSON(…), remove_empty => TRUE)` yields the correct per-type JSON. Custom SCV qualifiers move from typed fields into a generic `qualifiers` name/value array (`value` carried as JSON to tolerate the 3 qualifiers' differing MappableConcept struct schemas).

**Tech Stack:** BigQuery stored procedures (`bq`, project `clingen-dev`); the GA4GH gks-metaschema toolchain (`cd schema/clinvar-gks && make`) for schema regen; Python 3.12 for validation; `jq` for canonical diffs.

**Spec:** `docs/superpowers/specs/2026-08-12-custompropositions-conformance-and-delivery-grouping-design.md` (Phase 1). **Phase 2 (delivery grouping) is a separate later plan — NOT in scope here.**

**Branch:** create `feat/custompropositions-conformance-phase1` off `chore/update-va-spec-1.1.0-ballot-2026-07-2` (which has the new schema). Deploy a proc: `bq query --project_id=clingen-dev --use_legacy_sql=false < src/procedures/<file>.sql`. Test datasets: `clinvar_2026_07_20_v2_5_0` / `clinvar_2026_07_15_v2_5_0`.

**Conventions:** commits must NOT contain "Generated with Claude Code"/"Co-Authored-By". Schema regen: commit only semantic changes — the metaschema tool emits `$defs` in non-deterministic order (ga4gh/gks-metaschema#63), so canonical-diff (`diff <(jq -S . old) <(jq -S . new)`) to drop reorder churn.

---

## Chunk 1: Schema — add `ClinvarUndefinedProposition` + verify qualifiers + regenerate

### Task 1.1: Add the 10th custom type + union entry

**Files:** Modify `schema/clinvar-gks/clinvar-proposition-source.yaml`.

- [ ] **Step 1: Add the `$def`** after `ClinvarConflictingDataFromSubmitterProposition` (mirror `ClinvarRiskFactorProposition` exactly):

```yaml
  ClinvarUndefinedProposition:
    type: object
    maturity: draft
    description: >-
      A fallback custom proposition for a ClinVar submission whose classification does not
      map to any defined ClinVar-GKS or GA4GH proposition type. Emitted only when the upstream
      classification-to-type mapping yields no gks_type.
    allOf:
      - $ref: "#/$defs/ClinvarGermlineCustomProposition"
    properties:
      customPropositionType:
        type: string
        const: ClinvarUndefinedProposition
        default: ClinvarUndefinedProposition
        description: MUST be "ClinvarUndefinedProposition"
      predicate:
        type: string
        const: isClinvarUndefinedAssociationFor
        default: isClinvarUndefinedAssociationFor
        description: >-
          The relationship the Proposition describes between the subject variant and object
          condition. MUST be "isClinvarUndefinedAssociationFor".
```

- [ ] **Step 2: Add to the `ClinvarProposition` `oneOf` union** (after the `ConflictingDataFromSubmitter` entry):

```yaml
      - $ref: "#/$defs/ClinvarUndefinedProposition"
```

- [ ] **Step 3: Commit** `git add schema/clinvar-gks/clinvar-proposition-source.yaml && git commit -m "feat(schema): add ClinvarUndefinedProposition as 10th custom proposition type"`

### Task 1.2: Verify the `qualifiers` array survives the custom-base composition

**Files:** Read `schema/clinvar-gks/clinvar-proposition-source.yaml` (`ClinvarGermlineCustomPropositionProperties`), possibly modify it.

- [ ] **Step 1: Regenerate the schema** to see whether the generated custom-type JSON permits `qualifiers`:

```bash
cd schema/clinvar-gks && make all
```
Expected: `json/Clinvar*Proposition` regenerate (ignore reorder-only diffs).

- [ ] **Step 2: Check for `qualifiers` in a generated custom type**

```bash
grep -c '"qualifiers"' schema/clinvar-gks/json/ClinvarRiskFactorProposition
```
`ClinvarGermlineCustomPropositionProperties` has `additionalProperties: false` and only declares `subject`/`object`; `qualifiers` comes from `va-spec:CustomProposition` via an `allOf $refCurie`. **If the count is 0** (composition dropped it), re-declare `qualifiers` on `ClinvarGermlineCustomPropositionProperties` by copying the `qualifiers` property block from `submodules/va-spec/schema/va-spec/base/va-core-source.yaml` (the `CustomProposition.qualifiers` array of `{name, value: MappableConcept|iriReference}`), then re-run `make all` and re-check (expect `>0`).

- [ ] **Step 3: Commit** (only if the source changed) `git add schema/clinvar-gks/clinvar-proposition-source.yaml && git commit -m "fix(schema): ensure custom propositions permit the qualifiers array"`

### Task 1.3: Regenerate artifacts + docs, commit semantic changes only

**Files:** Modify `schema/clinvar-gks/{json,def}/*`, `docs/output-reference/classes/Clinvar*Proposition.md` (+ propositions page).

- [ ] **Step 1: Regenerate `json/`+`def/`** with `cd schema/clinvar-gks && make all`. Then regenerate the **class docs pages** with the standalone generator (NOT wired into the Makefile): `cd schema/clinvar-gks && python3 y2md.py clinvar-proposition-source.yaml` (writes to `schema/clinvar-gks/md/`; confirm the output dir + args by reading `y2md.py`'s `argparse`/`__main__`). Copy/refresh the generated pages into `docs/output-reference/classes/` (the repo's existing convention — check how the current `classes/Clinvar*Proposition.md` were produced/placed). **Expect ALL 10 custom class pages to change**, not just the new one: the current `classes/Clinvar*Proposition.md` are stale vs the new schema (they still show `type` const = the specific type and `subjectVariant`; they must become `customPropositionType`/`subject`). Add the new `ClinvarUndefinedProposition.md` to `mkdocs.yml` nav.
- [ ] **Step 2: Drop reorder churn.** For each modified `json/*`, if `diff <(git show HEAD:<f> | jq -S .) <(jq -S . <f>)` is empty, `git restore` it (reorder-only). Stage only files with real content changes (the new `ClinvarUndefinedProposition`, the union, and any `qualifiers` addition).
- [ ] **Step 3: Validate docs** `mkdocs build --strict` (via the repo's mkdocs). Expected: clean.
- [ ] **Step 4: Commit** `git add schema/clinvar-gks/json schema/clinvar-gks/def docs/ mkdocs.yml && git commit -m "docs(schema): regenerate proposition artifacts + docs for ClinvarUndefinedProposition"`

---

## Chunk 2: SCV proc — custom reshape + qualifiers array

### Task 2.1: Reshape the SCV subject proposition (`gks-scv-statement-proc.sql`)

**Files:** Modify `src/procedures/gks-scv-statement-proc.sql`. NOTE the SCV structure differs from RCV/VCV: Step 5 (~L339-372) builds a **flat temp table** `temp_gks_scv_proposition` with plain column selects (NO `TO_JSON` wrapper); the JSON wrapper is separate, at **Step 7e** (~L618-620), which already assembles the dict via `JSON_STRIP_NULLS(TO_JSON((SELECT AS STRUCT sp.* EXCEPT(scv_id))), remove_empty => TRUE)` — **already correct, no change needed there.** So Task 2.1 edits the flat column list at ~L343-355; `sgq`/`smq`/`spq` = `temp_gene_context_qualifiers`/`temp_moi_qualifiers`/`temp_penetrance_qualifiers` joined at ~L357-363.

- [ ] **Step 0: Handle the NULL proposition type first.** `is_custom := <type> LIKE 'Clinvar%'` evaluates to NULL (falsy) for an undef row whose `scv.proposition.type` is NULL — which would wrongly emit `type=NULL` (the very case `ClinvarUndefinedProposition` is being added for). First **verify** what `scv.proposition.type` holds for an undef row (`SELECT DISTINCT type FROM temp_gks_scv_proposition source …` or inspect the L47-51 fallback — it sets `'ClinvarUndefinedProposition'`, so type is likely non-null). If it CAN be NULL, coalesce it to `'ClinvarUndefinedProposition'` before the branch. Use that coalesced value as `p_type` in Step 1.

- [ ] **Step 1: Replace the flat column list.** The current columns are `{ id, type:scv.proposition.type, subjectVariant, predicate, objectCondition:COALESCE(4 sources), geneContextQualifier, modeOfInheritanceQualifier, penetranceQualifier }`. Replace with the branched columns (`p_type` = the Step-0 coalesced type; `is_custom := p_type LIKE 'Clinvar%'`; compute the 4-source `objectCondition` COALESCE **once** as a prior column/CTE `obj_ref` and reference it in both branches — do not retype it):

```sql
          FORMAT('%s-%s', scv.id, UPPER(IFNULL(scv.proposition_type_code, 'UNDEF'))) as id,
          IF(scv.proposition.type LIKE 'Clinvar%', 'CustomProposition', scv.proposition.type) as type,
          IF(scv.proposition.type LIKE 'Clinvar%', scv.proposition.type, NULL) as customPropositionType,
          IF(scv.proposition.type LIKE 'Clinvar%', NULL, FORMAT('#/variation/clinvar:%s', scv.variation_id)) as subjectVariant,
          IF(scv.proposition.type LIKE 'Clinvar%', FORMAT('#/variation/clinvar:%s', scv.variation_id), NULL) as subject,
          scv.proposition.pred as predicate,
          IF(is_custom, NULL, obj_ref) as objectCondition,   -- obj_ref = the existing 4-source COALESCE, computed once
          IF(is_custom, obj_ref, NULL) as object,
          -- standard keeps typed qualifiers; custom nulls them
          IF(scv.proposition.type LIKE 'Clinvar%', NULL, (SELECT AS STRUCT sgq.* EXCEPT(scv_id))) as geneContextQualifier,
          IF(scv.proposition.type LIKE 'Clinvar%', NULL, (SELECT AS STRUCT smq.* EXCEPT(scv_id))) as modeOfInheritanceQualifier,
          IF(scv.proposition.type LIKE 'Clinvar%', NULL, (SELECT AS STRUCT spq.* EXCEPT(scv_id))) as penetranceQualifier,
          -- custom: qualifiers[] name/value (value carried as JSON to tolerate differing struct schemas)
          IF(scv.proposition.type LIKE 'Clinvar%',
            ARRAY_CONCAT(
              IF(sgq.scv_id IS NOT NULL, [STRUCT('geneContext' AS name, TO_JSON((SELECT AS STRUCT sgq.* EXCEPT(scv_id))) AS value)], []),
              IF(smq.scv_id IS NOT NULL, [STRUCT('modeOfInheritance' AS name, TO_JSON((SELECT AS STRUCT smq.* EXCEPT(scv_id))) AS value)], []),
              IF(spq.scv_id IS NOT NULL, [STRUCT('penetrance' AS name, TO_JSON((SELECT AS STRUCT spq.* EXCEPT(scv_id))) AS value)], [])
            ),
            NULL) as qualifiers
```
The Step-5 temp table `temp_gks_scv_proposition` gains new columns `customPropositionType STRING`, `subject STRING`, `object STRING`, and `qualifiers ARRAY<STRUCT<name STRING, value JSON>>`. **Type the NULL branches explicitly** (e.g. `CAST(NULL AS STRING)`, `CAST(NULL AS ARRAY<STRUCT<name STRING, value JSON>>)`) so the physical temp-table schema unifies. The JSON wrapper at **Step 7e (~L618)** already does `JSON_STRIP_NULLS(TO_JSON(…), remove_empty => TRUE)` — no change there; `remove_empty => TRUE` drops the empty custom `qualifiers[]` and the null standard fields. `SELECT AS STRUCT sp.* EXCEPT(scv_id)` at Step 7e picks up the new columns automatically.

- [ ] **Step 2: Deploy** `bq query --project_id=clingen-dev --use_legacy_sql=false < src/procedures/gks-scv-statement-proc.sql` (expect `Created`/`Replaced`, no error).
- [ ] **Step 3: Verify emitted shapes** (custom + standard):

```bash
bq query --project_id=clingen-dev --use_legacy_sql=false --nouse_cache \
 "CALL \`clinvar_ingest.gks_scv_statement_proc\`(DATE '2026-07-20', FALSE);
  SELECT JSON_VALUE(value,'\$.type') t, JSON_VALUE(value,'\$.customPropositionType') cpt,
         JSON_QUERY(value,'\$.subject') subj, JSON_QUERY(value,'\$.subjectVariant') sv,
         JSON_QUERY(value,'\$.object') obj, JSON_QUERY(value,'\$.qualifiers') quals
  FROM \`clinvar_2026_07_20_v2_5_0.gks_dict_proposition\`
  WHERE JSON_VALUE(value,'\$.customPropositionType')='ClinvarRiskFactorProposition' LIMIT 2"
```
Expected (custom): `type=CustomProposition`, `customPropositionType=ClinvarRiskFactorProposition`, `subject` set, `subjectVariant` null, `object` set, `qualifiers` present iff the SCV had gene/moi/penetrance. Run the same for a standard `type=VariantPathogenicityProposition` → `subjectVariant`/`objectCondition` set, `customPropositionType`/`subject`/`object`/`qualifiers` absent.

- [ ] **Step 4: Commit** `git add src/procedures/gks-scv-statement-proc.sql && git commit -m "feat(gks): SCV custom propositions emit CustomProposition shape + qualifiers[] (standard unchanged)"`

---

## Chunk 3: RCV proc — custom reshape

### Task 3.1: Reshape the RCV proposition struct (all 3 layers)

**Files:** Modify `src/procedures/gks-rcv-statement-proc.sql` (proposition structs ~L344-419: base layer + two siblings). RCV proposition = `{type:cpt.gks_type, id, subjectVariant, predicate:<CASE>, objectCondition:rcd.condition_concept}` — no qualifiers.

- [ ] **Step 1: Apply the same branch to each of the 3 layers.** For each, replace `cpt.gks_type AS type` / `subjectVariant` / `objectCondition` with the branched fields (`is_custom := cpt.gks_type LIKE 'Clinvar%'`): `type=IF(is_custom,'CustomProposition',cpt.gks_type)`, `customPropositionType=IF(is_custom,cpt.gks_type,NULL)`, `subjectVariant=IF(NOT is_custom, '#/variation/clinvar:'||…, NULL)`, `subject=IF(is_custom, …, NULL)`, `objectCondition=IF(NOT is_custom, rcd.condition_concept, NULL)`, `object=IF(is_custom, rcd.condition_concept, NULL)`; keep the `predicate` CASE and `id` unchanged. No `qualifiers` (RCV has none). Ensure the wrapper is `JSON_STRIP_NULLS(TO_JSON(STRUCT(…)), remove_empty => TRUE)`.
- [ ] **Step 2: Deploy** the proc.
- [ ] **Step 3: Verify** one custom + one standard RCV proposition shape (mirror Task 2.1 Step 3 against `gks_dict_rcv_proposition`).
- [ ] **Step 4: Commit** `git commit -am "feat(gks): RCV custom propositions emit CustomProposition shape (all 3 layers)"`

---

## Chunk 4: VCV proc — custom reshape + array→ConditionSet fix (investigate first)

### Task 4.1: Investigate the VCV `objectCondition` array + ConditionSet source

**Files:** Read `src/procedures/gks-vcv-proc.sql` (~L125-150, 235, 322 — `unique_conditions = ARRAY_AGG(DISTINCT condition_ref)`), `gks-vcv-statement-proc.sql` (~L331/357/383), `gks-scv-condition-proc.sql` (how `gks_dict_condition_set` ids are formed), `parquet-schemas/{vcv,rcv}_proposition.sql`.

- [ ] **Step 1: Determine the target shape for VCV `object`.** `unique_conditions` is an ARRAY of `#/condition/…`/`#/conditionSet/…` IRI strings; the schema `object`/`objectCondition` is a SINGLE `Condition|ConditionSet|iriReference`. Document the options and pick one:
  - **(a)** When the array has exactly 1 element → emit that bare pointer; when >1 → the VCV needs a single `ConditionSet` pointer. Determine whether an existing `gks_dict_condition_set` entry already groups exactly the VCV's condition set (is there a VCV-level conditionSet id upstream?), OR whether a **synthetic** ConditionSet dict entry must be created (id + `concepts[]` members) — this is the crux; if synthetic entries are required, that is a `gks_dict_condition_set` producer change, not just a statement-proc change.
  - **(b)** If synthetic ConditionSets are out of scope for Phase 1, the fallback is: emit the single element when len=1 and **defer** the multi-condition VCV case with a logged note (still non-conformant for multi-condition VCV, but bounded).
- [ ] **Step 2: Record the decision** as a comment block at the VCV proposition struct and in the plan's execution notes. **STOP and surface to the controller if option (a) requires synthetic ConditionSet creation** (a larger change than a statement-proc edit) — the controller decides scope before proceeding.

### Task 4.2: Reshape the VCV proposition struct (custom branch) + apply the object decision

**Files:** Modify `src/procedures/gks-vcv-statement-proc.sql` (~L310-383, 3 layers).

- [ ] **Step 1: Apply the custom/standard branch** to each of the 3 layers (same as RCV: type/customPropositionType/subjectVariant/subject/objectCondition/object), using the Task-4.1 single-value `object`/`objectCondition` expression in place of the bare `agg.unique_conditions` array.
- [ ] **Step 2: Reconcile the extractor** — update `src/scripts/parquet-schemas/vcv_proposition.sql` (and `rcv_proposition.sql`) from `JSON_VALUE_ARRAY` to single-value `JSON_VALUE` for the object/condition column, matching the new single-value shape.
- [ ] **Step 3: Deploy + verify** custom + standard VCV proposition shapes; confirm `object`/`objectCondition` is a single value.
- [ ] **Step 4: Commit** `git commit -am "feat(gks): VCV custom propositions emit CustomProposition shape + single-value object (was array)"`

---

## Chunk 5: VariantOncogenicity object field (investigate; may defer)

### Task 5.1: Investigate `objectTumorType` data availability

**Files:** Read the subject-proposition builders + upstream condition source; check `submodules/va-spec/schema/va-spec/base/json/VariantOncogenicityProposition` for the exact `objectTumorType` shape.

- [ ] **Step 1: Determine whether ClinVar provides tumor-type data** distinct from the condition. The procs emit `objectCondition` for Oncogenicity today; va-spec wants `objectTumorType`. Check whether any upstream field carries a tumor type, or whether Oncogenicity's "condition" IS the tumor type (rename only) vs a genuine data gap.
- [ ] **Step 2: Decide + record.** If it is a clean rename (the condition value is the tumor type) → emit `objectTumorType` for `gks_type='VariantOncogenicityProposition'` in all 3 subject builders (a small `IF` on the object field name). If it is a data gap (no tumor-type data) → **defer** with a documented note in the spec's §6 and a tracking item; do NOT fabricate. **Surface the decision to the controller.**
- [ ] **Step 3 (if rename): implement + deploy + verify + commit** `git commit -am "fix(gks): VariantOncogenicity emits objectTumorType (was objectCondition)"`. (If deferred: no commit; note it.)

---

## Chunk 6: Parquet interim columns + conformance validation + oracle

### Task 6.1: Interim Parquet columns for both shapes

**Files:** Modify `src/scripts/parquet-schemas/{proposition,rcv_proposition,vcv_proposition}.sql`. **Sequencing:** `rcv_proposition.sql`/`vcv_proposition.sql` are ALSO edited in Chunk 4 (Task 4.2 Step 2, array→single `JSON_VALUE`); do Chunk 4 first, then layer this task's custom-column edits on top (don't revert the single-value conversion). (Note: `rcv_proposition.sql` is already mismatched today — `JSON_VALUE_ARRAY` over a scalar `rcd.condition_concept` — so Chunk 4's conversion is a genuine bugfix.)

- [ ] **Step 1: Add custom-shape columns** alongside the standard ones so both parse: add `customPropositionType` (`JSON_VALUE($.customPropositionType)`), and make the subject/object columns `COALESCE(JSON_VALUE($.subjectVariant), JSON_VALUE($.subject))` / `COALESCE($.objectCondition,$.object)` (strip the `#/…/` prefix as today). Keep `type` (now `CustomProposition` for custom) and `data`. (Full per-signature typing is Phase 2.)
- [ ] **Step 2: Smoke-test** one typed-Parquet export for `proposition` against `clinvar_2026_07_20_v2_5_0` (a scratch GCS prefix; `bq query EXPORT DATA` via `export-gks-dicts.sh` is the runner — or run the schema SQL directly with `LIMIT`), confirm custom + standard rows both yield populated `customPropositionType`/subject/object columns. Clean up scratch GCS.
- [ ] **Step 3: Commit** `git commit -am "feat(parquet): proposition extractors read both custom and standard shapes (interim)"`

### Task 6.2: Conformance validation gate

**Files:** Create `src/scripts/validate-proposition-conformance.sh` (or a small Python validator) + optional test.

- [ ] **Step 1: Build a validator** that samples emitted propositions per type (each custom `customPropositionType`, each standard `type`) from `gks_dict_{,vcv_,rcv_}proposition` and validates each `value` JSON against the matching `schema/clinvar-gks/json/*` (use `check-jsonschema`/`jsonschema`; the schema `$ref`s resolve to the generated `json/` + va-spec json). Fail on any `additionalProperties`/required/const violation.
- [ ] **Step 2: Run it** on `clinvar_2026_07_20_v2_5_0` → expect 0 violations for custom + the conformant standard groups (Pathogenicity/ClinicalSignificance; Oncogenicity/VCV per Chunks 4-5 decisions). Document any expected residual (deferred Oncogenicity/VCV-multi).
- [ ] **Step 3: Commit** `git commit -am "test(gks): proposition schema-conformance validator"`

### Task 6.3: Determinism / no-regression oracle

- [ ] **Step 1: Confirm the reshape is deterministic + standard rows unchanged.** Run the SCV/RCV/VCV statement procs twice on `2026-07-20` and confirm identical output (canonical multiset), and that STANDARD proposition rows are byte-identical to the pre-change output except the intended object-field fixes (diff a snapshot). The custom rows are intended to change.
- [ ] **Step 2: Confirm counts unchanged** — the per-type proposition counts (from the earlier `JSON_VALUE($.customPropositionType)`/`$.type` tally) match the pre-change type distribution (no rows dropped/duplicated by the reshape).

---

## Final: holistic review + PR

- [ ] Run the conformance validator + the full docs `mkdocs build --strict`.
- [ ] Confirm scratch GCS/datasets cleaned up.
- [ ] superpowers:requesting-code-review, then superpowers:finishing-a-development-branch → **stacked PR** (base = `chore/update-va-spec-1.1.0-ballot-2026-07-2`).

## Notes / risks
- **Qualifiers `value` as JSON** — chosen because the 3 SCV qualifier temps have differing MappableConcept struct schemas (gene has `mappings`; moi/penetrance have `extensions`), so a uniform `ARRAY<STRUCT<name,value>>` needs `value JSON`. Verify the emitted `qualifiers[].value` renders as the MappableConcept object (not a JSON-string) in the bundle.
- **VCV ConditionSet (Chunk 4)** and **Oncogenicity objectTumorType (Chunk 5)** are investigate-first and may reveal larger/blocked work — surface to the controller rather than fabricating.
- **Delta churn** — every custom proposition's `value` changes; expect a one-time full custom-proposition delta on the next release (no code change).
- **Standard "unchanged"** means shape-preserved, not that Chunks 4-5 are optional — they are true conformance fixes.
