#!/usr/bin/env bash
# Prints the URL of Veylor's Shielded USD kill switch, the owner's JSON
# document {"private_usd_available": true|false} (docs/private-usd.md,
# "Defines"), from scripts/release-config/veylor-private-usd-flag-url.txt: the
# one place every Veylor build pipeline takes it from, so a reproducible build
# finds it at its tag. Prints nothing while the file names none: then no build
# passes VIZOR_PRIVATE_USD_FLAG_URL, and the feature stays available. Fails on
# anything but one https URL without credentials, a fragment or whitespace.
set -euo pipefail

file="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/release-config/veylor-private-usd-flag-url.txt"
[[ -f "$file" ]] || { echo "missing $file" >&2; exit 1; }
url=""
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -n "$line" ]] || continue
  if [[ -n "$url" ]]; then
    echo "$file must hold one URL at most" >&2
    exit 1
  fi
  url="$line"
done < "$file"
[[ -n "$url" ]] || exit 0
if [[ ! "$url" =~ ^https://[A-Za-z0-9.-]+(:443)?(/[^@#[:space:]]*)?$ ]]; then
  echo "$file must hold an https URL without credentials or a fragment" >&2
  exit 1
fi
printf '%s\n' "$url"
