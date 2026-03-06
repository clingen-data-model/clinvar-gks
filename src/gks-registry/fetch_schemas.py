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

import re

from github_client import GitHubClient
from models import RepoInfo, ReleaseInfo, SchemaInfo, Dependency
from schema_parser import parse_schema


def get_github_schema_url(owner: str, repo: str, tag: str, source_path: str) -> str:
    """Generate full GitHub URL for a schema file."""
    return f"https://github.com/{owner}/{repo}/blob/{tag}/{source_path}"


def get_release_url(owner: str, repo: str, tag: str) -> str:
    """Generate GitHub release page URL."""
    return f"https://github.com/{owner}/{repo}/releases/tag/{tag}"


def extract_refs(content: dict, refs: list[str] = None) -> list[str]:
    """
    Recursively extract all $ref values from a JSON schema.

    Args:
        content: JSON schema content (dict or any value)
        refs: List to accumulate refs (created if None)

    Returns:
        List of unique $ref values
    """
    if refs is None:
        refs = []

    if isinstance(content, dict):
        for key, value in content.items():
            if key == "$ref" and isinstance(value, str):
                if value not in refs:
                    refs.append(value)
            else:
                extract_refs(value, refs)
    elif isinstance(content, list):
        for item in content:
            extract_refs(item, refs)

    return refs


def parse_ref_to_dependency(ref: str, current_repo: str, current_tag: str) -> Dependency | None:
    """
    Parse a $ref URL to extract product and release dependency.

    Example refs:
    - https://w3id.org/ga4gh/schema/gks-core/1.0.0/json/Coding
    - https://w3id.org/ga4gh/schema/vrs/2.0.0/json/Allele
    - /ga4gh/schema/gks-common/1.x/json/Extension

    Args:
        ref: The $ref URL value
        current_repo: Current repository name (to exclude self-references)
        current_tag: Current release tag (to exclude self-references)

    Returns:
        Dependency object or None if self-reference or unparseable
    """
    # Pattern for GA4GH schema $refs
    # Match: /ga4gh/schema/<product>/<version>/... or https://w3id.org/ga4gh/schema/<product>/<version>/...
    pattern = r"(?:https?://w3id\.org)?/ga4gh/schema/([^/]+)/([^/]+)/"
    match = re.search(pattern, ref)

    if not match:
        return None

    product = match.group(1)
    release = match.group(2)

    # Skip self-references (same product)
    # Note: product names may differ slightly (gks-common vs gks-core)
    if product == current_repo:
        return None

    return Dependency(product=product, release=release)


def calculate_dependencies(schemas: dict[str, SchemaInfo], current_repo: str, current_tag: str) -> list[Dependency]:
    """
    Calculate unique external dependencies from all schema $refs.

    Args:
        schemas: Dictionary of schema name to SchemaInfo
        current_repo: Current repository name
        current_tag: Current release tag

    Returns:
        List of unique Dependency objects
    """
    seen = set()
    dependencies = []

    for schema in schemas.values():
        for ref in schema.refs:
            dep = parse_ref_to_dependency(ref, current_repo, current_tag)
            if dep:
                key = (dep.product, dep.release)
                if key not in seen:
                    seen.add(key)
                    dependencies.append(dep)

    # Sort by product then release
    dependencies.sort(key=lambda d: (d.product, d.release))
    return dependencies
from markdown_generator import (
    generate_readme,
    generate_maturity_matrix,
    generate_release_history,
    generate_changelog,
    generate_release_notes,
    is_standard_release,
)


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

    Tries multiple schema paths and falls back to combined schema files.

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
    release_notes = release_data.get("body", "").strip() or None

    schemas = {}
    owner = repo_config["owner"]
    repo_name = repo_config["name"]
    release_url = get_release_url(owner, repo_name, tag)

    # Try each schema path until one works
    schema_paths = repo_config.get("schema_paths", [repo_config.get("schema_path")])
    for schema_path in schema_paths:
        if not schema_path:
            continue

        try:
            if not client.path_exists(owner, repo_name, tag, schema_path):
                continue

            schema_files = client.get_schema_files(owner, repo_name, tag, schema_path)

            for file_path in schema_files:
                filename = file_path.split("/")[-1]

                # Skip example schemas
                if filename.lower().startswith("example"):
                    continue

                try:
                    content = client.get_file_content(owner, repo_name, tag, file_path)
                    title, schema_info = parse_schema(content)

                    # Use title as schema name, fall back to filename
                    schema_name = title or filename
                    if schema_name.lower().startswith("example"):
                        continue

                    # Set source path and github_url
                    schema_info.source_path = file_path
                    schema_info.github_url = get_github_schema_url(owner, repo_name, tag, file_path)

                    # Extract $refs from schema content
                    schema_info.refs = extract_refs(content)

                    schemas[schema_name] = schema_info
                except Exception as e:
                    print(f"    Warning: Failed to parse {file_path}: {e}", file=sys.stderr)

        except Exception as e:
            continue  # Try next path

    # If no schemas found, try combined schema files
    if not schemas:
        combined_schemas = repo_config.get("combined_schemas", [])
        # Support legacy single combined_schema field
        if not combined_schemas and repo_config.get("combined_schema"):
            combined_schemas = [{"path": repo_config["combined_schema"]}]

        for combined_config in combined_schemas:
            combined_path = combined_config.get("path") if isinstance(combined_config, dict) else combined_config
            if not combined_path:
                continue

            try:
                if not client.path_exists(owner, repo_name, tag, combined_path):
                    continue

                content = client.get_file_content(owner, repo_name, tag, combined_path)

                # Check for separate prefix map file
                prefix_map = {}
                prefix_map_path = (
                    combined_config.get("prefix_map")
                    if isinstance(combined_config, dict) else None
                )
                if prefix_map_path and client.path_exists(
                    owner, repo_name, tag, prefix_map_path
                ):
                    try:
                        prefix_content = client.get_file_content(
                            owner, repo_name, tag, prefix_map_path
                        )
                        # ga4gh.json has type_prefix_map nested under identifiers
                        identifiers = prefix_content.get("identifiers", {})
                        prefix_map = identifiers.get("type_prefix_map", {})
                        # Also check top-level for backwards compatibility
                        if not prefix_map:
                            prefix_map = prefix_content.get("type_prefix_map", {})
                    except Exception:
                        pass

                schemas = parse_combined_schema(content, prefix_map, combined_path, owner, repo_name, tag)
                if schemas:
                    break
            except Exception as e:
                print(f"    Warning: Failed to parse {combined_path}: {e}", file=sys.stderr)

    # Calculate dependencies from $refs
    dependencies = calculate_dependencies(schemas, repo_name, tag)

    return ReleaseInfo(
        tag=tag,
        name=name,
        published_at=published_at.replace(tzinfo=None),
        schemas=schemas,
        release_notes=release_notes,
        release_url=release_url,
        dependencies=dependencies
    )


