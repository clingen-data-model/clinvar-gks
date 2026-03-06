"""Markdown generation for GKS Schema Registry documentation."""
from dataclasses import dataclass, field
from datetime import datetime
from collections import defaultdict
from typing import Optional

from models import RepoInfo, ReleaseInfo, SchemaInfo


@dataclass
class SchemaChange:
    """Represents a change to a schema between releases."""
    name: str
    change_type: str  # "added", "removed", "modified"
    details: list[str] = field(default_factory=list)
    old_schema: Optional[SchemaInfo] = None
    new_schema: Optional[SchemaInfo] = None


@dataclass
class ReleaseDiff:
    """Represents the diff between two releases."""
    repo: str
    from_tag: Optional[str]
    to_tag: str
    added: list[SchemaChange] = field(default_factory=list)
    removed: list[SchemaChange] = field(default_factory=list)
    modified: list[SchemaChange] = field(default_factory=list)

    @property
    def has_changes(self) -> bool:
        return bool(self.added or self.removed or self.modified)


def is_standard_release(tag: str) -> bool:
    """
    Check if a release is a standard release (not pre-release or development version).

    Standard releases don't contain -snapshot, -ballot, -connect, or -rc suffixes.
    """
    tag_lower = tag.lower()
    return not any(
        suffix in tag_lower
        for suffix in ["-snapshot", "-ballot", "-connect", ".connect", "-rc"]
    )


def compare_releases(
    repo_name: str,
    old_release: Optional[ReleaseInfo],
    new_release: ReleaseInfo
) -> ReleaseDiff:
    """
    Compare two releases and identify schema changes.

    Args:
        repo_name: Name of the repository
        old_release: Previous release (None for first release)
        new_release: Current release

    Returns:
        ReleaseDiff with added, removed, and modified schemas
    """
    old_schemas = old_release.schemas if old_release else {}
    new_schemas = new_release.schemas

    old_names = set(old_schemas.keys())
    new_names = set(new_schemas.keys())

    diff = ReleaseDiff(
        repo=repo_name,
        from_tag=old_release.tag if old_release else None,
        to_tag=new_release.tag
    )

    # Added schemas
    for name in sorted(new_names - old_names):
        diff.added.append(SchemaChange(
            name=name,
            change_type="added",
            new_schema=new_schemas[name]
        ))

    # Removed schemas
    for name in sorted(old_names - new_names):
        diff.removed.append(SchemaChange(
            name=name,
            change_type="removed",
            old_schema=old_schemas[name]
        ))

    # Modified schemas
    for name in sorted(old_names & new_names):
        old_schema = old_schemas[name]
        new_schema = new_schemas[name]
        changes = []

        if old_schema.maturity != new_schema.maturity:
            changes.append(
                f"maturity: `{old_schema.maturity}` → `{new_schema.maturity}`"
            )

        if old_schema.ga4gh_prefix != new_schema.ga4gh_prefix:
            old_prefix = old_schema.ga4gh_prefix or "none"
            new_prefix = new_schema.ga4gh_prefix or "none"
            changes.append(f"ga4gh_prefix: `{old_prefix}` → `{new_prefix}`")

        # Note: $id changes are omitted as they are typically version bumps

        # Only flag description changes if substantive (not just whitespace)
        old_desc = (old_schema.description or "").strip()
        new_desc = (new_schema.description or "").strip()
        if old_desc != new_desc:
            if not old_desc and new_desc:
                changes.append("description: added")
            elif old_desc and not new_desc:
                changes.append("description: removed")
            else:
                changes.append("description: updated")

        if changes:
            diff.modified.append(SchemaChange(
                name=name,
                change_type="modified",
                details=changes,
                old_schema=old_schema,
                new_schema=new_schema
            ))

    return diff


def generate_changelog(repos: dict[str, RepoInfo]) -> str:
    """
    Generate a changelog showing schema changes between releases.

    Args:
        repos: Dictionary of repo name to RepoInfo

    Returns:
        Markdown string
    """
    lines = [
        "# Schema Changelog",
        "",
        "Changes to schemas between releases, organized by repository.",
        "",
    ]

    for repo_name in sorted(repos.keys()):
        repo = repos[repo_name]
        if not repo.releases:
            continue

        # Sort releases by date
        sorted_releases = sorted(
            repo.releases.values(),
            key=lambda r: r.published_at
        )

        lines.extend([
            f"## {repo_name}",
            "",
        ])

        # Compare each release to the previous one
        # For standard releases, compare to previous standard release
        prev_release = None
        prev_standard_release = None
        for release in sorted_releases:
            # Determine what to compare against
            if is_standard_release(release.tag):
                compare_to = prev_standard_release
            else:
                compare_to = prev_release

            diff = compare_releases(repo_name, compare_to, release)

            if diff.has_changes or compare_to is None:
                if compare_to:
                    lines.append(
                        f"### {release.tag} (from {compare_to.tag})"
                    )
                else:
                    lines.append(f"### {release.tag} (initial)")

                lines.append("")

                if diff.added:
                    lines.append("**Added:**")
                    for change in diff.added:
                        prefix = ""
                        if change.new_schema and change.new_schema.ga4gh_prefix:
                            prefix = f" (`{change.new_schema.ga4gh_prefix}`)"
                        lines.append(f"- {change.name}{prefix}")
                    lines.append("")

                if diff.removed:
                    lines.append("**Removed:**")
                    for change in diff.removed:
                        lines.append(f"- {change.name}")
                    lines.append("")

                if diff.modified:
                    lines.append("**Modified:**")
                    for change in diff.modified:
                        details = ", ".join(change.details)
                        lines.append(f"- {change.name}: {details}")
                    lines.append("")

                if not diff.has_changes and compare_to is None:
                    lines.append(
                        f"*Initial release with {len(release.schemas)} schemas*"
                    )
                    lines.append("")

            # Track previous releases
            prev_release = release
            if is_standard_release(release.tag):
                prev_standard_release = release

        lines.append("")

    return "\n".join(lines)


