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

        for file_path in schema_files:
            # Get filename from full path
            filename = file_path.split("/")[-1]

            # Skip example schemas
            if filename.lower().startswith("example"):
                continue

            try:
                content = client.get_file_content(
                    repo_config["owner"],
                    repo_config["name"],
                    tag,
                    file_path
                )
                schema_info = parse_schema(content)

                # Skip schemas with titles starting with "example"
                title = schema_info.title or filename
                if title.lower().startswith("example"):
                    continue

                schemas[title] = schema_info
            except Exception as e:
                print(f"  Warning: Failed to parse {file_path}: {e}", file=sys.stderr)

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
