# Downloads

ClinVar-GKS releases are hosted on Cloudflare R2 object storage. All downloads are free with no authentication required and no egress fees.

---

## Latest Release

The `current/` directory contains the most recent weekly releases with stable filenames:

```bash
# Download the latest release
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/current/clinvar-gks-current.json.gz
```

---

## Monthly Archives

Archived releases are available by year, one per month:

```bash
# Download the February 2025 archive
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/archive/2025/clinvar-gks_2025_02.json.gz
```

---

## Download with Python

```python
import urllib.request

BASE = "https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev"

# Download current release
urllib.request.urlretrieve(
    f"{BASE}/current/clinvar-gks-current.json.gz",
    "clinvar-gks-current.json.gz"
)
```

---

## Feedback

This project is in active development and we welcome community feedback. If you encounter data quality issues, have questions about the output format, or want to suggest improvements:

- Open an issue on [GitHub](https://github.com/clingen-data-model/clinvar-gks/issues)
- Include the release date and specific records involved
