# GKS Schema Registry Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Python tool that aggregates JSON schema metadata from 4 GA4GH GKS repos, tracks all releases, and outputs JSON + Markdown views.

**Architecture:** Python script queries GitHub API for releases and schema files, parses schema metadata (maturity, $id, title, etc.), stores results in structured JSON files, generates Markdown documentation. GitHub Action provides on-demand trigger with auto-commit.

**Tech Stack:** Python 3.11+, requests, PyYAML, GitHub Actions

---

## Task 1: Project Scaffolding

**Files:**
- Create: `src/gks-registry/requirements.txt`
- Create: `src/gks-registry/config.yaml`
- Create: `src/gks-registry/__init__.py`

**Step 1: Create directory structure**

```bash
mkdir -p src/gks-registry/data/by-repo/{gks-core,vrs,cat-vrs,va-spec}
mkdir -p src/gks-registry/data/by-maturity
mkdir -p src/gks-registry/docs
```

**Step 2: Create requirements.txt**

```text
requests>=2.31.0
PyYAML>=6.0
```

**Step 3: Create config.yaml**

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

**Step 4: Create empty __init__.py**

```python
"""GKS Schema Registry - Aggregates schema metadata from GA4GH GKS repositories."""
```

**Step 5: Commit**

```bash
git add src/gks-registry/
git commit -m "feat(gks-registry): scaffold project structure and config"
```

---

## Task 2: Data Models

**Files:**
- Create: `src/gks-registry/models.py`
- Create: `src/gks-registry/tests/__init__.py`
- Create: `src/gks-registry/tests/test_models.py`

**Step 1: Write the failing test**

```python
"""Tests for data models."""
import pytest
from datetime import datetime


def test_schema_info_creation():
    from models import SchemaInfo

    schema = SchemaInfo(
        id="https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele",
        title="Allele",
        maturity="trial use",
        description="The state of a molecule at a Location.",
        ga4gh_prefix="VA",
        version="2.x"
    )

    assert schema.title == "Allele"
    assert schema.maturity == "trial use"


def test_schema_info_to_dict():
    from models import SchemaInfo

    schema = SchemaInfo(
        id="https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele",
        title="Allele",
        maturity="trial use",
        description="The state of a molecule.",
        ga4gh_prefix="VA",
        version="2.x"
    )

    result = schema.to_dict()

    assert result["$id"] == "https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele"
    assert result["title"] == "Allele"
    assert result["maturity"] == "trial use"


def test_release_info_creation():
    from models import ReleaseInfo, SchemaInfo

    schema = SchemaInfo(
        id="https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele",
        title="Allele",
        maturity="trial use",
        description="desc",
        ga4gh_prefix="VA",
        version="2.x"
    )

    release = ReleaseInfo(
        tag="v2.0.0",
        name="2.0.0",
        published_at=datetime(2025, 3, 14),
        schemas={"Allele": schema}
    )

    assert release.tag == "v2.0.0"
    assert "Allele" in release.schemas


def test_release_info_maturity_summary():
    from models import ReleaseInfo, SchemaInfo

    schemas = {
        "Allele": SchemaInfo("id1", "Allele", "normative", "desc", "VA", "2.x"),
        "Location": SchemaInfo("id2", "Location", "trial use", "desc", None, "2.x"),
        "Range": SchemaInfo("id3", "Range", "trial use", "desc", None, "2.x"),
    }

    release = ReleaseInfo(
        tag="v2.0.0",
        name="2.0.0",
        published_at=datetime(2025, 3, 14),
        schemas=schemas
    )

    summary = release.maturity_summary()

    assert summary["normative"] == 1
    assert summary["trial use"] == 2


def test_repo_info_creation():
    from models import RepoInfo

    repo = RepoInfo(
        name="vrs",
        url="https://github.com/ga4gh/vrs",
        releases={}
    )

    assert repo.name == "vrs"
```

**Step 2: Run test to verify it fails**

Run: `cd src/gks-registry && python -m pytest tests/test_models.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'models'"

**Step 3: Write implementation**

```python
"""Data models for GKS Schema Registry."""
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional
from collections import Counter


@dataclass
class SchemaInfo:
    """Represents metadata extracted from a JSON schema file."""
    id: str
    title: str
    maturity: str
    description: str
    ga4gh_prefix: Optional[str]
    version: str

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "$id": self.id,
            "title": self.title,
            "maturity": self.maturity,
            "description": self.description,
            "ga4gh_prefix": self.ga4gh_prefix,
            "version": self.version
        }


