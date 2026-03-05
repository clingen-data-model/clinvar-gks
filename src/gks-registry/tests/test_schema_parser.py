"""Tests for schema parser."""
import pytest


def test_extract_version_from_id():
    from schema_parser import extract_version_from_id

    result = extract_version_from_id("https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele")
    assert result == "2.x"


def test_extract_version_from_id_with_1x():
    from schema_parser import extract_version_from_id

    result = extract_version_from_id("https://w3id.org/ga4gh/schema/gks-core/1.x/json/Coding")
    assert result == "1.x"


def test_extract_version_from_id_no_match():
    from schema_parser import extract_version_from_id

    result = extract_version_from_id("https://example.com/no-version")
    assert result == "unknown"


def test_extract_version_from_id_full_semver():
    from schema_parser import extract_version_from_id

    result = extract_version_from_id("https://w3id.org/ga4gh/schema/vrs/2.0.0-snapshot.2025-02.3/json/Allele")
    assert result == "2.0.0-snapshot.2025-02.3"


def test_extract_version_from_id_semver_release():
    from schema_parser import extract_version_from_id

    result = extract_version_from_id("https://w3id.org/ga4gh/schema/vrs/2.0.1/json/Allele")
    assert result == "2.0.1"


def test_parse_schema_full():
    from schema_parser import parse_schema

    content = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele",
        "title": "Allele",
        "type": "object",
        "maturity": "trial use",
        "description": "The state of a molecule at a Location.",
        "ga4ghDigest": {
            "prefix": "VA"
        }
    }

    result = parse_schema(content)

    assert result.id == "https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele"
    assert result.title == "Allele"
    assert result.maturity == "trial use"
    assert result.description == "The state of a molecule at a Location."
    assert result.ga4gh_prefix == "VA"
    assert result.version == "2.x"


def test_parse_schema_minimal():
    from schema_parser import parse_schema

    content = {
        "$id": "https://w3id.org/ga4gh/schema/gks-core/1.x/json/code",
        "title": "code"
    }

    result = parse_schema(content)

    assert result.title == "code"
    assert result.maturity == "unknown"
    assert result.description == ""
    assert result.ga4gh_prefix is None


def test_parse_schema_with_keys_property():
    from schema_parser import parse_schema

    # Some schemas have ga4ghDigest.keys instead of ga4ghDigest.prefix
    content = {
        "$id": "https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele",
        "title": "Allele",
        "maturity": "normative",
        "ga4ghDigest": {
            "keys": ["type", "location", "state"],
            "prefix": "VA"
        }
    }

    result = parse_schema(content)
    assert result.ga4gh_prefix == "VA"


def test_parse_schema_with_ga4gh_property():
    from schema_parser import parse_schema

    # Newer schemas use 'ga4gh' instead of 'ga4ghDigest'
    content = {
        "$id": "https://w3id.org/ga4gh/schema/vrs/2.0.0-snapshot.2025-02.3/json/Allele",
        "title": "Allele",
        "maturity": "trial use",
        "description": "The state of a molecule at a Location.",
        "ga4gh": {
            "prefix": "VA",
            "inherent": ["location", "state", "type"]
        }
    }

    result = parse_schema(content)

    assert result.ga4gh_prefix == "VA"
    assert result.version == "2.0.0-snapshot.2025-02.3"
