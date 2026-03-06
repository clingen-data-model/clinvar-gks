"""Tests for markdown generator."""
from datetime import datetime


def test_generate_readme():
    from markdown_generator import generate_readme
    from models import RepoInfo, ReleaseInfo, SchemaInfo

    repos = {
        "vrs": RepoInfo(
            name="vrs",
            url="https://github.com/ga4gh/vrs",
            releases={
                "v2.0.0": ReleaseInfo(
                    tag="v2.0.0",
                    name="2.0.0",
                    published_at=datetime(2025, 3, 14),
                    schemas={
                        "Allele": SchemaInfo("id", "normative", "desc", "VA"),
                        "Location": SchemaInfo("id", "trial use", "desc", None),
                    }
                )
            }
        )
    }

    result = generate_readme(repos, datetime(2026, 3, 5, 12, 0, 0))

    assert "# GKS Schema Registry" in result
    assert "vrs" in result
    assert "v2.0.0" in result
    assert "| 2 |" in result  # schema count


def test_generate_maturity_matrix():
    from markdown_generator import generate_maturity_matrix
    from models import RepoInfo, ReleaseInfo, SchemaInfo

    repos = {
        "vrs": RepoInfo(
            name="vrs",
            url="https://github.com/ga4gh/vrs",
            releases={
                "v2.0.0": ReleaseInfo(
                    tag="v2.0.0",
                    name="2.0.0",
                    published_at=datetime(2025, 3, 14),
                    schemas={
                        "Allele": SchemaInfo("id1", "normative", "desc", "VA"),
                        "Location": SchemaInfo("id2", "trial use", "desc", None),
                    }
                )
            }
        )
    }

    result = generate_maturity_matrix(repos)

    assert "# Maturity Matrix" in result
    assert "## Normative" in result
    assert "Allele" in result
    assert "## Trial Use" in result
    assert "Location" in result


def test_generate_release_history():
    from markdown_generator import generate_release_history
    from models import RepoInfo, ReleaseInfo, SchemaInfo

    repos = {
        "vrs": RepoInfo(
            name="vrs",
            url="https://github.com/ga4gh/vrs",
            releases={
                "v2.0.0": ReleaseInfo(
                    tag="v2.0.0",
                    name="2.0.0",
                    published_at=datetime(2025, 3, 14),
                    schemas={"Allele": SchemaInfo("id", "normative", "desc", "VA")}
                ),
                "v1.0.0": ReleaseInfo(
                    tag="v1.0.0",
                    name="1.0.0",
                    published_at=datetime(2024, 1, 1),
                    schemas={}
                )
            }
        )
    }

    result = generate_release_history(repos)

    assert "# Release History" in result
    assert "2025" in result
    assert "v2.0.0" in result
    assert "2024" in result
    assert "v1.0.0" in result


def test_compare_releases():
    from markdown_generator import compare_releases
    from models import ReleaseInfo, SchemaInfo

    old_release = ReleaseInfo(
        tag="v1.0.0",
        name="1.0.0",
        published_at=datetime(2024, 1, 1),
        schemas={
            "Allele": SchemaInfo("id1", "draft", "An allele", "VA"),
            "Location": SchemaInfo("id2", "draft", "A location", None),
            "Deprecated": SchemaInfo("id3", "draft", "Old schema", None),
        }
    )

    new_release = ReleaseInfo(
        tag="v2.0.0",
        name="2.0.0",
        published_at=datetime(2025, 3, 14),
        schemas={
            "Allele": SchemaInfo("id1", "normative", "An allele", "VA"),
            "Location": SchemaInfo("id2", "trial use", "A location", "VSL"),
            "NewSchema": SchemaInfo("id4", "draft", "A new schema", None),
        }
    )

    diff = compare_releases("vrs", old_release, new_release)

    assert diff.repo == "vrs"
    assert diff.from_tag == "v1.0.0"
    assert diff.to_tag == "v2.0.0"

    # Check added
    assert len(diff.added) == 1
    assert diff.added[0].name == "NewSchema"

    # Check removed
    assert len(diff.removed) == 1
    assert diff.removed[0].name == "Deprecated"

    # Check modified
    assert len(diff.modified) == 2
    allele_mod = next(c for c in diff.modified if c.name == "Allele")
    assert "maturity" in allele_mod.details[0]
    location_mod = next(c for c in diff.modified if c.name == "Location")
    assert any("ga4gh_prefix" in d for d in location_mod.details)


