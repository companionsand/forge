# Client Release Deployment

This document captures the deployment transition from plaintext source checkouts to obfuscated release artifacts.

## Previous Plaintext Deploy Path

Before this transition:

- `install.sh` fetched a GitHub deploy key, cloned `raspberry-pi-client`, created `raspberry-pi-client/venv`, and installed `requirements.txt`.
- `launch.sh` ran `git fetch` plus `git reset --hard` on every boot and before restart, then launched `python main.py` from the checkout.
- Devices therefore contained the full application source tree.

## Current Release Artifact Contract

Devices now install GitHub Release assets instead of cloning source.

Expected assets per release:

- `raspberry-pi-client-<version>-linux-aarch64.tar.gz`
- `raspberry-pi-client-<version>-linux-aarch64-manifest.json`
- `raspberry-pi-client-<version>-linux-aarch64.tar.gz.sha256`

The tarball must expand to:

- `raspberry-pi-client/main.py`
- `raspberry-pi-client/lib/...`
- `raspberry-pi-client/version.py`
- `raspberry-pi-client/requirements.txt`
- `raspberry-pi-client/release-metadata.json`
- `raspberry-pi-client/pyarmor_runtime_*` when obfuscation is enabled

The manifest records:

- release tag
- semantic version
- release channel
- asset filename
- SHA-256 checksum
- PyArmor mode and target platform

## Wrapper Behavior

- `install.sh` calls `github/release_manager.py sync` to download and install the configured release bundle.
- `launch.sh` calls the same sync command on boot and before restart to pick up new releases.
- `rollback.sh` swaps `raspberry-pi-client.previous/` back into place and restarts `agent-launcher`.

Wrapper paths:

- Current client: `~/raspberry-pi-client-wrapper/raspberry-pi-client/`
- Previous client: `~/raspberry-pi-client-wrapper/raspberry-pi-client.previous/`
- Virtualenv: `~/raspberry-pi-client-wrapper/venv/`
- Release cache: `~/raspberry-pi-client-wrapper/downloads/releases/`
- Release state: `~/raspberry-pi-client-wrapper/.client-release-state.json`

## Configuration

Supported wrapper `.env` variables:

- `CLIENT_RELEASE_REPO`
- `CLIENT_RELEASE_CHANNEL`
- `CLIENT_RELEASE_TAG`
- `CLIENT_RELEASE_PLATFORM`
- `CLIENT_RELEASE_GITHUB_TOKEN`

Recommended defaults:

- `CLIENT_RELEASE_REPO=companionsand/raspberry-pi-client`
- `CLIENT_RELEASE_CHANNEL=production`
- `CLIENT_RELEASE_PLATFORM=linux-aarch64`

## Rollout Playbook

1. Build a plaintext dry-run bundle locally with `python scripts/build_release_bundle.py --no-obfuscate`.
2. Build an obfuscated release bundle with PyArmor and validate it using `scripts/smoke_test_release_bundle.py`.
   The PyArmor trial may report `out of license` for the full app, so expect to use a registered license for production-scale bundles.
3. Publish a staging tag such as `vX.Y.Z-rc1`.
4. Point one test device at staging with `CLIENT_RELEASE_CHANNEL=staging` or pin `CLIENT_RELEASE_TAG`.
5. Verify install, restart, wake word, BLE, networking, and idle-restart update behavior.
6. Expand to a small cohort once the first device is stable.
7. Publish the production tag `vX.Y.Z` and move the wider fleet to `CLIENT_RELEASE_CHANNEL=production`.

## Rollback

To roll back one device:

```bash
cd ~/raspberry-pi-client-wrapper
./rollback.sh
```

To pin one device to a known-good release:

```bash
CLIENT_RELEASE_TAG=vX.Y.Z
```
