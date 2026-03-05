"""Parser for extracting metadata from JSON schema files."""
from typing import Optional

from models import SchemaInfo


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

    return SchemaInfo(
        id=schema_id,
        title=title,
        maturity=maturity,
        description=description,
        ga4gh_prefix=ga4gh_prefix,
    )
