# ClinVar CustomProposition conformance + proposition delivery grouping — Design

> **Status:** design (drafting 2026-08-12). Follows the va-spec `1.1.0-ballot.2026-07.2` alignment
> (PR #78, branch `chore/update-va-spec-1.1.0-ballot-2026-07-2`), which reshaped the ClinVar custom
> proposition schema types. This spec covers (1) making the **pipeline** emit proposition data that
> conforms to the new schema, and (2) a forward-looking reorganization of **proposition delivery**
> (Parquet + bundle) grouped by subject/object datatype signature. All BigQuery work on `clingen-dev`.

## Goal

Two coupled deliverables:

1. **Conformance (required):** the BigQuery statement procs currently emit every proposition in one
   uniform shape (`{type:<specific>, subjectVariant, objectCondition, predicate, …typed qualifiers}`).
   The va-spec 1.1.0 ballot split propositions into **standard** types (unchanged shape) and
   **CustomProposition**-derived types (new shape: `type:"CustomProposition"` +
   `customPropositionType` + generic `subject`/`object` + generic `qualifiers[]`). The pipeline must
   emit the correct shape per type.
2. **Delivery grouping (forward-looking):** propositions are a fundamental, definitive aspect of
   statements and evidence lines. For clean typed delivery (Parquet + bundle), organize proposition
   records into groups that share the **same (subject-datatype, object-datatype) signature**, carrying
   `type`/`customPropositionType` + `predicate` + qualifier attributes as columns within each group.

---

## 1. Background — current proposition data model

- **Subject propositions** are stored in the per-level dict tables `gks_dict_proposition` (SCV),
  `gks_dict_vcv_proposition` (VCV), `gks_dict_rcv_proposition` (RCV), keyed by `key`=`prop_id`, value =
  a JSON object. The bundle merges all three into one `proposition` section
  (`assemble-gks-dicts.py:70`); typed Parquet is emitted per level
  (`parquet-schemas/{proposition,vcv_proposition,rcv_proposition}.sql`).
- **Target propositions** (the somatic Diagnostic/Prognostic/TherapeuticResponse types) are **embedded
  inside evidence lines** in `gks_dict_evidence_line` (SCV `evidence_line_target_proposition`,
  `gks-scv-statement-proc.sql:377-465`), not in the proposition dicts.
- Current emitted shape (all types, uniform) — `gks-{scv,rcv,vcv}-statement-proc.sql`:
  `{ id, type:<specific gks_type>, subjectVariant:'#/variation/clinvar:{id}', predicate,
     objectCondition:<…> }` plus, for **SCV** subject propositions, typed
  `geneContextQualifier`/`modeOfInheritanceQualifier`/`penetranceQualifier` (MappableConcept structs).
  RCV/VCV proposition structs carry **no** proposition-level qualifiers.
- **`objectCondition` cardinality differs by level (important):** SCV emits a **single** pointer
  (`gks-scv-statement-proc.sql`), RCV a **single** COALESCE'd value (`rcd.condition_concept`), but **VCV
  emits an ARRAY** — `agg.unique_conditions AS objectCondition` (`gks-vcv-statement-proc.sql:331/357/383`,
  `unique_conditions = ARRAY_AGG(DISTINCT …)` in `gks-vcv-proc.sql`). va-spec `objectCondition` and the
  clinvar custom `object` are **singular** (`Condition|ConditionSet|iriReference`; multiplicity is
  expressed by a single `ConditionSet` whose `concepts[]` holds the members). So **VCV standard AND
  custom propositions are already non-conformant** (array where the schema wants a single value) — see
  §3.5.
- The custom/standard split is by **`gks_type` name prefix**: `Clinvar*` = custom, `Variant*` =
  standard. There is **no** `is_custom` flag in the upstream `clinvar_ingest.clinvar_proposition_types`
  table (columns are upstream-sourced — `code, label, gks_type, statement_type_code, display_order,
  conflict_detectable` — and not verifiable in this repo); the classification→`gks_type` mapping is owned
  upstream (`clinvar-ingest-bq-tools`). This repo only reads it.

## 2. Proposition datatype signatures (the grouping key)

Verified against `submodules/va-spec/schema/va-spec/base/va-core-source.yaml` and the clinvar sources:

| Group | subject | object | Types | Qualifiers (typed, standard) |
|---|---|---|---|---|
| **G1 variant×condition (std)** | `subjectVariant` (Variation) | `objectCondition` (Condition\|ConditionSet\|iri) | VariantPathogenicity, VariantClinicalSignificance, VariantDiagnostic\*, VariantPrognostic\* | geneContext, alleleOrigin, penetrance, modeOfInheritance |
| **G2 variant×tumorType (std)** | `subjectVariant` | `objectTumorType` | VariantOncogenicity | (per va-spec) |
| **G3 variant×therapy (std)** | `subjectVariant` | `objectTherapy` | VariantTherapeuticResponse\* | conditionQualifier (+ gene/allele/…) |
| **G4 variant×condition (custom)** | `subject` (MolecularVariation\|CategoricalVariant\|iri) | `object` (Condition\|ConditionSet\|iri) | the 10 `Clinvar*` (RiskFactor, Protective, DrugResponse, Affects, Association, ConfersSensitivity, Other, NotProvided, ConflictingDataFromSubmitter, **Undefined**) | generic `qualifiers[]` name/value: geneContext, modeOfInheritance, penetrance |

\* Diagnostic/Prognostic/TherapeuticResponse are emitted only as **target** propositions inside
evidence lines (somatic). Pathogenicity/ClinicalSignificance/Oncogenicity + all custom types are
**subject** propositions in the proposition dicts.

**Note on standard object shapes:** the standard types are NOT all `variant×condition` — Oncogenicity
uses `objectTumorType` and TherapeuticResponse uses `objectTherapy`. So grouping by signature yields
multiple standard groups, not one. (The current proc emits `objectCondition` uniformly even for the
somatic target propositions — a pre-existing conformance question flagged in §6.)

---

## 3. Phase 1 — Conformance (schema + pipeline)

### 3.1 Schema changes (`schema/clinvar-gks/clinvar-proposition-source.yaml`)

- **`object` includes `ConditionSet`** — DONE (single `Condition|ConditionSet|iriReference`, matching
  the standard `objectCondition`).
- **Add `ClinvarUndefinedProposition`** as the 10th custom type: `allOf: [ClinvarGermlineCustomProposition]`,
  `customPropositionType` const `ClinvarUndefinedProposition`, `predicate` const
  `isClinvarUndefinedAssociationFor`. Add it to the `ClinvarProposition` `oneOf` union. (This is the
  fallback the SCV proc already emits and the `undef` row in the upstream table; it must be a defined
  type.)
- **Qualifiers:** the germline custom types carry the generic `qualifiers` name/value array inherited
  from `va-spec:CustomProposition` (`{name:string, value: MappableConcept|iriReference}`). **Verify**
  the `additionalProperties: false` on `ClinvarGermlineCustomPropositionProperties` + the `allOf`
  composition actually permits `qualifiers` (it comes from the va-spec base, not the clinvar Properties
  `$def`); if the metaschema composition rejects it, re-declare `qualifiers` on the germline base.
- **Regenerate** (`cd schema/clinvar-gks && make`) and refresh the generated `json/` + docs class pages.
  Note the metaschema non-deterministic ordering (issue ga4gh/gks-metaschema#63) — commit only the
  semantic changes (canonical-diff to filter reorder churn), per the PR-#78 practice.

### 3.2 Target emitted shapes

**Standard** (not converted to CustomProposition — keeps its per-type shape):
`{ id, type:<specific>, subjectVariant, predicate, <object field>, <typed qualifiers> }`. But
"unchanged" is **not** "already conformant" — two standard-type conformance gaps must also be resolved
(§3.5): VariantOncogenicity's object is `objectTumorType` (the procs emit `objectCondition`), and the
VCV object is an **array** (schema wants a single value). The `variant×condition` standard types
(Pathogenicity, ClinicalSignificance) at SCV/RCV are already conformant.

**Custom** (new): `{ id, type:"CustomProposition", customPropositionType:<gks_type>, subject,
predicate, object, qualifiers?:[{name,value},…] }` where:
- `type` = const `"CustomProposition"` (all 10 custom types),
- `customPropositionType` = the `gks_type` (`Clinvar*Proposition`),
- `subject` = the value currently emitted as `subjectVariant` (`#/variation/clinvar:{id}`),
- `object` = the value currently emitted as `objectCondition` (single `#/condition/…` or
  `#/conditionSet/…` pointer),
- `qualifiers` (SCV only) = an array built from the typed qualifier sources, one entry **only when its
  value is present**:
  `{name:"geneContext", value:<sgq MappableConcept>}`, `{name:"modeOfInheritance", value:<smq>}`,
  `{name:"penetrance", value:<spq>}`. (RCV/VCV custom propositions have no qualifiers.)

### 3.3 Pipeline emission (the 3 procs)

Branch on `gks_type LIKE 'Clinvar%'` (custom) vs standard. Implementation approach (BigQuery-friendly):
build **one wide struct** with all possible fields and `IF(is_custom, …, NULL)`-null the fields that
don't apply, then `JSON_STRIP_NULLS(…, remove_empty => TRUE)` drops the nulls **and empties** → the
correct per-type JSON shape (`remove_empty => TRUE` is required to drop an empty custom `qualifiers[]`).
Fields: `type` = `IF(is_custom,'CustomProposition', gks_type)`; `customPropositionType` =
`IF(is_custom, gks_type, NULL)`; `subjectVariant`/`subject` mutually exclusive; `objectCondition`/`object`
mutually exclusive; `predicate` unchanged; typed qualifiers only on standard SCV; `qualifiers[]` only on
custom SCV (built conditionally). Applies to:
- `gks-scv-statement-proc.sql` — subject proposition (Step 5, ~L343-355). The **target** proposition
  (Step 6, ~L409-443) is somatic-standard `Variant*` (Diagnostic/Prognostic/TherapeuticResponse) — the
  custom reshape does NOT apply to it, and it **already** emits `objectTherapy` + `conditionQualifier`
  for therapeutic vs `objectCondition` otherwise, so target props are verify-only for object
  conformance.
- `gks-rcv-statement-proc.sql` — the proposition struct across all 3 aggregation layers (~L344-419).
- `gks-vcv-statement-proc.sql` — same, 3 layers (~L310-383).

### 3.4 Phase-1 downstream

- **Parquet** `parquet-schemas/{proposition,rcv_proposition,vcv_proposition}.sql` must read
  `customPropositionType`/`subject`/`object` for custom rows in addition to `type`/`subjectVariant`/
  `objectCondition` for standard rows (see Phase 2 for the grouped redesign — Phase 1 can COALESCE both
  into columns as an interim).
- **Delta/change-log:** every custom proposition's `value` JSON changes → one-time full churn of all
  custom-proposition records in the next release's delta. Expected; no code change.
- **Docs:** regen the proposition class pages + the pipeline proposition pages.

### 3.5 Standard-type conformance fixes (also Phase 1)

The custom reshape is not the only conformance gap the ballot exposes; two **standard**-type gaps must
be decided in Phase 1 (fix now, or explicitly defer — but the §7 validation gate will fail on them
otherwise):

1. **VCV object is an array.** `gks-vcv-statement-proc.sql` emits `agg.unique_conditions` (an
   `ARRAY_AGG` of `#/condition/…` pointers) as `objectCondition` across all 3 layers, but the schema
   `objectCondition`/custom `object` is a **single** `Condition|ConditionSet|iriReference`. Fix: emit a
   single **`ConditionSet`** pointer (grouping the members via its `concepts[]`) instead of a bare
   array — the natural aggregate model — for VCV standard **and** custom propositions. This also makes
   the VCV custom `object` conform. (RCV already emits a single value; SCV single. Note the
   `rcv_proposition.sql` extractor uses `JSON_VALUE_ARRAY` — reconcile it to single.)
2. **VariantOncogenicity object field.** Oncogenicity is a **subject** proposition (all three subject
   builders emit uniform `objectCondition`), but va-spec requires **`objectTumorType`**. Fix: emit
   `objectTumorType` for `gks_type = 'VariantOncogenicityProposition'`. (The somatic **target** props'
   `objectTherapy` is already handled — §3.3.)

Decision needed: are #1 and #2 in-scope for this initiative's Phase 1 (recommended — they are true
schema non-conformances the ballot surfaces), or split into their own standard-conformance change?

---

## 4. Phase 2 — Proposition delivery grouping by datatype signature (forward-looking)

**Motivation:** typed Parquet and clean bundle sections require homogeneous datatypes per table. Today
one `proposition` bundle section / three per-level Parquet files mix all types and both custom/standard
shapes, so the typed extractors can only surface a few common columns and stuff the rest into a `data`
JSON blob. Grouping by (subject, object) signature lets each group be a fully-typed table.

**Design:** deliver propositions in groups keyed by their **(subjectType, objectType) signature**, each
carrying the shared subject/object columns + the discriminator (`type` for standard,
`customPropositionType` for custom) + `predicate` + the group's qualifier columns (flattened typed
columns for standard groups; the generic `qualifiers[]` array for the custom group). Concretely the
groups from §2:
- **G1** variant×condition (std): columns `id, type, predicate, subjectVariant, objectCondition,
  geneContext*, alleleOrigin*, penetrance*, modeOfInheritance*`.
