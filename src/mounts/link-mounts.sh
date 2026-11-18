#!/bin/sh
set -eu

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

remote_home="${HOME:?HOME is not set}"
mount_root=/mnt/mounts

case "$remote_home" in
  /*) ;;
  *) fail "Home must be absolute: $remote_home" ;;
esac
[ -d "$remote_home" ] || fail "Home does not exist: $remote_home"

if [ ! -e "$mount_root" ]; then
  printf 'INFO: No mounted folders under %s.\n' "$mount_root"
  exit 0
fi
[ -d "$mount_root" ] || fail "Mount root is not a directory: $mount_root"
command -v mountpoint >/dev/null || fail 'The util-linux mountpoint command is required.'

count=0
for target in "$mount_root"/* "$mount_root"/.[!.]* "$mount_root"/..?*; do
  [ -d "$target" ] || continue
  [ ! -L "$target" ] || continue

  if mountpoint -q -- "$target"; then
    :
  else
    status=$?
    [ "$status" -eq 32 ] || fail "Cannot inspect mount point: $target (exit $status)"
    continue
  fi

  count=$((count + 1))
  name="${target##*/}"
  link="$remote_home/$name"
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
    continue
  fi
  if [ -e "$link" ] || [ -L "$link" ]; then
    backup="$link.devcontainer-mounts-backup"
    if [ -e "$backup" ] || [ -L "$backup" ]; then
      fail "Refusing to replace existing backup: $backup"
    fi
    mv -nT -- "$link" "$backup"
    # mv -n can succeed without moving if another process creates the backup.
    if [ -e "$link" ] || [ -L "$link" ]; then
      fail "Could not back up existing path: $link (backup: $backup)"
    fi
    printf 'WARNING: Moved existing path %s to %s.\n' "$link" "$backup" >&2
  fi
  ln -sT "$target" "$link"
  printf 'Linked %s -> %s\n' "$link" "$target"
done

if [ "$count" -eq 0 ]; then
  printf 'INFO: No mounted folders under %s.\n' "$mount_root"
fi
