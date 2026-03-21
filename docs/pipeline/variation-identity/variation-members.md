# variation_members Table

## Overview

The `variation_members` table is created by the `clinvar_ingest.variation_identity` stored procedure. It consolidates all candidate variant expression sources — SPDI, HGVS, gnomAD, and location-derived HGVS — into a single table with a unified precedence ranking. For each variation+accession pair, only the highest-precedence source is retained. This table serves as the penultimate step before the final `variation_identity` table, which selects the single best expression per variation.

---

## Fields

| Field | Type | Description |
|---|---|---|
| `variation_id` | STRING | ClinVar variation identifier. |
| `assembly_version` | INT64 | Numeric assembly build number (e.g., `38`, `37`). NULL for transcript-based expressions. |
| `accession` | STRING | The sequence accession on which the source expression is defined. |
| `vrs_class` | STRING | The target VRS class for this variation (e.g., `Allele`, `CopyNumberCount`, `CopyNumberChange`, `Haplotype`, `Not Available`). |
| `absolute_copies` | INT64 | For `CopyNumberCount` variants, the absolute copy number. NULL for other VRS classes. |
| `range_copies` | ARRAY<INT64> | For `CopyNumberCount` variants with a copy number tuple, an array of copy number values defining the range. NULL for other VRS classes. |
| `fmt` | STRING | The format of the source expression. One of: `spdi`, `hgvs`, or `gnomad`. |
| `source` | STRING | The actual variant expression string used for VRS resolution. Content depends on `fmt`: an SPDI expression, an HGVS expression, or a gnomAD-formatted identifier. |
| `copy_change_type` | STRING | For `CopyNumberChange` variants, the direction of change: `loss` (for deletions and copy number losses) or `gain` (for duplications and copy number gains). NULL for other VRS classes. |
| `issue` | STRING | Any issue that would prevent successful VRS resolution. Aggregated from the source table's issue field or from the variation-level issue. NULL when no issue is detected. |
| `precedence` | INT64 | The source precedence rank (1 = highest priority). Values and their meanings: `1` = SPDI (genomic, GRCh38), `2` = HGVS genomic top-level, `3` = gnomAD location-derived, `4` = location-derived HGVS (fallback for non-precise regions), `5` = HGVS genomic (not top-level), `6` = HGVS coding MANE Select, `7` = HGVS coding MANE Plus Clinical, `8` = HGVS coding (non-MANE), `9` = HGVS other types (non-coding, etc.). |
| `hgvs_type` | STRING | The HGVS expression type from `variation_hgvs` (e.g., `genomic, top-level`, `coding`). NULL when the source is not HGVS-based or when no matching `variation_hgvs` row exists. |
| `consq_id` | STRING | Molecular consequence identifiers from `variation_hgvs` (e.g., `SO:0001583`). NULL when not available. |
| `consq_label` | STRING | Human-readable molecular consequence labels (e.g., `missense_variant`). NULL when not available. |
| `mane_select` | BOOL | Whether the accession is a MANE Select transcript. From `variation_hgvs`. |
| `mane_plus` | BOOL | Whether the accession is a MANE Plus Clinical transcript. From `variation_hgvs`. |
| `hgvs` | ARRAY<STRUCT<nucleotide STRING, protein STRING>> | The full array of HGVS expression pairs from `variation_hgvs`. NULL when the source is not HGVS-based or no matching row exists. |
| `chr` | STRING | Chromosome identifier from `variation_loc`. NULL when no matching location row exists. |
| `variant_length` | INT64 | Variant length as reported in `variation_loc`. NULL when no matching location row exists. |

---

## Row Granularity

One row per **variation_id + accession** combination. When multiple source types exist for the same variation+accession (e.g., both an SPDI and an HGVS expression on the same accession), only the row with the highest precedence (lowest precedence number) is retained.

---

## Precedence Hierarchy

The precedence ranking reflects a preference for the most reliable and normalized source:

1. **SPDI** — NCBI-normalized canonical form (GRCh38 only)
2. **HGVS genomic, top-level** — chromosomal-level HGVS from ClinVar
3. **gnomAD** — VCF-derived identifier from location coordinates
4. **Location-derived HGVS** — fallback HGVS built from positional data (used only when gnomAD format is not available)
5. **HGVS genomic** — non-top-level genomic accessions (e.g., alternate loci, patches)
6. **HGVS coding MANE Select** — transcript-level, MANE Select designated
7. **HGVS coding MANE Plus** — transcript-level, MANE Plus Clinical designated
8. **HGVS coding (other)** — transcript-level, non-MANE
9. **HGVS other** — remaining types (non-coding, etc.)

Within the same precedence level for a given variation+accession, ties are broken by the row-number windowing in the source query (first row wins).
