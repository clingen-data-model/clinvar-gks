# Proposition delivery grouping (Phase 2) — Design

**Date:** 2026-08-14
**Branch:** `feat/proposition-delivery-grouping-phase2` (off `main`, which now carries Phase 1 — PRs #78/#79)
**Predecessor:** Phase 1 conformance (merged). This is Phase 2 of the design in
`docs/superpowers/specs/2026-08-12-custompropositions-conformance-and-delivery-grouping-design.md` §4.

## Goal

Replace the single mixed `proposition` bundle section with **four datatype-homogeneous top-level
sections**, so each proposition group can be delivered as a fully-typed Parquet table and a clean bundle
section instead of a grab-bag with everything stuffed into a `data` JSON blob.

This is a **breaking bundle-contract change** (a consumer relying on the `proposition` section must move to
the four new keys). It is intentional and approved.

## Background — current state (verified against code)

- **Three per-level proposition dict tables:** `gks_dict_proposition` (SCV), `gks_dict_rcv_proposition`
  (RCV), `gks_dict_vcv_proposition` (VCV), built by `gks-{scv,rcv,vcv}-statement-proc.sql`.
- **They collapse into ONE bundle section.** `assemble-gks-dicts.py:70` maps all three globs
  (`proposition-*`, `vcv_proposition-*`, `rcv_proposition-*`) into a single `proposition` section
  (`key`→`value`).
- **Discriminator:** the emitted JSON carries `$.type` (e.g. `VariantPathogenicityProposition`,
  `VariantOncogenicityProposition`, `CustomProposition`); custom rows put the specific ClinVar type in
  `$.customPropositionType`. Set identically in all three procs
  (`IF(is_custom, 'CustomProposition', <gks_type>)`; SCV `:381-382`, RCV `:348-349`, VCV `:314-315`).
- **Object-field split (already emitted, Phase 1):** standard `variant×condition` → `objectCondition`;
  Oncogenicity → `objectTumorType`; custom → `object`; somatic therapeutic target props →
  `objectTherapy` (+ `conditionQualifier`). Subject is `subjectVariant` (standard) or `subject` (custom).
- **Target propositions are already first-class dict rows, NOT inline.** SCV Step 6 builds
  `temp_gks_scv_target_proposition` with id `FORMAT('%s-%s', scv.id, UPPER(tp.code))` (`:446`), UNION'd
  into `gks_dict_proposition` (`:648-666`). The evidence line references it by pointer:
  `FORMAT('#/proposition/%s', stp.id)` (`:713`). Diagnostic/Prognostic/TherapeuticResponse are **SCV-only**
  and arrive exclusively as these target props; RCV/VCV proposition dicts emit only
  Pathogenicity/ClinicalSignificance/Oncogenicity + custom.
- **References:** statements point at their proposition via `FORMAT('#/proposition/%s', <id>)` — 7
  statement sites (SCV `:784`; RCV `:112,172,237`; VCV `:79,139,204`) — plus the 1 evidence-line site
  (SCV `:713`). **Eight reference sites total.** RCV/VCV evidence-line dicts carry no proposition pointer.
- **No delta-manifest/oracle script exists on this branch.** The incremental/oracle machinery is
  VRS-only and lives on the Plan 3/4 line, which `main` does not contain. The *only* "section list" in the
  scripts is `assemble-gks-dicts.py:70`.

## The four delivery groups

Keyed by (subject, object) datatype signature:

| Bundle key | Group | `$.type` values | subject → object | Levels |
|---|---|---|---|---|
| `varcond-proposition` | G1 variant×condition (std) | VariantPathogenicity, VariantClinicalSignificance, VariantDiagnostic, VariantPrognostic | `subjectVariant` → `objectCondition` | scv, rcv, vcv (Diag/Prog SCV-only) |
| `vartumor-proposition` | G2 variant×tumorType (std) | VariantOncogenicity | `subjectVariant` → `objectTumorType` | scv, rcv, vcv |
| `vartherapy-proposition` | G3 variant×therapy (std) | VariantTherapeuticResponse | `subjectVariant` → `objectTherapy` (+ `conditionQualifier`) | scv only (target props) |
| `varcustom-proposition` | G4 variant×condition (custom) | CustomProposition (10 `Clinvar*` in `$.customPropositionType`) | `subject` → `object` | scv, rcv, vcv |

(Exact `$.type` string literals — with/without the `Proposition` suffix — are confirmed during planning
against a live release; the grouping keys off these literals.)

## Design decisions (locked)

1. **Four top-level bundle keys replace `proposition`.** No `proposition` section remains. Breaking.
2. **References are group-qualified and computed proc-side** (`#/varcond-proposition/{id}` …), stored in
   the statement and evidence-line dict records. The dict is the single source of truth; bundle, Parquet
   (and any future delta/oracle) all carry the stored pointer. Rewrites all **eight** reference sites.
3. **Target propositions are routed to their signature group** (Diagnostic/Prognostic → `varcond`,
   TherapeuticResponse → `vartherapy`) and their evidence-line reference (`:713`) becomes group-qualified.
   No new id/dedup work — they are already first-class dict rows.
4. **Dict tables stay per-level** (scv/rcv/vcv) to preserve the incremental/delta cascade for a future
   rebase. The four-way split happens at the **delivery layer** (export + assemble), by filtering
   proposition rows on their group.

## Group-derivation rule — one canonical mapping

Both the proc-side reference emit (decision 2) and the delivery-layer split (decision 4) must assign the
**same** group to a given proposition, or a reference will point at a section the row isn't in. To make
that provable, the mapping keys off **one input domain everywhere — the resolved gks type string** (the
`$.type` value the export sees, i.e. `CustomProposition` or the specific `Variant*Proposition`), and it is
**total** with a **fail-fast default**:

```text
group(gks_type) =
  gks_type = 'CustomProposition'                                  -> 'varcustom'
  gks_type = 'VariantOncogenicityProposition'                     -> 'vartumor'
  gks_type = 'VariantTherapeuticResponseProposition'             -> 'vartherapy'
  gks_type IN (VariantPathogenicity, VariantClinicalSignificance,
               VariantDiagnostic, VariantPrognostic)Proposition   -> 'varcond'
  ELSE                                                            -> ERROR  (fail the build)
```

The `ELSE → ERROR` matters: the procs collapse any non-custom type to its verbatim gks string, so a new
standard type added upstream to `clinvar_proposition_types` would otherwise fall through to a NULL group
→ a malformed `#/-proposition/{id}` pointer and a row in no section. Planning makes the default fail the
build (or routes to an explicit quarantine section the gate flags), never silently drop.

**Single input domain — the RCV/VCV catch.** The two SCV reference sites and the export already have the
gks type string in scope (`temp_gks_scv_proposition.type` at `:784`, `temp_gks_scv_target_proposition.type`
at `:713`, `JSON_VALUE(value,'$.type')` at export). The **six RCV/VCV reference sites (`:112/172/237`,
`:79/139/204`) do NOT** — they select from the `gks_*_agg` tables whose only type signal is
`agg.prop_type`, a **code** that is resolved to `gks_type` only later, inside the dict builds (RCV
`cpt` join `:375/409/443`, VCV `:345/381/417`). Keying the group off the *code* there would be a second
mapping over a different key domain that could silently drift from the `$.type` mapping. **Therefore the
plan MUST resolve gks_type at the RCV/VCV reference sites too** — either add the `LEFT JOIN
clinvar_proposition_types cpt` at those six sites, or precompute a resolved `gks_type` (or `prop_group`)
column on the `gks_*_agg` tables — so every layer applies the *same* CASE over the *same* gks-type input.

Implementation of the mapping: an **inline CASE** (recommended for this branch — self-contained, no
upstream dependency), written once and copied verbatim into the proc reference sites and the export
split. Revisit a `delivery_group` column on upstream `clinvar_proposition_types` only if a third consumer
of the mapping appears.

## Change surface (verified anchors)

- **Procs — 8 reference sites → group-qualified.** SCV statement `:784`, RCV `:112/172/237`, VCV
  `:79/139/204`, SCV evidence-line `:713`. Each site emits `FORMAT('#/%s-proposition/%s', <group>, <id>)`,
  with `<group>` from the canonical CASE over the **resolved gks type**: SCV statement uses
  `temp_gks_scv_proposition.type`/`.customPropositionType`, SCV evidence-line uses
  `temp_gks_scv_target_proposition.type`, and the six RCV/VCV sites must first resolve gks_type (add the
  `cpt` join or a precomputed column on the `gks_*_agg` tables — see the Group-derivation rule). **Oracle-
  gated for determinism.** The proposition *dict rows themselves are unchanged* (same id, same JSON) —
  only the reference strings in statements/evidence-lines change, plus their downstream section placement.
- **Export (`export-gks-dicts.sh`).** Today: `extract gks_dict_proposition proposition.ndjson.gz` (+ vcv
  `:100`, rcv `:102`) and `extract_parquet_typed` (`:129/133/135`). New: emit **group-prefixed shards**
  per (group × level), filtered by the group rule — e.g. `varcond-proposition-*`,
  `varcond-vcv_proposition-*`, `vartumor-*`, `vartherapy-proposition-*` (SCV only), `varcustom-*`. The
  NDJSON path (`bq extract`, whole-table) must move to a filtered `EXPORT DATA … AS SELECT … WHERE
  group=…` (or per-group filtered temp tables) to slice by group.
- **Parquet schemas.** Replace the 3 generic files (`proposition.sql`, `rcv_proposition.sql`,
  `vcv_proposition.sql`) with **4 typed per-group files**, each `UNION ALL` across the levels that carry
  the group, exposing that group's real columns instead of a COALESCE + `data` blob:
  - `varcond`: `id, type, predicate, subjectVariant, objectCondition, geneContext, alleleOrigin*,
    penetrance, modeOfInheritance` (SCV only carries the typed qualifiers; RCV/VCV have none).
  - `vartumor`: `id, type, predicate, subjectVariant, objectTumorType`.
  - `vartherapy`: `id, type, predicate, subjectVariant, objectTherapy, conditionQualifier`.
  - `varcustom`: `id, customPropositionType, predicate, subject, object, qualifiers[]`.
  (`alleleOrigin*` is not emitted anywhere in the procs — it would be a wholly synthesized `NULL` literal
  in the Parquet, nothing to `JSON_VALUE` from; Q4 decides whether to carry it for schema completeness or
  drop it until upstream populates it.)
- **Assemble (`assemble-gks-dicts.py:70`).** Replace the single `proposition` entry with **4 entries**,
  each merging that group's per-level globs (`key`→`value`), e.g.
  `("varcond-proposition", ["varcond-proposition-*", "varcond-vcv_proposition-*", "varcond-rcv_proposition-*"], "key", "value")`, etc.
- **`validate-proposition-conformance.sh`.** Update the three-table UNION (`:19-21`) and add the
  **reference-integrity check** described under Verification (recompute group from the target row's
  `$.type`, compare to the pointer prefix; no surviving `#/proposition/`; no unknown-group rows).
- **Docs.** Proposition class/pipeline pages and the downloads page reflect the four sections + the
  breaking-change note.

## Non-goals

- No restructuring of the dict tables (they stay per-level; split is delivery-layer only).
- No delta-manifest work — none exists on this branch. **Caveat:** if this ever rebases onto the Plan 3/4
  incremental line, the delta section map / oracle section list must also carry the four keys, and the
  reference rewrite (being proc-side) will produce a one-time full-statement delta churn on cutover.
  (Same class of caveat as the Phase-1 VCV synthetic-ConditionSet producer.)
- No change to the reference *mechanism* (still `#/{section}/{id}` JSON pointers) — only the section name
  in the pointer.

## Correctness / verification

- **Oracle-gate** the proc reference changes (determinism; the proc summary already supports oracle
  comparison used in prior phases).
- **Bundle equivalence:** the union of the four new sections' id-sets == the old single `proposition`
  section's id-set for the same release (no proposition lost or duplicated), and each proposition lands in
  exactly one group.
- **Reference integrity (the gate):** for every statement and evidence line, **recompute the canonical
  group from the target proposition row's `$.type`** and assert it equals the pointer's group prefix — an
  id-existence check is insufficient because ids are unique across all four sections, so a mis-routed
  pointer would still resolve. Also assert zero dangling pointers, zero surviving `#/proposition/`, and
  zero rows mapping to an unknown/ERROR group.
- **Typed-column spot check:** each group's Parquet exposes real columns (not `data`-only) for a sample of
  each `$.type`.

## Open planning items

- **Q4 — exact typed qualifier column set per standard group** (enumerate from va-spec; decide whether to
  carry the never-populated `alleleOrigin` column as a synthesized NULL or drop it until upstream emits it).
- **Export NDJSON filtering mechanism** — `bq extract` can't filter; move to `EXPORT DATA … WHERE` or
  per-group temp tables. Decide which, and whether Parquet is 4 files (UNION across levels) or 4×levels.
- **Group-mapping home** — inline CASE (recommended) vs. upstream `clinvar_proposition_types.delivery_group`.
- **Exact `$.type` literals** — confirm the `Proposition` suffix presence against a live release so the
  group `WHERE`/CASE matches.
