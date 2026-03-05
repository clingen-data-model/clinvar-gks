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
        Recursively list schema files in a directory for a specific release tag.

        Args:
            owner: Repository owner
            repo: Repository name
            tag: Release tag (e.g., "schema/vrs/json" or "schema/va-spec")
            path: Path to schema directory

        Returns:
            List of full paths to schema files (only from 'json' subdirectories)
        """
        # Check if the initial path is already a json directory
        in_json_dir = path.endswith("/json") or path.split("/")[-1] == "json"
        return self._get_files_recursive(owner, repo, tag, path, in_json_dir)

    def _get_files_recursive(
        self, owner: str, repo: str, tag: str, path: str, in_json_dir: bool = False
    ) -> list[str]:
        """Recursively get all files from a directory.

        Only returns files that are inside a 'json' directory.
        """
        url = f"{self.BASE_URL}/repos/{owner}/{repo}/contents/{path}"
        params = {"ref": tag}

        response = requests.get(url, headers=self.headers, params=params)
        response.raise_for_status()

        files = []
        for item in response.json():
            if item["name"].startswith("."):
                continue

            if item["type"] == "file":
                # Only include files if we're inside a json directory
                if in_json_dir:
                    files.append(item["path"])
            elif item["type"] == "dir":
                # Check if this directory is named 'json'
                entering_json_dir = in_json_dir or item["name"] == "json"
                # Recursively get files from subdirectory
                files.extend(
                    self._get_files_recursive(
                        owner, repo, tag, item["path"], entering_json_dir
                    )
                )

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
