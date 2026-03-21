# Getting Started

## Accessing the Datasets

ClinVar-GKS output files are published to a public Google Cloud Storage bucket after each pipeline run.

### Public Bucket

```
gs://clingen-public/clinvar-gks/
```

### File Naming Convention

Files follow this naming pattern:

```
clinvar_gks_{type}_{YYYY_MM_DD}_{version}.jsonl.gz
```

Where:

- `{type}` is one of: `variation`, `scv_by_ref`, `scv_inline`
- `{YYYY_MM_DD}` is the ClinVar release date
- `{version}` is the dataset version (e.g., `v2_4_3`)

### Download Examples

Using `gsutil`:

```bash
# List available files
gsutil ls gs://clingen-public/clinvar-gks/

# Download the latest variation file
gsutil cp gs://clingen-public/clinvar-gks/clinvar_gks_variation_2025_09_28_v2_4_3.jsonl.gz .

# Download and decompress
gsutil cat gs://clingen-public/clinvar-gks/clinvar_gks_variation_2025_09_28_v2_4_3.jsonl.gz | gunzip > variation.jsonl
```

### File Format

All files are **gzipped newline-delimited JSON** (`.jsonl.gz`). Each line is a self-contained JSON object conforming to the relevant GA4GH schema.

## What's In Each File

| File | Contents | Schema |
| --- | --- | --- |
| `variation` | Cat-VRS categorical variant objects for all ClinVar variations | Cat-VRS 1.0 |
| `scv_by_ref` | VA-Spec clinical statements referencing variations by ID | VA-Spec 1.0 |
| `scv_inline` | VA-Spec clinical statements with full variation objects embedded | VA-Spec 1.0 |

The `scv_by_ref` and `scv_inline` files contain the same statements — they differ only in whether the variant is referenced or inlined. Use `scv_by_ref` if you already have the variation data loaded; use `scv_inline` for self-contained records.

## Next Steps

- [Pipeline Overview](pipeline/index.md) — understand how the data is produced
- [Statement Profiles](profiles/index.md) — learn about the 14 statement types and their classifications
- [Output File Schemas](data-access/output-files.md) — detailed field documentation
- [Examples](data-access/examples.md) — annotated JSON examples
