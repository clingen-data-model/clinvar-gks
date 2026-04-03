# Downloads

!!! warning "Early Adopter Release"
    ClinVar-GKS datasets are in an **early adopter** phase. Data structures and
    output formats may change as we incorporate community feedback and align with
    evolving GA4GH GKS specifications. Please report issues and suggestions via
    the [GitHub issue tracker](https://github.com/clingen-data-model/clinvar-gks/issues).

ClinVar-GKS datasets are hosted on Cloudflare R2 object storage. All downloads are free with no authentication required and no egress fees.

---

## Latest Release

The `current/` directory always contains the most recent weekly release with stable filenames:

| Dataset | URL |
| --- | --- |
| Categorical Variants | `https://clinvar-gks.09208aa33790838db213a21f630c33e7.r2.dev/current/clinvar_gks_variation.jsonl.gz` |
| SCV Statements | `https://clinvar-gks.09208aa33790838db213a21f630c33e7.r2.dev/current/clinvar_gks_scv_by_ref.jsonl.gz` |
| Release Manifest | `https://clinvar-gks.09208aa33790838db213a21f630c33e7.r2.dev/current/manifest.json` |

The `manifest.json` file contains metadata about the current release — release date, schema version, and the list of published files.

### Download with curl

```bash
# Download latest categorical variants
curl -O https://clinvar-gks.09208aa33790838db213a21f630c33e7.r2.dev/current/clinvar_gks_variation.jsonl.gz

# Download latest SCV statements
curl -O https://clinvar-gks.09208aa33790838db213a21f630c33e7.r2.dev/current/clinvar_gks_scv_by_ref.jsonl.gz

# Check which release is current
curl -s https://clinvar-gks.09208aa33790838db213a21f630c33e7.r2.dev/current/manifest.json | python3 -m json.tool
```

### Download with Python

```python
import urllib.request, json

BASE = "https://clinvar-gks.09208aa33790838db213a21f630c33e7.r2.dev"

# Check current release metadata
with urllib.request.urlopen(f"{BASE}/current/manifest.json") as r:
    manifest = json.loads(r.read())
    print(f"Release: {manifest['release_date']} ({manifest['schema_version']})")

# Download a dataset
urllib.request.urlretrieve(
    f"{BASE}/current/clinvar_gks_variation.jsonl.gz",
    "clinvar_gks_variation.jsonl.gz"
)
```

---

## Archived Releases

Weekly releases are organized by year and month:

```text
https://clinvar-gks.09208aa33790838db213a21f630c33e7.r2.dev/
  {YYYY}/
    {YYYY-MM}/
      {YYYY-MM-DD}/
        clinvar_gks_variation_{YYYY_MM_DD}_{version}.jsonl.gz
        clinvar_gks_scv_by_ref_{YYYY_MM_DD}_{version}.jsonl.gz
        manifest.json
```

### Example: Accessing a Specific Release

```bash
# Download the 2026-03-15 variation file
curl -O https://clinvar-gks.09208aa33790838db213a21f630c33e7.r2.dev/2026/2026-03/2026-03-15/clinvar_gks_variation_2026_03_15_v2_4_3.jsonl.gz
```

### Release Index

A root `index.json` file lists all available releases:

```bash
curl -s https://clinvar-gks.09208aa33790838db213a21f630c33e7.r2.dev/index.json | python3 -m json.tool
```

---

## Release Cadence

New datasets are published weekly, typically within 1-2 days of each ClinVar XML release. The `current/` files are overwritten with each new release. Archived releases are retained indefinitely.

---

## File Sizes

Typical compressed file sizes per release:

| Dataset | Approximate Size |
| --- | --- |
| `variation` | ~1.5 GB |
| `scv_by_ref` | ~2.0 GB |

Total download for a full weekly release is approximately 3.5 GB.

---

## Programmatic Access

The storage endpoint is S3-compatible. Tools that support custom S3 endpoints can access the bucket directly:

```bash
# Using AWS CLI (no credentials needed for public reads)
aws s3 ls s3://clinvar-gks/current/ \
  --endpoint-url https://09208aa33790838db213a21f630c33e7.r2.cloudflarestorage.com \
  --no-sign-request
```

---

## Feedback

This project is in active development and we welcome feedback from early adopters. If you encounter data quality issues, have questions about the output format, or want to suggest improvements:

- Open an issue on [GitHub](https://github.com/clingen-data-model/clinvar-gks/issues)
- Include the release date (from `manifest.json`) and the dataset file involved