@dataclass
class ReleaseInfo:
    """Represents a GitHub release with its schemas."""
    tag: str
    name: str
    published_at: datetime
    schemas: dict[str, SchemaInfo] = field(default_factory=dict)

    def maturity_summary(self) -> dict[str, int]:
        """Count schemas by maturity level."""
        maturities = [s.maturity for s in self.schemas.values()]
        return dict(Counter(maturities))

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "tag": self.tag,
            "name": self.name,
            "published_at": self.published_at.isoformat(),
            "schema_count": len(self.schemas),
            "maturity_summary": self.maturity_summary(),
            "schemas": {name: schema.to_dict() for name, schema in self.schemas.items()}
        }


@dataclass
class RepoInfo:
    """Represents a GitHub repository with its releases."""
    name: str
    url: str
    releases: dict[str, ReleaseInfo] = field(default_factory=dict)

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "url": self.url,
            "releases": {tag: release.to_dict() for tag, release in self.releases.items()}
        }
```

**Step 4: Run test to verify it passes**

Run: `cd src/gks-registry && python -m pytest tests/test_models.py -v`
Expected: All 5 tests PASS

**Step 5: Commit**

```bash
git add src/gks-registry/models.py src/gks-registry/tests/
git commit -m "feat(gks-registry): add data models with serialization"
```

---

## Task 3: Schema Parser

**Files:**
- Create: `src/gks-registry/schema_parser.py`
- Create: `src/gks-registry/tests/test_schema_parser.py`

**Step 1: Write the failing test**

```python
"""Tests for schema parser."""
import pytest


def test_extract_version_from_id():
    from schema_parser import extract_version_from_id

    result = extract_version_from_id("https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele")
    assert result == "2.x"


def test_extract_version_from_id_with_1x():
    from schema_parser import extract_version_from_id

    result = extract_version_from_id("https://w3id.org/ga4gh/schema/gks-core/1.x/json/Coding")
    assert result == "1.x"


def test_extract_version_from_id_no_match():
    from schema_parser import extract_version_from_id

    result = extract_version_from_id("https://example.com/no-version")
    assert result == "unknown"


def test_parse_schema_full():
    from schema_parser import parse_schema

    content = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele",
        "title": "Allele",
        "type": "object",
        "maturity": "trial use",
        "description": "The state of a molecule at a Location.",
        "ga4ghDigest": {
            "prefix": "VA"
        }
    }

    result = parse_schema(content)

    assert result.id == "https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele"
    assert result.title == "Allele"
    assert result.maturity == "trial use"
    assert result.description == "The state of a molecule at a Location."
    assert result.ga4gh_prefix == "VA"
    assert result.version == "2.x"


def test_parse_schema_minimal():
    from schema_parser import parse_schema

    content = {
        "$id": "https://w3id.org/ga4gh/schema/gks-core/1.x/json/code",
        "title": "code"
    }

    result = parse_schema(content)

    assert result.title == "code"
    assert result.maturity == "unknown"
    assert result.description == ""
    assert result.ga4gh_prefix is None


def test_parse_schema_with_keys_property():
    from schema_parser import parse_schema

    # Some schemas have ga4ghDigest.keys instead of ga4ghDigest.prefix
    content = {
        "$id": "https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele",
        "title": "Allele",
        "maturity": "normative",
        "ga4ghDigest": {
            "keys": ["type", "location", "state"],
            "prefix": "VA"
        }
    }

    result = parse_schema(content)
    assert result.ga4gh_prefix == "VA"
```

**Step 2: Run test to verify it fails**

Run: `cd src/gks-registry && python -m pytest tests/test_schema_parser.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'schema_parser'"

**Step 3: Write implementation**

```python
"""Parser for extracting metadata from JSON schema files."""
import re
from typing import Optional

from models import SchemaInfo


def extract_version_from_id(schema_id: str) -> str:
    """
    Extract version string from $id URL.

    Example: "https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele" -> "2.x"
    """
    match = re.search(r'/(\d+\.x)/', schema_id)
    if match:
        return match.group(1)
    return "unknown"


def parse_schema(content: dict) -> SchemaInfo:
    """
    Parse a JSON schema and extract relevant metadata.

    Args:
        content: Parsed JSON schema dictionary

    Returns:
        SchemaInfo with extracted metadata
    """
    schema_id = content.get("$id", "")
    title = content.get("title", "")
    maturity = content.get("maturity", "unknown")
    description = content.get("description", "")

    # Extract ga4gh prefix from ga4ghDigest.prefix if present
    ga4gh_digest = content.get("ga4ghDigest", {})
    ga4gh_prefix: Optional[str] = None
    if isinstance(ga4gh_digest, dict):
        ga4gh_prefix = ga4gh_digest.get("prefix")

    version = extract_version_from_id(schema_id)

    return SchemaInfo(
        id=schema_id,
        title=title,
        maturity=maturity,
        description=description,
        ga4gh_prefix=ga4gh_prefix,
        version=version
    )
```

**Step 4: Run test to verify it passes**

Run: `cd src/gks-registry && python -m pytest tests/test_schema_parser.py -v`
Expected: All 6 tests PASS

