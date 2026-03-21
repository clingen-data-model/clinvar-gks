# variation_identity Procedure

## Overview

The `clinvar_ingest.variation_identity` stored procedure extracts and normalizes variant identity information from ClinVar release data. Its goal is to determine, for each ClinVar variation, the single best expression (SPDI, HGVS, or gnomAD format) that can be used to resolve the variant into a GA4GH VRS (Variation Representation Specification) identifier.

The procedure accepts a single parameter — `on_date DATE` — which identifies the ClinVar release schema to process.

---

## Workflow

The procedure executes the following steps sequentially within a loop over the target schema(s) identified by the `on_date` parameter.

### Step 1: Extract Variation Records

Builds a foundational set of variation records from ClinVar, enriched with:
- Copy number data (absolute copy number or copy number tuple) extracted from submitted clinical assertion variations
- A canonical SPDI expression when provided by ClinVar
- A cytogenetic location
- An initial `vrs_class` assignment based on available data (SPDI presence implies `Allele`, copy number data implies `CopyNumberCount`, etc.)

**Output:** Internal working table used by all subsequent steps.

### Step 2: Build `variation_loc`

Parses the `Location` element from each variation's content to extract sequence location data across all available assemblies and accessions. For each location, derives:
- A **gnomAD-formatted identifier** from VCF fields (when available)
- An **HGVS expression** from positional coordinates using the `clinvar_ingest.deriveHGVS` function
- Variant length estimates and range endpoint flags

See [variation_loc_table.md](variation_loc_table.md) for full field documentation.

### Step 3: Build `variation_hgvs`

Parses the `HGVSlist` element from each variation's content to extract all HGVS nucleotide and protein expressions. For each variation+accession pair, selects the best representative expression while preserving all alternatives in an array. Also captures molecular consequences and MANE transcript designations.

See [variation_hgvs_table.md](variation_hgvs_table.md) for full field documentation.

### Step 4: Refine VRS Class Assignments

Updates VRS class assignments for variations that were not classified in Step 1 (i.e., those without a canonical SPDI or copy number data). Uses derived variant length and range endpoint information from `variation_loc` and `variation_hgvs` to determine whether deletions and duplications should be classified as `Allele` (short, precise) or `CopyNumberChange` (long or imprecise).

Classification rules:
- **CopyNumberChange**: Deletions/duplications where derived variant length is NULL, exceeds 1000bp, or has imprecise range endpoints
- **Allele**: Deletions, duplications, indels, insertions, microsatellites, tandem duplications, and SNVs with precise endpoints
- **Not Available**: All other cases

### Step 5: Build `variation_xref`

Extracts cross-references to external databases (ClinGen, dbSNP, OMIM, etc.) from each variation's `XRefList` element.

See [variation_xref_table.md](variation_xref_table.md) for full field documentation.

### Step 6: Build `variation_spdi`

Extracts the canonical SPDI expression for variations that have one, associating it with the GRCh38 assembly.

See [variation_spdi_table.md](variation_spdi_table.md) for full field documentation.

### Step 7: Build `variation_members`

Consolidates all candidate expression sources into a single table with a unified 9-level precedence hierarchy. For each variation+accession pair, retains only the highest-precedence source. Joins back to `variation_hgvs` and `variation_loc` to carry forward HGVS expression arrays, molecular consequences, MANE designations, and location metadata.

See [variation_members_table.md](variation_members_table.md) for full field documentation.

### Step 8: Build `variation_identity`

Selects the single best expression source per variation from `variation_members`, merges in variation-level metadata (name, type, cytogenetic location), and builds the cross-reference mappings array from `variation_xref`. This is the final output table consumed by downstream VRS processing.

See [variation_identity_table.md](variation_identity_table.md) for full field documentation.

---

## Output Tables

| Table | Description |
|---|---|
| `variation_loc` | Sequence locations with derived gnomAD and HGVS expressions |
| `variation_hgvs` | HGVS expressions with molecular consequences and MANE designations |
| `variation_xref` | Cross-references to external databases |
| `variation_spdi` | Canonical SPDI expressions (GRCh38) |
| `variation_members` | Consolidated expression sources ranked by precedence |
| `variation_identity` | Final single-best expression per variation with full metadata |

---

## Dependencies

- **UDFs**: `clinvar_ingest.parseAttributeSet`, `clinvar_ingest.parseSequenceLocations`, `clinvar_ingest.deriveHGVS`, `clinvar_ingest.parseHGVS`, `clinvar_ingest.parseXRefs`, `clinvar_ingest.schema_on`
- **Source Tables**: `variation`, `clinical_assertion_variation`, `clinical_assertion`
- **Downstream Consumers**: VRS Python processing pipeline, `gks_catvar_proc`, `gks_statement_scv_proc`
