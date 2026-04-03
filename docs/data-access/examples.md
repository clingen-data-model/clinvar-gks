# Examples

Annotated example files are maintained in the [examples/](https://github.com/clingen-data-model/clinvar-gks/tree/main/examples) directory of the repository. These serve as reference targets for the data structures produced by the pipeline and are useful for early adopters and for validating output against expected formats.

---

## Categorical Variants (Cat-VRS)

Examples of `CategoricalVariant` records — the resolved VRS representations of ClinVar variations with expressions, cross-references, and metadata.

| File | Variant | Type | Description |
| --- | --- | --- | --- |
| [cat-vrs-canonical-allele-ex01.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/cat-vrs/cat-vrs-canonical-allele-ex01.jsonc) | MTOR c.5992_5993del | CanonicalAllele | Deletion with DefiningAlleleConstraint, HGVS/SPDI/gnomAD expressions, GRCh38 assembly, HGVS list with molecular consequence, gene associations |
| [cat-vrs-canonical-allele-ex02.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/cat-vrs/cat-vrs-canonical-allele-ex02.jsonc) | KCNQ4 c.803CCT[1] | CanonicalAllele | In-frame deletion (repeat) with ReferenceLengthExpression state, MANE Select transcript designation |

See [Categorical Variants output reference](../output-reference/cat-vrs.md) for field documentation.

---

## SCV Statements

Examples of VA-Spec `Statement` records for individual ClinVar submissions.

### Germline Pathogenicity (G.01)

| File | SCV | Classification | Gene / Condition | Description |
| --- | --- | --- | --- | --- |
| [SCV001571657.2-path.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV001571657.2-path.jsonc) | SCV001571657.2 | Pathogenic (definitive) | KRAS / Acute myeloid leukemia | VariantPathogenicityProposition, NOCP review status, gene context with HGNC mapping, MedGen/Orphanet/MeSH/MONDO condition xrefs |
| [va-spec-var-path-scv-ex02.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/va-spec-var-path-scv-ex02.jsonc) | SCV001245167.2 | Pathogenic (definitive) | KCNQ4 / AD hearing loss 2A | VariantPathogenicityProposition, CP review status, ACMG Guidelines 2015 method, mode of inheritance qualifier (AD), PubMed citation |

### Germline Other Types (G.02-G.09)

| File | SCV | Classification | Type | Description |
| --- | --- | --- | --- | --- |
| [SCV004035006.2-assoc.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV004035006.2-assoc.jsonc) | SCV004035006.2 | association (supports) | Association (G.06) | ClinVarAssociationProposition, KRAS variant with multiple endometrial conditions in a ConditionSet |
| [SCV002099547.2-np.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV002099547.2-np.jsonc) | SCV002099547.2 | not provided (supports) | Not Provided (G.09) | ClinVarNotProvidedProposition, KRAS / Encephalocraniocutaneous lipomatosis |

### Oncogenicity (O.10)

| File | SCV | Classification | Gene / Condition | Description |
| --- | --- | --- | --- | --- |
| [SCV005093950.2.ONCO.json](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV005093950.2.ONCO.json) | SCV005093950.2 | Oncogenic (definitive) | ERBB2 / Neoplasm | VariantOncogenicityProposition, CP review status, ClinGen/CGC/VICC Guidelines 2022 method |

### Somatic Clinical Impact (S.11-S.14)

| File | SCV | Classification | Tier | Sub-type | Description |
| --- | --- | --- | --- | --- | --- |
| [SCV004565358.1.T1.Strong.json](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV004565358.1.T1.Strong.json) | SCV004565358.1 | Tier I - Strong | Tier I | Therapeutic Response (S.12) | EGFR L858R / NSCLC, drug sensitivity evidence line with erlotinib therapy, AMP/ASCO/CAP Guidelines 2017 |
| [SCV004565361.1.T2.Potential.json](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV004565361.1.T2.Potential.json) | SCV004565361.1 | Tier II - Potential | Tier II | Diagnostic (S.13) | ACVR1 / diffuse intrinsic pontine glioma, diagnostic inclusion criterion evidence line |
| [SCV005387955.1.T3.Unknown.json](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV005387955.1.T3.Unknown.json) | SCV005387955.1 | Tier III - Unknown | Tier III | Clinical Significance (S.11) | TG variant, neutral direction, no paired sub-statement |
| [SCV005061369.1.T4.B:LB.json](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV005061369.1.T4.B:LB.json) | SCV005061369.1 | Tier IV - Benign/LB | Tier IV | Clinical Significance (S.11) | TP53 / CML, disputes direction, no paired sub-statement |

See [SCV Statements output reference](../output-reference/scv-statements.md) for field documentation.

---

## VCV Statements

Examples of aggregate classification `Statement` records produced by rolling up SCV submissions through the aggregation hierarchy.

### Germline

| File | VCV | Prop Types | Submission Levels | Description |
| --- | --- | --- | --- | --- |
| [VCV000012582.63-G.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/vcv/VCV000012582.63-G.jsonc) | VCV000012582 | Pathogenicity, Association, Not Provided | CP, NOCP, NOCL | Full 4-layer germline hierarchy (L4→L3→L1). CP pathogenicity with 13 contributing SCVs concordant. NOCP non-contributing. Association and Not Provided as non-contributing prop types |
| [VCV000007105.202.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/vcv/VCV000007105.202.jsonc) | VCV000007105 | Pathogenicity, Drug Response, Risk Factor, Not Provided | PGEP, CP, NOCP, NOCL | Complex germline with PGEP classification (expert panel + practice guideline), ConceptSet objectClassification, multiple prop types at L3, winner-takes-all ranking |

### Somatic

| File | VCV | Prop Types | Tiers | Description |
| --- | --- | --- | --- | --- |
| [VCV000012582.63-S-SCI.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/vcv/VCV000012582.63-S-SCI.jsonc) | VCV000012582 | Somatic Clinical Impact | Tier I, Tier II | 3-layer somatic hierarchy (L3→L2→L1). Layer 2 tier aggregation combining Tier I and Tier II. CP contributing, NOCP non-contributing |
| [VCV000012582.63-S-ONCO.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/vcv/VCV000012582.63-S-ONCO.jsonc) | VCV000012582 | Oncogenicity | N/A | Somatic oncogenicity aggregate (L3→L1). Single CP submission, no tier grouping |

### PGEP

| File | VCV | Submission Level | Description |
| --- | --- | --- | --- |
| [VCV-PGEP-example.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/vcv/VCV-PGEP-example.jsonc) | VCV999999999 (hypothetical) | PGEP | Demonstrates `classification_conceptSetSet` with 2 nested AND-groups (Classification + Condition + SubmissionLevel), `objectClassification_conceptSetSet` without extensions, and "practice guideline and expert panel mix" review status |

See [VCV Statements output reference](../output-reference/vcv-statements.md) for field documentation.
