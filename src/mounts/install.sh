#!/bin/sh
set -eu

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
helper="$script_dir/link-mounts.sh"
[ -f "$helper" ] || fail 'link-mounts.sh is missing from the Feature.'

destination=/usr/local/share/devcontainer-mounts
mkdir -p "$destination"
cp "$helper" "$destination/link-mounts.sh"
chmod 0755 "$destination/link-mounts.sh"
