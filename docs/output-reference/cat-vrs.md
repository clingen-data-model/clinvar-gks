# Categorical Variants

## Overview

The `variation.jsonl.gz` file contains one JSON record per ClinVar variation that successfully resolved to a VRS identity. Each record is a `CategoricalVariant` conforming to the Cat-VRS specification — a higher-level grouping that associates a ClinVar variation with its resolved VRS allele or copy number variant, along with expressions, cross-references, and ClinVar metadata.

This file is produced by the [Cat-VRS procedure](../pipeline/cat-vrs/index.md).

---

## Record Structure

Each record is a `CategoricalVariant` with the following top-level fields:

<div class="field-table" markdown>

| Field | Type | Description |
| --- | --- | --- |
| `id` | string | ClinVar-scoped identifier — `clinvar:{variation_id}` |
| `type` | string | Always `CategoricalVariant` |
| `name` | string | Best available HGVS expression for the variant |
| `constraints` | array | Defining constraints linking to the resolved VRS variant. See [Constraints](#constraints) |
| `mappings` | array | Cross-references to external databases. See [Mappings](#mappings) |
| `members` | array | JSON pointer references to the defining allele within `constraints` |
| `extensions` | array | ClinVar metadata and supplementary data. See [Extensions](#extensions) |

</div>

---

## Constraints

The `constraints` array defines the relationship between the categorical variant and its resolved VRS representation. The constraint type depends on the variant class:

| Categorical Type | Constraint Type | Key Fields |
| --- | --- | --- |
| `CanonicalAllele` | `DefiningAlleleConstraint` | `allele` — a VRS `Allele` with `id`, `location`, `state`, and `expressions` |
| `CategoricalCnvChange` | `DefiningLocationConstraint` + `CopyChangeConstraint` | `location` — a VRS `SequenceLocation`; `copyChange` — gain/loss designation |
| `CategoricalCnvCount` | `DefiningLocationConstraint` + `CopyCountConstraint` | `location` — a VRS `SequenceLocation`; `copies` — integer or range |

### Allele Constraint Example

The `DefiningAlleleConstraint` contains a fully resolved VRS `Allele`:

```json
{
  "type": "DefiningAlleleConstraint",
  "allele": {
    "id": "ga4gh:VA.PN-6_l2_yI1UPBRCtFnWkR52iZXKVJ8b",
    "type": "Allele",
    "name": "NC_000001.11:g.11128044_11128045del",
    "digest": "PN-6_l2_yI1UPBRCtFnWkR52iZXKVJ8b",
    "location": {
      "id": "ga4gh:SL.5-SKfXZ941W7JbZW3UmQKtijyUfd6d7z",
      "type": "SequenceLocation",
      "sequenceReference": {
        "type": "SequenceReference",
        "refgetAccession": "SQ.Ya6Rs7DHhDeg7YaOSg1EoNi3U_nQ9SvO",
        "residueAlphabet": "na",
        "molecularType": "genomic"
      },
      "start": 11128043,
      "end": 11128045
    },
    "state": {
      "type": "ReferenceLengthExpression",
      "length": 0,
      "sequence": "",
      "repeatSubunitLength": 2
    },
    "expressions": [
      { "syntax": "hgvs.g", "value": "NC_000001.11:g.11128044_11128045del" },
      { "syntax": "spdi", "value": "NC_000001.11:11128043:AT:ATAT" },
      { "syntax": "gnomad", "value": "1-11128043-CAT-C" }
    ]
  }
}
```

---

## Mappings

The `mappings` array contains cross-references to external databases. Each mapping includes a `coding` (database, identifier, IRIs) and a `relation`:

| Relation | Meaning |
| --- | --- |
| `exactMatch` | The ClinVar self-reference — links back to the ClinVar variation page |
| `closeMatch` | ClinGen allele registry identifiers |
| `relatedMatch` | All other external databases (dbSNP, OMIM, UniProtKB, GTR, PharmGKB, etc.) |

### Example

```json
{
  "coding": {
    "system": "https://www.ncbi.nlm.nih.gov/snp",
    "code": "rs1570942058",
    "iris": [
      "https://identifiers.org/dbsnp:rs1570942058",
      "https://www.ncbi.nlm.nih.gov/snp/rs1570942058"
    ]
  },
  "relation": "relatedMatch"
}
```

---

## Extensions

Extensions carry ClinVar-specific metadata not part of the core Cat-VRS specification. Each extension is a name/value pair. See [Categorical Variant Extensions](../pipeline/cat-vrs/catvar-extensions.md) for the complete reference with all extension types and custom structures.

Common extensions:

| Extension Name | Value Type | Description |
| --- | --- | --- |
| `categorical variation type` | string | The Cat-VRS type — `CanonicalAllele`, `CategoricalCnvChange`, `CategoricalCnvCount` |
| `clinvar variation type` | string | ClinVar's variant type (e.g., `Deletion`, `single nucleotide variant`) |
| `clinvar variation subtype` | string | ClinVar's subclass type (e.g., `SimpleAllele`, `Haplotype`) |
| `clinvar cytogenetic location` | string | Chromosomal band location (e.g., `1p36.22`) |
| `clinvar assembly` | string | Reference genome assembly (e.g., `GRCh38`) |
| `hgvs list` | array | All HGVS expressions with molecular consequences and MANE designations |
