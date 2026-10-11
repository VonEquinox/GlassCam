#!/bin/bash
# No network or package install. Materialize the original 19 FFCS XH2S assets.
set -euo pipefail
if [[ $# -ne 2 || -z "$2" || "$2" == / ]]; then
  echo 'Usage: prepare_ffcs_resources.sh SOURCE_ZIP OUTPUT_XH2S_DIRECTORY' >&2
  exit 2
fi
archive="$1"
output="$2"
script_dir="$(cd "$(dirname "$0")" && pwd)"
expected='bc8c9b4d7691f3ecef03a79e3b1a7ddd8364647e97877ee02ceefa8e50e2ea02'
if command -v shasum >/dev/null 2>&1; then
  digest() { shasum -a 256 "$1" | awk '{print $1}'; }
  check_assets() { (cd "$1" && shasum -a 256 -c "$script_dir/ffcs_xh2s_SHA256SUMS"); }
else
  digest() { sha256sum "$1" | awk '{print $1}'; }
  check_assets() { (cd "$1" && sha256sum -c "$script_dir/ffcs_xh2s_SHA256SUMS"); }
fi
[[ -f "$archive" ]] || { echo "Missing original FFCS archive: $archive" >&2; exit 3; }
[[ "$(digest "$archive")" == "$expected" ]] || { echo 'FFCS archive SHA256 mismatch' >&2; exit 4; }
mkdir -p "$output"
if [[ -f "$output/.verified" ]] && check_assets "$output" >/dev/null 2>&1; then
  echo 'FFCS: all 19 cached original LUT hashes verified.'
  exit 0
fi
stage="$(mktemp -d "$output/.ffcs-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
unzip -j -o "$archive" 'FFCS_技术实现完整交付/implementation/ffcs/data/xh2s/*.lutz' -d "$stage" >/dev/null
check_assets "$stage"
# Move only the expected, checksum-verified filenames. No archive path is used
# as a filesystem destination; unzip -j discarded all stored path components.
while read -r hash filename; do mv "$stage/$filename" "$output/$filename"; done < "$script_dir/ffcs_xh2s_SHA256SUMS"
printf '%s\n' "$expected" > "$output/.verified"
echo 'FFCS: 19 original LUTs ready.'