**Step 5: Commit**

```bash
git add src/gks-registry/schema_parser.py src/gks-registry/tests/test_schema_parser.py
git commit -m "feat(gks-registry): add schema parser with version extraction"
```

---

## Task 4: GitHub Client

**Files:**
- Create: `src/gks-registry/github_client.py`
- Create: `src/gks-registry/tests/test_github_client.py`

**Step 1: Write the failing test**

```python
"""Tests for GitHub client."""
import pytest
from unittest.mock import Mock, patch
from datetime import datetime


def test_get_releases():
    from github_client import GitHubClient

    mock_response = Mock()
    mock_response.status_code = 200
    mock_response.json.return_value = [
        {
            "tag_name": "v2.0.0",
            "name": "2.0.0",
            "published_at": "2025-03-14T00:00:00Z"
        },
        {
            "tag_name": "v1.0.0",
            "name": "1.0.0",
            "published_at": "2024-01-01T00:00:00Z"
        }
    ]

    with patch("github_client.requests.get", return_value=mock_response):
        client = GitHubClient()
        releases = client.get_releases("ga4gh", "vrs")

    assert len(releases) == 2
    assert releases[0]["tag_name"] == "v2.0.0"


def test_get_releases_handles_pagination():
    from github_client import GitHubClient

    # First page
    mock_response1 = Mock()
    mock_response1.status_code = 200
    mock_response1.json.return_value = [{"tag_name": f"v{i}.0.0"} for i in range(30)]
    mock_response1.links = {"next": {"url": "https://api.github.com/page2"}}

    # Second page (empty = end)
    mock_response2 = Mock()
    mock_response2.status_code = 200
    mock_response2.json.return_value = [{"tag_name": "v30.0.0"}]
    mock_response2.links = {}

    with patch("github_client.requests.get", side_effect=[mock_response1, mock_response2]):
        client = GitHubClient()
        releases = client.get_releases("ga4gh", "vrs")

    assert len(releases) == 31


def test_get_schema_files():
    from github_client import GitHubClient

    mock_response = Mock()
    mock_response.status_code = 200
    mock_response.json.return_value = [
        {"name": "Allele", "type": "file"},
        {"name": "Location", "type": "file"},
        {"name": ".gitignore", "type": "file"},  # Should be filtered
    ]

    with patch("github_client.requests.get", return_value=mock_response):
        client = GitHubClient()
        files = client.get_schema_files("ga4gh", "vrs", "v2.0.0", "schema/vrs/json")

    assert "Allele" in files
    assert "Location" in files
    assert ".gitignore" not in files


def test_get_file_content():
    from github_client import GitHubClient

    mock_response = Mock()
    mock_response.status_code = 200
    mock_response.json.return_value = {
        "$id": "https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele",
        "title": "Allele"
    }

    with patch("github_client.requests.get", return_value=mock_response):
        client = GitHubClient()
        content = client.get_file_content("ga4gh", "vrs", "v2.0.0", "schema/vrs/json/Allele")

    assert content["title"] == "Allele"


def test_client_uses_token():
    from github_client import GitHubClient

    client = GitHubClient(token="test-token")

    assert client.headers["Authorization"] == "Bearer test-token"
```

**Step 2: Run test to verify it fails**

Run: `cd src/gks-registry && python -m pytest tests/test_github_client.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'github_client'"

**Step 3: Write implementation**

```python
"""GitHub API client for fetching releases and schema files."""
import os
from typing import Optional

import requests


class GitHubClient:
    """Client for interacting with GitHub API."""

    BASE_URL = "https://api.github.com"
    RAW_URL = "https://raw.githubusercontent.com"

    def __init__(self, token: Optional[str] = None):
        """
        Initialize client with optional auth token.

        Args:
            token: GitHub personal access token (or GITHUB_TOKEN from env)
        """
        self.token = token or os.environ.get("GITHUB_TOKEN")
        self.headers = {
            "Accept": "application/vnd.github.v3+json",
        }
        if self.token:
            self.headers["Authorization"] = f"Bearer {self.token}"

    def get_releases(self, owner: str, repo: str) -> list[dict]:
        """
        Fetch all releases for a repository.

        Args:
            owner: Repository owner (e.g., "ga4gh")
            repo: Repository name (e.g., "vrs")

        Returns:
            List of release dictionaries
        """
        releases = []
        url = f"{self.BASE_URL}/repos/{owner}/{repo}/releases"
        params = {"per_page": 100}

        while url:
            response = requests.get(url, headers=self.headers, params=params)
            response.raise_for_status()
            releases.extend(response.json())

            # Handle pagination
            url = response.links.get("next", {}).get("url")
            params = {}  # URL already contains params

        return releases

    def get_schema_files(self, owner: str, repo: str, tag: str, path: str) -> list[str]:
        """
        List schema files in a directory for a specific release tag.

        Args:
            owner: Repository owner
            repo: Repository name
            tag: Release tag (e.g., "v2.0.0")
            path: Path to schema directory (e.g., "schema/vrs/json")

        Returns:
            List of schema file names (excluding hidden files)
        """
        url = f"{self.BASE_URL}/repos/{owner}/{repo}/contents/{path}"
        params = {"ref": tag}

        response = requests.get(url, headers=self.headers, params=params)
        response.raise_for_status()

        files = []
        for item in response.json():
            if item["type"] == "file" and not item["name"].startswith("."):
                files.append(item["name"])

        return files

    def get_file_content(self, owner: str, repo: str, tag: str, path: str) -> dict:
        """
        Fetch and parse a JSON file from a specific release tag.

        Args:
            owner: Repository owner
            repo: Repository name
            tag: Release tag
            path: Path to file

        Returns:
            Parsed JSON content as dictionary
        """
        url = f"{self.RAW_URL}/{owner}/{repo}/{tag}/{path}"

        response = requests.get(url, headers=self.headers)
        response.raise_for_status()

        return response.json()
