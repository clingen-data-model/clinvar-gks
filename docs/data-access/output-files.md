# Output Files

!!! warning "Early Adopter Release"
    Output file contents and structure may change as the project incorporates
    feedback and aligns with evolving GA4GH GKS specifications.

The ClinVar-GKS pipeline produces gzip-compressed JSONL files — one JSON object per line, each representing a single record. Files are published weekly in sync with ClinVar XML releases.

---

## File Summary

| File | Record Type | GA4GH Spec | Typical Size |
| --- | --- | --- | --- |
| `clinvar_gks_variation.jsonl.gz` | `CategoricalVariant` | Cat-VRS | ~1.5 GB |
| `clinvar_gks_scv_by_ref.jsonl.gz` | `Statement` | VA-Spec | ~2.0 GB |

---

## Categorical Variants (`variation`)

Each line is a Cat-VRS `CategoricalVariant` object representing a single ClinVar variation. The record includes VRS-normalized identifiers, genomic expressions (HGVS, SPDI, gnomAD), cross-references, gene associations, and assembly mappings.

**Record count:** ~2.8 million per release (one per ClinVar variation)

**Key fields:**

- `id` — VRS-computed categorical variant identifier
- `type` — Cat-VRS type (e.g., `CanonicalAllele`)
- `members` — VRS allele definitions with sequence locations
- `mappings` — cross-references to external databases (ClinVar, ClinGen, OMIM)
- `extensions` — HGVS expressions, gene context, molecular consequences

See [Categorical Variants output reference](../output-reference/cat-vrs.md) for full field documentation and [Cat-VRS examples](examples.md#categorical-variants-cat-vrs) for annotated samples.

---

## SCV Statements (`scv_by_ref`)

Each line is a VA-Spec `Statement` object representing a single ClinVar submitted classification (SCV). Variations are referenced by their VRS ID rather than embedded inline, keeping file size manageable.

**Record count:** ~4.1 million per release (one per ClinVar SCV)

**Key fields:**

- `id` — statement identifier derived from the SCV accession
- `type` — VA-Spec statement type (e.g., `Statement`)
- `classification` — the submitted clinical classification
- `proposition` — the clinical assertion (variant, condition, predicate)
- `strength` — review status and assertion criteria
- `direction` — whether the evidence supports or disputes the proposition
- `extensions` — submission metadata, submitter details, review status

See [SCV Statements output reference](../output-reference/scv-statements.md) for full field documentation and [SCV examples](examples.md#scv-statements) for annotated samples.

---

## File Format Details

### JSONL Structure

Files use newline-delimited JSON (JSONL) format — each line is a complete, self-contained JSON object. No wrapper array or document-level metadata.

```bash
# Inspect the first record
gunzip -c clinvar_gks_variation.jsonl.gz | head -1 | python3 -m json.tool
```

### Compression

All files are gzip-compressed. Standard tools handle decompression transparently:

```bash
# Stream without decompressing to disk
gunzip -c clinvar_gks_scv_by_ref.jsonl.gz | wc -l

# Python
import gzip, json
with gzip.open('clinvar_gks_variation.jsonl.gz', 'rt') as f:
    for line in f:
        record = json.loads(line)
```

### File Naming Convention

Published files follow this naming pattern:

```text
clinvar_gks_{dataset}_{YYYY_MM_DD}_{version}.jsonl.gz
```

| Component | Description | Example |
| --- | --- | --- |
| `dataset` | Output type identifier | `variation`, `scv_by_ref` |
| `YYYY_MM_DD` | ClinVar release date | `2026_03_15` |
| `version` | Dataset schema version | `v2_4_3` |

The `current/` directory uses stable filenames without the date or version suffix — see [Downloads](download.md) for details.
