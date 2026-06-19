# GeneListItem

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A complex structure for sharing individual Gene entries associated with Clinvar Variations including `entrez_gene_id`, `hgnc_id`, `symbol`, `relationship_type`, `source`, and `iris`.

**JSON Schema:** [GeneListItem](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/GeneListItem){ target=_blank }

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `entrez_gene_id` | `string` | 0..1 | NCBI Entrez Gene identifier. |
| `hgnc_id` | `string` | 0..1 | HGNC gene identifier (e.g., `HGNC:1234`). May be null for genes without an HGNC assignment. |
| `symbol` | `string` | 0..1 | The gene symbol (e.g., `BRCA1`, `MTOR`). |
| `relationship_type` | `string` | 0..1 | The relationship between the variation and the gene as reported by ClinVar (e.g.,  `within single gene`, `genes overlapped by variant`). |
| `source` | `string` | 0..1 | The source of the gene association (e.g., `submitted`, `calculated`). |
| `iris` | [iriReference](iriReference.md)[] (unordered) | 0..m | Identifier IRIs for the gene, including links to identifiers.org (HGNC and/or NCBI Gene) and NCBI Gene pages.         |