```

**Step 4: Run test to verify it passes**

Run: `cd src/gks-registry && python -m pytest tests/test_github_client.py -v`
Expected: All 5 tests PASS

**Step 5: Commit**

```bash
git add src/gks-registry/github_client.py src/gks-registry/tests/test_github_client.py
git commit -m "feat(gks-registry): add GitHub API client with pagination"
```

---

## Task 5: Markdown Generator

**Files:**
- Create: `src/gks-registry/markdown_generator.py`
- Create: `src/gks-registry/tests/test_markdown_generator.py`

**Step 1: Write the failing test**

```python
"""Tests for markdown generator."""
import pytest
from datetime import datetime


def test_generate_readme():
    from markdown_generator import generate_readme
    from models import RepoInfo, ReleaseInfo, SchemaInfo

    repos = {
        "vrs": RepoInfo(
            name="vrs",
            url="https://github.com/ga4gh/vrs",
            releases={
                "v2.0.0": ReleaseInfo(
                    tag="v2.0.0",
                    name="2.0.0",
                    published_at=datetime(2025, 3, 14),
                    schemas={
                        "Allele": SchemaInfo("id", "Allele", "normative", "desc", "VA", "2.x"),
                        "Location": SchemaInfo("id", "Location", "trial use", "desc", None, "2.x"),
                    }
                )
            }
        )
    }

    result = generate_readme(repos, datetime(2026, 3, 5, 12, 0, 0))

    assert "# GKS Schema Registry" in result
    assert "vrs" in result
    assert "v2.0.0" in result
    assert "| 2 |" in result  # schema count


def test_generate_maturity_matrix():
    from markdown_generator import generate_maturity_matrix
    from models import RepoInfo, ReleaseInfo, SchemaInfo

    repos = {
        "vrs": RepoInfo(
            name="vrs",
            url="https://github.com/ga4gh/vrs",
            releases={
                "v2.0.0": ReleaseInfo(
                    tag="v2.0.0",
                    name="2.0.0",
                    published_at=datetime(2025, 3, 14),
                    schemas={
                        "Allele": SchemaInfo("id1", "Allele", "normative", "desc", "VA", "2.x"),
                        "Location": SchemaInfo("id2", "Location", "trial use", "desc", None, "2.x"),
                    }
                )
            }
        )
    }

    result = generate_maturity_matrix(repos)

    assert "# Maturity Matrix" in result
    assert "## Normative" in result
    assert "Allele" in result
    assert "## Trial Use" in result
    assert "Location" in result


def test_generate_release_history():
    from markdown_generator import generate_release_history
    from models import RepoInfo, ReleaseInfo, SchemaInfo

    repos = {
        "vrs": RepoInfo(
            name="vrs",
            url="https://github.com/ga4gh/vrs",
            releases={
                "v2.0.0": ReleaseInfo(
                    tag="v2.0.0",
                    name="2.0.0",
                    published_at=datetime(2025, 3, 14),
                    schemas={"Allele": SchemaInfo("id", "Allele", "normative", "desc", "VA", "2.x")}
                ),
                "v1.0.0": ReleaseInfo(
                    tag="v1.0.0",
                    name="1.0.0",
                    published_at=datetime(2024, 1, 1),
                    schemas={}
                )
            }
        )
    }

    result = generate_release_history(repos)

    assert "# Release History" in result
    assert "2025" in result
    assert "v2.0.0" in result
    assert "2024" in result
    assert "v1.0.0" in result
```

**Step 2: Run test to verify it fails**

Run: `cd src/gks-registry && python -m pytest tests/test_markdown_generator.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'markdown_generator'"

**Step 3: Write implementation**

