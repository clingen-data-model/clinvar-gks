# HgvsListItem

!!! info "Trial Use"

    This data class is at a **trial use** maturity level and may change in future releases. Maturity levels are described in the [GKS Maturity Model](https://vrs.ga4gh.org/en/2.0/appendices/maturity_model.html#maturity-model).

A complex structure for sharing individual HGVS entries associated with Clinvar Variations including nucleotide expressions, protein expressions, molecular consequence and mane select/plus settings for the specific aligned and projected forms of the clinvar variant.

**JSON Schema:** [HgvsListItem](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/HgvsListItem){ target=_blank }

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `nucleotideExpression` | `Expression` | 0..1 | The nucleotide HGVS expression with `syntax` (e.g.,` hgvs.c`, `hgvs.g`)  and `value` (the HGVS string).  |
| `nucleotideType` | `string` | 0..1 | The type of nucleotide expression as reported by ClinVar (e.g., `coding`,  `genomic`, `genomic, top-level`). |
| `maneSelect` | `boolean` | 0..1 | `true` if this transcript is designated as MANE Select. Absent or `false` when  not applicable. |
| `manePlus` | `boolean` | 0..1 | `true` if this transcript is designated as MANE Plus Clinical. Absent or `false`  when not applicable. |
| `proteinExpression` | `Expression` | 0..1 | The protein HGVS expression with syntax (typically `hgvs.p`) and `value`. Present  only when a protein-level expression exists for the nucleotide expression. |
| `molecularConsequence` | `Coding`[] (unordered) | 0..m | Sequence Ontology terms describing the predicted molecular consequence.  Each entry includes `code` (SO identifier), `system`, `name` (SO term label),  and `iris` (identifiers.org link). |

