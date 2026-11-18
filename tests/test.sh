#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for tool in docker jq tar sha256sum; do
  command -v "$tool" >/dev/null || fail "Required command is missing: $tool"
done

host_uid="$(id -u)"
[[ "$host_uid" != 0 ]] || fail 'Run these host-side tests as a non-root user.'

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
bash "$root/scripts/package.sh"
archive="$root/dist/devcontainer-feature-mounts.tgz"

mapfile -t entries < <(tar -tzf "$archive")
[[ "${#entries[@]}" == 3 && "${entries[0]}" == devcontainer-feature.json && "${entries[1]}" == install.sh && "${entries[2]}" == link-mounts.sh ]] \
  || fail 'The archive must contain root-level metadata, install.sh, and link-mounts.sh.'

(
  cd -- "$root/dist"
  sha256sum --check devcontainer-feature-mounts.tgz.sha256
)

tmp="$(mktemp -d)"
fixture_dirs=()

cleanup() {
  for directory in "${fixture_dirs[@]}"; do
    rm -f -- "$directory/host-marker.txt" "$directory/container-marker.txt"
    rmdir -- "$directory"
  done
  rm -f -- \
    "$tmp/feature/devcontainer-feature.json" \
    "$tmp/feature/install.sh" \
    "$tmp/feature/link-mounts.sh" \
    "$tmp/repo/src/mounts/devcontainer-feature.json" \
    "$tmp/repo/src/mounts/install.sh" \
    "$tmp/repo/src/mounts/link-mounts.sh" \
    "$tmp/repo/scripts/package.sh" \
    "$tmp/repo/dist/devcontainer-feature-mounts.tgz" \
    "$tmp/repo/dist/devcontainer-feature-mounts.tgz.sha256" \
    "$tmp/invalid.json" "$tmp/package-error.txt" "$tmp/targets.txt"
  for directory in \
    "$tmp/repo/src/mounts" "$tmp/repo/src" "$tmp/repo/scripts" \
    "$tmp/repo/dist" "$tmp/repo" "$tmp/feature" "$tmp"; do
    if [[ -d "$directory" ]]; then
      rmdir -- "$directory"
    fi
  done
}
trap cleanup EXIT

mkdir -p "$tmp/feature" "$tmp/repo/src/mounts" "$tmp/repo/scripts"
cp "$root/src/mounts/install.sh" "$root/src/mounts/link-mounts.sh" "$tmp/repo/src/mounts/"
cp "$root/scripts/package.sh" "$tmp/repo/scripts/"
jq '.mounts += [{
  "type": "bind",
  "source": "/test-only/unused-host-path",
  "target": "/mnt/mounts/extra config"
}]' "$root/src/mounts/devcontainer-feature.json" > "$tmp/repo/src/mounts/devcontainer-feature.json"
bash "$tmp/repo/scripts/package.sh"
tar -xzf "$tmp/repo/dist/devcontainer-feature-mounts.tgz" -C "$tmp/feature"
[[ -x "$tmp/feature/install.sh" ]] || fail 'The packaged installer lost its executable bit.'
[[ -x "$tmp/feature/link-mounts.sh" ]] || fail 'The packaged hook lost its executable bit.'
jq -r '.mounts[].target' "$tmp/feature/devcontainer-feature.json" > "$tmp/targets.txt"
hook="$(jq -er '.onCreateCommand | select(type == "string" and startswith("/"))' "$tmp/feature/devcontainer-feature.json")"

jq '.mounts[0].target = "/mnt/mounts/../outside"' \
  "$tmp/repo/src/mounts/devcontainer-feature.json" > "$tmp/invalid.json"
mv "$tmp/invalid.json" "$tmp/repo/src/mounts/devcontainer-feature.json"
if bash "$tmp/repo/scripts/package.sh" >"$tmp/package-error.txt" 2>&1; then
  fail 'Packaging accepted a mount target that escapes the mount root.'
fi
grep -Fq 'Mounts must be unique bind mounts' "$tmp/package-error.txt" || {
  cat "$tmp/package-error.txt" >&2
  fail 'Invalid targets failed for an unexpected reason.'
}
printf 'PASS: metadata-only mount addition and invalid-target rejection\n'

mount_args=()
while IFS= read -r target; do
  source="$tmp/data-${#fixture_dirs[@]}"
  mkdir "$source"
  fixture_dirs+=("$source")
  printf '%s\n' 'host-marker' > "$source/host-marker.txt"
  printf '%s\n' 'not-written' > "$source/container-marker.txt"
  mount_args+=(--mount "type=bind,source=$source,target=$target")