- **G2** variant×tumorType (std): `id, type, predicate, subjectVariant, objectTumorType, …`.
- **G3** variant×therapy (std): `id, type, predicate, subjectVariant, objectTherapy, conditionQualifier, …`.
- **G4** variant×condition (custom): `id, customPropositionType, predicate, subject, object, qualifiers[]`.

Each group → its own typed Parquet file and its own bundle sub-section (or a `proposition` section
sub-keyed by group). A statement/evidence-line still references a proposition by its `#/proposition/{id}`
pointer; only the *organization* of the proposition store changes, not the reference mechanism.

### 4.1 Open design questions (resolve during planning)

1. **Cross-level vs within-level grouping.** Today propositions are separated by source level
   (scv/vcv/rcv) — load-bearing for the incremental/delta cascade and the aggregation model. Does the
   datatype-signature grouping apply **within** each level (e.g. `scv_variantConditionProposition`,
   `vcv_variantConditionProposition`, …), or **across** levels (one `variantConditionProposition` store
   for the whole dataset)? Cross-level is cleaner for consumers but changes the delta/aggregation keying;
   within-level preserves the current cascade. **Recommend: keep within-level for the dict/delta layer
   (preserve the cascade), group by signature only at the delivery layer (Parquet + bundle section
   naming).**
