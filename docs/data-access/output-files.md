# Output File

Each ClinVar-GKS release is published as a **single gzip-compressed JSON file** containing all data for the corresponding ClinVar XML release in the bundle format.

---

## File Format

The release file is a `.json.gz` file. The decompressed content is a single JSON object with named bundle sections at the root level — each section is a keyed collection of objects of the same class.

```bash
# Decompress and inspect the top-level keys
gunzip -c clinvar-gks-current.json.gz | python3 -c "
import json, sys
data = json.load(sys.stdin)
for key in data:
    print(f'{key}: {len(data[key]):,} entries')
"
```

See [Output Format](../output-reference/overview.md) for the full bundle structure, section inventory, and reference patterns.

---

## File Naming Convention

### Current Release

The `current/` endpoint uses a stable filename:

```text
clinvar-gks-current.json.gz
```

### Weekly Releases

Weekly releases within the current month include the release date:

```text
clinvar-gks-{YYYY-MM-DD}.json.gz
```

### Monthly Archives

Archived monthly releases include the year and month:

```text
clinvar-gks_{YYYY}_{MM}.json.gz
```

---

## Working with the File

### Python

```python
import gzip
import json

with gzip.open('clinvar-gks-current.json.gz', 'rt') as f:
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
gunzip -c clinvar-gks-current.json.gz | python3 -c "
import json, sys
data = json.load(sys.stdin)
for key in data:
    print(f'{key}: {len(data[key]):,}')
"

# Extract a single variation as pretty-printed JSON
gunzip -c clinvar-gks-current.json.gz | python3 -c "
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
