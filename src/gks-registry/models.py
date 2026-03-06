"""Data models for GKS Schema Registry."""
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional
from collections import Counter


@dataclass
class SchemaInfo:
    """Represents metadata extracted from a JSON schema file."""
    id: str
    maturity: str
    description: str
    ga4gh_prefix: Optional[str]
    source_path: Optional[str] = None  # Path to source file in repo
    github_url: Optional[str] = None  # Full GitHub URL to schema source
    refs: list[str] = field(default_factory=list)  # $ref values found in schema

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        result = {
            "$id": self.id,
            "maturity": self.maturity,
            "description": self.description,
            "ga4gh_prefix": self.ga4gh_prefix,
        }
        if self.source_path:
            result["source_path"] = self.source_path
        if self.github_url:
            result["github_url"] = self.github_url
        return result


@dataclass
class Dependency:
    """Represents a dependency on another product release."""
    product: str
    release: str

    def to_dict(self) -> dict:
        return {"product": self.product, "release": self.release}


@dataclass
class ReleaseInfo:
    """Represents a GitHub release with its schemas."""
    tag: str
    name: str
    published_at: datetime
    schemas: dict[str, SchemaInfo] = field(default_factory=dict)
    release_notes: Optional[str] = None  # GitHub release body/description
    release_url: Optional[str] = None  # GitHub release page URL
    previous_release: Optional[str] = None  # Tag of previous release
    dependencies: list[Dependency] = field(default_factory=list)  # External product deps

    def maturity_summary(self) -> dict[str, int]:
        """Count schemas by maturity level."""
        maturities = [s.maturity for s in self.schemas.values()]
        return dict(Counter(maturities))

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        result = {
            "tag": self.tag,
            "name": self.name,
            "published_at": self.published_at.isoformat(),
            "schema_count": len(self.schemas),
            "maturity_summary": self.maturity_summary(),
            "schemas": {name: schema.to_dict() for name, schema in self.schemas.items()}
        }
        if self.release_notes:
            result["release_notes"] = self.release_notes
        if self.release_url:
            result["release_url"] = self.release_url
        if self.previous_release:
            result["previous_release"] = self.previous_release
        if self.dependencies:
            result["dependencies"] = [d.to_dict() for d in self.dependencies]
        return result


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
