#!/bin/sh
# Fetch the Unicode Character Database files `zig build ucdgen` distills
# into lib/js/unicode.bin, into tools/testdata/ucd (ignored by git: the
# blob is what is vendored, not its 8 MB of sources). The version is
# the one test262's generated property-escape tests encode; to move it,
# change VERSION here, re-run, then `zig build ucdgen`.
set -e
VERSION=17.0.0
DIR="$(dirname "$0")/testdata/ucd"
if [ -f "$DIR/Scripts.txt" ] && head -1 "$DIR/Scripts.txt" | grep -q "Scripts-$VERSION"; then
  echo "ucd: at $VERSION"; exit 0
fi
rm -rf "$DIR"
mkdir -p "$DIR/extracted" "$DIR/emoji"
for f in UnicodeData.txt DerivedCoreProperties.txt PropList.txt Scripts.txt \
         ScriptExtensions.txt CaseFolding.txt SpecialCasing.txt \
         PropertyValueAliases.txt PropertyAliases.txt DerivedNormalizationProps.txt \
         extracted/DerivedGeneralCategory.txt extracted/DerivedBinaryProperties.txt \
         emoji/emoji-data.txt; do
  curl -fsS -o "$DIR/$f" "https://www.unicode.org/Public/$VERSION/ucd/$f"
done
# The emoji sequence files (properties of strings, `\p{RGI_Emoji}` under
# the v flag) are published beside the UCD, not in it.
for f in emoji-sequences.txt emoji-zwj-sequences.txt; do
  curl -fsS -o "$DIR/emoji/$f" "https://www.unicode.org/Public/$VERSION/emoji/$f"
done
echo "ucd: fetched $VERSION"
