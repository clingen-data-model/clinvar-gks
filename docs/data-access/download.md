# Downloads

ClinVar-GKS releases are hosted on Cloudflare R2 object storage. All downloads are free with no authentication required and no egress fees.

---

## Latest Release

The stable "latest" files always point to the most recent release:

```bash
# Download the latest monthly release
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/clinvar-gks_00-latest.json.gz

# Download the latest weekly release
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/weekly/clinvar-gks_00-latest_weekly.json.gz
```

---

## Specific Releases

Download a specific monthly or weekly release by date:

```bash
# Download the June 2026 monthly release
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/clinvar-gks_2026-06.json.gz

# Download the June 14, 2026 weekly release
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/weekly/clinvar-gks_2026-0614.json.gz
```

---

## Archives

Prior years' releases are available in the `archives/` directory:

```bash
# Download the March 2025 monthly archive
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/archives/2025/clinvar-gks_2025-03.json.gz

# Download a specific weekly archive
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/archives/2025/weekly/clinvar-gks_2025-0315.json.gz
```

---

## Download with Python

```python
import urllib.request

BASE = "https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev"

# Download latest monthly release
urllib.request.urlretrieve(
    f"{BASE}/datasets/clinvar-gks_00-latest.json.gz",
    "clinvar-gks-latest.json.gz"
)

# Download latest weekly release
urllib.request.urlretrieve(
    f"{BASE}/datasets/weekly/clinvar-gks_00-latest_weekly.json.gz",
    "clinvar-gks-latest-weekly.json.gz"
)
```

---

## Feedback

This project is in active development and we welcome community feedback. If you encounter data quality issues, have questions about the output format, or want to suggest improvements:

- Open an issue on [GitHub](https://github.com/clingen-data-model/clinvar-gks/issues)
- Include the release date and specific records involved