2. **Bundle consumer contract.** Splitting the single `proposition` section into signature-named
   sub-sections (or adding a group discriminator) changes the published bundle shape — a
   consumer-facing change. Decide the naming + whether it's additive or a breaking reorg, and coordinate
   with the delta-publishing model (Plan 4).
3. **Target propositions.** The somatic target props (G1/G3) live inside evidence lines, not the
   proposition dicts. Does grouping apply to them too (extract into grouped proposition tables), or do
   they stay embedded? If extracted, evidence lines would reference them by pointer like statements do.
4. **Qualifier column set per standard group.** Enumerate the exact typed qualifier columns per group
   from va-spec (gene/allele/penetrance/modeOfInheritance for G1; conditionQualifier + … for G3) so the
   Parquet schema is complete. **Note:** `alleleOriginQualifier` exists in va-spec (and is listed in the
   §2/§4 G1 column set for completeness) but the pipeline does **not** currently populate it — SCV Step 5
   builds only gene/moi/penetrance — so that column would be perpetually null until upstream provides it.
5. **Where the grouping is computed.** In the statement procs (emit into grouped dict tables) vs a new
   post-processing/regroup proc vs only at export time (`export-gks-dicts.sh` + `parquet-schemas`).
   The lightest is export-time grouping (the dict tables stay per-level; the Parquet/bundle export
   splits by signature via `JSON_VALUE($.type)`/prefix), avoiding proc/delta churn beyond Phase 1.

