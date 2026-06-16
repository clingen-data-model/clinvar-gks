# Data Access

ClinVar-GKS releases are published weekly as a single gzip-compressed JSON file, synchronized with each ClinVar XML release. The files are freely available for download from Cloudflare R2 object storage with no authentication required and no egress fees.

---

## Current Release

The most recent weekly releases for the current month are available at:

```text
https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/current/
```

Download the latest release:

```bash
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/current/clinvar-gks-current.json.gz
```

Each release file is a single JSON object containing all dictionary sections — variations, statements, propositions, conditions, and supporting reference data. See [Output Format](../output-reference/overview.md) for the complete structure.

---

## Release Schedule

- **Weekly releases** are published within the current month, one per ClinVar XML release
- **Monthly archives** retain one release per prior month, based on the last release of that month

All weekly releases for the current month are available at the `current/` endpoint. As a new month begins, the prior month's final release moves to the archive.

---

## Archives

Monthly archived releases are available at:

```text
https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/archive/{year}/
```

Archive files include the year and month in the filename — for example, `clinvar-gks_2025_02.json.gz` for the February 2025 archive release.

Example — download the February 2025 archive:

```bash
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/archive/2025/clinvar-gks_2025_02.json.gz
```

---

## Release Notes

Each release — weekly and monthly — is accompanied by a release notes file (`.md` or `.txt`) in the same directory. Release notes include:

- The ClinVar XML release date and version
- Record counts per section (variations, SCVs, VCVs, RCVs)
- Known issues or changes specific to the release

---

## File Format

Each release is a **gzip-compressed JSON file** (`.json.gz`). The decompressed content is a single JSON object with dictionary sections at the root level:

```json
{
  "sequenceReference": { ... },
  "location": { ... },
  "allele": { ... },
  "gene": { ... },
  "variation": { ... },
  "condition": { ... },
  "conditionSet": { ... },
  "submitter": { ... },
  "proposition": { ... },
  "scv": { ... },
  "vcv": { ... },
  "rcv": { ... }
}
```

Each section is a keyed dictionary — the key is the object's unique identifier, and the value is the complete object. Objects reference each other using `#/` JSON pointer strings.

See [Output Format](../output-reference/overview.md) for detailed documentation of each section.

---

## What's Next

- [Output Format](../output-reference/overview.md) — the bundled dictionary structure and reference patterns
- [Examples](examples.md) — annotated sample records from each section
- [Pipeline Overview](../pipeline/index.md) — how the data is produced from ClinVar XML
