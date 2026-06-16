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
| `extensions` | array | ClinVar metadata and supplementary data. See [Extensions](#extensions) |

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

Extensions carry ClinVar-specific metadata not part of the core Cat-VRS specification. Each extension is a name/value pair. See [Categorical Variant Extensions](../pipeline/cat-vrs/catvar-extensions.md) for the complete reference with all extension types and custom structures.

Common extensions:

| Extension Name | Value Type | Description |
| --- | --- | --- |
| `categoricalVariationType` | string | The Cat-VRS type — `CanonicalAllele`, `CategoricalCnvChange`, `CategoricalCnvCount` |
| `clinvarVariationType` | string | ClinVar's variant type (e.g., `Deletion`, `single nucleotide variant`) |
| `clinvarSubclassType` | string | ClinVar's subclass type (e.g., `SimpleAllele`, `Haplotype`) |
| `clinvarCytogeneticLocation` | string | Chromosomal band location (e.g., `1p36.22`) |
| `clinvarGeneList` | array | Gene associations with `#/gene/` references, relationship type, and source |
| `clinvarHgvsList` | array | All HGVS expressions with molecular consequences and MANE designations |

---

## Examples

Annotated JSONC examples of variation records are available in the repository:

- [Cat-VRS examples](https://github.com/clingen-data-model/clinvar-gks/tree/main/examples/cat-vrs) — CanonicalAllele records for ClinVar variations
