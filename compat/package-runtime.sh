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

# Keep only Wine's portable C: drive mapping. The other generated dosdevices
# links bind the prefix to host paths (notably z: -> /) and must not cross the
# artifact boundary. Consumers can execute the prepared prefix without a
# consumer-side wineboot update when this relative C: mapping is present.
dosdevices="$prefix/dosdevices"
c_drive_link="$dosdevices/c:"
[[ -d "$dosdevices" ]] || {
  echo "[cfw] prepared prefix is missing dosdevices: $dosdevices" >&2
  exit 65
}
[[ -L "$c_drive_link" && "$(readlink "$c_drive_link")" == "../drive_c" ]] || {
  echo "[cfw] prepared prefix has invalid portable C: mapping: $c_drive_link" >&2
  exit 65
}

# Normalize every archive-visible input that may otherwise vary by build host:
# lexical order, tar/PAX format, volatile PAX metadata, ownership, timestamp,
# portable permissions, and the gzip header. Enumerate archive members without
# recursing so only dosdevices/c: is retained.
(
  cd "$prefix"
  {
    find . -path './dosdevices' -prune -o -print
    printf '%s\n' './dosdevices' './dosdevices/c:'
  } | LC_ALL=C sort -u | tar \
    --no-recursion \
    --sort=name \
    --format=posix \
    --pax-option=delete=atime,delete=ctime \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --mode='u+rwX,go+rX,go-w' \
    --files-from=- \
    -cf -
) | gzip -n > "$part"

mv -f "$part" "$output"
trap - EXIT
