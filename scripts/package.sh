#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

for tool in jq tar sha256sum; do
  command -v "$tool" >/dev/null || fail "Required command is missing: $tool"
done

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
feature="$root/src/mounts"
metadata="$feature/devcontainer-feature.json"

[[ -x "$feature/install.sh" ]] || fail 'src/mounts/install.sh must be executable.'
[[ -x "$feature/link-mounts.sh" ]] || fail 'src/mounts/link-mounts.sh must be executable.'

if ! id="$(jq -er '.id | select(type == "string" and test("^[a-z0-9][a-z0-9-]*$"))' "$metadata")"; then
  fail 'Feature metadata must contain a valid lowercase id.'
fi

[[ "$id" == "$(basename -- "$feature")" ]] \
  || fail 'Feature id must match its source directory name.'

if ! version="$(jq -er '.version | select(type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))' "$metadata")"; then
  fail 'Feature version must use stable MAJOR.MINOR.PATCH format.'
fi

if ! jq -e '
  def valid_target:
    type == "string"
    and startswith("/mnt/mounts/")
    and (ltrimstr("/mnt/mounts/") |
      . != "" and . != "." and . != ".." and (contains("/") | not))
    and (explode | all(. >= 32 and . != 127));
  .mounts as $mounts |
  ($mounts | type == "array")
  and all($mounts[];
    .type == "bind"
    and (.source | type == "string" and length > 0)
    and (.target | valid_target))
  and ([$mounts[].target] | length == (unique | length))
' "$metadata" >/dev/null; then
  fail 'Mounts must be unique bind mounts directly below /mnt/mounts with valid folder names.'
fi

mkdir -p "$root/dist"
archive="devcontainer-feature-$id.tgz"
tar -czf "$root/dist/$archive" -C "$feature" devcontainer-feature.json install.sh link-mounts.sh

(
  cd -- "$root/dist"
  sha256sum "$archive" > "$archive.sha256"
)

printf 'Packaged %s version %s: %s\n' "$id" "$version" "$root/dist/$archive"