def test_compare_releases_initial():
    from markdown_generator import compare_releases
    from models import ReleaseInfo, SchemaInfo

    new_release = ReleaseInfo(
        tag="v1.0.0",
        name="1.0.0",
        published_at=datetime(2024, 1, 1),
        schemas={
            "Allele": SchemaInfo("id1", "draft", "An allele", "VA"),
        }
    )

    diff = compare_releases("vrs", None, new_release)

    assert diff.from_tag is None
    assert diff.to_tag == "v1.0.0"
    assert len(diff.added) == 1
    assert len(diff.removed) == 0
    assert len(diff.modified) == 0


def test_generate_changelog():
    from markdown_generator import generate_changelog
    from models import RepoInfo, ReleaseInfo, SchemaInfo

    repos = {
        "vrs": RepoInfo(
            name="vrs",
            url="https://github.com/ga4gh/vrs",
            releases={
                "v1.0.0": ReleaseInfo(
                    tag="v1.0.0",
                    name="1.0.0",
                    published_at=datetime(2024, 1, 1),
                    schemas={
                        "Allele": SchemaInfo("id1", "draft", "desc", "VA"),
                    }
                ),
                "v2.0.0": ReleaseInfo(
                    tag="v2.0.0",
                    name="2.0.0",
                    published_at=datetime(2025, 3, 14),
                    schemas={
                        "Allele": SchemaInfo("id1", "normative", "desc", "VA"),
                        "Location": SchemaInfo("id2", "trial use", "desc", None),
                    }
                )
            }
        )
    }

    result = generate_changelog(repos)

    assert "# Schema Changelog" in result
    assert "## vrs" in result
    assert "v1.0.0 (initial)" in result
    assert "v2.0.0 (from v1.0.0)" in result
    assert "**Added:**" in result
    assert "Location" in result
    assert "**Modified:**" in result
    assert "Allele" in result


def test_generate_release_notes():
    from markdown_generator import generate_release_notes
    from models import RepoInfo, ReleaseInfo, SchemaInfo

    repos = {
        "vrs": RepoInfo(
            name="vrs",
            url="https://github.com/ga4gh/vrs",
            releases={
                "v1.0.0": ReleaseInfo(
                    tag="v1.0.0",
                    name="1.0.0",
                    published_at=datetime(2024, 1, 1),
                    schemas={
                        "Allele": SchemaInfo("id1", "draft", "An allele", "VA"),
                    }
                ),
                "v2.0.0": ReleaseInfo(
                    tag="v2.0.0",
                    name="2.0.0",
                    published_at=datetime(2025, 3, 14),
                    schemas={
                        "Allele": SchemaInfo("id1", "normative", "An allele", "VA"),
                        "Location": SchemaInfo("id2", "trial use", "A loc", None),
                    }
                )
            }
        )
    }

    result = generate_release_notes(repos, datetime(2026, 3, 5))

    # Check we have two release docs
    assert len(result) == 2
    assert "vrs/v1.0.0.md" in result
    assert "vrs/v2.0.0.md" in result

    # Check v1.0.0 content
    v1_content = result["vrs/v1.0.0.md"]
    assert "# vrs v1.0.0" in v1_content
    assert "Allele" in v1_content
    # Check for table format
    assert "| Schema | Maturity | Description |" in v1_content
    # Initial release with schemas shows Added section
    assert "## Changelog" in v1_content
    assert "### Added" in v1_content

    # Check v2.0.0 content
    v2_content = result["vrs/v2.0.0.md"]
    assert "# vrs v2.0.0" in v2_content
    assert "## Schemas" in v2_content
    assert "## Changelog" in v2_content
    assert "### Added" in v2_content
    assert "Location" in v2_content
    assert "### Modified" in v2_content
    assert "Allele" in v2_content