done < "$tmp/targets.txt"

docker run --rm -i --user root --entrypoint /bin/sh \
  --env "FEATURE_HOOK=$hook" \
  --mount "type=bind,source=$tmp/feature,target=/tmp/feature,readonly" \
  mcr.microsoft.com/devcontainers/python:3.12-bookworm -se <<'BUILD'
sh /tmp/feature/install.sh
test -x "$FEATURE_HOOK"
HOME=/root "$FEATURE_HOOK" > /tmp/hook-output
grep -Fq 'No mounted folders' /tmp/hook-output
printf 'PASS: build-time installation needs no mounts or remote home\n'
BUILD

docker run --rm -i --user root --entrypoint /bin/bash \
  --env "HOST_UID=$host_uid" \
  --env "FEATURE_HOOK=$hook" \
  --mount "type=bind,source=$tmp/feature,target=/tmp/feature,readonly" \
  --mount "type=bind,source=$tmp/targets.txt,target=/tmp/expected-targets.txt,readonly" \
  "${mount_args[@]}" \
  mcr.microsoft.com/devcontainers/python:3.12-bookworm -se <<'CONTAINER'
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_error() {
  if ! grep -Fq -- "$1" /tmp/install-error; then
    cat /tmp/install-error >&2
    fail "Expected diagnostic: $1"
  fi
}

sh /tmp/feature/install.sh
if env -u HOME "$FEATURE_HOOK" >/tmp/install-error 2>&1; then
  fail 'The runtime hook accepted a missing home.'
fi
expect_error 'HOME'

mkdir /tmp/installer-only
cp /tmp/feature/install.sh /tmp/installer-only/
if sh /tmp/installer-only/install.sh >/tmp/install-error 2>&1; then
  fail 'The installer accepted a missing runtime helper.'
fi
expect_error 'link-mounts.sh is missing'

mkdir /mnt/mounts/mounts-unmounted-test
touch /mnt/mounts/mounts-file-test
first_target="$(head -n 1 /tmp/expected-targets.txt)"
ln -s "$first_target" /mnt/mounts/mounts-alias-test

if [ "$(id -u vscode)" != "$HOST_UID" ]; then
  usermod --uid "$HOST_UID" vscode
fi

cat > /tmp/check-mounts.sh <<'CHECK'
#!/bin/sh
set -eu

[ "$(id -un)" = "$1" ] && [ "$HOME" = "$2" ] || {
  printf 'FAIL: Unexpected user or home\n' >&2
  exit 1
}

while IFS= read -r target; do
  name="${target##*/}"
  link="$HOME/$name"
  [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ] || {
    printf 'FAIL: Unexpected home link: %s\n' "$link" >&2
    exit 1
  }
  mountpoint -q -- "$target" || {
    printf 'FAIL: Not a mount point: %s\n' "$target" >&2
    exit 1
  }
  grep -Fxq 'host-marker' "$link/host-marker.txt" || {
    printf 'FAIL: Host marker mismatch: %s\n' "$link" >&2
    exit 1
  }
  printf '%s\n' "$1" > "$link/container-marker.txt"
done < /tmp/expected-targets.txt

for name in mounts-unmounted-test mounts-file-test mounts-alias-test; do
  [ ! -e "$HOME/$name" ] && [ ! -L "$HOME/$name" ] || {
    printf 'FAIL: Linked a path that is not a mounted folder: %s\n' "$name" >&2
    exit 1
  }
done

printf 'PASS: %s home links and bind-mount read/write\n' "$1"
CHECK
chmod +x /tmp/check-mounts.sh

su -s /bin/sh vscode -c '
  mkdir -p "$HOME/.azure/cliextensions/account" "$HOME/.copilot"
  printf "%s\n" "container-extension" > "$HOME/.azure/cliextensions/account/feature-marker.txt"
'
su -s /bin/sh vscode -c 'exec "$FEATURE_HOOK"'
su -s /bin/sh vscode -c '/tmp/check-mounts.sh vscode /home/vscode'
azure_backup=/home/vscode/.azure.devcontainer-mounts-backup
copilot_backup=/home/vscode/.copilot.devcontainer-mounts-backup
grep -Fxq 'container-extension' "$azure_backup/cliextensions/account/feature-marker.txt" \
  || fail 'The existing Azure CLI extension data was not backed up.'
