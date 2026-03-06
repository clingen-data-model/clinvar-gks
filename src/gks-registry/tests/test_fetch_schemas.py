"""Tests for main orchestrator."""
import pytest
from unittest.mock import Mock, patch, MagicMock
from datetime import datetime
import json
import os


def test_load_config():
    from fetch_schemas import load_config

    config = load_config()

    assert "repos" in config
    assert len(config["repos"]) == 4
    assert config["repos"][0]["name"] == "gks-core"


def test_load_existing_registry_empty():
    from fetch_schemas import load_existing_registry

    with patch("builtins.open", side_effect=FileNotFoundError):
        result = load_existing_registry("nonexistent.json")

    assert result == {}


def test_save_registry():
    from fetch_schemas import save_registry
    from models import RepoInfo

    repos = {"vrs": RepoInfo(name="vrs", url="https://github.com/ga4gh/vrs", releases={})}

    mock_file = MagicMock()
    with patch("builtins.open", return_value=mock_file):
        with patch("os.makedirs"):
            save_registry(repos, "test.json", datetime(2026, 3, 5))

    # Verify open was called
    mock_file.__enter__().write.assert_called()


def test_process_release():
    from fetch_schemas import process_release
    from github_client import GitHubClient

    mock_client = Mock(spec=GitHubClient)
    mock_client.path_exists.return_value = True
    mock_client.get_schema_files.return_value = ["Allele", "Location"]
    mock_client.get_file_content.side_effect = [
        {"$id": "id1", "title": "Allele", "maturity": "normative"},
        {"$id": "id2", "title": "Location", "maturity": "trial use"},
    ]

    repo_config = {
        "owner": "ga4gh",
        "name": "vrs",
        "schema_paths": ["schema/vrs/json"],
    }
    release_data = {"tag_name": "v2.0.0", "name": "2.0.0", "published_at": "2025-03-14T00:00:00Z"}

    result = process_release(mock_client, repo_config, release_data)

    assert result.tag == "v2.0.0"
    assert len(result.schemas) == 2
    assert "Allele" in result.schemas


def test_process_release_falls_back_to_combined_schema():
    from fetch_schemas import process_release
    from github_client import GitHubClient

    mock_client = Mock(spec=GitHubClient)
    # First path doesn't exist
    mock_client.path_exists.side_effect = [False, True]
    mock_client.get_file_content.return_value = {
        "title": "VRS",
        "definitions": {
            "Allele": {"$id": "id1", "description": "An allele", "maturity": "normative"},
            "Location": {"$id": "id2", "description": "A location"},
        }
    }

    repo_config = {
        "owner": "ga4gh",
        "name": "vrs",
        "schema_paths": ["schema/vrs/json"],
        "combined_schema": "schema/vrs.json",
    }
    release_data = {"tag_name": "v1.3.0", "name": "1.3.0", "published_at": "2023-01-01T00:00:00Z"}

    result = process_release(mock_client, repo_config, release_data)

    assert result.tag == "v1.3.0"
    assert len(result.schemas) == 2
    assert "Allele" in result.schemas
    assert "Location" in result.schemas


def test_parse_combined_schema():
    from fetch_schemas import parse_combined_schema

    content = {
        "title": "GA4GH-VRS",
        "definitions": {
            "Allele": {
                "$id": "https://w3id.org/ga4gh/schema/vrs/1.x/Allele",
                "description": "An allele",
                "maturity": "normative",
                "ga4ghDigest": {"prefix": "VA"}
            },
            "Location": {
                "$id": "https://w3id.org/ga4gh/schema/vrs/1.x/Location",
                "description": "A location",
            },
            # Lowercase/short names should be skipped
            "curie": {"description": "A CURIE"},
        }
    }

    result = parse_combined_schema(content)

    assert len(result) == 2
    assert "Allele" in result
    assert "Location" in result
    assert "curie" not in result  # Skipped as internal type
    assert result["Allele"].ga4gh_prefix == "VA"
    assert result["Location"].maturity == "unknown"
