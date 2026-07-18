#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: package-runtime.sh PREFIX OUTPUT.tar.gz" >&2
  exit 64
fi

prefix="$1"
output="$2"
source_date_epoch="${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must identify the exact source revision time}"

[[ -d "$prefix/drive_c" ]] || {
  echo "[cfw] prepared prefix is missing drive_c: $prefix" >&2
  exit 65
}
[[ "$source_date_epoch" =~ ^[0-9]+$ ]] || {
  echo "[cfw] SOURCE_DATE_EPOCH must be a non-negative integer" >&2
  exit 64
}

mkdir -p "$(dirname "$output")"
part="${output}.part"
rm -f "$part"
trap 'rm -f "$part"' EXIT
umask 022

# Normalize every archive-visible input that may otherwise vary by build host:
# lexical order, tar/PAX format, volatile PAX metadata, ownership, timestamp,
# portable permissions, and the gzip header.
tar \
  --sort=name \
  --format=posix \
  --pax-option=delete=atime,delete=ctime \
  --mtime="@${SOURCE_DATE_EPOCH}" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --mode='u+rwX,go+rX,go-w' \
  -C "$prefix" \
  -cf - . \
  | gzip -n > "$part"

mv -f "$part" "$output"
trap - EXIT
