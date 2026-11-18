# devcontainer-mounts

[English](./README.md) | [日本語](./README.ja.md)

A personal Dev Container Feature that shares the host's `~/.copilot` and `~/.azure`
directories with a container. Enable it through VS Code User Settings without
adding it to each project's `devcontainer.json`.

Distribution uses HTTPS tarballs attached to GitHub Releases. No GHCR,
Marketplace, or catalog registration is required. This is not a general-purpose
tool for specifying arbitrary mount paths through User Settings.

## Supported environments

- WSL2 / Linux with Docker Engine running on the same host
- Dev Containers created or rebuilt using an image, Dockerfile, or Docker Compose
- The `vscode` user, root, and other users with custom home directories

Local tests use a Debian Bookworm-based Dev Container image.
Native Windows, macOS, and remote Docker hosts have not been tested.

## Usage

### 1. Prepare the host directories

When using WSL, run this on the WSL Ubuntu host, not inside a container:

```bash
mkdir -p -m 700 "$HOME/.copilot" "$HOME/.azure"
```

Existing directory permissions are not changed. Container creation fails if a
mount source does not exist.

### 2. Add the Feature to User Settings

Publish `v1.0.1` to GitHub Releases first. The following URL becomes available
only after that release is published.

For Windows + WSL, add this to the active profile's User Settings in the Windows
VS Code application. Do not put it in the container's Remote Settings or shared
project settings.

```json
{
  "dev.containers.defaultFeatures": {
    "https://github.com/shigeyf/devcontainer-mounts/releases/download/v1.0.1/devcontainer-feature-mounts.tgz": {}
  }
}
```

If you already have User Settings, merge the relevant entry into them rather
than replacing the entire file.

### 3. Rebuild using the standard command

Run **Dev Containers: Rebuild Container**. For a new container, use
**Dev Containers: Reopen in Container**.
Reconnecting to an existing container does not change its mounts.

### 4. Disable the Feature

Remove this Feature's entry from User Settings and rebuild the container.
Host data is not deleted. Mounts independently defined by the project are not
disabled by this operation.

## How it works

| Host directory | Bind mount inside the container | User-facing path |
| --- | --- | --- |
| `${localEnv:HOME}/.copilot` | `/mnt/mounts/.copilot` | The effective user's `~/.copilot` |
| `${localEnv:HOME}/.azure` | `/mnt/mounts/.azure` | The effective user's `~/.azure` |

Mounts are defined in
[`devcontainer-feature.json`](./src/mounts/devcontainer-feature.json).
At build time, [`install.sh`](./src/mounts/install.sh) only installs the generic
[`link-mounts.sh`](./src/mounts/link-mounts.sh) helper.
The Feature's `onCreateCommand` runs this helper as the effective user after the
mounts become available.

The helper inspects only actual mounted directories directly under `/mnt/mounts`
and creates matching symlinks in `$HOME`. Ordinary directories, files, and
symlinks are ignored. If no mounts are found, it logs that fact and exits.
No home directory such as `/home/vscode` or `/root` is hardcoded, so custom users
and home directories are supported.

No JSON parser such as jq is needed inside the container, but the util-linux
`mountpoint` command and support for `mv -nT` and `ln -sT` (provided by GNU
coreutils) are required. These options prevent overwriting backups and creating
links inside an unexpectedly recreated directory. Feature `onCreateCommand`
hooks run before the project's own `onCreateCommand`. Home symlinks are not yet
available to other Features' installation scripts during the image build.

To inspect the mounts and home links, run inside the container:

```bash
readlink "$HOME/.copilot"
readlink "$HOME/.azure"
mountpoint /mnt/mounts/.copilot
mountpoint /mnt/mounts/.azure
```

## Important notes

- Both directories are read/write. Container processes can modify host
  credentials, history, and settings. Use this Feature only with trusted projects.
