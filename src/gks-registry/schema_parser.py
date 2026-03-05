"""Parser for extracting metadata from JSON schema files."""
import re
from typing import Optional

from models import SchemaInfo


def extract_version_from_id(schema_id: str) -> str:
    """
    Extract version string from $id URL.

    Examples:
        "https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele" -> "2.x"
        "https://w3id.org/ga4gh/schema/vrs/2.0.0-snapshot.2025-02.3/json/Allele" -> "2.0.0-snapshot.2025-02.3"
    """
    # Match version between schema/{repo}/ and /json/
    # Handles: 2.x, 2.0.0, 2.0.0-snapshot.2025-02.3, etc.
    match = re.search(r'/schema/[^/]+/([^/]+)/json/', schema_id)
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

    # Extract ga4gh prefix - check both 'ga4gh' (newer) and 'ga4ghDigest' (older) properties
    ga4gh_prefix: Optional[str] = None
    for prop_name in ("ga4gh", "ga4ghDigest"):
        ga4gh_obj = content.get(prop_name, {})
        if isinstance(ga4gh_obj, dict) and "prefix" in ga4gh_obj:
            ga4gh_prefix = ga4gh_obj["prefix"]
            break

    version = extract_version_from_id(schema_id)

    return SchemaInfo(
        id=schema_id,
        title=title,
        maturity=maturity,
        description=description,
        ga4gh_prefix=ga4gh_prefix,
        version=version
    )
