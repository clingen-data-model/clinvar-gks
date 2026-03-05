"""Tests for GitHub client."""
import pytest
from unittest.mock import Mock, patch
from datetime import datetime


def test_get_releases():
    from github_client import GitHubClient

    mock_response = Mock()
    mock_response.status_code = 200
    mock_response.json.return_value = [
        {
            "tag_name": "v2.0.0",
            "name": "2.0.0",
            "published_at": "2025-03-14T00:00:00Z"
        },
        {
            "tag_name": "v1.0.0",
            "name": "1.0.0",
            "published_at": "2024-01-01T00:00:00Z"
        }
    ]
    mock_response.links = {}

    with patch("github_client.requests.get", return_value=mock_response):
        client = GitHubClient()
        releases = client.get_releases("ga4gh", "vrs")

    assert len(releases) == 2
    assert releases[0]["tag_name"] == "v2.0.0"


def test_get_releases_handles_pagination():
    from github_client import GitHubClient

    # First page
    mock_response1 = Mock()
    mock_response1.status_code = 200
    mock_response1.json.return_value = [{"tag_name": f"v{i}.0.0"} for i in range(30)]
    mock_response1.links = {"next": {"url": "https://api.github.com/page2"}}

    # Second page (empty = end)
    mock_response2 = Mock()
    mock_response2.status_code = 200
    mock_response2.json.return_value = [{"tag_name": "v30.0.0"}]
    mock_response2.links = {}

    with patch("github_client.requests.get", side_effect=[mock_response1, mock_response2]):
        client = GitHubClient()
        releases = client.get_releases("ga4gh", "vrs")

    assert len(releases) == 31


def test_get_schema_files():
    from github_client import GitHubClient

    mock_response = Mock()
    mock_response.status_code = 200
    mock_response.json.return_value = [
        {"name": "Allele", "type": "file", "path": "schema/vrs/json/Allele"},
        {"name": "Location", "type": "file", "path": "schema/vrs/json/Location"},
        {"name": ".gitignore", "type": "file", "path": "schema/vrs/json/.gitignore"},
    ]

    with patch("github_client.requests.get", return_value=mock_response):
        client = GitHubClient()
        files = client.get_schema_files("ga4gh", "vrs", "v2.0.0", "schema/vrs/json")

    assert "schema/vrs/json/Allele" in files
    assert "schema/vrs/json/Location" in files
    # Hidden files should be filtered out
    assert not any(".gitignore" in f for f in files)


def test_get_schema_files_recursive():
    from github_client import GitHubClient

    # First call returns files and a subdirectory
    mock_response1 = Mock()
    mock_response1.status_code = 200
    mock_response1.json.return_value = [
        {"name": "Allele", "type": "file", "path": "schema/vrs/json/Allele"},
        {"name": "subdir", "type": "dir", "path": "schema/vrs/json/subdir"},
    ]

    # Second call (for subdirectory) returns more files
    mock_response2 = Mock()
    mock_response2.status_code = 200
    mock_response2.json.return_value = [
        {"name": "Nested", "type": "file", "path": "schema/vrs/json/subdir/Nested"},
    ]

    with patch("github_client.requests.get", side_effect=[mock_response1, mock_response2]):
        client = GitHubClient()
        files = client.get_schema_files("ga4gh", "vrs", "v2.0.0", "schema/vrs/json")

    assert "schema/vrs/json/Allele" in files
    assert "schema/vrs/json/subdir/Nested" in files
    assert len(files) == 2


def test_get_file_content():
    from github_client import GitHubClient

    mock_response = Mock()
    mock_response.status_code = 200
    mock_response.json.return_value = {
        "$id": "https://w3id.org/ga4gh/schema/vrs/2.x/json/Allele",
        "title": "Allele"
    }

    with patch("github_client.requests.get", return_value=mock_response):
        client = GitHubClient()
        content = client.get_file_content("ga4gh", "vrs", "v2.0.0", "schema/vrs/json/Allele")

    assert content["title"] == "Allele"


def test_client_uses_token():
    from github_client import GitHubClient

    client = GitHubClient(token="test-token")

    assert client.headers["Authorization"] == "Bearer test-token"
