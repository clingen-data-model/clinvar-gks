# Variation Identity

## Overview

The `clinvar_ingest.variation_identity` stored procedure extracts and normalizes variant identity information from ClinVar release data. Its goal is to determine, for each ClinVar variation, the single best expression (SPDI, HGVS, or gnomAD format) that can be used to resolve the variant into a GA4GH VRS (Variation Representation Specification) identifier.

The procedure accepts a single parameter — `on_date DATE` — which identifies the ClinVar release schema to process.

---

## Workflow

The procedure executes the following steps sequentially within a loop over the target schema(s) identified by the `on_date` parameter.

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

**Output:** Internal temporary table used by all subsequent steps.

### Step 2: Build `variation_loc`

Parses the `Location` element from each variation's content to extract sequence location data across all available assemblies and accessions. For each location, derives:

- A **gnomAD-formatted identifier** from VCF fields (when available)
- An **HGVS expression** from positional coordinates using the `clinvar_ingest.deriveHGVS` function
- **Variant length estimates** from positional data with assembly-based precedence ranking
- **Range endpoint flags** for imprecise structural variant locations

See [Sequence Locations](variation-loc.md) for full field documentation.

**Output:** `variation_loc` — one row per variation + accession + assembly combination.

### Step 3: Build `variation_hgvs`

Parses the `HGVSlist` element from each variation's content to extract all HGVS nucleotide and protein expressions. For each variation + accession pair, selects the best representative expression using a ranking that prefers higher assembly version, presence of consequence annotations, balanced parentheses, protein expression availability, and shorter nucleotide expression length. Preserves all alternatives in an array.

Also captures:

- **Molecular consequences** — Sequence Ontology terms for each expression
- **MANE designations** — MANE Select and MANE Plus Clinical transcript flags
- **Pre-identified issues** — unsupported accession prefixes, repeat expressions, intronic positions, and other patterns that prevent VRS resolution

See [HGVS Expressions](variation-hgvs.md) for full field documentation.

**Output:** `variation_hgvs` — one row per variation + accession combination.

### Step 4: Refine VRS Class Assignments

Updates VRS class assignments for variations that were not classified in Step 1 (those without a canonical SPDI or copy number data). Uses derived variant length and range endpoint information from `variation_loc` and `variation_hgvs` to determine whether deletions and duplications should be classified as `Allele` or `CopyNumberChange`.

Classification rules:

- **CopyNumberChange** — deletions/duplications where derived variant length is NULL, exceeds 1000 bp, or has imprecise range endpoints
- **Allele** — deletions, duplications, indels, insertions, microsatellites, tandem duplications, and SNVs with precise endpoints
- **Not Available** — all other cases

**Output:** Updates the internal working table in place.

### Step 5: Build `variation_xref`

Extracts cross-references to external databases (ClinGen, dbSNP, OMIM, UniProtKB, GTR, etc.) from each variation's `XRefList` element.

See [Cross-References](variation-xref.md) for full field documentation.

**Output:** `variation_xref` — one row per variation + external reference combination.

### Step 6: Extract Canonical SPDI

Extracts the canonical SPDI expression for variations that have one, associating it with the GRCh38 assembly and deriving the sequence accession from the expression. SPDI is NCBI's normalized variant representation format and serves as the highest-precedence source for VRS resolution.

**Output:** Internal temporary table consumed by Step 7.

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

Within the same precedence level for a given variation + accession, ties are broken by row-number windowing (first row wins).

**Output:** Internal temporary table consumed by Step 8.

### Step 8: Build `variation_identity`

Selects the single best expression source per variation from the consolidated members table, merges in variation-level metadata (name, type, cytogenetic location), and builds the cross-reference mappings array from `variation_xref`. This is the final output table consumed by downstream VRS processing and the Cat-VRS pipeline.

See [Variation Identity](variation-identity.md) for full field documentation.

**Output:** `variation_identity` — one row per ClinVar variation.

---

## Output Tables

| Table | Description |
| --- | --- |
| `variation_loc` | Sequence locations with derived gnomAD and HGVS expressions |
| `variation_hgvs` | HGVS expressions with molecular consequences and MANE designations |
| `variation_xref` | Cross-references to external databases |
| `variation_identity` | Final single-best expression per variation with full metadata |

---

## Dependencies

- **UDFs**: `clinvar_ingest.parseAttributeSet`, `clinvar_ingest.parseSequenceLocations`, `clinvar_ingest.deriveHGVS`, `clinvar_ingest.parseHGVS`, `clinvar_ingest.parseXRefs`, `clinvar_ingest.schema_on`
- **Source Tables**: `variation`, `clinical_assertion_variation`, `clinical_assertion`
- **Downstream Consumers**: VRS Python processing pipeline, `gks_catvar_proc`
