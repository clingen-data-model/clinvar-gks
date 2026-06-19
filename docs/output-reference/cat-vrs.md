# Variations

## Overview

The `variation` bundle section contains one record per ClinVar variation. Each record represents a ClinVar variation and its relationship to a resolved VRS genomic identity, along with expressions, cross-references, gene associations, and ClinVar metadata.

ClinVar variations are represented using the GA4GH [Cat-VRS](https://cat-vrs.readthedocs.io/) (Categorical Variation) specification. Cat-VRS defines categorical variant types that group variants at a higher level than individual VRS alleles — bridging the gap between ClinVar's variation concept and VRS's precise genomic representations.

This section is produced by the [Cat-VRS procedure](../pipeline/cat-vrs/index.md).

### Variation Types

ClinVar variations map to three Cat-VRS representation types:

- **CanonicalAllele** — The vast majority of ClinVar variations. ClinVar identifies each variation by mapping submitted variant attributes to a GRCh38 genomic allele (falling back to GRCh37 or NCBI36 for historical data). This *defining allele* becomes the `DefiningAlleleConstraint`, and the same genomic allele generates the VRS allele referenced via `#/allele/`. See the [Cat-VRS CanonicalAllele](https://cat-vrs.readthedocs.io/) specification.

- **CategoricalCnvCount / CategoricalCnvChange** — Copy number variants use a `DefiningLocationConstraint` following the same identification approach, with an additional `CopyCountConstraint` when an absolute copy count is provided, or a `CopyChangeConstraint` when only gain/loss is indicated.

- **Generalized Categorical Variant** — Haplotypes, genotypes, and other complex or ambiguously defined variants that cannot yet be mapped to a specific VRS allele or location. These rely solely on the ClinVar variation ID to distinguish them. Work continues within the GA4GH GKS workstream to expand VRS and Cat-VRS coverage for these types as community need arises.

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
| `members` | array | `#/allele/` references to the defining VRS allele (empty for generalized variants) |
| `extensions` | array of [Extension](#extensions) | ClinVar-specific metadata and supplementary data (0..*). See [Extensions](#extensions) |

</div>

---

## Constraints

The `constraints` array defines the relationship between the variation and its resolved VRS representation. The constraint type depends on the variant class:

| Variation Type | Constraint Type | Key Fields |
| --- | --- | --- |
| CanonicalAllele | `DefiningAlleleConstraint` | `allele` — `#/allele/{id}` reference to a VRS Allele |
| CategoricalCnvChange | `DefiningLocationConstraint` + `CopyChangeConstraint` | `location` — `#/location/{id}` reference; `copyChange` — gain/loss |
| CategoricalCnvCount | `DefiningLocationConstraint` + `CopyCountConstraint` | `location` — `#/location/{id}` reference; `copies` — integer or range |
| Generalized | None | No VRS constraint — identified by ClinVar variation ID only |

### Allele Constraint Example

The `DefiningAlleleConstraint` references a VRS Allele in the `allele` bundle section:

```json
{
  "type": "DefiningAlleleConstraint",
  "allele": "#/allele/ga4gh:VA.ELQCnIBGqaTl0AEE0Az18XZ2cgIHAQIY",
  "relations": [
    { "primaryCoding": { "code": "liftover_to", "system": "ga4gh-gks-term:allele-relation" } },
    { "primaryCoding": { "code": "transcribed_to", "system": "http://www.sequenceontology.org" } }
  ]
}
```

### Location Constraint Example

The `DefiningLocationConstraint` for copy number variants references a VRS Location:

```json
{
  "type": "DefiningLocationConstraint",
  "location": "#/location/ga4gh:SL.5-SKfXZ941W7JbZW3UmQKtijyUfd6d7z",
  "matchCharacteristic": {
    "primaryCoding": { "code": "is_within", "system": "ga4gh-gks-term:location-match" }
  },
  "relations": [
    { "primaryCoding": { "code": "liftover_to", "system": "ga4gh-gks-term:allele-relation" } }
  ]
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
    "system": "dbSNP",
    "code": "1799945",
    "iris": ["https://identifiers.org/dbsnp:rs1799945"]
  },
  "relation": "relatedMatch"
}
```

---

## Extensions

Extensions carry ClinVar-specific metadata not part of the core Cat-VRS specification. Each extension follows the GA4GH Extension structure: `{ "name": "<name>", "value": <value> }`. Extensions appear at two structural levels — on the top-level `CategoricalVariant` record and on nested `SequenceReference` objects.

See [Categorical Variant Extensions (Pipeline)](../pipeline/cat-vrs/catvar-extensions.md) for details on how these extensions are built during pipeline processing.

### CategoricalVariant Extensions

<div class="field-table" markdown>

| Extension Name | Value Type | Description |
|---|---|---|
| `categoricalVariationType` | `string` | The Cat-VRS category assigned to this variation: `CanonicalAllele`, `CategoricalCnvChange`, `CategoricalCnvCount`, or `Non-Constrained`. Determines which constraint types are generated. |
| `definingVrsVariationType` | `string` | The VRS class assigned during variation identity processing (e.g., `Allele`, `CopyNumberChange`, `CopyNumberCount`, `Not Available`). Reflects the upstream classification used to route the variant through VRS processing. |
| `clinvarVariationType` | `string` | The variation type as reported by ClinVar (e.g., `Deletion`, `single nucleotide variant`, `Duplication`, `Indel`). Present when ClinVar provides a variation type. |
| `clinvarSubclassType` | `string` | The variation subclass as reported by ClinVar (e.g., `SimpleAllele`, `Haplotype`, `CompoundHeterozygote`). Present when ClinVar provides a subclass type. |
| `clinvarCytogeneticLocation` | `string` | The cytogenetic band location of the variation (e.g., `1p36.22`, `17q21.31`). Present when ClinVar provides a cytogenetic location. |
| `vrsPreProcessingIssue` | `string` | Issues detected during VRS pre-processing of the variation's input expressions. Present only when issues exist. May contain multiple issues separated by newlines. |
| `vrsProcessingException` | `string` | Errors returned by the external VRS Python processing service. Present only when errors occurred during VRS resolution. |
| `clinvarHgvsList` | array of [HgvsListItem](#hgvslistitem) | Complete list of HGVS expressions from ClinVar for this variation, including nucleotide and protein expressions, molecular consequences (SO terms), and MANE transcript designations. |
| `clinvarGeneList` | array of [GeneListItem](#genelistitem) | Gene associations for this variation from ClinVar, including Entrez gene IDs, HGNC IDs, gene symbols, relationship types, and identifier IRIs. |

</div>

### SequenceReference Extensions

Extensions on `SequenceReference` objects nested within `constraints[].allele.location.sequenceReference` and `members[].location.sequenceReference`.

<div class="field-table" markdown>

| Extension Name | Value Type | Description |
|---|---|---|
| `assembly` | `string` | The genome assembly name for this sequence reference (e.g., `GRCh38`, `GRCh37`, `NCBI36`). |

</div>

### HgvsListItem

Each item in the `clinvarHgvsList` extension array represents one HGVS expression entry from ClinVar's `HGVSlist` element for the variation.

<div class="field-table" markdown>

| Field | Type | Description |
|---|---|---|
| `nucleotideExpression` | object | The nucleotide HGVS expression with `syntax` (e.g., `hgvs.c`, `hgvs.g`) and `value` (the HGVS string). |
| `nucleotideType` | `string` | The type of nucleotide expression as reported by ClinVar (e.g., `coding`, `genomic`, `genomic, top-level`). |
| `maneSelect` | `boolean` | `true` if this transcript is designated as MANE Select. Absent when not applicable. |
| `manePlus` | `boolean` | `true` if this transcript is designated as MANE Plus Clinical. Absent when not applicable. |
| `proteinExpression` | object | The protein HGVS expression with `syntax` (typically `hgvs.p`) and `value`. Present only when a protein-level expression exists for the nucleotide expression. |
| `molecularConsequence` | array | Sequence Ontology terms describing the predicted molecular consequence. Each entry includes `code` (SO identifier), `system`, `name` (SO term label), and `iris` (identifiers.org link). |

</div>

### GeneListItem

Each item in the `clinvarGeneList` extension array represents one gene association for the variation.

<div class="field-table" markdown>

| Field | Type | Description |
|---|---|---|
| `entrez_gene_id` | `string` | NCBI Entrez Gene identifier. |
| `hgnc_id` | `string` | HGNC gene identifier (e.g., `HGNC:1234`). May be null for genes without an HGNC assignment. |
| `symbol` | `string` | The gene symbol (e.g., `BRCA1`, `MTOR`). |
| `relationship_type` | `string` | The relationship between the variation and the gene as reported by ClinVar (e.g., `within single gene`, `genes overlapped by variant`). |
| `source` | `string` | The source of the gene association (e.g., `submitted`, `calculated`). |
| `iris` | array | Identifier IRIs for the gene, including links to identifiers.org (HGNC and/or NCBI Gene) and NCBI Gene pages. |

</div>

---

## Examples

Annotated JSONC examples of variation records are available in the repository:

- [Cat-VRS examples](https://github.com/clingen-data-model/clinvar-gks/tree/main/examples/cat-vrs) — CanonicalAllele records for ClinVar variations