---

## 5. Full change surface

- **Schema:** `clinvar-proposition-source.yaml` (+ regenerate `json/`, docs).
- **Procs:** `gks-{scv,rcv,vcv}-statement-proc.sql` (Phase 1 emission; possibly grouped dicts in Phase 2
  if not export-time).
- **Export/Parquet:** `export-gks-dicts.sh`, `parquet-schemas/*proposition*.sql` (Phase 1 columns;
  Phase 2 per-group files).
- **Bundle:** `assemble-gks-dicts.py` `SECTIONS` (Phase 2 section reorg).
- **Delta/change-log + Plan 4 delta publishing:** proposition churn (Phase 1); section-map changes
  (Phase 2) must stay consistent across `export`/`assemble`/`build-delta-manifest`/`oracle`.
- **Docs:** proposition class pages + pipeline proposition pages + downloads (Phase 2 section changes).

## 6. Open questions / to verify during planning

- **`qualifiers` schema composition** — confirm the custom base actually permits the inherited
  `qualifiers` array under `additionalProperties:false` allOf composition (§3.1).
- **Standard object-field conformance** — resolved into §3.5 as concrete Phase-1 fixes: VCV array→single
  `ConditionSet`, and VariantOncogenicity **subject** props `objectCondition`→`objectTumorType`. The
  somatic **target** props already emit `objectTherapy`/`conditionQualifier` (verify-only). Spot-check
  the generated JSON for `VariantOncogenicityProposition`/`VariantTherapeuticResponseProposition` to
  confirm exact object field names before implementing.
