# Variation Identity

## Overview

The `clinvar_ingest.variation_identity` stored procedure extracts and normalizes variant identity information from ClinVar release data. Its goal is to determine, for each ClinVar variation, the single best expression (SPDI, HGVS, or gnomAD format) that can be used to resolve the variant into a GA4GH VRS (Variation Representation Specification) identifier.

The procedure accepts a single parameter — `on_date DATE` — which identifies the ClinVar release schema to process.

Two entry points share the same logic (BigQuery has no default parameters or overloading, so the mode is exposed as separate wrappers over an internal `variation_identity_build(on_date, debug, incremental)`):

- `variation_identity(on_date, debug)` — **full rebuild**. Re-parses every variation. Always correct; use for the first release, after a transform change, or when a baseline is unavailable.
- `variation_identity_incremental(on_date, debug)` — **incremental rebuild**. Re-parses only the variations changed since the prior release and carries the rest forward. See [Incremental Rebuild](#incremental-rebuild).

---

## Workflow

The procedure executes the following steps sequentially within a loop over the target schema(s) identified by the `on_date` parameter.

Steps produce three types of output:

- <span class="role-badge badge-pipeline">Pipeline table</span> — persists in BigQuery for use by downstream procedures or external processing
- <span class="role-badge badge-artifact">JSON artifact</span> — exported as a JSONL file for public distribution
- <span class="role-badge badge-internal">Internal</span> — exists only within the procedure and is consumed by later steps

### Step 1: Extract Variation Records

Builds a foundational working table of variation records from ClinVar, enriched with:

- **Copy number data** — absolute copy number or copy number tuple extracted from submitted clinical assertion variations
- **Canonical SPDI** — the NCBI-normalized SPDI expression when provided by ClinVar
- **Cytogenetic location** — the chromosomal band location
- **Initial VRS class** — a baseline classification based on available data:
  - `Allele` when a canonical SPDI is present
  - `CopyNumberCount` when copy number data exists for a deletion/duplication/gain/loss
  - `CopyNumberChange` for copy number gains/losses without count data
  - `Haplotype` for haplotype subclass types
  - `Not Available` for genotype subclass types

**Output:** Internal temporary table used by all subsequent steps. <span class="role-badge badge-internal">Internal</span>

### Step 2: Build `variation_loc`

Parses the `Location` element from each variation's content to extract sequence location data across all available assemblies and accessions. For each location, derives:

- A **gnomAD-formatted identifier** from VCF fields (when available)
- An **HGVS expression** from positional coordinates using the `clinvar_ingest.deriveHGVS` function
- **Variant length estimates** from positional data with assembly-based precedence ranking
- **Range endpoint flags** for imprecise structural variant locations

See [Sequence Locations](variation-loc.md) for full field documentation.

**Output:** `variation_loc` — one row per variation + accession + assembly combination. <span class="role-badge badge-pipeline">Pipeline table</span>

### Step 3: Build `variation_hgvs`

Parses the `HGVSlist` element from each variation's content to extract all HGVS nucleotide and protein expressions. For each variation + accession pair, selects the best representative expression using a ranking that prefers higher assembly version, presence of consequence annotations, balanced parentheses, protein expression availability, and shorter nucleotide expression length. Preserves all alternatives in an array.

Also captures:

- **Molecular consequences** — Sequence Ontology terms for each expression
- **MANE designations** — MANE Select and MANE Plus Clinical transcript flags
- **Pre-identified issues** — unsupported accession prefixes, repeat expressions, intronic positions, and other patterns that prevent VRS resolution

See [HGVS Expressions](variation-hgvs.md) for full field documentation.

**Output:** `variation_hgvs` — one row per variation + accession combination. <span class="role-badge badge-pipeline">Pipeline table</span>

### Step 4: Refine VRS Class Assignments

Updates VRS class assignments for variations that were not classified in Step 1 (those without a canonical SPDI or copy number data). Uses derived variant length and range endpoint information from `variation_loc` and `variation_hgvs` to determine whether deletions and duplications should be classified as `Allele` or `CopyNumberChange`.

Classification rules:

- **CopyNumberChange** — deletions/duplications where derived variant length is NULL, exceeds 1000 bp, or has imprecise range endpoints
- **Allele** — deletions, duplications, indels, insertions, microsatellites, tandem duplications, and SNVs with precise endpoints
- **Not Available** — all other cases

**Output:** Updates the internal working table in place. <span class="role-badge badge-internal">Internal</span>

### Step 5: Build `variation_xref`

Extracts cross-references to external databases (ClinGen, dbSNP, OMIM, UniProtKB, GTR, etc.) from each variation's `XRefList` element.

See [Cross-References](variation-xref.md) for full field documentation.

**Output:** `variation_xref` — one row per variation + external reference combination. <span class="role-badge badge-pipeline">Pipeline table</span>

### Step 6: Extract Canonical SPDI

Extracts the canonical SPDI expression for variations that have one, associating it with the GRCh38 assembly and deriving the sequence accession from the expression. SPDI is NCBI's normalized variant representation format and serves as the highest-precedence source for VRS resolution.

**Output:** Internal temporary table consumed by Step 7. <span class="role-badge badge-internal">Internal</span>

### Step 7: Consolidate Expression Sources

Consolidates all candidate expression sources — SPDI, HGVS, gnomAD, and location-derived HGVS — into a single table with a unified 9-level precedence hierarchy. For each variation + accession pair, retains only the highest-precedence source and joins back to `variation_hgvs` and `variation_loc` to carry forward expression arrays, molecular consequences, MANE designations, and location metadata.

#### Precedence Hierarchy

| Rank | Source | Description |
| --- | --- | --- |
| 1 | SPDI | NCBI-normalized canonical form (GRCh38 only) |
| 2 | HGVS genomic, top-level | Chromosomal-level HGVS from ClinVar |
| 3 | gnomAD | VCF-derived identifier from location coordinates |
| 4 | Location-derived HGVS | Fallback HGVS built from positional data (when gnomAD unavailable) |
| 5 | HGVS genomic | Non-top-level genomic accessions (alternate loci, patches) |
| 6 | HGVS coding MANE Select | Transcript-level, MANE Select designated |
| 7 | HGVS coding MANE Plus | Transcript-level, MANE Plus Clinical designated |
| 8 | HGVS coding (other) | Transcript-level, non-MANE |
| 9 | HGVS other | Remaining types (non-coding, etc.) |

Within the same precedence level for a given variation + accession, ties are broken by a **total-order** row-number windowing (assembly version, then format, source, and issue) so the selected source is deterministic across runs. Determinism matters for both reproducibility and the incremental carry-forward — see [Incremental Rebuild](#incremental-rebuild).

**Output:** Internal temporary table consumed by Step 8. <span class="role-badge badge-internal">Internal</span>

### Step 8: Build `variation_identity`

Selects the single best expression source per variation from the consolidated members table, merges in variation-level metadata (name, type, cytogenetic location), and builds the cross-reference mappings array from `variation_xref`. This is the final output table consumed by downstream VRS processing and the Cat-VRS pipeline.

See [Variation Identity](variation-identity.md) for full field documentation.

**Output:** `variation_identity` — one row per ClinVar variation. <span class="role-badge badge-pipeline">Pipeline table</span>

---

## Output Tables

| Table | Description | Role |
| --- | --- | --- |
| `variation_loc` | Sequence locations with derived gnomAD and HGVS expressions | <span class="role-badge badge-pipeline">Pipeline table</span> |
| `variation_hgvs` | HGVS expressions with molecular consequences and MANE designations | <span class="role-badge badge-pipeline">Pipeline table</span> |
| `variation_xref` | Cross-references to external databases | <span class="role-badge badge-pipeline">Pipeline table</span> |
| `variation_identity` | Final single-best expression per variation with full metadata | <span class="role-badge badge-pipeline">Pipeline table</span> |

---

## Incremental Rebuild

`variation_identity_incremental` produces the same four output tables as a full rebuild, but re-runs the heavy per-variation content parsing (`parseSequenceLocations`, `parseHGVS`, `parseXRefs`, SPDI) only for the variations that changed since the prior release. On a typical weekly release this is roughly 0.4% of variations, cutting execution cost by **~7.5× slot-time** and **~2.1× bytes** while producing output that is byte-for-byte identical to a full rebuild (0 canonical diffs across all four tables).

### How it works

1. **Changed set** — the variations to recompute are `diff_variation` (`new` or `modified`) unioned with the **copy-number cascade**: variations whose `variation` row is byte-identical but whose CopyNumber-bearing `clinical_assertion_variation` / `clinical_assertion` changed (resolved over both the compare and baseline snapshots so removed submissions are caught). Removed variations are tracked separately.
2. **Parse only the changed set** — Steps 1–8 run against the changed variations and write to per-variation staging tables.
3. **Carry forward + merge** — each of the four outputs is rebuilt with a `UNION ALL` of the baseline rows for unchanged variations and the freshly parsed rows for changed ones (a `CREATE TABLE … AS SELECT` union, not row-level `DELETE`/`INSERT`, which avoids a scattered-row rewrite penalty). Explicit column lists ensure a schema drift errors rather than silently corrupting.
4. **Global `mappings`** — the cross-reference `mappings` array is recomputed from the fully merged `variation_xref` (a cheap join), because a variation's mappings can be sourced from `variation_xref` rows keyed on an external id that belongs to other variations.

### Fallback guard (automatic)

`variation_identity_incremental` falls back to a full rebuild when the baseline release, its four output tables, or the current release's `diff_*` driver tables are missing. The full path is always correct, so a missing prerequisite is never an error.

### Version-invalidation (operator-asserted)

Carry-forward assumes the prior release was built by the **same** `variation_identity` transform.

!!! warning "Reseed after a transform change"
    After any change to the `variation_identity` procedure, run the full `variation_identity` once on the next release to reseed the baseline, then resume `variation_identity_incremental`. The fallback guard checks that prerequisites *exist*, not that the transform is unchanged — that assertion is the operator's.

Producing `variation_identity` incrementally also yields the clean changed-variation set that the [VRS Processing](../vrs-processing.md) step consumes to shrink the expensive vrs-python payload.

---

## Dependencies

- **UDFs**: `clinvar_ingest.parseAttributeSet`, `clinvar_ingest.parseSequenceLocations`, `clinvar_ingest.deriveHGVS`, `clinvar_ingest.parseHGVS`, `clinvar_ingest.parseXRefs`, `clinvar_ingest.schema_on`
- **Source Tables**: `variation`, `clinical_assertion_variation`, `clinical_assertion`
- **Incremental drivers** (incremental mode only): `diff_variation`, `diff_clinical_assertion`, `diff_clinical_assertion_variation` (from `dataset_diff_on`), plus the prior release's `variation_identity` / `variation_loc` / `variation_hgvs` / `variation_xref` as the carry-forward baseline
- **Downstream Consumers**: VRS Python processing pipeline, `gks_catvar_proc`
