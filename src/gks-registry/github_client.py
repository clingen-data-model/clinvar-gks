"""GitHub API client for fetching releases and schema files."""
import os
from typing import Optional

import requests


class GitHubClient:
    """Client for interacting with GitHub API."""

    BASE_URL = "https://api.github.com"
    RAW_URL = "https://raw.githubusercontent.com"

    def __init__(self, token: Optional[str] = None):
        """
        Initialize client with optional auth token.

        Args:
            token: GitHub personal access token (or GITHUB_TOKEN from env)
        """
        self.token = token or os.environ.get("GITHUB_TOKEN")
        self.headers = {
            "Accept": "application/vnd.github.v3+json",
        }
        if self.token:
            self.headers["Authorization"] = f"Bearer {self.token}"

    def get_releases(self, owner: str, repo: str) -> list[dict]:
        """
        Fetch all releases for a repository.

        Args:
            owner: Repository owner (e.g., "ga4gh")
            repo: Repository name (e.g., "vrs")

        Returns:
            List of release dictionaries
        """
        releases = []
        url = f"{self.BASE_URL}/repos/{owner}/{repo}/releases"
        params = {"per_page": 100}

        while url:
            response = requests.get(url, headers=self.headers, params=params)
            response.raise_for_status()
            releases.extend(response.json())

            # Handle pagination
            url = response.links.get("next", {}).get("url")
            params = {}  # URL already contains params

        return releases

    def get_schema_files(self, owner: str, repo: str, tag: str, path: str) -> list[str]:
        """
        List schema files in a directory for a specific release tag.

        Args:
            owner: Repository owner
            repo: Repository name
            tag: Release tag (e.g., "v2.0.0")
            path: Path to schema directory (e.g., "schema/vrs/json")

        Returns:
            List of schema file names (excluding hidden files)
        """
        url = f"{self.BASE_URL}/repos/{owner}/{repo}/contents/{path}"
        params = {"ref": tag}

        response = requests.get(url, headers=self.headers, params=params)
        response.raise_for_status()

        files = []
        for item in response.json():
            if item["type"] == "file" and not item["name"].startswith("."):
                files.append(item["name"])

        return files

    def get_file_content(self, owner: str, repo: str, tag: str, path: str) -> dict:
        """
        Fetch and parse a JSON file from a specific release tag.

        Args:
            owner: Repository owner
            repo: Repository name
            tag: Release tag
            path: Path to file

        Returns:
            Parsed JSON content as dictionary
        """
        url = f"{self.RAW_URL}/{owner}/{repo}/{tag}/{path}"

        response = requests.get(url, headers=self.headers)
        response.raise_for_status()

        return response.json()
