# Output File

Each ClinVar-GKS release is published as a **single gzip-compressed JSON file** containing all data for the corresponding ClinVar XML release in the bundle format.

---

## File Format

The release file is a `.json.gz` file. The decompressed content is a single JSON object with named bundle sections at the root level — each section is a keyed collection of objects of the same class.

```bash
# Decompress and inspect the top-level keys
gunzip -c clinvar-gks_00-latest.json.gz | python3 -c "
import json, sys
data = json.load(sys.stdin)
for key in data:
    print(f'{key}: {len(data[key]):,} entries')
"
```

See [Output Format](../output-reference/overview.md) for the full bundle structure, section inventory, and reference patterns.

---

## File Naming Convention

### Latest Release

Stable filenames that always point to the most recent release:

```text
clinvar-gks_00-latest.json.gz           (latest monthly)
clinvar-gks_00-latest_weekly.json.gz    (latest weekly)
```

The `00-` prefix ensures these sort before dated files in directory listings.

### Weekly Releases

Weekly releases include the ClinVar release year, month, and day:

```text
clinvar-gks_yyyy-mmdd.json.gz
```

For example, `clinvar-gks_2026-0614.json.gz` for the June 14, 2026 release.

### Monthly Releases

Monthly releases include the year and month:

```text
clinvar-gks_yyyy-mm.json.gz
```

For example, `clinvar-gks_2026-06.json.gz` for the June 2026 release.

---

## Working with the File

### Python

```python
import gzip
import json

with gzip.open('clinvar-gks_00-latest.json.gz', 'rt') as f:
    bundle = json.load(f)

# Look up a specific variation
variant = bundle['variation']['clinvar:10']
print(variant['name'])

# Resolve a reference
allele_ref = variant['members'][0]  # e.g., "#/allele/ga4gh:VA.abc123"
section, key = allele_ref.lstrip('#/').split('/', 1)
allele = bundle[section][key]
```

### Command Line

```bash
# Count entries per section
gunzip -c clinvar-gks_00-latest.json.gz | python3 -c "
import json, sys
data = json.load(sys.stdin)
for key in data:
    print(f'{key}: {len(data[key]):,}')
"

# Extract a single variation as pretty-printed JSON
gunzip -c clinvar-gks_00-latest.json.gz | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(json.dumps(data['variation']['clinvar:10'], indent=2))
"
```

---

## Sections Included

Each release file contains the following bundle sections:

| Section | Content |
| --- | --- |
| `sequenceReference` | VRS reference sequences with refget accessions |
| `location` | VRS sequence locations with coordinates |
| `allele` | VRS alleles with state and expressions |
| `gene` | Gene records with identifiers and symbols |
| `variation` | Cat-VRS categorical variants |
| `condition` | Trait and disease concepts |
| `conditionSet` | Multi-condition groupings |
| `submitter` | Submitting organizations |
| `proposition` | Classification propositions (SCV, VCV, and RCV) |
| `scv` | Submitted classification statements |
| `vcv` | Variation-level aggregate statements |
| `rcv` | Condition-level aggregate statements |

See [Data Model](../output-reference/classes/index.md) for class descriptions and relationship diagrams.
