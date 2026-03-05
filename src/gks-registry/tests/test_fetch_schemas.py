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
    mock_client.get_schema_files.return_value = ["Allele", "Location"]
    mock_client.get_file_content.side_effect = [
        {"$id": "id1", "title": "Allele", "maturity": "normative"},
        {"$id": "id2", "title": "Location", "maturity": "trial use"},
    ]

    repo_config = {"owner": "ga4gh", "name": "vrs", "schema_path": "schema/vrs/json"}
    release_data = {"tag_name": "v2.0.0", "name": "2.0.0", "published_at": "2025-03-14T00:00:00Z"}

    result = process_release(mock_client, repo_config, release_data)

    assert result.tag == "v2.0.0"
    assert len(result.schemas) == 2
    assert "Allele" in result.schemas
