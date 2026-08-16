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

**Phase B — bounded predicate alignment (gap 3).** Coordinate with `clinvar-ingest` to move
`clinvar_clinsig_types.final_predicate` for ClinicalSignificance to `hasClinicalSignificanceFor`, and update
the 6 RCV/VCV hardcodes in the same release so SCV/RCV/VCV stay consistent. Verify with the validator.

**Phase C — MappableConcept `type` (gap 1).** The biggest item. Decide upstream-vs-in-repo, then set the
required `type` on every MappableConcept (determine the correct const per usage — `MappableConcept` vs a
subtype like `Therapy`/`Condition`). Verify pipeline-wide with the validator.

**Phase D — extension `value` (gap 2).** Collapse the typed extension fields to the va-spec `value` at emit
(a single JSON `value`), preserving the information. Likely upstream.

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
