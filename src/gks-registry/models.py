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

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "$id": self.id,
            "maturity": self.maturity,
            "description": self.description,
            "ga4gh_prefix": self.ga4gh_prefix,
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