- If a home path already contains `.copilot`, `.azure`, or a conflicting symlink,
  the helper moves it to the same path with `.devcontainer-mounts-backup`
  appended, logs a warning, and creates the host-facing symlink. For example,
  an existing `~/.azure` becomes `~/.azure.devcontainer-mounts-backup`.
  Existing data is not deleted or merged into the host. If that backup path
  already exists, the helper stops with an error without replacing either path.
  Rerunning the hook leaves correct symlinks and their backups unchanged.
- Azure CLI Features can create `.azure` during the image build, for example
  when installing CLI extensions. Those container-local extensions and settings
  remain in the backup and are no longer active through `~/.azure`; after
  linking, the host's directory is used. Backups remain inside the container
  and are not preserved when that container is deleted or rebuilt. Copy out
  anything you need before rebuilding, and do not delete authentication data
  without reviewing it.
- Host ownership and permissions are not changed. Files newly created by a root
  container may be owned by root on the host.
- Sharing directories does not guarantee shared authentication. Behavior depends
  on the OS keychain, authentication method, and application version.
- Concurrent access to shared history or databases depends on each application's
  locking behavior.
- To add a directory, update the metadata's `mounts` and publish a new version.
  Neither `install.sh` nor `link-mounts.sh` needs to change.
- Use `/mnt/mounts/<folder-name>` as the target. A matching link is created
  directly in the user's home. Names containing spaces are supported, but nested
  names, `.`, `..`, control characters, and duplicate targets are rejected.
- Never add actual `.copilot` or `.azure` directories, tokens, or the contents of
  personal configuration files to this repository.

## Development and local testing

The host needs Bash, Docker, jq, GNU tar, and sha256sum. Run tests as a non-root
host user with Docker Engine on the same host.

```bash
bash tests/test.sh
```

Tests use temporary dummy data only; they do not read your actual `~/.copilot`
or `~/.azure` directories. They verify the release archive's contents and
executable permissions, checksums, and home links and read/write access for
three users. They also cover installation without build-time mounts, repeated
hook execution, filtering out non-mounts, backing up existing directories,
files, and conflicting symlinks, and refusing to overwrite existing backups.
The directory fixtures include build-time Azure CLI extension data and an empty
Copilot directory; container-local data must not be copied into the host mounts.

An additional test modifies only temporary metadata to add a folder containing a
space, then verifies it for all three users without changing either script.
All host mount sources are replaced with temporary dummy directories.
Test containers and temporary files are removed when testing finishes.

These tests exercise the installer and the creation hook running as the
effective user against real bind mounts. End-to-end testing through VS Code User
Settings and the published URL must be performed separately after publication.

To build only the package:

```bash
bash scripts/package.sh
```

Output:

```text
dist/devcontainer-feature-mounts.tgz
dist/devcontainer-feature-mounts.tgz.sha256
```

The tarball contains root-level metadata and executable `install.sh` and
`link-mounts.sh` scripts. No additional mount-list file is generated.
Do not commit generated files or credentials.

## Publishing to GitHub Releases

1. Commit your changes and push them to the repository's default branch yourself.
2. Confirm that the **Test** workflow succeeds.
3. Open **Actions > Release > Run workflow** and select the default branch.
4. After testing, the workflow creates a tag from the Feature's `version` and
   attaches the tarball and checksum to a release.
5. Once the assets have been uploaded, the workflow publishes the draft release.

The Feature version is `1.0.1`, with tag `v1.0.1`. You do not need to push a tag
before running the workflow; the workflow creates it. The release job is skipped
when run against a branch other than the default branch.

No additional PAT or GHCR authentication is needed. The workflow uses the built-in
`GITHUB_TOKEN` with `contents: write`. GitHub Actions must be enabled for the
repository.

Existing tags, releases, and assets are never automatically overwritten. If
publication fails partway through, inspect any remaining tag or draft before
taking action. The workflow does not automatically delete or replace them.

For updates, change the metadata's `version` to a new `MAJOR.MINOR.PATCH`, publish
a new release, and update the User Settings URL to the new tag. Do not replace
assets under an existing version.
