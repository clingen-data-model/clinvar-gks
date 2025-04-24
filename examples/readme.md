# Examples

The `jsonc` examples provide a target model for the variety of cat-vrs and va-spec statements that are going to be generated from this project. It is provided here for discussion and to assist early adopters so they can provide feedback and ask for clarity where some portions may not be well understood.

The names of the files should provide some guidance to what they contain. We will try to keep to the following file naming convention.

ClinVar Variation records - matching clinvar unique `variationId`s.
- cat-vrs-[canonical-allele|categorical-cnv-[chg|cnt]|described-var]-ex##.jsonc
  where,
    `canonical-allele` contain cat-vrs CanonicalAllele Recipe examples
    `categorical-cnv-cnt` contain cat-vrs CategoricalCNV CopyCount Recipe examples 
    `categorical-cnv-chg` contain cat-vrs CategoricalCNV CopyChange Recipe examples 
    `described-var` contain cat-vrs No Constraint Categorical Variant examples for variants that are not yet supported by this project, VRS 2.0 or Cat-VRS 1.0.

- va-spec-var-path-scv-ex##.jsonc
  where,
    `var-path-scv` contain va-spec Variant Pathogenicity SCV examples 
    NOTE: RCV|VCV aggregate germline disease pathogenicity statements are forthcoming as well as Oncogenicity and Somatic Clinical Impact statements.

- custom-[drug-resp|other]-scv-ex##.jsonc
  where,
    `drug-resp-scv` contain custom profiles for Drug Response SCVs.
    `other-scv` contain custom profiles for all other germline disease SCVs that are not variant pathogenicity or drug response.

