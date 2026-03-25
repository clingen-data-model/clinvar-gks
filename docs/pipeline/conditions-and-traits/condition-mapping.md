# Condition Mapping (Steps 2–14 of gks_scv_condition_proc)

## Overview

Steps 2–14 of the `clinvar_ingest.gks_scv_condition_proc` procedure map each SCV's submitted traits (clinical assertion traits) to ClinVar's normalized RCV traits. This is the most complex phase in the conditions pipeline because submitters provide their own trait names and cross-references, which frequently differ from the curated trait records that ClinVar assigns at the RCV level. The procedure uses a progressive, multi-stage matching strategy — starting with high-confidence trait mapping records and falling back through increasingly broad matching techniques — to resolve as many SCV traits as possible to a normalized `trait_id`.

---

## Workflow

The procedure executes the following steps sequentially within a loop over the target schema(s) identified by the `on_date` parameter. Temp tables (`_SESSION.temp_*`) are used for intermediate results and dropped at the end.

Steps produce three types of output:

- <span class="role-badge badge-pipeline">Pipeline table</span> — persists in BigQuery for use by downstream procedures or external processing
- <span class="role-badge badge-artifact">JSON artifact</span> — exported as a JSONL file for public distribution
- <span class="role-badge badge-internal">Internal</span> — exists only within the procedure and is consumed by later steps

### Steps 2–3: Prepare Trait Mappings and RCV Mapping Traits

Two temp tables are created to stage the input data:

- **`temp_normalized_trait_mappings`** — loads ClinVar's `trait_mapping` table, normalizing `mapping_type`, `mapping_ref`, and `mapping_value` to lowercase for consistent matching
- **`temp_rcv_mapping_traits`** — parses RCV mapping records, unnesting the `scv_accessions` array so each SCV is paired with its RCV's parsed trait set content

### Step 4: Build `temp_gks_scv_trait_sets`

Joins the parsed RCV mapping traits with the `clinical_assertion_trait_set` table to produce a per-SCV record containing:

- The RCV `trait_set_id` and parsed `rcv_traits` array
- The SCV's `clinical_assertion_trait_ids` array
- Counts of RCV traits vs. SCV traits (used downstream for singleton matching)
- The SCV's submitted trait set type (`cats_type`) vs. the RCV trait set type
- Extensions for `clinvarTraitSetType` and `clinvarTraitSetId`

**Output:** `temp_gks_scv_trait_sets` — one row per SCV with its associated RCV trait set. <span class="role-badge badge-internal">Internal</span>

### Step 5: Build `temp_all_rcv_traits`

Unnests the `rcv_traits` array from `temp_gks_scv_trait_sets` to extract individual RCV trait records. For each trait, extracts:

- Preferred and alternate names
- Cross-reference IDs by database: MedGen, MONDO, OMIM, HPO, Orphanet, MeSH
- Trait relationship type (e.g., `Finding member`, `co-occurring condition`)
- A convenience `scv_ids` array to avoid re-joining the full trait sets table downstream

!!! note "Duplicate MedGen IDs"
    Trait ID `17556` ("not provided") has two MedGen IDs — `CN517202` (deprecated) and `C3661900` (current). This is the only trait with duplicate MedGen IDs and is handled explicitly in downstream matching.

**Output:** `temp_all_rcv_traits` — one row per trait set + trait ID + MedGen ID combination. <span class="role-badge badge-internal">Internal</span>

### Step 6: Build `temp_normalized_traits`

Deduplicates the RCV trait records to create a master lookup of unique trait IDs. When a trait ID appears in multiple trait sets with different amounts of cross-reference data, the record with the most lookup values (alternate names, OMIM IDs, HPO IDs, etc.) is retained. Ties in cross-reference coverage are broken alphabetically by `trait_type`, which prioritizes "Disease" over "Finding."

**Output:** `temp_normalized_traits` — one row per unique trait ID with the richest cross-reference data available. <span class="role-badge badge-internal">Internal</span>

### Step 7: Build `temp_scv_trait_name_xrefs`

Extracts name and cross-reference data from the SCV-side `clinical_assertion_trait` records. Only processes traits with 2-part IDs (direct SCV traits, not observation traits). For each SCV trait, extracts:

- Submitted xrefs normalized by database (MedGen/UMLS, OMIM, HPO/HP, MONDO, Orphanet, MeSH)
- HPO IDs normalized via the `clinvar_ingest.normalizeHpId` UDF
- The full set of submitted xrefs as `code`/`system` pairs for inclusion in the output

**Output:** `temp_scv_trait_name_xrefs` — one row per SCV trait with parsed cross-references. <span class="role-badge badge-internal">Internal</span>

### Step 8: Build `temp_all_scv_traits`

