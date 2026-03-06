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