```python
"""Markdown generation for GKS Schema Registry documentation."""
from datetime import datetime
from collections import defaultdict

from models import RepoInfo, ReleaseInfo


def generate_readme(repos: dict[str, RepoInfo], generated_at: datetime) -> str:
    """
    Generate the main README with summary table.

    Args:
        repos: Dictionary of repo name to RepoInfo
        generated_at: Timestamp for the generation

    Returns:
        Markdown string
    """
    lines = [
        "# GKS Schema Registry",
        "",
        f"> Auto-generated: {generated_at.isoformat()}Z",
        "",
        "## Summary",
        "",
        "| Repo | Latest Release | Schemas | Normative | Trial Use | Draft |",
        "|------|----------------|---------|-----------|-----------|-------|",
    ]

    for name, repo in sorted(repos.items()):
        if not repo.releases:
            continue

        # Get latest release by date
        latest = max(repo.releases.values(), key=lambda r: r.published_at)
        summary = latest.maturity_summary()

        lines.append(
            f"| {name} | {latest.tag} | {len(latest.schemas)} | "
            f"{summary.get('normative', 0)} | {summary.get('trial use', 0)} | "
            f"{summary.get('draft', 0)} |"
        )

    lines.extend([
        "",
        "## Quick Links",
        "",
        "- [Maturity Matrix](maturity-matrix.md)",
        "- [Release History](release-history.md)",
        "- [JSON Data](../data/registry.json)",
        "",
    ])

    return "\n".join(lines)


def generate_maturity_matrix(repos: dict[str, RepoInfo]) -> str:
    """
    Generate maturity matrix showing schemas grouped by maturity level.

    Args:
        repos: Dictionary of repo name to RepoInfo

    Returns:
        Markdown string
    """
    # Collect schemas by maturity from latest release of each repo
    by_maturity: dict[str, list[tuple[str, str, str, str]]] = defaultdict(list)

    for name, repo in repos.items():
        if not repo.releases:
            continue

        latest = max(repo.releases.values(), key=lambda r: r.published_at)
        for schema_name, schema in latest.schemas.items():
            by_maturity[schema.maturity].append(
                (schema_name, name, latest.tag, schema.id)
            )

    lines = [
        "# Maturity Matrix",
        "",
        "Schemas grouped by maturity level from the latest release of each repository.",
        "",
    ]

    # Output in order: normative, trial use, draft, deprecated, unknown
    maturity_order = ["normative", "trial use", "draft", "deprecated", "unknown"]

    for maturity in maturity_order:
        schemas = by_maturity.get(maturity, [])
        if not schemas:
            continue

        # Title case the maturity level
        title = maturity.title()
        lines.extend([
            f"## {title}",
            "",
            "| Schema | Repo | Release | $id |",
            "|--------|------|---------|-----|",
        ])

        for schema_name, repo_name, tag, schema_id in sorted(schemas):
            lines.append(f"| {schema_name} | {repo_name} | {tag} | `{schema_id}` |")

        lines.append("")

    return "\n".join(lines)


def generate_release_history(repos: dict[str, RepoInfo]) -> str:
    """
    Generate release history timeline.

    Args:
        repos: Dictionary of repo name to RepoInfo

    Returns:
        Markdown string
    """
    # Collect all releases with their repo
    all_releases: list[tuple[datetime, str, ReleaseInfo]] = []

    for name, repo in repos.items():
        for release in repo.releases.values():
            all_releases.append((release.published_at, name, release))

    # Sort by date descending
    all_releases.sort(key=lambda x: x[0], reverse=True)

    lines = [
        "# Release History",
        "",
        "All releases across GKS repositories, sorted by date.",
        "",
    ]

    # Group by year
    current_year = None

    for published_at, repo_name, release in all_releases:
        year = published_at.year

        if year != current_year:
            current_year = year
            lines.extend([
                f"## {year}",
                "",
                "| Date | Repo | Release | Schemas |",
                "|------|------|---------|---------|",
            ])

        date_str = published_at.strftime("%Y-%m-%d")
        lines.append(f"| {date_str} | {repo_name} | {release.tag} | {len(release.schemas)} |")

    lines.append("")

    return "\n".join(lines)
```

**Step 4: Run test to verify it passes**

Run: `cd src/gks-registry && python -m pytest tests/test_markdown_generator.py -v`
Expected: All 3 tests PASS

**Step 5: Commit**

```bash
git add src/gks-registry/markdown_generator.py src/gks-registry/tests/test_markdown_generator.py
git commit -m "feat(gks-registry): add markdown generator for docs"
```

---

## Task 6: Main Orchestrator

**Files:**
- Create: `src/gks-registry/fetch_schemas.py`
- Create: `src/gks-registry/tests/test_fetch_schemas.py`

**Step 1: Write the failing test**

