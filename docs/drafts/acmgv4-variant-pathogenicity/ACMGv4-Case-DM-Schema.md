# ACMGv4 Case Schema and Attribute Matrix

## Superset Case Schema

```jsonc
{
  // General (all cases)
  "case_id": "string",
  "moi": "AD|AR|SD|XLD|XLR",
  "zygosity": "string",
  "mde_affected": "T|F|U",
  "well_phenotyped": "T|F|U",

  // UAF-specific
  "age_matched_penetrance": "NEAR-100|80-100|BELOW-80",
  "zygosity_plus_type": "TRANS-CONF-PATH|TRANS-CONF-LIKPATH|TRANS-CONF-VUS|HOM-HEMI",

  // ALT-specific
  "additional_var": {
    "id": "string (optional - hgvs, caid, clinvar, etc.)",
    "classification": "PLP|VUS|BLB",
    "gene": {
      "same_as_VBC": "boolean",
      "associated_with_MDE": "boolean"
    }
  },
  "severity_comparison": "GREATER-THAN-AD|SAME-AS-AD",

  // AFF-specific
  "pheno_spec_gene_type": "SPECIFIC|CONSISTENT|INCONSISTENT",
  "all_rel_disorder_genes_tested": "boolean",
  "vois_exist": "boolean",

  // DNV-specific
  "confirmed_parental": "boolean"
}
```

## Attribute-by-Group Matrix

| Attribute | General | CLN_UAF | CLN_ALT | CLN_AFF | CLN_DNV |
|---|:---:|:---:|:---:|:---:|:---:|
| `case_id` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `moi` | ✓ | | | | |
| `zygosity` | ✓ | | | | |
| `mde_affected` | ✓ | | | | |
| `well_phenotyped` | ✓ | | | | |
| `age_matched_penetrance` | | ✓ | | | |
| `zygosity_plus_type` | | ✓ (AR/XLR only) | | ✓ (AXLR only) | |
| `additional_var.id` | | | ✓ | | |
| `additional_var.classification` | | | ✓ | | |
| `additional_var.gene.same_as_VBC` | | | ✓ | | |
| `additional_var.gene.associated_with_MDE` | | | ✓ | | |
| `severity_comparison` | | | ✓ | | |
| `pheno_spec_gene_type` | | | | ✓ | ✓ |
| `all_rel_disorder_genes_tested` | | | | ✓ | ✓ |
| `vois_exist` | | | | ✓ | |
| `confirmed_parental` | | | | | ✓ |

## Notes

- The **General** attributes are information needed to route a case into the correct CLN group, so they are conceptually present on every case but only explicitly listed in the "General Case" block.
- `zygosity_plus_type` is used in both CLN_UAF (AR/XLR) and CLN_AFF (AXLR) with the combined value set: `TRANS-CONF-PATH|TRANS-CONF-LIKPATH|TRANS-CONF-VUS|HOM-HEMI`.
- CLN_ALT has two sub-types (ALT_Var vs ALT_Gene) distinguished by `additional_var.gene.same_as_VBC` being `true` vs `false`, but they share the same schema.

## Reference: Acronyms

### Core Terms

| Acronym | Definition |
| --- | --- |
| MDE | Mendelian Disease Entity — the disease being assessed as caused by the VBC in an individual |
| VBC | Variant Being Considered — the target variant being assessed for causality of the MDE |
| MOI | Mode of Inheritance |
| CLN | Clinical observations of the VBC in a human (cases where the proband has the VBC) |

### Mode of Inheritance (MOI) Values

| Value | Definition |
| --- | --- |
| AD | Autosomal Dominant |
| AR | Autosomal Recessive |
| SD | Semi Dominant |
| XLD | X-Linked Dominant |
| XLR | X-Linked Recessive |

### MOI Grouping Terms

These are not valid `moi` attribute values. They are shorthand for how specific MOI values are aggregated in the case grouping logic.

| Group | Encompasses | Also Known As |
| --- | --- | --- |
| AXLD | AD, XLD | Monoallelic |
| AXLR | AR, XLR, SD | Biallelic |
| XL | XLD, XLR | X-Linked (either) |

### CLN Case Groups

| Group | Definition |
| --- | --- |
| CLN_UAF | Unaffected observations — cases where the individual has the VBC but is not affected with the MDE |
| CLN_ALT | Affected observations with an alternate cause of disease |
| CLN_AFF | Affected observations (standard — not de novo or alternate cause) |
| CLN_DNV | Affected observations with de novo variant occurrence (MOI must be AD, SD, XLD, or XLR) |

### CLN_ALT Sub-Types

| Sub-Type | Definition |
| --- | --- |
| ALT_Var | Affected individual has an additional P/LP variant in the **same** gene as the VBC |
| ALT_Gene | Affected individual has an additional P/LP variant in a **different** gene associated with the same MDE |

### Attribute Value Abbreviations

| Value | Definition |
| --- | --- |
| PLP | Pathogenic or Likely Pathogenic |
| VUS | Variant of Uncertain Significance |
| BLB | Benign or Likely Benign |
| HOM-HEMI | Homozygous or Hemizygous |
| TRANS-CONF-PATH | Trans-confirmed Pathogenic |
| TRANS-CONF-LIKPATH | Trans-confirmed Likely Pathogenic |
| TRANS-CONF-VUS | Trans-confirmed VUS |
| DNV | De Novo |
