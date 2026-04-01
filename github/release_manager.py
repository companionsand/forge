#!/usr/bin/env python3
"""Download, verify, install, and roll back Raspberry Pi client releases."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_REPO = "companionsand/raspberry-pi-client"
DEFAULT_CHANNEL = "production"
DEFAULT_PLATFORM = "linux-aarch64"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load_json(path: Path) -> dict | None:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


@dataclass(frozen=True)
class ReleaseConfig:
    wrapper_dir: Path
    client_dir: Path
    previous_dir: Path
    downloads_dir: Path
    state_file: Path
    repo: str
    channel: str
    tag: str | None
    platform: str
    github_token: str | None

    @classmethod
    def from_args(cls, args: argparse.Namespace) -> "ReleaseConfig":
        wrapper_dir = Path(args.wrapper_dir).resolve()
        client_dir = wrapper_dir / "raspberry-pi-client"
        return cls(
            wrapper_dir=wrapper_dir,
            client_dir=client_dir,
            previous_dir=wrapper_dir / "raspberry-pi-client.previous",
            downloads_dir=wrapper_dir / "downloads" / "releases",
            state_file=wrapper_dir / ".client-release-state.json",
            repo=args.repo,
            channel=args.channel,
            tag=args.tag or None,
            platform=args.platform,
            github_token=args.github_token or None,
        )


class GithubReleaseManager:
    def __init__(self, config: ReleaseConfig) -> None:
        self.config = config

    def _request_json(self, url: str) -> dict | list:
        request = urllib.request.Request(
            url,
            headers=self._headers(accept="application/vnd.github+json"),
        )
        try:
            with urllib.request.urlopen(request) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"GitHub API request failed ({exc.code}): {body}") from exc

    def _download(self, url: str, destination: Path) -> None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        request = urllib.request.Request(url, headers=self._headers())
        try:
            with urllib.request.urlopen(request) as response, destination.open("wb") as handle:
                shutil.copyfileobj(response, handle)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Download failed ({exc.code}): {body}") from exc

    def _headers(self, *, accept: str | None = None) -> dict[str, str]:
        headers = {"User-Agent": "kin-ai-release-manager/1.0"}
        if accept:
            headers["Accept"] = accept
        if self.config.github_token:
            headers["Authorization"] = f"Bearer {self.config.github_token}"
        return headers

    def _release_url(self) -> str:
        repo = self.config.repo
        if self.config.tag:
            tag = urllib.parse.quote(self.config.tag, safe="")
            return f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
        if self.config.channel == "production":
            return f"https://api.github.com/repos/{repo}/releases/latest"
        return f"https://api.github.com/repos/{repo}/releases"

    def resolve_release(self) -> dict:
        payload = self._request_json(self._release_url())
        if self.config.tag:
            if not isinstance(payload, dict):
                raise RuntimeError("GitHub returned invalid release payload for tag lookup.")
            return payload

        if self.config.channel == "production":
            if not isinstance(payload, dict):
                raise RuntimeError("GitHub returned invalid production release payload.")
            return payload

        if not isinstance(payload, list):
            raise RuntimeError("GitHub returned invalid staging release list.")

        for release in payload:
            if not release.get("draft") and release.get("prerelease"):
                return release
        raise RuntimeError(
            f"No prerelease found for staging channel in GitHub releases for {self.config.repo}."
        )

    def select_assets(self, release: dict) -> tuple[dict, dict]:
        tarball_name = f"-{self.config.platform}.tar.gz"
        manifest_name = f"-{self.config.platform}-manifest.json"
        tarball = None
        manifest = None
        for asset in release.get("assets", []):
            name = asset.get("name", "")
            if name.endswith(tarball_name):
                tarball = asset
            elif name.endswith(manifest_name):
                manifest = asset
        if tarball is None or manifest is None:
            raise RuntimeError(
                f"Release {release.get('tag_name')} does not contain the expected {self.config.platform} assets."
            )
        return tarball, manifest

    def current_state(self) -> dict | None:
        return _load_json(self.config.state_file)

    def _extract_tarball(self, tarball_path: Path, destination: Path) -> None:
        with tarfile.open(tarball_path, "r:gz") as archive:
            for member in archive.getmembers():
                member_path = destination / member.name
                resolved_destination = destination.resolve()
                resolved_member = member_path.resolve()
                if not str(resolved_member).startswith(str(resolved_destination)):
                    raise RuntimeError(f"Unsafe path in release archive: {member.name}")
            archive.extractall(destination)

    def sync(self, *, force: bool = False) -> dict:
        release = self.resolve_release()
        tag_name = release.get("tag_name")
        current_state = self.current_state()
        if (
            not force
            and current_state
            and current_state.get("release_tag") == tag_name
            and self.config.client_dir.exists()
        ):
            return {
                "action": "noop",
                "channel": self.config.channel,
                "client_dir": str(self.config.client_dir),
                "release_tag": tag_name,
                "version": current_state.get("version"),
            }

        tarball_asset, manifest_asset = self.select_assets(release)
        self.config.downloads_dir.mkdir(parents=True, exist_ok=True)

        with tempfile.TemporaryDirectory(prefix="kin-release-download-") as temp_dir:
            temp_root = Path(temp_dir)
            tarball_path = temp_root / tarball_asset["name"]
            manifest_path = temp_root / manifest_asset["name"]

            self._download(manifest_asset["browser_download_url"], manifest_path)
            self._download(tarball_asset["browser_download_url"], tarball_path)

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            expected_sha = manifest["asset"]["sha256"]
            actual_sha = _sha256(tarball_path)
            if actual_sha != expected_sha:
                raise RuntimeError(
                    f"Checksum mismatch for {tarball_path.name}: expected {expected_sha}, got {actual_sha}"
                )

            extracted_root = temp_root / "extracted"
            extracted_root.mkdir(parents=True, exist_ok=True)
            self._extract_tarball(tarball_path, extracted_root)

            bundle_root = extracted_root / manifest["bundle_root"]
            if not bundle_root.exists():
                raise RuntimeError(
                    f"Release bundle is missing root directory {manifest['bundle_root']}"
                )

            env_path = self.config.client_dir / ".env"
            preserved_env = env_path.read_text(encoding="utf-8") if env_path.exists() else None

            self._rotate_directories(bundle_root)

            if preserved_env is not None:
                (self.config.client_dir / ".env").write_text(preserved_env, encoding="utf-8")

            installed_state = {
                "asset_name": tarball_asset["name"],
                "bundle_sha256": actual_sha,
                "channel": self.config.channel,
                "client_dir": str(self.config.client_dir),
                "installed_at": _now(),
                "manifest_name": manifest_asset["name"],
                "platform": self.config.platform,
                "release_id": release.get("id"),
                "release_name": release.get("name"),
                "release_tag": manifest["release_tag"],
                "release_url": release.get("html_url"),
                "version": manifest["version"],
            }
            _write_json(self.config.state_file, installed_state)

            cached_tarball = self.config.downloads_dir / tarball_asset["name"]
            cached_manifest = self.config.downloads_dir / manifest_asset["name"]
            shutil.copy2(tarball_path, cached_tarball)
            shutil.copy2(manifest_path, cached_manifest)

            return {
                "action": "installed",
                "channel": self.config.channel,
                "client_dir": str(self.config.client_dir),
                "release_tag": manifest["release_tag"],
                "version": manifest["version"],
            }

    def _rotate_directories(self, new_client_dir: Path) -> None:
        previous_dir = self.config.previous_dir
        client_dir = self.config.client_dir

        if previous_dir.exists():
            shutil.rmtree(previous_dir)

        restored = False
        try:
            if client_dir.exists():
                client_dir.replace(previous_dir)
                restored = True
            new_client_dir.replace(client_dir)
        except Exception:
            if restored and not client_dir.exists() and previous_dir.exists():
                previous_dir.replace(client_dir)
            raise

    def rollback(self) -> dict:
        if not self.config.previous_dir.exists():
            raise RuntimeError("No previous client release is available for rollback.")

        current_dir = self.config.client_dir
        previous_dir = self.config.previous_dir
        rollback_temp = self.config.wrapper_dir / "raspberry-pi-client.rollback"
        if rollback_temp.exists():
            shutil.rmtree(rollback_temp)

        if current_dir.exists():
            current_dir.replace(rollback_temp)

        previous_dir.replace(current_dir)

        if rollback_temp.exists():
            rollback_temp.replace(previous_dir)

        metadata_path = current_dir / "release-metadata.json"
        metadata = _load_json(metadata_path) or {}
        state = self.current_state() or {}
        state.update(
            {
                "channel": state.get("channel", self.config.channel),
                "client_dir": str(current_dir),
                "installed_at": _now(),
                "release_tag": metadata.get("release_tag", state.get("release_tag")),
                "rolled_back_at": _now(),
                "version": metadata.get("version", state.get("version")),
            }
        )
        _write_json(self.config.state_file, state)

        return {
            "action": "rolled_back",
            "client_dir": str(current_dir),
            "release_tag": state.get("release_tag"),
            "version": state.get("version"),
        }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=("sync", "rollback", "current"),
        help="Release operation to perform.",
    )
    parser.add_argument(
        "--wrapper-dir",
        default=str(Path(__file__).resolve().parents[1]),
        help="Wrapper root directory.",
    )
    parser.add_argument(
        "--repo",
        default=os.environ.get("CLIENT_RELEASE_REPO", DEFAULT_REPO),
        help="GitHub repo that hosts release assets.",
    )
    parser.add_argument(
        "--channel",
        default=os.environ.get("CLIENT_RELEASE_CHANNEL", DEFAULT_CHANNEL),
        choices=("production", "staging"),
        help="Release channel to install when --tag is not set.",
    )
    parser.add_argument(
        "--tag",
        default=os.environ.get("CLIENT_RELEASE_TAG"),
        help="Explicit release tag to install.",
    )
    parser.add_argument(
        "--platform",
        default=os.environ.get("CLIENT_RELEASE_PLATFORM", DEFAULT_PLATFORM),
        help="Asset platform suffix to install.",
    )
    parser.add_argument(
        "--github-token",
        default=os.environ.get("CLIENT_RELEASE_GITHUB_TOKEN"),
        help="Optional GitHub token for private release downloads.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Install even when the target release matches the current state file.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    manager = GithubReleaseManager(ReleaseConfig.from_args(args))

    if args.command == "sync":
        result = manager.sync(force=args.force)
    elif args.command == "rollback":
        result = manager.rollback()
    else:
        result = manager.current_state() or {
            "action": "uninitialized",
            "client_dir": str(manager.config.client_dir),
        }

    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
