# GKS Schema Registry Design

**Date:** 2026-03-05
**Status:** Approved
**Author:** Claude Code + Larry Babb

## Overview

A central aggregator tool that captures the state of JSON schemas across four GA4GH GKS repositories, tracking all releases and schema maturity levels for use by downstream implementers, GA4GH governance, and documentation generators.

## Target Repositories

| Repo | URL | Schema Path |
|------|-----|-------------|
| gks-core | https://github.com/ga4gh/gks-core | `schema/gks-core/json/` |
| vrs | https://github.com/ga4gh/vrs | `schema/vrs/json/` |
| cat-vrs | https://github.com/ga4gh/cat-vrs | `schema/cat-vrs/json/` |
| va-spec | https://github.com/ga4gh/va-spec | `schema/va-spec/json/` |

## Requirements

### Data Captured Per Schema

| Field | Source | Example |
|-------|--------|---------|
| `$id` | Schema file | `https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele` |
| `title` | Schema file | `Allele` |
| `maturity` | Schema file | `trial use` |
| `description` | Schema file | `The state of a molecule at a Location.` |
| `ga4gh_prefix` | Schema file | `VA` |
| `version` | Extracted from $id | `2.x` |

### Maturity Levels

- `draft`
- `trial use`
- `normative`
- `deprecated` (future)

### Output Formats

- **JSON**: Machine-readable source of truth
- **Markdown**: Human-readable documentation views

### History

All releases tracked (not just current state).

### Trigger

On-demand manual execution via GitHub Actions `workflow_dispatch`.

## Architecture

### Approach

- **Python script** as core logic (testable locally, portable)
- **GitHub Action** as trigger mechanism
- **Results committed to repo** (acts as historical record)

### Location

Self-contained in `src/gks-registry/` within the clinvar-gks repo, designed for easy extraction to a standalone repo (e.g., `ga4gh/gks-schema-registry`) in the future.

## Directory Structure

```
src/gks-registry/
├── fetch_schemas.py          # Main entry point
├── github_client.py          # GitHub API wrapper
├── schema_parser.py          # Extract fields from JSON schemas
├── markdown_generator.py     # Generate markdown views
├── requirements.txt          # Python dependencies
├── config.yaml               # Repo list and settings
│
├── data/                     # Generated outputs (committed to repo)
│   ├── registry.json         # Master file: all repos, all releases, all schemas
│   ├── by-repo/              # Per-repo breakdown
│   │   ├── gks-core/
│   │   │   └── v1.0.0.json
│   │   ├── vrs/
│   │   │   ├── v2.0.0.json
│   │   │   └── v2.0.1.json
│   │   ├── cat-vrs/
│   │   │   └── ...
│   │   └── va-spec/
│   │       └── ...
│   └── by-maturity/          # Cross-repo maturity views
│       ├── normative.json
│       ├── trial-use.json
│       └── draft.json
│
└── docs/                     # Generated markdown (committed)
    ├── README.md             # Overview + quick reference
    ├── maturity-matrix.md    # Cross-repo maturity table
    └── release-history.md    # Timeline of all releases
```

## Data Model

### Master Registry (`data/registry.json`)

```json
{
  "generated_at": "2026-03-05T12:00:00Z",
  "repos": {
    "gks-core": {
      "url": "https://github.com/ga4gh/gks-core",
      "releases": {
        "v1.0.0": {
          "tag": "v1.0.0",
          "name": "1.0.0",
          "published_at": "2024-11-15T00:00:00Z",
          "schemas": {
            "MappableConcept": {
              "$id": "https://w3id.org/ga4gh/schema/gks-core/1.x/json/MappableConcept",
              "title": "MappableConcept",
              "maturity": "trial use",
              "description": "A concept based on a primaryCoding...",
              "ga4gh_prefix": null,
              "version": "1.x"
            }
          }
        }
      }
    }
  }
}
```

### Per-Release (`data/by-repo/<repo>/<tag>.json`)

