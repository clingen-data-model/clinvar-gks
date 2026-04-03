# Examples

Annotated JSONC example files are maintained in the [examples/](https://github.com/clingen-data-model/clinvar-gks/tree/main/examples) directory of the repository. These serve as reference targets for the data structures produced by the pipeline and are useful for early adopters and for validating output against expected formats.

---

## Categorical Variants (Cat-VRS)

Examples of `CategoricalVariant` records — the resolved VRS representations of ClinVar variations with expressions, cross-references, and metadata.

- [examples/cat-vrs/](https://github.com/clingen-data-model/clinvar-gks/tree/main/examples/cat-vrs)

See [Categorical Variants output reference](../output-reference/cat-vrs.md) for field documentation, or the [Cat-VRS pipeline](../pipeline/cat-vrs/index.md) for how these records are built.

---

## SCV Statements

Examples of VA-Spec `Statement` records for individual ClinVar submissions — covering pathogenicity, oncogenicity, somatic clinical impact, therapeutic response, and other assertion types.

- [examples/scv/](https://github.com/clingen-data-model/clinvar-gks/tree/main/examples/scv)

See [SCV Statements output reference](../output-reference/scv-statements.md) for field documentation, or the [SCV Statements pipeline](../pipeline/scv-statements/index.md) for how these records are built.

---

## VCV Statements

Examples of aggregate classification `Statement` records — the variant-level summaries produced by rolling up SCV submissions through four layers of aggregation. Includes germline, somatic, and PGEP (practice guideline / expert panel) examples.

- [examples/vcv/](https://github.com/clingen-data-model/clinvar-gks/tree/main/examples/vcv)

See the [VCV Statements pipeline](../pipeline/vcv-statements/index.md) for how these records are built.
