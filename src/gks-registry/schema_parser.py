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