def parse_combined_schema(
    content: dict,
    prefix_map: dict = None,
    source_path: str = None,
    owner: str = None,
    repo_name: str = None,
    tag: str = None
) -> dict[str, SchemaInfo]:
    """
    Parse a combined schema file (like vrs.json) that contains all schemas
    in a 'definitions' or '$defs' section.

    Args:
        content: The combined JSON schema content
        prefix_map: Optional mapping of schema name to ga4gh prefix
        source_path: Path to the combined schema file in the repo
        owner: GitHub owner (for building github_url)
        repo_name: Repository name (for building github_url)
        tag: Release tag (for building github_url)

    Returns:
        Dictionary of schema name to SchemaInfo
    """
    schemas = {}
    prefix_map = prefix_map or {}

    # Build github_url for combined schema file
    github_url = None
    if owner and repo_name and tag and source_path:
        github_url = get_github_schema_url(owner, repo_name, tag, source_path)

    # Look for definitions in either 'definitions' or '$defs'
    definitions = content.get("definitions", content.get("$defs", {}))

    for schema_name, schema_def in definitions.items():
        # Skip internal/utility types (typically lowercase or very short names)
        if schema_name[0].islower() and len(schema_name) < 10:
            continue

        # Skip example schemas
        if schema_name.lower().startswith("example"):
            continue

        # Extract what we can from the definition
        schema_id = schema_def.get("$id", "")
        description = schema_def.get("description", "")
        maturity = schema_def.get("maturity", "unknown")

        # Try to extract ga4gh prefix from schema, or use prefix_map
        ga4gh_prefix = prefix_map.get(schema_name)
        if not ga4gh_prefix:
            for prop_name in ("ga4gh", "ga4ghDigest"):
                ga4gh_obj = schema_def.get(prop_name, {})
                if isinstance(ga4gh_obj, dict) and "prefix" in ga4gh_obj:
                    ga4gh_prefix = ga4gh_obj["prefix"]
                    break

        # Extract $refs from this schema definition
        refs = extract_refs(schema_def)

        schemas[schema_name] = SchemaInfo(
            id=schema_id,
            maturity=maturity,
            description=description,
            ga4gh_prefix=ga4gh_prefix,
            source_path=source_path,
            github_url=github_url,
            refs=refs,
        )

    return schemas


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

    # Changelog
    changelog = generate_changelog(repos)
    (docs_path / "changelog.md").write_text(changelog)

    # Per-release notes
    releases_path = docs_path / "releases"
    release_notes = generate_release_notes(repos, generated_at)
    for filename, content in release_notes.items():
        file_path = releases_path / filename
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_text(content)


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
                            maturity=sdata["maturity"],
                            description=sdata["description"],
                            ga4gh_prefix=sdata.get("ga4gh_prefix"),
                            source_path=sdata.get("source_path"),
                            github_url=sdata.get("github_url"),
                        )
                        for sname, sdata in existing_release["schemas"].items()
                        if not sname.lower().startswith("example")
                    },
                    release_notes=existing_release.get("release_notes"),
                    release_url=existing_release.get("release_url"),
                    previous_release=existing_release.get("previous_release"),
                    dependencies=[
                        Dependency(product=d["product"], release=d["release"])
                        for d in existing_release.get("dependencies", [])
                    ]
                )
            else:
                print(f"  Processing {tag}...")
                repo.releases[tag] = process_release(client, repo_config, release_data)
                print(f"    Found {len(repo.releases[tag].schemas)} schemas")

        repos[name] = repo

    # Post-process: set previous_release for each release
    print("\nCalculating previous releases...")
    for repo in repos.values():
        # Sort releases by date
        sorted_releases = sorted(
            repo.releases.values(),
            key=lambda r: r.published_at
        )
        # Set previous_release for each
        # Standard releases point to previous standard release
        # Non-standard releases point to previous release (any type)
        for i, release in enumerate(sorted_releases):
            # Reset to None first (clear any stale cached values)
            release.previous_release = None
            if i > 0:
                if is_standard_release(release.tag):
                    # Find the most recent standard release before this one
                    for j in range(i - 1, -1, -1):
                        if is_standard_release(sorted_releases[j].tag):
                            release.previous_release = sorted_releases[j].tag
                            break
                else:
                    # Non-standard releases point to any previous release
                    release.previous_release = sorted_releases[i - 1].tag

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
