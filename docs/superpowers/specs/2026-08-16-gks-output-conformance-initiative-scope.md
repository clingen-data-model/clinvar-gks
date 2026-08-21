# GKS Output Conformance Initiative — Scope

**Date:** 2026-08-16
**Status:** Scoping (no implementation yet)
**Trigger:** The JSON-Schema validator delivered in PR #81
(`src/scripts/validate-schema-conformance.py`) shows that emitted GKS records are systematically
non-conformant with the va-spec `1.1.0-ballot.2026-07.2` schemas in ways beyond the Phase-1/2
proposition work. This document inventories the gaps, categorizes them by blast radius and ownership,
and proposes a phased approach with the validator as the acceptance gate.

## How the gaps were found

`validate-schema-conformance.py` loads every schema under `schema/` (clinvar-gks + va-spec / vrs /
cat-vrs / gks-core via the symlinks), resolves `$ref`s by `$id`, routes each record to its schema by
type, and validates. Because the metaschema emits `allOf`-incompatible `additionalProperties: false`, the
validator strips the closed-world assertion and checks **open-world** (`required`, `type`, `enum`,
`format`, and `$ref`-resolved nested shapes). So the gaps below are all **missing-required / wrong-enum /
wrong-value** — not merely "extra property" noise.

Sampled on `clinvar_2026_07_20_v2_5_0`.

## Gap inventory

| # | Gap | Root cause | Blast radius | Owner | Category |
|---|---|---|---|---|---|
| 1 | **MappableConcept missing `type`** — every MappableConcept emits `conceptType` but not the required `type` | the MappableConcept builders don't set `type` | pipeline-wide: genes (30/30), all proposition qualifiers (gene/moi/penetrance), conditions, drug therapies, classifications, submitters | mostly **upstream** `clinvar_ingest` (gene/trait/concept builders) + some gks procs | **Systemic** |
| 2 | **Extensions use typed field names** (`value_string`, `value_submitted_condition`, …) instead of the required va-spec `value` | extensions are built as typed BQ structs and never collapsed to a single `value` | every extension everywhere | **upstream** `clinvar_ingest` + gks procs | **Systemic** |
| 3 | **`VariantClinicalSignificance` predicate** — emits `isClinicallySignificantFor`; schema const is `hasClinicalSignificanceFor` | SCV: upstream `clinvar_ingest.clinvar_clinsig_types.final_predicate`; RCV/VCV: hardcoded (gks-rcv `:387/421/455`, gks-vcv `:352/388/424`) | all ClinicalSignificance propositions | **cross-repo**: upstream table + 6 in-repo hardcodes | **Bounded, cross-repo** |
| 4 | **`VariantTherapeuticResponse` "reduced sensitivity" predicate** — emits `predictsReducedSensitivtyTo` (misspelled, and not in the va-spec enum `predictsSensitivityTo`/`predictsResistanceTo`) | `gks-scv-statement-proc.sql` Step 1 CASE — a placeholder for a ClinVar value va-spec has no predicate for (`-- AHW is looking into whether this should be allowed`) | somatic therapeutic "reduced sensitivity" SCVs (rare) | **domain decision** (AHW) + gks proc | **Domain** |

Notes:
- Gaps 1–2 are the dominant cause of validator failures (they appear on nearly every record that carries a
  MappableConcept or an extension).
- The `sensitivity/response`→`predictsSensitivityTo` and `resistance`→`predictsResistanceTo` mappings are
  already correct; only "reduced sensitivity" and the "should never occur" ELSE branches are non-conformant.

## Ownership: upstream vs in-repo

The MappableConcept and extension shapes (gaps 1, 2) and the ClinSig predicate value (gap 3, SCV path) are
produced **upstream** in the `clinvar_ingest` dataset (the `clinvar-ingest-bq-tools` repo), then carried
through the gks procs. This means:

- A single-source fix for gaps 1–2 belongs **upstream** (fix the concept/extension builders once), which is
  cleaner than patching every gks proc — but requires cross-repo coordination.
- Gap 3 cannot be fixed consistently in this repo alone: changing only the RCV/VCV hardcodes would make SCV
  (upstream-sourced) and RCV/VCV emit **different** predicates for the same proposition type. The upstream
  `clinvar_clinsig_types.final_predicate` and the 6 in-repo hardcodes must move together.
- Gap 4 needs a **domain** decision on how ClinVar "reduced sensitivity" maps to va-spec (there is no
  matching predicate today) — likely a va-spec extension request or a documented, intentional deviation.

## Proposed approach

**Gate:** drive each category to zero failing signatures under `validate-schema-conformance.py`.

**Phase A — baseline & validator coverage.** Extend the validator to route **all** dict sections
(statements, genes, conditions, conditionSets, submitters, evidence lines), not just propositions, and
record a full baseline of failing signatures per section. Deliverable: a documented conformance baseline +
the validator wired as a release check.

