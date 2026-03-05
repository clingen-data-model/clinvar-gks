"""Tests for data models."""
import pytest
from datetime import datetime


def test_schema_info_creation():
    from models import SchemaInfo

    schema = SchemaInfo(
        id="https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele",
        title="Allele",
        maturity="trial use",
        description="The state of a molecule at a Location.",
        ga4gh_prefix="VA",
        version="2.x"
    )

    assert schema.title == "Allele"
    assert schema.maturity == "trial use"


def test_schema_info_to_dict():
    from models import SchemaInfo

    schema = SchemaInfo(
        id="https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele",
        title="Allele",
        maturity="trial use",
        description="The state of a molecule.",
        ga4gh_prefix="VA",
        version="2.x"
    )

    result = schema.to_dict()

    assert result["$id"] == "https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele"
    assert result["title"] == "Allele"
    assert result["maturity"] == "trial use"


def test_release_info_creation():
    from models import ReleaseInfo, SchemaInfo

    schema = SchemaInfo(
        id="https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele",
        title="Allele",
        maturity="trial use",
        description="desc",
        ga4gh_prefix="VA",
        version="2.x"
    )

    release = ReleaseInfo(
        tag="v2.0.0",
        name="2.0.0",
        published_at=datetime(2025, 3, 14),
        schemas={"Allele": schema}
    )

    assert release.tag == "v2.0.0"
    assert "Allele" in release.schemas


def test_release_info_maturity_summary():
    from models import ReleaseInfo, SchemaInfo

    schemas = {
        "Allele": SchemaInfo("id1", "Allele", "normative", "desc", "VA", "2.x"),
        "Location": SchemaInfo("id2", "Location", "trial use", "desc", None, "2.x"),
        "Range": SchemaInfo("id3", "Range", "trial use", "desc", None, "2.x"),
    }

    release = ReleaseInfo(
        tag="v2.0.0",
        name="2.0.0",
        published_at=datetime(2025, 3, 14),
        schemas=schemas
    )

    summary = release.maturity_summary()

    assert summary["normative"] == 1
    assert summary["trial use"] == 2


def test_repo_info_creation():
    from models import RepoInfo

    repo = RepoInfo(
        name="vrs",
        url="https://github.com/ga4gh/vrs",
        releases={}
    )

    assert repo.name == "vrs"