Joins SCV trait records with their trait mappings and trait set metadata. This is the central table that all subsequent matching stages operate against. Includes:

- The SCV trait's name, type, MedGen ID, and parsed xref IDs
- Counts of total CA traits and trait mappings for the SCV (used for singleton detection)
- The RCV trait count and SCV trait count from the trait sets table
- Submitted xrefs from the SCV trait

Only direct SCV traits (2-part IDs) are included — observation traits are filtered out.

**Output:** `temp_all_scv_traits` — one row per SCV + SCV trait combination. <span class="role-badge badge-internal">Internal</span>

### Step 9: Build `temp_all_mapped_scv_traits`

Matches SCV traits to their ClinVar trait mapping records by comparing submitted trait data against the normalized trait mappings. Matching is attempted via multiple UNION branches:

1. **Preferred name** — SCV trait name matches a `name`/`preferred` trait mapping
2. **MedGen xref** — SCV trait's MedGen ID matches a `xref`/`medgen` trait mapping
3. **OMIM xref** — SCV trait's OMIM ID matches an `xref`/`omim*` trait mapping
4. **MONDO xref** — SCV trait's MONDO ID matches a `xref`/`mondo` trait mapping
5. **HPO xref** — SCV trait's HPO ID matches a `xref`/`hp|hpo|human phenotype ontology` trait mapping
6. **MeSH xref** — SCV trait's MeSH ID matches a `xref`/`mesh` trait mapping
7. **Orphanet xref** — SCV trait's Orphanet ID matches a `xref`/`orphanet` trait mapping
8. **Singleton fallback** — for SCV traits not matched above where exactly one unmapped trait mapping remains, defaults to that remaining mapping

Each match records a `tm_match` string describing how the match was made (e.g., `scv trait: preferred name 'breast cancer'`).

**Output:** `temp_all_mapped_scv_traits` — one row per SCV trait with its matched trait mapping record. <span class="role-badge badge-internal">Internal</span>

### Step 10: RCV Trait Assignment — Stage 1

Assigns RCV traits to SCV traits using the trait mapping results from Step 9. Two sub-strategies execute in sequence:

1. **Trait mapping MedGen ID** — joins the mapped SCV trait's `medgen_id` (from the trait mapping) to the RCV trait's `medgen_id` within the same trait set
2. **Trait mapping ref/type/values** — for SCV traits unmatched by MedGen ID, compares the trait mapping's `mapping_type`/`mapping_ref`/`mapping_value` against RCV traits by preferred name, alternate names, and xref IDs (MedGen, OMIM, MONDO, HPO, MeSH, Orphanet)

**Output:** `temp_rcv_trait_assignment_stage1` — cumulative assignments from this stage. <span class="role-badge badge-internal">Internal</span>

### Step 11: RCV Trait Assignment — Stage 2

Handles singleton SCV traits — cases where:

- The SCV trait count equals the RCV trait count
- Exactly one SCV trait and one RCV trait remain unassigned after Stage 1

These are paired by elimination.

**Output:** `temp_rcv_trait_assignment_stage2` — cumulative assignments from Stages 1–2. <span class="role-badge badge-internal">Internal</span>

### Step 12: RCV Trait Assignment — Stage 3

Directly matches remaining unassigned SCV traits to RCV traits by comparing the SCV's submitted xref IDs against the normalized trait's xref IDs:

- MedGen ID
- OMIM ID
- HPO ID
- MONDO ID
- Orphanet ID
- MeSH ID

**Output:** `temp_rcv_trait_assignment_stage3` — cumulative assignments from Stages 1–3. <span class="role-badge badge-internal">Internal</span>

### Step 13: RCV Trait Assignment — Stage 4 (Rogue Traits)