```python
"""Tests for main orchestrator."""
import pytest
from unittest.mock import Mock, patch, MagicMock
from datetime import datetime
import json
import os


def test_load_config():
    from fetch_schemas import load_config

    config = load_config()

    assert "repos" in config
    assert len(config["repos"]) == 4
    assert config["repos"][0]["name"] == "gks-core"


def test_load_existing_registry_empty():
    from fetch_schemas import load_existing_registry

    with patch("builtins.open", side_effect=FileNotFoundError):
        result = load_existing_registry("nonexistent.json")

    assert result == {}


def test_save_registry():
    from fetch_schemas import save_registry
    from models import RepoInfo

    repos = {"vrs": RepoInfo(name="vrs", url="https://github.com/ga4gh/vrs", releases={})}

    mock_file = MagicMock()
    with patch("builtins.open", return_value=mock_file):
        save_registry(repos, "test.json", datetime(2026, 3, 5))

    # Verify open was called
    mock_file.__enter__().write.assert_called()


def test_process_release():
    from fetch_schemas import process_release
    from github_client import GitHubClient

    mock_client = Mock(spec=GitHubClient)
    mock_client.get_schema_files.return_value = ["Allele", "Location"]
    mock_client.get_file_content.side_effect = [
        {"$id": "id1", "title": "Allele", "maturity": "normative"},
        {"$id": "id2", "title": "Location", "maturity": "trial use"},
    ]

    repo_config = {"owner": "ga4gh", "name": "vrs", "schema_path": "schema/vrs/json"}
    release_data = {"tag_name": "v2.0.0", "name": "2.0.0", "published_at": "2025-03-14T00:00:00Z"}

    result = process_release(mock_client, repo_config, release_data)

    assert result.tag == "v2.0.0"
    assert len(result.schemas) == 2
    assert "Allele" in result.schemas
```

**Step 2: Run test to verify it fails**

Run: `cd src/gks-registry && python -m pytest tests/test_fetch_schemas.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'fetch_schemas'"

**Step 3: Write implementation**

```python
#!/usr/bin/env python3
"""
GKS Schema Registry - Main orchestrator.

Fetches schema metadata from GA4GH GKS repositories and generates
JSON data files and Markdown documentation.
"""
import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path

import yaml

from github_client import GitHubClient
from models import RepoInfo, ReleaseInfo, SchemaInfo
from schema_parser import parse_schema
from markdown_generator import generate_readme, generate_maturity_matrix, generate_release_history


def load_config(config_path: str = None) -> dict:
    """Load configuration from YAML file."""
    if config_path is None:
        config_path = Path(__file__).parent / "config.yaml"

    with open(config_path) as f:
        return yaml.safe_load(f)


def load_existing_registry(path: str) -> dict:
    """Load existing registry JSON if it exists."""
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def process_release(client: GitHubClient, repo_config: dict, release_data: dict) -> ReleaseInfo:
    """
    Process a single release: fetch all schemas and parse them.

    Args:
        client: GitHub API client
        repo_config: Repository configuration from config.yaml
        release_data: Release data from GitHub API

    Returns:
        ReleaseInfo with all schemas populated
    """
    tag = release_data["tag_name"]
    name = release_data.get("name", tag)
    published_at = datetime.fromisoformat(release_data["published_at"].replace("Z", "+00:00"))

    schemas = {}

    try:
        schema_files = client.get_schema_files(
            repo_config["owner"],
            repo_config["name"],
            tag,
            repo_config["schema_path"]
        )

        for filename in schema_files:
            try:
                path = f"{repo_config['schema_path']}/{filename}"
                content = client.get_file_content(
                    repo_config["owner"],
                    repo_config["name"],
                    tag,
                    path
                )
                schema_info = parse_schema(content)
                schemas[schema_info.title or filename] = schema_info
            except Exception as e:
                print(f"  Warning: Failed to parse {filename}: {e}", file=sys.stderr)

    except Exception as e:
        print(f"  Warning: Failed to list schemas for {tag}: {e}", file=sys.stderr)

    return ReleaseInfo(
        tag=tag,
        name=name,
        published_at=published_at.replace(tzinfo=None),
        schemas=schemas
    )


def save_registry(repos: dict[str, RepoInfo], path: str, generated_at: datetime) -> None:
    """Save the master registry JSON file."""
    data = {
        "generated_at": generated_at.isoformat() + "Z",
        "repos": {name: repo.to_dict() for name, repo in repos.items()}
    }

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def save_by_repo(repos: dict[str, RepoInfo], base_dir: str) -> None:
    """Save per-repo JSON files."""
    for name, repo in repos.items():
        repo_dir = Path(base_dir) / name
        repo_dir.mkdir(parents=True, exist_ok=True)

        for tag, release in repo.releases.items():
            # Sanitize tag for filename
            safe_tag = tag.replace("/", "-")
            path = repo_dir / f"{safe_tag}.json"

            data = {
                "repo": name,
                **release.to_dict()
            }

            with open(path, "w") as f:
                json.dump(data, f, indent=2)


