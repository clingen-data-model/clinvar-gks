# Variation Identity Table (variation_identity)

## Overview

The `variation_identity` table is the final output of the `clinvar_ingest.variation_identity` stored procedure. It provides a single row per ClinVar variation, containing the best available expression source for VRS resolution along with variation metadata. This table is the primary input for downstream VRS processing and GKS pipeline steps.

---

## Fields

<div class="field-table" markdown>

| Field | Type | Description |
|---|---|---|
| `variation_id` | string | ClinVar variation identifier. Every variation in ClinVar is represented, regardless of whether a viable expression source was found. |
| `name` | string | The ClinVar display name for the variation (e.g., `NM_000546.6(TP53):c.743G>A (p.Arg248Gln)`). |
| `assembly_version` | int64 | Numeric assembly build number of the selected expression source (e.g., `38`, `37`). NULL for transcript-based expressions or when no source was identified. |
| `accession` | string | The sequence accession of the selected expression source. NULL when no viable source was identified. |
| `vrs_class` | string | The target VRS class for this variation. One of: `Allele`, `CopyNumberCount`, `CopyNumberChange`, `Haplotype`, `Not Available`, or `Unknown`. Defaults to `Unknown` when neither the member nor the variation-level classification could determine a class. |
| `absolute_copies` | int64 | For `CopyNumberCount` variants, the absolute copy number. NULL for other VRS classes. |
| `range_copies` | array&lt;int64&gt; | For `CopyNumberCount` variants with a copy number tuple, an array of copy number values. NULL for other VRS classes. |
| `fmt` | string | The format of the selected source expression: `spdi`, `hgvs`, or `gnomad`. NULL when no viable source was identified. |
| `source` | string | The actual variant expression string selected for VRS resolution. NULL when no viable source was identified. |
| `copy_change_type` | string | For `CopyNumberChange` variants, the direction of change: `loss` or `gain`. NULL for other VRS classes. |
| `issue` | string | Any issue preventing VRS resolution. Sources include: expression-level issues (unsupported accession, intronic positions, etc.), variation-level issues (unsupported subtypes), or the fallback message `No viable variation members identified.` when no candidate sources exist. NULL when the variation can be resolved. |
| `precedence` | int64 | The precedence rank of the selected source (1–9). See [Precedence Hierarchy](index.md#precedence-hierarchy) for the full ranking. NULL when no source was selected. |
| `variation_type` | string | The ClinVar variation type (e.g., `single nucleotide variant`, `Deletion`, `Duplication`, `copy number gain`, `copy number loss`, `Insertion`, `Indel`, `Microsatellite`). |
| `subclass_type` | string | The ClinVar variation subclass (e.g., `SimpleAllele`, `Haplotype`, `Genotype`). |
| `cytogenetic` | string | The cytogenetic location (e.g., `17p13.1`). NULL when not provided by ClinVar. |
| `chr` | string | Chromosome identifier from the selected location source (e.g., `1`, `X`, `MT`). NULL when no location data is available. |
| `variant_length` | int64 | Variant length from the selected location source. NULL when not available. |
| `mappings` | array<br/>[Mapping](#mapping) | Cross-references to external databases. NULL when no cross-references exist. |

</div>

---

## Row Granularity

One row per **variation_id**. Every ClinVar variation is represented exactly once. The selected expression source is the highest-precedence candidate from the consolidated expression sources (see [Precedence Hierarchy](index.md#precedence-hierarchy)), with ties broken by descending assembly version, issue status (NULL issues preferred), and accession.

---

## Mapping

Each element in the `mappings` array is a struct with the following fields:

<div class="field-table" markdown>

| Field | Type | Description |
|---|---|---|
| `system` | string | The external database name (e.g., `ClinGen`, `dbSNP`, `OMIM`, `UniProtKB`) |
| `code` | string | The identifier in the external database (e.g., a ClinGen allele registry ID, an rsID) |
| `relation` | string | The match relation — `closeMatch` for ClinGen, `relatedMatch` for all others |

</div>

---

## Notes

Variations without any viable expression source still appear in this table with NULL values for `accession`, `fmt`, `source`, and related fields. The `issue` field will indicate why no source could be selected. This ensures that all ClinVar variations are accounted for in downstream processing, even those that cannot be resolved to a VRS representation.