Handles "rogue" SCV traits — those that do not appear in the expected RCV trait set. These are matched against the full `temp_normalized_traits` table (not constrained to the SCV's trait set) using a prioritized single-pass lookup:

1. OMIM ID match
2. HPO ID match
3. Orphanet ID match
4. MONDO ID match
5. MeSH ID match
6. Preferred name match (case-insensitive, with special handling for the "not provided" trait)
7. Alternate name match (case-insensitive, with the same "not provided" exclusion)
8. MedGen ID match for traits with null `cat_name`

Each sub-step only processes traits that were not matched by a previous sub-step, preventing duplicate assignments.

**Output:** `temp_rcv_trait_assignment_stage4` — cumulative assignments from all stages. <span class="role-badge badge-internal">Internal</span>

### Step 14: Build `gks_scv_condition_mapping`

Assembles the final condition mapping table by joining Stage 4 assignments with the SCV trait data and trait mapping records. Includes:

- SCV and trait identifiers
- The submitted trait name, type, and MedGen ID
- The matched normalized trait ID, name, relationship type, and MedGen ID
- The trait mapping match description and mapping type/ref/value
- The assignment type describing which stage resolved the match
- Submitted xrefs from the SCV trait

SCV traits that could not be resolved by any stage are included with a null `trait_id` and an `assign_type` of `unassignable scv trait`.

**Output:** `gks_scv_condition_mapping` — one row per SCV trait with its resolved (or unresolved) trait assignment. <span class="role-badge badge-pipeline">Pipeline table</span>

---

## Output Tables

| Table | Description | Role |
| --- | --- | --- |
| `temp_gks_scv_trait_sets` | Per-SCV record with RCV trait set, trait counts, and trait set extensions | <span class="role-badge badge-internal">Internal</span> |
| `temp_normalized_traits` | Deduplicated master list of unique RCV trait IDs with richest cross-reference data | <span class="role-badge badge-internal">Internal</span> |
| `temp_all_scv_traits` | All direct SCV traits with parsed xrefs, counts, and trait set metadata | <span class="role-badge badge-internal">Internal</span> |
| `temp_all_mapped_scv_traits` | SCV traits matched to ClinVar trait mapping records | <span class="role-badge badge-internal">Internal</span> |
| `gks_scv_condition_mapping` | Final per-SCV-trait mapping to a normalized trait ID with assignment provenance | <span class="role-badge badge-pipeline">Pipeline table</span> |

---

## Assignment Type Reference

The `assign_type` field in `gks_scv_condition_mapping` records how each SCV trait was resolved:

| Stage | `assign_type` | Description |
| --- | --- | --- |
| 1 | `rcv-tm medgen id` | Trait mapping MedGen ID matched RCV trait MedGen ID |
| 1 | `tm reftype preferred name` | Trait mapping name/preferred matched RCV preferred name |
| 1 | `tm reftype alternate name` | Trait mapping name/alternate matched RCV alternate name |
| 1 | `tm reftype xref medgen` | Trait mapping xref/medgen matched RCV MedGen ID |
| 1 | `tm reftype xref omim` | Trait mapping xref/omim matched RCV OMIM ID |
| 1 | `tm reftype xref mondo` | Trait mapping xref/mondo matched RCV MONDO ID |
| 1 | `tm reftype xref hp` | Trait mapping xref/hp matched RCV HPO ID |
| 1 | `tm reftype xref mesh` | Trait mapping xref/mesh matched RCV MeSH ID |
| 1 | `tm reftype xref orphanet` | Trait mapping xref/orphanet matched RCV Orphanet ID |
| 2 | `single remaining trait` | Singleton — last unmatched SCV trait paired with last unmatched RCV trait |
| 3 | `rcv-scv trait medgen_id` | SCV submitted MedGen ID matched normalized trait MedGen ID |
| 3 | `rcv-scv trait omim_id` | SCV submitted OMIM ID matched normalized trait OMIM ID |
| 3 | `rcv-scv trait hp_id` | SCV submitted HPO ID matched normalized trait HPO ID |
| 3 | `rcv-scv trait mondo_id` | SCV submitted MONDO ID matched normalized trait MONDO ID |
| 3 | `rcv-scv trait orphanet_id` | SCV submitted Orphanet ID matched normalized trait Orphanet ID |
| 3 | `rcv-scv trait mesh_id` | SCV submitted MeSH ID matched normalized trait MeSH ID |
| 4 | `rcv-scv rogue trait omim_id` | Rogue trait matched across all normalized traits by OMIM ID |
| 4 | `rcv-scv rogue trait hp_id` | Rogue trait matched by HPO ID |
| 4 | `rcv-scv rogue trait orphanet_id` | Rogue trait matched by Orphanet ID |
| 4 | `rcv-scv rogue trait mondo_id` | Rogue trait matched by MONDO ID |
| 4 | `rcv-scv rogue trait mesh_id` | Rogue trait matched by MeSH ID |
| 4 | `rcv-scv rogue trait name` | Rogue trait matched by preferred name or MedGen ID (null name) |
| 4 | `rcv-scv rogue alternate trait name` | Rogue trait matched by alternate name |
| — | `unassignable scv trait` | No match found by any stage |

---

## Dependencies

- **UDFs**: `clinvar_ingest.parseTraitSet`, `clinvar_ingest.parseXRefItems`, `clinvar_ingest.normalizeHpId`
- **Source Tables**: `trait_mapping`, `rcv_mapping`, `clinical_assertion_trait_set`, `clinical_assertion_trait`
- **Upstream Steps**: Step 1 (Traits) — `temp_gks_trait` is available but not used by these steps
- **Downstream Steps**: Step 15 (Condition Sets); `gks_scv_condition_mapping` also consumed by `gks_vcv_proc`