def escape_table_cell(text: str) -> str:
    """Escape text for use in a markdown table cell."""
    if not text:
        return ""
    # Replace newlines with spaces and escape pipes
    return text.replace("\n", " ").replace("|", "\\|").strip()


def generate_release_notes(
    repos: dict[str, RepoInfo],
    generated_at: datetime
) -> dict[str, str]:
    """
    Generate per-release markdown documents.

    Args:
        repos: Dictionary of repo name to RepoInfo
        generated_at: Timestamp for generation

    Returns:
        Dictionary of filename to markdown content
    """
    release_docs = {}

    for repo_name in sorted(repos.keys()):
        repo = repos[repo_name]
        if not repo.releases:
            continue

        # Sort releases by date
        sorted_releases = sorted(
            repo.releases.values(),
            key=lambda r: r.published_at
        )

        prev_release = None
        prev_standard_release = None
        for release in sorted_releases:
            # For standard releases, compare to previous standard release
            # For non-standard releases, compare to immediate previous
            if is_standard_release(release.tag):
                compare_to = prev_standard_release
            else:
                compare_to = prev_release

            diff = compare_releases(repo_name, compare_to, release)

            lines = [
                f"# {repo_name} {release.tag}",
                "",
                f"> Released: {release.published_at.strftime('%Y-%m-%d')}",
                "",
            ]

            # Release Notes section (from GitHub release body)
            if release.release_notes:
                lines.extend([
                    "## Release Notes",
                    "",
                    release.release_notes,
                    "",
                ])

            # Summary
            summary = release.maturity_summary()
            lines.extend([
                "## Summary",
                "",
                f"- **Total schemas:** {len(release.schemas)}",
            ])
            for maturity in ["normative", "trial use", "draft", "unknown"]:
                count = summary.get(maturity, 0)
                if count:
                    lines.append(f"- **{maturity.title()}:** {count}")
            lines.append("")

            # Schemas table
            lines.extend([
                "## Schemas",
                "",
                "| Schema | Maturity | Description |",
                "|--------|----------|-------------|",
            ])

            for name in sorted(release.schemas.keys()):
                schema = release.schemas[name]
                maturity = schema.maturity
                desc = escape_table_cell(schema.description or "")

                # Create schema link if github_url available
                if schema.github_url:
                    schema_link = f"[{name}]({schema.github_url})"
                else:
                    schema_link = name

                # Add GA4GH prefix if present
                if schema.ga4gh_prefix:
                    schema_link = f"{schema_link} (`{schema.ga4gh_prefix}`)"

                lines.append(f"| {schema_link} | {maturity} | {desc} |")

            lines.append("")

            # Changelog section at bottom
            lines.extend([
                "---",
                "",
                "## Changelog",
                "",
            ])

            if compare_to:
                lines.append(f"*Compared to {compare_to.tag}*")
                lines.append("")

            if diff.has_changes:
                if diff.added:
                    lines.append("### Added")
                    lines.append("")
                    for change in diff.added:
                        prefix_note = ""
                        if change.new_schema and change.new_schema.ga4gh_prefix:
                            prefix_note = f" (`{change.new_schema.ga4gh_prefix}`)"
                        lines.append(f"- **{change.name}**{prefix_note}")
                    lines.append("")

                if diff.removed:
                    lines.append("### Removed")
                    lines.append("")
                    for change in diff.removed:
                        lines.append(f"- **{change.name}**")
                    lines.append("")

                if diff.modified:
                    lines.append("### Modified")
                    lines.append("")
                    for change in diff.modified:
                        lines.append(f"- **{change.name}**")
                        for detail in change.details:
                            lines.append(f"  - {detail}")
                    lines.append("")

            elif compare_to is None:
                lines.append("*This is the initial release.*")
                lines.append("")
            else:
                lines.append("*No schema changes in this release.*")
                lines.append("")

            # Navigation
            lines.extend([
                "---",
                "",
                f"[Back to {repo_name} releases](./)",
                "",
            ])

            # Use safe filename
            safe_tag = release.tag.replace("/", "-")
            filename = f"{repo_name}/{safe_tag}.md"
            release_docs[filename] = "\n".join(lines)

            # Track previous releases
            prev_release = release
            if is_standard_release(release.tag):
                prev_standard_release = release

    return release_docs


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
