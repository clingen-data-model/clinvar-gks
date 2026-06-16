# Output Reference

The ClinVar-GKS pipeline produces a single compressed JSON file per release, containing all variant representations, clinical classification statements, and supporting reference data. This section documents the output from a **consumer perspective** — how the file is structured, what each section contains, and how to interpret the data.

For details on how the output is built, see the [Pipeline](../pipeline/index.md) documentation.

---

## Release Format

Each release is a single gzip-compressed JSON file (`.json.gz`) containing a root-level object with **dictionary sections**. Each section is a keyed collection — the key is the object's unique identifier, and the value is the complete object.

See [Output Format Overview](overview.md) for a detailed guide to the dictionary structure, reference patterns, and how to navigate between sections.

---

## Sections

| Section | Content | Key Format |
| --- | --- | --- |
| [`sequenceReference`](cat-vrs.md) | VRS sequence references | `SQ.{digest}` |
| [`location`](cat-vrs.md) | VRS sequence locations | `ga4gh:SL.{digest}` |
| [`allele`](cat-vrs.md) | VRS alleles with expressions | `ga4gh:VA.{digest}` |
| [`gene`](cat-vrs.md) | Gene records | `ncbigene:{id}` |
| [`variation`](cat-vrs.md) | Cat-VRS categorical variants | `clinvar:{variation_id}` |
| `condition` | Trait/disease concepts | `clinvar.trait:{id}` |
| `conditionSet` | Multi-condition groupings | `clinvar.traitset:{id}` |
| `submitter` | Submitting organizations | `clinvar.submitter:{id}` |
| [`proposition`](scv-statements.md) | Classification propositions | `{scv_id}-{CODE}` / `{vcv_id}-{group}-{prop}-{level}` |
| [`scv`](scv-statements.md) | Submitted classifications | `clinvar.submission:{scv_id}.{version}` |
| [`vcv`](vcv-statements.md) | Variation-level aggregates | `{vcv_id}-{group}-{prop}-{level}` |
| [`rcv`](rcv-statements.md) | Condition-level aggregates | `{rcv_id}-{group}-{prop}-{level}` |

---

## Format Conventions

- **Null stripping** — null-valued fields and empty arrays/objects are omitted from the output
- **GA4GH identifiers** — VRS identifiers use the `ga4gh:` prefix (e.g., `ga4gh:VA.abc123`)
- **ClinVar identifiers** — ClinVar-scoped identifiers use the `clinvar:` prefix (e.g., `clinvar:12345`)
- **JSON pointer references** — objects reference each other using `#/{section}/{key}` strings (e.g., `#/allele/ga4gh:VA.abc123`)

---

## Cross-Section References

Objects reference each other using `#/` JSON pointer strings rather than embedding full objects. This keeps the file compact and avoids duplication. For example:

- A **variation** references its allele as `#/allele/ga4gh:VA.abc123`
- An **SCV statement** references its proposition as `#/proposition/SCV001234567-PATH`
- A **VCV evidence line** references its contributing SCVs as `#/scv/clinvar.submission:SCV001234567.1`

See [ID References](id-references.md) for the complete reference format guide, identifier patterns, and resolution rules.

---

## Specifications

The output conforms to these GA4GH standards:

- **[VRS 2.0](https://vrs.ga4gh.org/)** — Variation Representation Specification for allele and copy number representations
- **[Cat-VRS](https://cat-vrs.readthedocs.io/)** — Categorical Variation for grouping variants at a higher categorical level
- **[VA-Spec](https://va-spec.readthedocs.io/)** — Variant Annotation Specification for clinical variant statements
