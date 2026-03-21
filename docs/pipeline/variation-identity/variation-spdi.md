# variation_spdi Table

## Overview

The `variation_spdi` table is created by the `clinvar_ingest.variation_identity` stored procedure. It captures the canonical SPDI (Sequence Position Deletion Insertion) expression for variations that have one provided by ClinVar. SPDI is NCBI's normalized variant representation format and is the highest-precedence source used for VRS resolution in the downstream `variation_members` table.

---

## Fields

| Field | Type | Description |
|---|---|---|
| `variation_id` | STRING | ClinVar variation identifier. |
| `assembly` | STRING | Always `GRCh38`. ClinVar canonical SPDI expressions are provided on the GRCh38 assembly. |
| `assembly_version` | INT64 | Always `38`. Numeric assembly build number, consistent with the assembly field. |
| `accession` | STRING | The sequence accession extracted from the SPDI expression (the portion before the first `:`). For example, `NC_000001.11` from `NC_000001.11:12345:A:G`. |
| `spdi_source` | STRING | The full canonical SPDI expression as provided by ClinVar (e.g., `NC_000001.11:12345:A:G`). This is the raw expression used as input for VRS resolution. |

---

## Row Granularity

One row per **variation_id**. Only variations that have a non-null `canonical_spdi` value in ClinVar are represented. This typically covers simple alleles (SNVs, small insertions, small deletions) where NCBI has been able to compute a canonical SPDI form.

---

## Notes

SPDI expressions are the preferred source for VRS resolution because they are already normalized by NCBI. In the `variation_members` precedence hierarchy, SPDI sources are ranked at precedence `1`, ahead of all HGVS and gnomAD-derived sources.
