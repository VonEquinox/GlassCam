#!/bin/bash
# Offline, hash-verified materialization of all 50 FFCS 0.2.0 native LUTs.
set -euo pipefail
if [[ $# -ne 2 || -z "$2" || "$2" == / ]]; then
  echo 'Usage: prepare_ffcs_resources.sh SOURCE_ZIP OUTPUT_FFCS_DIRECTORY' >&2
  exit 2
fi
archive="$1"
output="$2"
script_dir="$(cd "$(dirname "$0")" && pwd)"
expected='ebc7a783280aeeea73791cdd40fcccb30c2b9648061616c96d4a1f9b1decff6c'
if command -v shasum >/dev/null 2>&1; then
  digest() { shasum -a 256 "$1" | awk '{print $1}'; }
  check_assets() { (cd "$1" && shasum -a 256 -c "$script_dir/ffcs_native_SHA256SUMS"); }
else
  digest() { sha256sum "$1" | awk '{print $1}'; }
  check_assets() { (cd "$1" && sha256sum -c "$script_dir/ffcs_native_SHA256SUMS"); }
fi
[[ -f "$archive" ]] || { echo "Missing original FFCS archive: $archive" >&2; exit 3; }
[[ "$(digest "$archive")" == "$expected" ]] || { echo 'FFCS archive SHA256 mismatch' >&2; exit 4; }
mkdir -p "$output"
if [[ -f "$output/.verified" ]] && [[ "$(cat "$output/.verified")" == "$expected" ]] && check_assets "$output" >/dev/null 2>&1; then
  echo 'FFCS: all 50 cached original LUT hashes verified.'
  exit 0
fi
stage="$(mktemp -d "$output/.ffcs-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
# Paths come only from this checked-in checksum list, never from ZIP members.
while read -r hash filename; do
  case "$filename" in
    xh2s/*.lutz|xa3/*.lutz|gfx100/*.lutz|gfx100s/*.lutz|gfx100ii/*.lutz) ;;
    *) echo 'Unexpected asset path' >&2; exit 5;;
  esac
  [[ "$filename" != *..* ]] || exit 5
  mkdir -p "$stage/$(dirname "$filename")"
  unzip -p "$archive" "FFCS_技术实现完整交付/implementation/ffcs/data/$filename" > "$stage/$filename"
done < "$script_dir/ffcs_native_SHA256SUMS"
check_assets "$stage"
while read -r hash filename; do
  mkdir -p "$output/$(dirname "$filename")"
  mv "$stage/$filename" "$output/$filename"
done < "$script_dir/ffcs_native_SHA256SUMS"
printf '%s\n' "$expected" > "$output/.verified"
echo 'FFCS: 50 original LUTs ready.'
