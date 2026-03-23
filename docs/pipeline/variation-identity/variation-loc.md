# Sequence Locations (variation_loc)

## Overview

The `variation_loc` table is created by the `clinvar_ingest.variation_identity` stored procedure. It extracts and normalizes sequence location data from ClinVar variation records, deriving both gnomAD-formatted identifiers and HGVS expressions from the positional coordinates provided in each variant's `Location` element. Each row represents a single sequence location for a given variation on a specific accession.

---

## Fields

<div class="field-table" markdown>

| Field | Type | Description |
|---|---|---|
| `variation_id` | string | ClinVar variation identifier. |
| `variation_type` | string | The type of variation as classified by ClinVar (e.g., `single nucleotide variant`, `Deletion`, `Duplication`, `copy number gain`, `copy number loss`). Carried forward from the source variation record. |
| `accession` | string | The sequence accession (e.g., `NC_000001.11`) on which this location is defined. Only locations with a non-null accession are included. |
| `assembly` | string | The genome assembly name (e.g., `GRCh38`, `GRCh37`). |
| `assembly_version` | int64 | Numeric assembly build number extracted from the assembly string (e.g., `38`, `37`). |
| `chr` | string | The chromosome identifier (e.g., `1`, `X`, `MT`). Locations where `chr` is `Un` (unknown) have their `gnomad_source` set to NULL. |
| `start` | int64 | Precise start position on the sequence (0-based or 1-based per ClinVar convention). NULL for locations that only have inner/outer range endpoints. |
| `stop` | int64 | Precise stop position on the sequence. NULL for locations that only have inner/outer range endpoints. |
| `inner_start` | int64 | Inner start position for imprecise structural variant locations. |
| `inner_stop` | int64 | Inner stop position for imprecise structural variant locations. |
| `outer_start` | int64 | Outer start position for imprecise structural variant locations. |
| `outer_stop` | int64 | Outer stop position for imprecise structural variant locations. |
| `variant_length` | int64 | The variant length as explicitly reported by ClinVar in the location element. May be NULL. |
| `position_vcf` | int64 | VCF-style position for the variant. |
| `reference_allele_vcf` | string | VCF-style reference allele. |
| `alternate_allele_vcf` | string | VCF-style alternate allele. |
| `gnomad_source` | string | A gnomAD-formatted variant identifier derived from VCF fields, in the format `chr-position_vcf-ref-alt` (e.g., `1-12345-A-G`). NULL when any required component is missing or when the chromosome is `Un`. |
| `loc_hgvs_source` | string | An HGVS expression derived from the location's positional data using the `clinvar_ingest.deriveHGVS` function. Only populated when an accession is present. This provides a fallback HGVS expression for variants that lack one in the HGVS list. |
| `loc_hgvs_issue` | string | A pre-identified issue with the derived `loc_hgvs_source` expression. Currently flags accessions with prefixes not supported by vrs-python. NULL when no issue is detected. |
| `varlen_precedence` | int64 | Assembly-based precedence rank for variant length derivation: `1` = GRCh38, `2` = GRCh37, `3` = GRCh36. Used when choosing the best length estimate across assemblies. |
| `has_range_endpoints` | boolean | Whether any inner/outer range endpoint is present (i.e., the location uses imprecise coordinates rather than exact start/stop). |
| `derived_variant_length` | int64 | Variant length calculated from available positional data. Uses `variant_length` if provided, otherwise falls back to `stop - start`, then `inner_stop - inner_start`, then `outer_stop - outer_start`. |
| `derived_start` | string | A string representation of the start position. For precise locations this is the `start` value as a string. For imprecise locations it is formatted as `[outer_start, inner_start]` with nulls shown as `null`. |
| `derived_stop` | string | A string representation of the stop position. For precise locations this is the `stop` value as a string. For imprecise locations it is formatted as `[inner_stop, outer_stop]` with nulls shown as `null`. |

</div>

---

## Row Granularity

One row per **variation_id + accession + assembly** combination. A single variation may have multiple rows when ClinVar provides locations on multiple assemblies (e.g., GRCh38 and GRCh37) or on multiple accessions (e.g., chromosomal and alternate loci). Only locations with a non-null accession are included.

---

## Notes

The `gnomad_source` and `loc_hgvs_source` fields are complementary derivations from the same positional data. The `gnomad_source` is available for simple variants with VCF-style representation, while `loc_hgvs_source` is derived for all variants with an accession. During expression source consolidation, the `loc_hgvs_source` is only used as a fallback when `gnomad_source` is not available (see [Precedence Hierarchy](index.md#precedence-hierarchy)).
