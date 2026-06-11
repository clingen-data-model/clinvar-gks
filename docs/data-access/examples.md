# Examples

Annotated example files are maintained in the [examples/](https://github.com/clingen-data-model/clinvar-gks/tree/main/examples) directory of the repository. These serve as reference targets for the data structures produced by the pipeline and are useful for early adopters and for validating output against expected formats.

---

## Categorical Variants (Cat-VRS)

Examples of `CategoricalVariant` records — the resolved VRS representations of ClinVar variations with expressions, cross-references, and metadata.

| File | Variant | Type | Description |
| --- | --- | --- | --- |
| [clinvar:12582.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/cat-vrs/clinvar%3A12582.jsonc) | KRAS (variation 12582) | CanonicalAllele | Canonical allele with DefiningAlleleConstraint, multiple expression formats, gene associations, cross-references |
| [clinvar:208366.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/cat-vrs/clinvar%3A208366.jsonc) | Variation 208366 | CanonicalAllele | Additional canonical allele example |

See [Categorical Variants output reference](../output-reference/cat-vrs.md) for field documentation.

---

## SCV Statements

Examples of VA-Spec `Statement` records for individual ClinVar submissions.

### Germline Pathogenicity (G.01)

| File | SCV | Classification | Gene / Condition | Description |
| --- | --- | --- | --- | --- |
| [SCV001571657.2 (path).jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV001571657.2%20(path).jsonc) | SCV001571657.2 | Pathogenic (definitive) | KRAS / Acute myeloid leukemia | VariantPathogenicityProposition, NOCP review status, gene context with HGNC mapping, MedGen/Orphanet/MeSH/MONDO condition xrefs |

### Germline Other Types (G.02-G.09)

| File | SCV | Classification | Type | Description |
| --- | --- | --- | --- | --- |
| [SCV004035006.2 (assoc).jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV004035006.2%20(assoc).jsonc) | SCV004035006.2 | association (supports) | Association (G.06) | ClinVarAssociationProposition, KRAS variant with multiple endometrial conditions in a ConditionSet |
| [SCV002099547.2 (not-provided).jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV002099547.2%20(not-provided).jsonc) | SCV002099547.2 | not provided (supports) | Not Provided (G.09) | ClinVarNotProvidedProposition, KRAS / Encephalocraniocutaneous lipomatosis |

### Oncogenicity (O.10)

| File | SCV | Classification | Gene / Condition | Description |
| --- | --- | --- | --- | --- |
| [SCV005093950.2 (onco).json](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV005093950.2%20(onco).json) | SCV005093950.2 | Oncogenic (definitive) | ERBB2 / Neoplasm | VariantOncogenicityProposition, CP review status, ClinGen/CGC/VICC Guidelines 2022 method |

### Somatic Clinical Impact (S.11-S.14)

| File | SCV | Classification | Tier | Sub-type | Description |
| --- | --- | --- | --- | --- | --- |
| [SCV004565358.1 (therapeutic-resp-T1).json](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV004565358.1%20(therapeutic-resp-T1).json) | SCV004565358.1 | Tier I - Strong | Tier I | Therapeutic Response (S.12) | EGFR L858R / NSCLC, drug sensitivity evidence line with erlotinib therapy, AMP/ASCO/CAP Guidelines 2017 |
| [SCV004565361.1 (diagnostic-T2).json](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV004565361.1%20(diagnostic-T2).json) | SCV004565361.1 | Tier II - Potential | Tier II | Diagnostic (S.13) | ACVR1 / diffuse intrinsic pontine glioma, diagnostic inclusion criterion evidence line |
| [SCV005387955.1 (unk-T3).json](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV005387955.1%20(unk-T3).json) | SCV005387955.1 | Tier III - Unknown | Tier III | Clinical Significance (S.11) | TG variant, neutral direction, no paired sub-statement |
| [SCV005061369.1 (blb-T4).json](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/scv/SCV005061369.1%20(blb-T4).json) | SCV005061369.1 | Tier IV - Benign/LB | Tier IV | Clinical Significance (S.11) | TP53 / CML, disputes direction, no paired sub-statement |

See [SCV Statements output reference](../output-reference/scv-statements.md) for field documentation.

---

## VCV Statements

Examples of aggregate classification `Statement` records produced by rolling up SCV submissions through the aggregation hierarchy.

### Germline

| File | VCV | Prop Types | Submission Levels | Description |
| --- | --- | --- | --- | --- |
| [VCV000012582.63-G-PATH.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/vcv/VCV000012582.63-G-PATH.jsonc) | VCV000012582 | Pathogenicity, Association, Not Provided | CP, NOCP, NOCL | Aggregate Contribution Layer germline statement. CP pathogenicity with 13 contributing SCVs concordant, NOCP non-contributing. Association and Not Provided as non-contributing prop types |

### Somatic

| File | VCV | Prop Types | Tiers | Description |
| --- | --- | --- | --- | --- |
| [VCV000012582.63-S-sci.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/vcv/VCV000012582.63-S-sci.jsonc) | VCV000012582 | Somatic Clinical Impact | Tier I, Tier II | Aggregate Contribution → Tier Grouping → Base Grouping hierarchy. Tier Grouping combining Tier I and Tier II. CP contributing, NOCP non-contributing |
| [VCV000012582.63-S-onco.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/vcv/VCV000012582.63-S-onco.jsonc) | VCV000012582 | Oncogenicity | N/A | Somatic oncogenicity aggregate (Aggregate Contribution → Base Grouping). Single CP submission, no tier grouping |

### PG and EP (single-submission levels)

PG (practice guideline) and EP (reviewed by expert panel) submissions are aggregated as separate top-tier submission levels. PG outranks EP in the Aggregate Contribution Layer winner-takes-all selection, followed by CP, NOCP, NOCL, and FLAG.

| File | VCV | Submission Level | Description |
| --- | --- | --- | --- |
| [VCV-PG-example.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/vcv/VCV-PG-example.jsonc) | VCV999999999 (hypothetical) | PG | Base Grouping statement for a practice guideline submission. Uses standard `classification` and `objectClassification` |
| [VCV-EP-example.jsonc](https://github.com/clingen-data-model/clinvar-gks/blob/main/examples/vcv/VCV-EP-example.jsonc) | VCV999999999 (hypothetical) | EP | Base Grouping statement for an expert panel submission. Same form as PG; only the submission level qualifier and review status differ |

See [VCV Statements output reference](../output-reference/vcv-statements.md) for field documentation.