**Phase B — bounded predicate alignment (gap 3).** ✅ **DONE** (per domain direction: the
`VariantClinicalSignificance` predicate is always `hasClinicalSignificanceFor`). The 6 RCV/VCV hardcodes
were changed, and the SCV path — which sources the predicate from the upstream
`clinvar_ingest.clinvar_clinsig_types.final_predicate` — now **overrides** it in-proc for that type, so all
three levels emit `hasClinicalSignificanceFor` without waiting on the upstream repo. (Upstream
`final_predicate` should still be aligned eventually, at which point the override becomes a no-op.)
`VariantPathogenicity` was already correct (`isCausalFor`).

**Phase C — MappableConcept `type` (gap 1).** ✅ **DONE** (per domain direction: `type` is always
`"MappableConcept"`; Condition/Therapy inherit it via `allOf`, `conceptType` stays the specific type).
Hardcoded on every MappableConcept construction (~40 sites: classification, confidence, strength,
evidenceOutcome, gene context, modeOfInheritance, penetrance, drug Therapy, condition, gene dict) across
`gks-catvar`, `gks-scv-condition`, and the 3 statement procs. Additive → `gks_json_proc` unaffected.
Verified: gks_dict_gene 92952/92952, gks_dict_condition 22366/22366, statement classifications 6.4M,
proposition qualifiers all carry `type`; 0 required-property errors remain.

**Phase D — extension `value` (gap 2). ARCHITECTURE DECISION NEEDED.** The `value_xxx → value` collapse
**already exists** in the upstream UDF `clinvar_ingest.normalizeAndKeyById`, which `gks_json_proc` applies to
the `gks_dict_*` tables to produce its normalized JSON output. The **bundle** path
(`export-gks-dicts.sh` → `assemble-gks-dicts.py`) exports the `gks_dict_*` tables **raw**, without that
normalization — which is exactly why the bundle carries `value_string`/`value_xxx`. The typed `value_xxx`
fields must stay in `gks_dict_*` (per the caution: `gks_json_proc`/`normalizeAndKeyById` nullify-by-type
then drop the `_xxx`). So the fix is to make the **bundle path** apply the same collapse. Options:
- **D1** — apply `normalizeAndKeyById` (or an equivalent value-collapse) in the bundle **export**
  (`EXPORT DATA` SELECTs already exist for Parquet; NDJSON would move off raw `bq extract`).
- **D2** — a dedicated value-collapse transform at export/assemble that renames the single populated
  `value_xxx` → `value` per extension (no reliance on the upstream UDF).
- **D3** — source the bundle from the already-normalized `gks_json`/`gks_catvar` output instead of raw
  `gks_dict_*` (couples to the `gks_json_proc` retirement / Plan 4 direction).

Decision depends on `normalizeAndKeyById`'s internals (upstream) and the `gks_json_proc`/Plan-4 direction.

✅ **DONE via D2** (fresh collapse at export). A recursive JS UDF (`collapse_ext_values`) renames the one
populated `value_*` key → `value` in every extension object (any object with a `name` sibling), at any
depth. Applied in `export-gks-dicts.sh` to the 4 proposition group exports (collapse the `value`) and to
`gks_dict_scv` / `gks_dict_evidence_line` (strip-nulls then collapse the `extensions` column). The
`gks_dict_*` tables keep `value_*` intact, so `gks_json_proc`/`normalizeAndKeyById` are unaffected.
Verified: proposition validator 320→7 failures (residual 7 out of scope — see below); scv extensions →
`{name, value}` with no null-field pollution. **Residual / follow-ups (out of gaps 1–2):**
(a) compound `objectTherapy` `TherapyGroup` shape (~4 somatic records — a ConceptSet detail from the
Phase-1 objectTherapy fix); (b) `predictsReducedSensitivtyTo` (3 records — AHW/va-spec); (c) statement
`contributions[].contributor` and other bundle `#/…` references validate as strings where the schema wants
inline objects (the bundle reference-vs-inline tension — needs schema `iriReference` or ref-resolution
before validating); (d) Parquet `data` blob column not yet collapsed (typed columns are the primary
interface; low priority).

**Gap 4** is tracked separately pending the AHW domain decision.

## Open questions to resolve during planning

1. **Upstream vs in-repo** for gaps 1–2. Upstream is the single source but cross-repo; in-repo is
   self-contained but touches many procs and duplicates the fix.
2. **MappableConcept `type` value** — is it the literal `"MappableConcept"`, or the specific subtype
   (`Therapy`, `Condition`, gene concept)? Confirm per usage against va-spec.
3. **Extension `value` typing** — the pipeline uses typed columns because BQ structs need typed fields; the
   emit step must serialize whichever typed field is present into a single `value` (JSON) while keeping the
   `name`. Confirm no consumer depends on the current `value_string` etc. names.
4. **Validator scope** — should it become a hard release gate (fail the release on new non-conformance), or
   an advisory baseline until the systemic gaps are closed?

## Non-goals

- No data fixes in this scoping doc — implementation is Phases B–D, each its own plan.
- No change to the validator's open-world strategy (the closed-world `additionalProperties` fix belongs
  upstream in gks-metaschema — tracked separately).
