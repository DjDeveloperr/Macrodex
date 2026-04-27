#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_path="${1:-}"
dest="$repo_root/Packages/PiJSC"
tmp_dir=""

cleanup() {
  if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
    rm -rf "$tmp_dir"
  fi
}
trap cleanup EXIT

if [[ -z "$source_path" ]]; then
  echo "usage: $0 /path/to/PiJSC-or-git-url" >&2
  exit 64
fi

if [[ "$source_path" == http://* || "$source_path" == https://* || "$source_path" == git@* ]]; then
  tmp_dir="$(mktemp -d)"
  git clone --depth 1 "$source_path" "$tmp_dir/PiJSC"
  source_path="$tmp_dir/PiJSC"
fi

if [[ ! -f "$source_path/Package.swift" ]]; then
  echo "source must be a PiJSC package directory containing Package.swift" >&2
  exit 66
fi

rsync -a --delete \
  --exclude ".git" \
  --exclude ".build" \
  "$source_path/" \
  "$dest/"

echo "Updated vendored PiJSC at Packages/PiJSC"
