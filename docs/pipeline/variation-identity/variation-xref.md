# Cross-References (variation_xref)

## Overview

The `variation_xref` table is created by the `clinvar_ingest.variation_identity` stored procedure. It extracts cross-reference (XRef) entries from ClinVar variation records, providing links to external databases that have catalogued the same or related variants.

---

## Fields

<div class="field-table" markdown>

| Field | Type | Description |
|---|---|---|
| `variation_id` | string | ClinVar variation identifier. |
| `db` | string | The name of the external database (e.g., `ClinGen`, `dbSNP`, `OMIM`, `UniProtKB`). Parsed from the XRef list in the variation's XML content. |
| `id` | string | The identifier assigned to this variant in the external database (e.g., a ClinGen allele registry ID, an rsID). |
| `type` | string | The type or category of the cross-reference as provided by ClinVar. |

</div>

---

## Row Granularity

One row per **variation_id + external reference** combination. A single variation may have zero, one, or many cross-references across different external databases.

---

## Notes

The cross-references are parsed from the `XRefList` element of each variation's content using the `clinvar_ingest.parseXRefs` UDF. Downstream, the `variation_identity` table consumes these cross-references to build a `mappings` array, where ClinGen references are assigned a `closeMatch` relation and all other databases are assigned `relatedMatch`.