def save_by_maturity(repos: dict[str, RepoInfo], base_dir: str, generated_at: datetime) -> None:
    """Save by-maturity JSON files."""
    from collections import defaultdict

    by_maturity: dict[str, list[dict]] = defaultdict(list)

    for name, repo in repos.items():
        if not repo.releases:
            continue

        # Use latest release
        latest = max(repo.releases.values(), key=lambda r: r.published_at)

        for schema_name, schema in latest.schemas.items():
            by_maturity[schema.maturity].append({
                "repo": name,
                "release": latest.tag,
                "name": schema_name,
                "$id": schema.id
            })

    base_path = Path(base_dir)
    base_path.mkdir(parents=True, exist_ok=True)

    for maturity, schemas in by_maturity.items():
        # Sanitize maturity for filename
        safe_maturity = maturity.replace(" ", "-").lower()
        path = base_path / f"{safe_maturity}.json"

        data = {
            "maturity": maturity,
            "generated_at": generated_at.isoformat() + "Z",
            "schemas": sorted(schemas, key=lambda s: (s["repo"], s["name"]))
        }

        with open(path, "w") as f:
            json.dump(data, f, indent=2)


def save_docs(repos: dict[str, RepoInfo], docs_dir: str, generated_at: datetime) -> None:
    """Generate and save markdown documentation."""
    docs_path = Path(docs_dir)
    docs_path.mkdir(parents=True, exist_ok=True)

    # README
    readme = generate_readme(repos, generated_at)
    (docs_path / "README.md").write_text(readme)

    # Maturity matrix
    matrix = generate_maturity_matrix(repos)
    (docs_path / "maturity-matrix.md").write_text(matrix)

    # Release history
    history = generate_release_history(repos)
    (docs_path / "release-history.md").write_text(history)


def main(full_refresh: bool = False) -> None:
    """
    Main entry point.

    Args:
        full_refresh: If True, re-fetch all releases. If False, only fetch new ones.
    """
    config = load_config()
    client = GitHubClient()

    base_dir = Path(__file__).parent
    data_dir = base_dir / config["output"]["data_dir"]
    docs_dir = base_dir / config["output"]["docs_dir"]
    registry_path = data_dir / "registry.json"

    # Load existing registry if not doing full refresh
    existing = {} if full_refresh else load_existing_registry(registry_path)

    repos: dict[str, RepoInfo] = {}
    generated_at = datetime.utcnow()

    for repo_config in config["repos"]:
        name = repo_config["name"]
        owner = repo_config["owner"]

        print(f"Processing {owner}/{name}...")

        # Get existing releases for this repo
        existing_tags = set()
        if name in existing.get("repos", {}):
            existing_tags = set(existing["repos"][name].get("releases", {}).keys())

        # Fetch releases from GitHub
        releases_data = client.get_releases(owner, name)
        print(f"  Found {len(releases_data)} releases")

        repo = RepoInfo(
            name=name,
            url=f"https://github.com/{owner}/{name}",
            releases={}
        )

        for release_data in releases_data:
            tag = release_data["tag_name"]

            if tag in existing_tags and not full_refresh:
                print(f"  Skipping {tag} (already processed)")
                # Copy from existing
                existing_release = existing["repos"][name]["releases"][tag]
                repo.releases[tag] = ReleaseInfo(
                    tag=tag,
                    name=existing_release["name"],
                    published_at=datetime.fromisoformat(existing_release["published_at"]),
                    schemas={
                        sname: SchemaInfo(
                            id=sdata["$id"],
                            title=sdata["title"],
                            maturity=sdata["maturity"],
                            description=sdata["description"],
                            ga4gh_prefix=sdata["ga4gh_prefix"],
                            version=sdata["version"]
                        )
                        for sname, sdata in existing_release["schemas"].items()
                    }
                )
            else:
                print(f"  Processing {tag}...")
                repo.releases[tag] = process_release(client, repo_config, release_data)
                print(f"    Found {len(repo.releases[tag].schemas)} schemas")

        repos[name] = repo

    # Save outputs
    print("\nSaving outputs...")

    save_registry(repos, registry_path, generated_at)
    print(f"  Saved registry.json")

    save_by_repo(repos, data_dir / "by-repo")
    print(f"  Saved by-repo JSON files")

    save_by_maturity(repos, data_dir / "by-maturity", generated_at)
    print(f"  Saved by-maturity JSON files")

    save_docs(repos, docs_dir, generated_at)
    print(f"  Saved markdown docs")

    print("\nDone!")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="GKS Schema Registry updater")
    parser.add_argument(
        "--full-refresh",
        action="store_true",
        help="Re-fetch all releases instead of incremental update"
    )
    args = parser.parse_args()

    main(full_refresh=args.full_refresh)
