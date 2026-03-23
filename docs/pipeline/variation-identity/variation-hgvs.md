# variation_hgvs Table

## Overview

The `variation_hgvs` table is created by the `clinvar_ingest.variation_identity` stored procedure. It extracts and normalizes HGVS (Human Genome Variation Society) nomenclature expressions from ClinVar variation records, selecting the best representative expression per variation/accession pair when multiple representations exist.

---

## Fields

| Field | Type | Description |
|---|---|---|
| `variation_id` | STRING | ClinVar variation identifier.  |
| `accession` | STRING | The sequence accession version (e.g., `NC_000001.11`, `NM_000546.6`) on which the HGVS expression is defined. Extracted from the nucleotide expression's `sequence_accession_version`. |
| `type` | STRING | The HGVS expression type as classified by ClinVar. Common values include `genomic, top-level`, `genomic`, `coding`, and `non-coding`.  |
| `hgvs_source` | STRING | A cleaned version of the nucleotide HGVS expression used as input for VRS resolution. Cleaning includes removing appended numeric suffixes from deletion expressions (e.g., `del123` becomes `del`). |
| `issue` | STRING | A pre-identified issue that would prevent successful VRS resolution of this expression. Possible values include: unsupported accession prefix, repeat expressions, unbalanced parentheses, intronic positions, protein expressions, or a catch-all for any expression not matching known resolvable patterns. NULL when no issue is detected. |
| `assembly` | STRING | The genome assembly name (e.g., `GRCh38`, `GRCh37`). NULL for transcript-based (coding/non-coding) expressions that are not tied to a specific assembly. |
| `assembly_version` | INT64 | Numeric assembly build number extracted from the assembly string (e.g., `38`, `37`, `36`). Used for sorting and precedence; higher versions are preferred. NULL when `assembly` is NULL. |
| `consq_id` | STRING | Aggregated (comma-separated) molecular consequence identifiers from Sequence Ontology, formatted as `db:id` (e.g., `SO:0001583`). Multiple distinct consequences for the same variation/accession are concatenated. |
| `consq_label` | STRING | Aggregated (comma-separated) human-readable molecular consequence labels (e.g., `missense_variant`, `synonymous_variant`). |
| `mane_select` | BOOL | Whether this accession is designated as the MANE Select transcript for this gene. |
| `mane_plus` | BOOL | Whether this accession is designated as a MANE Plus Clinical transcript. |
| `has_range_endpoints` | BOOL | Whether the HGVS expression uses inner/outer range notation (e.g., `(123_456)_(789_012)del`) rather than precise start/stop coordinates. |
| `varlen_precedence` | INT64 | Assembly-based precedence rank for variant length derivation: `1` = GRCh38, `2` = GRCh37, `3` = GRCh36, `4` = other/NULL. Used when choosing the best length estimate across assemblies. |
| `derived_variant_length` | INT64 | The length of the variant derived from HGVS positional coordinates. Calculated as `end_pos - start_pos` for range expressions, or `1` (effectively `start + 1 - start`) for single-position variants. Used downstream to determine whether a deletion/duplication should be classified as an `Allele` (shorter, precise) or `CopyNumberChange` (longer or imprecise). |
| `expr` | ARRAY<STRUCT<nucleotide STRING, protein STRING>> | An array of all HGVS expression pairs for this variation/accession combination. Each element contains the full nucleotide expression and its corresponding protein expression (if available). This preserves all alternate representations even though only one `hgvs_source` is selected as the canonical representative. Ordered by protein expression descending (non-null protein expressions appear first). |

---

## Row Granularity

One row per **variation_id + accession** combination. When ClinVar provides multiple HGVS representations on the same accession for a single variation (e.g., both precise and ambiguous endpoint forms), the table selects the single best representative using a ranking that prefers: higher assembly version, presence of consequence annotations, balanced parentheses, protein expression availability, and shorter nucleotide expression length. All alternate expressions are preserved in the `expr` array field.

---

## Notes on the `expr` Array

### Alternative Nucleotide Expressions

In some cases, multiple HGVS nucleotide expressions exist for the same variation+accession pair. While the top-level `hgvs_source` field holds only the single best representative expression, the `expr` array retains all alternatives. To access these, unnest the `expr` field and examine `expr.nucleotide` values — when `ARRAY_LENGTH(expr) > 1`, the additional elements represent alternate nucleotide representations on the same accession.

### Protein Expressions

All HGVS protein expressions (p. notation) are found exclusively in the `expr.protein` fields. When multiple nucleotide expressions exist for a single variation+accession, only the primary (first) nucleotide expression will potentially have an associated protein expression. Secondary nucleotide expressions in the array will have NULL protein values.
