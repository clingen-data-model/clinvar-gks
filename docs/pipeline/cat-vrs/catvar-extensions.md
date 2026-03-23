# Categorical Variant Extensions

## Overview

Categorical variant records contain `extensions` arrays at multiple levels of the JSON structure. Extensions carry ClinVar-specific information, VRS processing details, and linked data that are not part of the GA4GH Cat-VRS specification but are essential for clinical interpretation.

All extensions follow the structure `{ "name": "<extension_name>", "value": <value> }`, where the value type varies by extension. Most extensions carry simple scalar values (string, boolean, etc.). Extensions with complex value types — arrays of structured objects — are documented as custom extension structures in a [dedicated section](#custom-extension-structures) below.

---

## CategoricalVariant Extensions

Extensions on the top-level `CategoricalVariant` record.

<div class="field-table" markdown>

| Extension | Type | Description |
|---|---|---|
| `categoricalVariationType` | string | The Cat-VRS category assigned to this variation: `CanonicalAllele`, `CategoricalCnvChange`, `CategoricalCnvCount`, or `Non-Constrained`. Determines which constraint types are generated. |
| `definingVrsVariationType` | string | The VRS class assigned during variation identity processing (e.g., `Allele`, `CopyNumberChange`, `CopyNumberCount`, `Not Available`). Reflects the upstream classification used to route the variant through VRS processing. |
| `clinvarVariationType` | string | The variation type as reported by ClinVar (e.g., `Deletion`, `single nucleotide variant`, `Duplication`, `Indel`). Present when ClinVar provides a variation type. |
| `clinvarSubclassType` | string | The variation subclass as reported by ClinVar (e.g., `SimpleAllele`, `Haplotype`, `CompoundHeterozygote`). Present when ClinVar provides a subclass type. |
| `clinvarCytogeneticLocation` | string | The cytogenetic band location of the variation (e.g., `1p36.22`, `17q21.31`). Present when ClinVar provides a cytogenetic location. |
| `vrsPreProcessingIssue` | string | Issues detected during VRS pre-processing of the variation's input expressions. Present only when issues exist. May contain multiple issues separated by newlines. |
| `vrsProcessingException` | string | Errors returned by the external VRS Python processing service. Present only when errors occurred during VRS resolution. |
| `clinvarHgvsList` | array<br/>[HgvsListItem](#hgvs-list) | Complete list of HGVS expressions from ClinVar for this variation, including nucleotide and protein expressions, molecular consequences (SO terms), and MANE transcript designations. See [HGVS List](#hgvs-list) custom extension structure below. |
| `clinvarGeneList` | array<br/>[GeneListItem](#gene-list) | Gene associations for this variation from ClinVar, including Entrez gene IDs, HGNC IDs, gene symbols, relationship types, and identifier IRIs. See [Gene List](#gene-list) custom extension structure below. |

</div>

### Example

A complete `extensions` array for a successfully resolved CategoricalVariant:

```json
[
  { "name": "categoricalVariationType", "value": "CanonicalAllele" },
  { "name": "definingVrsVariationType", "value": "Allele" },
  { "name": "clinvarVariationType", "value": "Deletion" },
  { "name": "clinvarSubclassType", "value": "SimpleAllele" },
  { "name": "clinvarCytogeneticLocation", "value": "1p36.22" },
  {
    "name": "clinvarHgvsList",
    "value": [
      {
        "nucleotideExpression": { "syntax": "hgvs.c", "value": "NM_004958.4:c.5992_5993del" },
        "nucleotideType": "coding",
        "maneSelect": true,
        "proteinExpression": { "syntax": "hgvs.p", "value": "NP_004949.3:p.Met1998fs" },
        "molecularConsequence": [
          {
            "name": "frameshift_variant",
            "system": "http://www.sequenceontology.org/browser/",
            "code": "SO:0001589",
            "iris": ["http://www.sequenceontology.org/browser/release_2.5.3/term/SO:0001589"]
          }
        ]
      },
      {
        "nucleotideExpression": { "syntax": "hgvs.g", "value": "NC_000001.11:g.11128044_11128045del" },
        "nucleotideType": "genomic, top-level"
      },
      {
        "nucleotideExpression": { "syntax": "hgvs.g", "value": "NC_000001.10:g.11188101_11188102del" },
        "nucleotideType": "genomic, top-level"
      }
    ]
  },
  {
    "name": "clinvarGeneList",
    "value": [
      {
        "entrez_gene_id": "2475",
        "hgnc_id": "HGNC:3942",
        "symbol": "MTOR",
        "relationship_type": "within single gene",
        "source": "calculated",
        "iris": [
          "https://identifiers.org/hgnc:3942",
          "https://www.ncbi.nlm.nih.gov/gene/2475"
        ]
      }
    ]
  }
]
```

When VRS processing issues are present, the error extensions appear alongside the classification extensions:

```json
[
  { "name": "categoricalVariationType", "value": "Non-Constrained" },
  { "name": "definingVrsVariationType", "value": "Not Available" },
  { "name": "clinvarVariationType", "value": "Microsatellite" },
  { "name": "clinvarSubclassType", "value": "SimpleAllele" },
  { "name": "vrsPreProcessingIssue", "value": "HGVS expression not valid: repeat expression" },
  { "name": "vrsProcessingException", "value": "Unable to resolve variant expression" }
]
```

---

## SequenceReference Extensions

Extensions on `SequenceReference` objects nested within `constraints[].allele.location.sequenceReference` and `members[].location.sequenceReference`.

<div class="field-table" markdown>

| Extension | Type | Description |
|---|---|---|
| `assembly` | string | The genome assembly name for this sequence reference (e.g., `GRCh38`, `GRCh37`, `NCBI36`). |

</div>

### Example

```json
{
  "type": "SequenceReference",
  "refgetAccession": "SQ.Ya6Rs7DHhDeg7YaOSg1EoNi3U_nQ9SvO",
  "residueAlphabet": "na",
  "molecularType": "genomic",
  "extensions": [
    { "name": "assembly", "value": "GRCh38" }
  ]
}
```

---

## Custom Extension Structures

Extensions with complex value types use structured objects rather than simple scalars. The structures below define the shape of each custom extension's `value` field.

### HGVS List

The `clinvarHgvsList` extension contains an array of HGVS expression objects, each representing one expression entry from ClinVar's `HGVSlist` element for the variation. Each object may contain:

<div class="field-table" markdown>

| Field | Type | Description |
|---|---|---|
| `nucleotideExpression` | object | The nucleotide HGVS expression with `syntax` (e.g., `hgvs.c`, `hgvs.g`) and `value` (the HGVS string). |
| `nucleotideType` | string | The type of nucleotide expression as reported by ClinVar (e.g., `coding`, `genomic`, `genomic, top-level`). |
| `maneSelect` | boolean | `true` if this transcript is designated as MANE Select. Absent when not applicable. |
| `manePlus` | boolean | `true` if this transcript is designated as MANE Plus Clinical. Absent when not applicable. |
| `proteinExpression` | object | The protein HGVS expression with `syntax` (typically `hgvs.p`) and `value`. Present only when a protein-level expression exists for the nucleotide expression. |
| `molecularConsequence` | array | Sequence Ontology terms describing the predicted molecular consequence. Each entry includes `code` (SO identifier), `system`, `name` (SO term label), and `iris` (identifiers.org link). |

</div>

### Gene List

The `clinvarGeneList` extension contains an array of gene association objects. Each object includes:

<div class="field-table" markdown>

| Field | Type | Description |
|---|---|---|
| `entrez_gene_id` | string | NCBI Entrez Gene identifier. |
| `hgnc_id` | string | HGNC gene identifier (e.g., `HGNC:1234`). May be null for genes without an HGNC assignment. |
| `symbol` | string | The gene symbol (e.g., `BRCA1`, `MTOR`). |
| `relationship_type` | string | The relationship between the variation and the gene as reported by ClinVar (e.g., `within single gene`, `genes overlapped by variant`). |
| `source` | string | The source of the gene association (e.g., `submitted`, `calculated`). |
| `iris` | array | Identifier IRIs for the gene, including links to identifiers.org (HGNC and/or NCBI Gene) and NCBI Gene pages. |

</div>
