# ACMGv4 Human Observation — Case Data Model (Working Notes)

!!! warning "Working Draft"
    These are working notes for extracting and documenting the JSON case structures
    used in the ACMGv4 Human Observation evidence framework. This file is a companion
    to [ACMGv4-Case-DM-Schema.md](ACMGv4-Case-DM-Schema.md), which derives the
    superset schema and attribute matrix from the examples below.

---

## General Case Attributes

Every case carries these attributes, which determine routing into the appropriate CLN group.

```jsonc
{
  "case_id": "...",
  "moi": "...",
  "zygosity": "...",
  "mde_affected": "T|F|U",
  "well_phenotyped": "T|F|U"
}
```

---

## CLN_UAF — Unaffected Observations

Cases where the individual has the VBC but is **not** affected with the MDE.

### UAF Monoallelic (AD/XLD)

`UAF_AD/XLD_Agg_Per_Case_Type.98`

```jsonc
{
  "case_id": "99098-W",
  "age_matched_penetrance": "NEAR-100"  // NEAR-100 | 80-100 | BELOW-80
}
```

### UAF Biallelic (AR/XLR)

`UAF_AR/XLR_Agg_Per_Case_Type.99`

```jsonc
{
  "case_id": "3832.Z99",
  "age_matched_penetrance": "NEAR-100",  // NEAR-100 | 80-100 | BELOW-80
  "zygosity_plus_type": "TRANS-CONF-PATH"  // TRANS-CONF-PATH | TRANS-CONF-LIKPATH | HOM-HEMI
}
```

---

## CLN_ALT — Affected Observations with Alternate Cause

Cases where the individual is affected, but an alternate genetic cause explains the disease.

### ALT_Var — Additional P/LP Variant in Same Gene

`ALT_VAR_AXLD.1.AggCaseTyp.20`

```jsonc
{
  "case_id": "1005.Z",
  "additional_var": {
    "id": "(optional — hgvs, caid, clinvar, etc.)",
    "classification": "PLP",  // PLP | VUS | BLB
    "gene": {
      "same_as_VBC": true,
      "associated_with_MDE": true
    }
  },
  "severity_comparison": "GREATER-THAN-AD"  // GREATER-THAN-AD | SAME-AS-AD
}
```

### ALT_Gene — Additional P/LP Variant in Different Gene

`ALT_GENE_AXLD.1.AggCaseTyp.30`

```jsonc
{
  "case_id": "3512-XYZ",
  "additional_var": {
    "id": "(optional — hgvs, caid, clinvar, etc.)",
    "classification": "PLP",  // PLP | VUS | BLB
    "gene": {
      "same_as_VBC": false,
      "associated_with_MDE": true
    }
  },
  "severity_comparison": "SAME-AS-AD"  // GREATER-THAN-AD | SAME-AS-AD
}
```

---

## CLN_AFF — Affected Observations (Standard)

Standard affected cases — not de novo and not alternate cause.

### AFF Monoallelic (AD/XLD)

`AFF_AXLD.1.AggCaseTyp.1` — Specific phenotype, all genes tested, no VUS

```jsonc
{
  "case_id": "001.A",
  "pheno_spec_gene_type": "SPECIFIC",
  "all_rel_disorder_genes_tested": true,
  "vois_exist": false
}
```

`AFF_AXLD.1.AggCaseTyp.2` — Consistent phenotype, not all genes tested, VUS present

```jsonc
{
  "case_id": "001.X2",
  "pheno_spec_gene_type": "CONSISTENT",
  "all_rel_disorder_genes_tested": false,
  "vois_exist": true
}
```

`AFF_AXLD.1.AggCaseTyp.3` — Inconsistent phenotype

```jsonc
{
  "case_id": "001.Y",
  "pheno_spec_gene_type": "INCONSISTENT"
}
```

### AFF Biallelic (AR/XLR/SD)

`AFF_AXLR.1.AggCaseTyp.4` — Consistent phenotype, VUS present, trans-confirmed

```jsonc
{
  "case_id": "099.N12",
  "pheno_spec_gene_type": "CONSISTENT",
  "all_rel_disorder_genes_tested": false,
  "vois_exist": true,
  "zygosity_plus_type": "TRANS-CONF-VUS"
}
```

`AFF_AXLR.1.AggCaseTyp.5` — Specific phenotype, all genes tested, homozygous/hemizygous

```jsonc
{
  "case_id": "409.F1",
  "pheno_spec_gene_type": "SPECIFIC",
  "all_rel_disorder_genes_tested": true,
  "vois_exist": false,
  "zygosity_plus_type": "HOM-HEMI"
}
```

---

## CLN_DNV — Affected with De Novo Variant

De novo variant occurrence. MOI must be AD, SD, XLD, or XLR only.

`CLN_DNV.1.AggCaseTyp.10` — Confirmed parental testing

```jsonc
{
  "case_id": "001.B",
  "pheno_spec_gene_type": "SPECIFIC",
  "all_rel_disorder_genes_tested": true,
  "confirmed_parental": true
}
```

`CLN_DNV.1.AggCaseTyp.11` — Without confirmed parental testing

```jsonc
{
  "case_id": "888.A",
  "pheno_spec_gene_type": "SPECIFIC",
  "all_rel_disorder_genes_tested": true,
  "confirmed_parental": false
}
```
