# Variations

ClinVar variations are represented using the GA4GH [Cat-VRS](https://cat-vrs.readthedocs.io/) (Categorical Variation) specification. Each variation maps to one of three Cat-VRS types depending on how ClinVar resolves the variant's genomic identity.

The [ClinvarCategoricalVariant](ClinvarCategoricalVariant.md) union type encompasses all three:

| Cat-VRS Type | ClinVar Profile | Description |
| --- | --- | --- |
| CanonicalAllele | [ClinvarCanonicalAllele](ClinvarCanonicalAllele.md) | The vast majority of ClinVar variations. Defined by a GRCh38 genomic allele mapped from submitted variant attributes. |
| CategoricalCnv | [ClinvarCategoricalCnvChange](ClinvarCategoricalCnvChange.md) | Copy number variants with qualitative change (gain/loss). Uses a DefiningLocationConstraint with CopyChangeConstraint. |
| CategoricalCnv | [ClinvarCategoricalCnvCount](ClinvarCategoricalCnvCount.md) | Copy number variants with absolute copy count. Uses a DefiningLocationConstraint with CopyCountConstraint. |
| CategoricalVariant | [ClinvarNonConstrainedVariant](ClinvarNonConstrainedVariant.md) | Haplotypes, genotypes, and complex variants that cannot be mapped to a specific VRS allele or location. |

---

## ClinVar-Specific Extensions

All ClinVar variant types carry a shared set of extensions that provide ClinVar metadata not captured by the Cat-VRS base types:

| Extension | Description |
| --- | --- |
| `clinvarHgvsList` | Complete list of HGVS expressions — nucleotide and protein forms, MANE select/plus designations, and molecular consequences (SO terms). Each entry is an [HgvsListItem](HgvsListItem.md). |
| `clinvarGeneList` | Gene associations including Entrez gene ID, HGNC ID, symbol, and relationship type. Each entry is a [GeneListItem](GeneListItem.md). |
| `categoricalVariationType` | The Cat-VRS category assigned: `CanonicalAllele`, `CategoricalCnvChange`, `CategoricalCnvCount`, or `Non-Constrained`. |
| `definingVrsVariationType` | The VRS class from upstream processing: `Allele`, `CopyNumberChange`, `CopyNumberCount`, `Haplotype`, `Unknown`, or `Not Available`. |
| `clinvarVariationType` | The variation type as reported by ClinVar (e.g., `Deletion`, `single nucleotide variant`, `Duplication`). |
| `clinvarSubclassType` | The ClinVar subclass: `SimpleAllele`, `Haplotype`, or `Genotype`. |
| `clinvarCytogeneticLocation` | Cytogenetic band location (e.g., `17q21.31`). |
| `vrsPreProcessingIssue` | Issues detected during VRS pre-processing. Present only when issues exist. |
| `vrsProcessingException` | Errors from the VRS processing service. Present only when errors occurred. |

---

## VRS Composition Chain

Variants reference their resolved VRS representations through bundle-internal `#/` pointers:

```
Variation → #/allele/{id} → #/location/{id} → #/sequenceReference/{id}
```

- **Alleles** carry the alternate state, SPDI/HGVS/gnomAD expressions, and a location reference
- **Locations** carry start/end coordinates and a sequence reference
- **Sequence References** carry the refget accession, molecule type, residue alphabet, and assembly extension

These VRS types use their upstream GA4GH schemas directly. ClinVar adds an `assembly` extension to SequenceReference (e.g., `GRCh38`).