test ! -e /mnt/mounts/.azure/cliextensions \
  || fail 'Container-local Azure CLI extensions were copied to the host.'
test -d "$copilot_backup" && test ! -L "$copilot_backup" \
  || fail 'The existing empty Copilot directory was not backed up.'
su -s /bin/sh vscode -c 'exec "$FEATURE_HOOK"'
su -s /bin/sh vscode -c '/tmp/check-mounts.sh vscode /home/vscode'
grep -Fxq 'container-extension' "$azure_backup/cliextensions/account/feature-marker.txt" \
  || fail 'The repeated hook changed the Azure CLI backup.'
test ! -e "$azure_backup.devcontainer-mounts-backup" \
  || fail 'The repeated hook created another backup.'
printf 'PASS: Azure CLI data and empty directory backed up, repeated hook, and non-mount filtering\n'

HOME=/root "$FEATURE_HOOK"
HOME=/root /tmp/check-mounts.sh root /root

usermod --login pocuser --home /srv/poc-home --move-home vscode
groupmod --new-name pocuser vscode
while IFS= read -r target; do
  rm -- "/srv/poc-home/${target##*/}"
done < /tmp/expected-targets.txt
su -s /bin/sh pocuser -c 'exec "$FEATURE_HOOK"'
su -s /bin/sh pocuser -c '/tmp/check-mounts.sh pocuser /srv/poc-home'

first_name="${first_target##*/}"
mkdir -p /tmp/file-home
printf '%s\n' 'keep-me' > "/tmp/file-home/$first_name"
HOME=/tmp/file-home "$FEATURE_HOOK"
test "$(readlink "/tmp/file-home/$first_name")" = "$first_target" \
  || fail 'The existing file was not replaced with the expected link.'
grep -Fxq 'keep-me' "/tmp/file-home/$first_name.devcontainer-mounts-backup" \
  || fail 'The existing file was not backed up.'
printf 'PASS: existing file backed up\n'

mkdir -p /tmp/symlink-home
ln -s /tmp/missing-target "/tmp/symlink-home/$first_name"
HOME=/tmp/symlink-home "$FEATURE_HOOK"
test "$(readlink "/tmp/symlink-home/$first_name")" = "$first_target" \
  || fail 'The conflicting symlink was not replaced with the expected link.'
test "$(readlink "/tmp/symlink-home/$first_name.devcontainer-mounts-backup")" = /tmp/missing-target \
  || fail 'The conflicting symlink was not backed up.'
printf 'PASS: conflicting dangling symlink backed up\n'

for backup_type in directory file symlink; do
  conflict_home="/tmp/conflict-$backup_type-home"
  mkdir -p "$conflict_home/$first_name"
  printf '%s\n' 'keep-original' > "$conflict_home/$first_name/keep.txt"
  backup="$conflict_home/$first_name.devcontainer-mounts-backup"
  case "$backup_type" in
    directory)
      mkdir "$backup"
      printf '%s\n' 'keep-backup' > "$backup/keep.txt"
      ;;
    file) printf '%s\n' 'keep-backup' > "$backup" ;;
    symlink) ln -s /tmp/missing-backup-target "$backup" ;;
  esac
  if HOME="$conflict_home" "$FEATURE_HOOK" >/tmp/install-error 2>&1; then
    fail "The runtime hook accepted an existing $backup_type backup."
  fi
  expect_error "Refusing to replace existing backup: $backup"
  test ! -L "$conflict_home/$first_name" \
    || fail 'The original directory was replaced despite a backup conflict.'
  grep -Fxq 'keep-original' "$conflict_home/$first_name/keep.txt" \
    || fail 'The original directory contents were changed.'
  case "$backup_type" in
    directory) grep -Fxq 'keep-backup' "$backup/keep.txt" ;;
    file) grep -Fxq 'keep-backup' "$backup" ;;
    symlink) test "$(readlink "$backup")" = /tmp/missing-backup-target ;;
  esac || fail "The existing $backup_type backup was changed."
done
printf 'PASS: existing directory, file, and dangling symlink backups preserved\n'
CONTAINER

for directory in "${fixture_dirs[@]}"; do
  grep -Fxq pocuser "$directory/container-marker.txt" \
    || fail "Container writes did not reach the host: $directory"
done

printf 'PASS: package layout, checksum, installer, and host-side writes\n'
