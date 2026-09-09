#!/bin/sh
# Fetch upstream CLDR JSON and re-project into third_party/cldr/<tag>.json.
# Offline of `zig build` — the gate is hermetic; this is a manual refresh,
# the same shape as the runtime locale auto-updater's fetch.
set -eu
REL="${1:-48.2.0}"
BASE="https://raw.githubusercontent.com/unicode-org/cldr-json/main/cldr-json"
TMP="$(mktemp -d)"
for loc in en de fr ja; do
  curl -sSf "$BASE/cldr-numbers-full/main/$loc/numbers.json"     -o "$TMP/$loc-numbers.json"
  curl -sSf "$BASE/cldr-dates-full/main/$loc/ca-gregorian.json"  -o "$TMP/$loc-cagreg.json"
  curl -sSf "$BASE/cldr-numbers-full/main/$loc/currencies.json"  -o "$TMP/$loc-curr.json"
done
curl -sSf "$BASE/cldr-core/supplemental/currencyData.json" -o "$TMP/currencyData.json"
python3 tools/cldr-project.py "$TMP" third_party/cldr "$REL"
rm -rf "$TMP"
echo "re-projected CLDR $REL into third_party/cldr/"