```json
{
  "repo": "vrs",
  "tag": "v2.0.0",
  "name": "2.0.0",
  "published_at": "2025-03-14T00:00:00Z",
  "schema_count": 26,
  "maturity_summary": {
    "normative": 5,
    "trial use": 18,
    "draft": 3
  },
  "schemas": { ... }
}
```

### By-Maturity (`data/by-maturity/<level>.json`)

```json
{
  "maturity": "normative",
  "generated_at": "2026-03-05T12:00:00Z",
  "schemas": [
    {
      "repo": "vrs",
      "release": "v2.0.0",
      "name": "Allele",
      "$id": "https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele"
    }
  ]
}
```

## Markdown Outputs

### Overview (`docs/README.md`)

- Summary table with latest release per repo
- Schema counts and maturity breakdown
- Quick links to detailed views

### Maturity Matrix (`docs/maturity-matrix.md`)

- Schemas grouped by maturity level
- Cross-repo view showing which schemas are at each level

### Release History (`docs/release-history.md`)

- Timeline of all releases
- Tracks schema additions and maturity changes over time

## GitHub Action Workflow

```yaml
name: Update GKS Schema Registry

on:
  workflow_dispatch:
    inputs:
      full_refresh:
        description: 'Re-fetch all releases (not just new ones)'
        required: false
        default: 'false'
        type: boolean

jobs:
  update-registry:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - run: pip install -r src/gks-registry/requirements.txt
      - run: python src/gks-registry/fetch_schemas.py --full-refresh=${{ inputs.full_refresh }}
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      - run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add src/gks-registry/data/ src/gks-registry/docs/
          git diff --staged --quiet || git commit -m "Update GKS schema registry $(date -u +%Y-%m-%d)"
          git push
```

## Python Module Design

### Configuration (`config.yaml`)

```yaml
repos:
  - name: gks-core
    owner: ga4gh
    schema_path: schema/gks-core/json
  - name: vrs
    owner: ga4gh
    schema_path: schema/vrs/json
  - name: cat-vrs
    owner: ga4gh
    schema_path: schema/cat-vrs/json
  - name: va-spec
    owner: ga4gh
    schema_path: schema/va-spec/json

maturity_levels:
  - draft
  - trial use
  - normative
  - deprecated

output:
  data_dir: data
  docs_dir: docs
```

### Modules

| Module | Responsibility |
|--------|----------------|
| `fetch_schemas.py` | Main orchestrator (~150 lines) |
| `github_client.py` | GitHub API wrapper (~80 lines) |
| `schema_parser.py` | Schema field extraction (~50 lines) |
| `markdown_generator.py` | Markdown generation (~100 lines) |

### Core Functions

```python
# github_client.py
def get_releases(owner: str, repo: str) -> list[Release]
def get_schema_files(owner: str, repo: str, tag: str, path: str) -> list[str]
def get_file_content(owner: str, repo: str, tag: str, path: str) -> dict

# schema_parser.py
def parse_schema(content: dict) -> SchemaInfo
def extract_version_from_id(schema_id: str) -> str

# markdown_generator.py
def generate_readme(registry: Registry) -> str
def generate_maturity_matrix(registry: Registry) -> str
def generate_release_history(registry: Registry) -> str
```

### Data Classes

```python
@dataclass
class SchemaInfo:
    id: str
    title: str
    maturity: str
    description: str
    ga4gh_prefix: str | None
    version: str

@dataclass
class ReleaseInfo:
    tag: str
    name: str
    published_at: datetime
    schemas: dict[str, SchemaInfo]

@dataclass
class RepoInfo:
    name: str
    url: str
    releases: dict[str, ReleaseInfo]
```

## Usage

```bash
# Local execution
cd src/gks-registry
pip install -r requirements.txt
python fetch_schemas.py

# Via GitHub Actions
gh workflow run update-gks-registry.yml

# With full refresh
gh workflow run update-gks-registry.yml -f full_refresh=true
```

## Future Considerations

- Extract to standalone `ga4gh/gks-schema-registry` repo
- Add webhook triggers from source repos
- Add schema diff/changelog generation
- Add JSON Schema validation of outputs