- **`ClinvarUndefinedProposition` frequency** — it never fired on the test datasets (upstream mapping
  fully resolved). Confirm whether to keep the proc fallback + schema type, or eliminate the fallback by
  guaranteeing the upstream mapping is total.
- **Branch signal** — prefix-sniff `gks_type LIKE 'Clinvar%'` (self-contained) vs an upstream
  `is_custom`/signature column added to `clinvar_proposition_types`. Prefix works today; the `undef`
  sentinel classifies as custom under it (correct).

## 7. Correctness

- **Schema-conformance validation** (new): validate a sample of emitted propositions (custom + each
  standard group) against the generated `schema/clinvar-gks/json/*` — this is the gate that the reshape
  is correct and would catch stray fields (`additionalProperties:false`).
- **Full-vs-full determinism** for the reshaped procs (the existing gks proc oracles / the Plan-4
  reconstruction oracle if on that line) — the proposition `value` changes are intended; verify only
  the intended fields changed and the id sets are stable.

## 8. Phasing

1. **Phase 1 (conformance)** — schema (undefined type + qualifiers verify), pipeline emission reshape,
   interim Parquet columns, docs, conformance validation. Required to match the new va-spec ballot.
2. **Phase 2 (delivery grouping)** — resolve §4.1 questions, then group proposition delivery by
   signature (Parquet per group + bundle section reorg), coordinated with Plan 4 delta publishing.
   Forward-looking; can follow Phase 1.
