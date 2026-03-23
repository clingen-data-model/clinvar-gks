# Output Reference

The ClinVar-GKS pipeline produces three JSONL files distributed via a public Google Cloud Storage bucket. Each file contains one JSON record per line, compressed with gzip.

This section documents the JSON output from a **consumer perspective** — what each file contains, the structure of its records, and how to interpret the fields. For details on how these files are built, see the [Pipeline](../pipeline/index.md) documentation.

---

## Output Files

| File | Content | Records | Pipeline Source |
| --- | --- | --- | --- |
| `variation.jsonl.gz` | [Categorical Variants](cat-vrs.md) | One per ClinVar variation with a resolved VRS identity | `gks_catvar` table via [Cat-VRS](../pipeline/cat-vrs/index.md) |
| `scv_by_ref.jsonl.gz` | [SCV Statements (by reference)](scv-statements.md#by-reference-format) | One per submitted clinical assertion | `gks_statement_scv_by_ref` table via [SCV Statements](../pipeline/scv-statements/index.md) |
| `scv_inline.jsonl.gz` | [SCV Statements (inline)](scv-statements.md#inline-format) | One per submitted clinical assertion | `gks_statement_scv_inline` table via [SCV Statements](../pipeline/scv-statements/index.md) |

---

## Format Conventions

All output files share these conventions:

- **JSONL** — one JSON object per line, no surrounding array
- **gzip compressed** — decompress with `gunzip` or read directly with libraries that support gzip streams
- **Null stripping** — null-valued fields and empty arrays are omitted from the output
- **GA4GH identifiers** — VRS identifiers use the `ga4gh:` prefix (e.g., `ga4gh:VA.abc123`)
- **ClinVar identifiers** — ClinVar-scoped identifiers use the `clinvar:` prefix (e.g., `clinvar:12345`)

---

## Specifications

The output conforms to these GA4GH standards:

- **[VRS 2.0](https://vrs.ga4gh.org/)** — Variation Representation Specification for allele and copy number representations
- **[Cat-VRS](https://cat-vrs.readthedocs.io/)** — Categorical Variation for grouping variants at a higher categorical level
- **[VA-Spec](https://va-spec.readthedocs.io/)** — Variant Annotation Specification for clinical variant statements
