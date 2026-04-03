# Data Access

!!! warning "Early Adopter Release"
    ClinVar-GKS datasets are currently in an **early adopter** phase. The data
    structures, field names, and output formats may change as we incorporate
    feedback and align with evolving GA4GH GKS specifications. We encourage
    early adopters to report issues and suggestions via the
    [GitHub issue tracker](https://github.com/clingen-data-model/clinvar-gks/issues).

ClinVar-GKS output datasets are published weekly as gzip-compressed JSONL files, synchronized with each ClinVar XML release. The datasets are freely available for download from Cloudflare R2 object storage with no authentication required and no egress fees.

---

## Available Datasets

Each weekly release produces the following files:

| Dataset | Description |
|---|---|
| **Categorical Variants** (`variation`) | Cat-VRS categorical variant representations for all ClinVar variations |
| **SCV Statements** (`scv_by_ref`) | VA-Spec SCV classification statements with variations referenced by VRS ID |

See [Output Files](output-files.md) for detailed format documentation and field descriptions.

---

## Quick Start

Download the latest release files directly:

```bash
# Latest categorical variants
curl -O https://clinvar-gks.09208aa33790838db213a21f630c33e7.r2.dev/current/clinvar_gks_variation.jsonl.gz

# Latest SCV statements (by reference)
curl -O https://clinvar-gks.09208aa33790838db213a21f630c33e7.r2.dev/current/clinvar_gks_scv_by_ref.jsonl.gz
```

See [Downloads](download.md) for the full URL structure, archived releases, and programmatic access patterns.

---

## What's Next

- Browse [Examples](examples.md) for annotated sample records from each dataset
- Review the [Output Reference](../output-reference/index.md) for complete field documentation
- Check the [Profiles](../profiles/index.md) section for classification types, propositions, and review status mappings
