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

    schemas = {}
    owner = repo_config["owner"]
    repo_name = repo_config["name"]

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

                    schemas[schema_name] = schema_info
                except Exception as e:
                    print(f"    Warning: Failed to parse {file_path}: {e}", file=sys.stderr)

            if schemas:
                break  # Found schemas, stop trying other paths

        except Exception as e:
            continue  # Try next path

    # If no schemas found, try combined schema file
    if not schemas and repo_config.get("combined_schema"):
        combined_path = repo_config["combined_schema"]
        try:
            if client.path_exists(owner, repo_name, tag, combined_path):
                content = client.get_file_content(owner, repo_name, tag, combined_path)
                schemas = parse_combined_schema(content)
        except Exception as e:
            print(f"    Warning: Failed to parse combined schema: {e}", file=sys.stderr)

    return ReleaseInfo(
        tag=tag,
        name=name,
        published_at=published_at.replace(tzinfo=None),
        schemas=schemas
    )


def parse_combined_schema(content: dict) -> dict[str, SchemaInfo]:
    """
    Parse a combined schema file (like vrs.json) that contains all schemas
    in a 'definitions' or '$defs' section.

    Args:
        content: The combined JSON schema content

    Returns:
        Dictionary of schema name to SchemaInfo
    """
    schemas = {}

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

        # Try to extract ga4gh prefix
        ga4gh_prefix = None
        for prop_name in ("ga4gh", "ga4ghDigest"):
            ga4gh_obj = schema_def.get(prop_name, {})
            if isinstance(ga4gh_obj, dict) and "prefix" in ga4gh_obj:
                ga4gh_prefix = ga4gh_obj["prefix"]
                break

        schemas[schema_name] = SchemaInfo(
            id=schema_id,
            maturity=maturity,
            description=description,
            ga4gh_prefix=ga4gh_prefix,
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
                        )
                        for sname, sdata in existing_release["schemas"].items()
                        if not sname.lower().startswith("example")
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
