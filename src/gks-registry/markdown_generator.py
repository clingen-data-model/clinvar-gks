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