```

**Step 4: Run test to verify it passes**

Run: `cd src/gks-registry && python -m pytest tests/test_fetch_schemas.py -v`
Expected: All 4 tests PASS

**Step 5: Commit**

```bash
git add src/gks-registry/fetch_schemas.py src/gks-registry/tests/test_fetch_schemas.py
git commit -m "feat(gks-registry): add main orchestrator with incremental updates"
```

---

## Task 7: GitHub Actions Workflow

**Files:**
- Create: `.github/workflows/update-gks-registry.yml`

**Step 1: Create the workflow file**

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
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'

      - name: Install dependencies
        run: pip install -r src/gks-registry/requirements.txt

      - name: Fetch and update registry
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        working-directory: src/gks-registry
        run: |
          if [ "${{ inputs.full_refresh }}" = "true" ]; then
            python fetch_schemas.py --full-refresh
          else
            python fetch_schemas.py
          fi

      - name: Commit changes
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add src/gks-registry/data/ src/gks-registry/docs/
          if git diff --staged --quiet; then
            echo "No changes to commit"
          else
            git commit -m "Update GKS schema registry $(date -u +%Y-%m-%d)"
            git push
          fi
```

**Step 2: Verify workflow syntax**

Run: `cat .github/workflows/update-gks-registry.yml | python -c "import yaml, sys; yaml.safe_load(sys.stdin); print('Valid YAML')"`
Expected: "Valid YAML"

**Step 3: Commit**

```bash
git add .github/workflows/update-gks-registry.yml
git commit -m "ci: add GitHub Action for on-demand registry updates"
```

---

## Task 8: Integration Test - Local Run

**Files:**
- None (verification only)

**Step 1: Install dependencies**

Run: `cd src/gks-registry && pip install -r requirements.txt`
Expected: Successfully installed requests and PyYAML

**Step 2: Run the tool locally (limited test)**

Run: `cd src/gks-registry && python fetch_schemas.py --full-refresh 2>&1 | head -50`
Expected: Output showing "Processing ga4gh/gks-core...", "Found X releases", etc.

**Step 3: Verify outputs exist**

Run: `ls -la src/gks-registry/data/`
Expected: registry.json, by-repo/, by-maturity/ directories

**Step 4: Verify markdown docs exist**

Run: `ls -la src/gks-registry/docs/`
Expected: README.md, maturity-matrix.md, release-history.md

**Step 5: Commit generated data**

```bash
git add src/gks-registry/data/ src/gks-registry/docs/
git commit -m "feat(gks-registry): initial registry data from all 4 repos"
```

---

## Task 9: Final Cleanup and Documentation

**Files:**
- Create: `src/gks-registry/README.md`

**Step 1: Create README for the module**

```markdown
# GKS Schema Registry

A tool that aggregates JSON schema metadata from GA4GH GKS repositories.

## Repositories Tracked

- [gks-core](https://github.com/ga4gh/gks-core)
- [vrs](https://github.com/ga4gh/vrs)
- [cat-vrs](https://github.com/ga4gh/cat-vrs)
- [va-spec](https://github.com/ga4gh/va-spec)

## Usage

### Local Execution

```bash
cd src/gks-registry
pip install -r requirements.txt
python fetch_schemas.py
```

### Full Refresh

```bash
python fetch_schemas.py --full-refresh
```

### Via GitHub Actions

```bash
gh workflow run update-gks-registry.yml
gh workflow run update-gks-registry.yml -f full_refresh=true
```

## Outputs

- `data/registry.json` - Master registry with all repos, releases, schemas
- `data/by-repo/<repo>/<tag>.json` - Per-release JSON files
- `data/by-maturity/<level>.json` - Schemas grouped by maturity
- `docs/README.md` - Overview with summary table
- `docs/maturity-matrix.md` - Cross-repo maturity view
- `docs/release-history.md` - Timeline of all releases

## Configuration

Edit `config.yaml` to add/remove repositories or change paths.
```

**Step 2: Run all tests**

Run: `cd src/gks-registry && python -m pytest tests/ -v`
Expected: All tests PASS

**Step 3: Final commit**

```bash
git add src/gks-registry/README.md
git commit -m "docs(gks-registry): add README with usage instructions"
```

---

## Summary

| Task | Description | Est. Steps |
|------|-------------|------------|
| 1 | Project scaffolding | 5 |
| 2 | Data models | 5 |
| 3 | Schema parser | 5 |
| 4 | GitHub client | 5 |
| 5 | Markdown generator | 5 |
| 6 | Main orchestrator | 5 |
| 7 | GitHub Actions workflow | 3 |
| 8 | Integration test | 5 |
| 9 | Final cleanup | 3 |

**Total: 9 tasks, ~41 steps**
