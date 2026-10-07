#!/bin/sh
# Fetch the WPT reftests listed in tools/testdata/web/wpt-reftests.txt
# at a pinned commit into tools/testdata/wpt (ignored by git, like
# test262 and the Acid tests: fetched, never vendored), each test beside
# the reference its `rel=match` names and the stylesheets and pictures
# it links (one level, relative paths; `../reference/` lands under
# tools/testdata/wpt/reference/). To move the pin, change PIN and re-run.
set -e
PIN=bdadba91cf68adbfe90eaf264117218d02a3d94b
HERE="$(dirname "$0")"
LIST="$HERE/testdata/web/wpt-reftests.txt"
DIR="$HERE/testdata/wpt"
RAW="https://raw.githubusercontent.com/web-platform-tests/wpt/$PIN/css"
if [ -f "$DIR/PIN" ] && [ "$(cat "$DIR/PIN")" = "$PIN" ] && [ "$(cat "$DIR/LIST.sum" 2>/dev/null)" = "$(cksum < "$LIST")" ]; then
  echo "wpt: at $PIN"; exit 0
fi
rm -rf "$DIR"
mkdir -p "$DIR"
# fetch PATH (relative to css/): skip what is already there
fetch() {
  p="$1"
  # normalise a/../b
  p=$(printf '%s' "$p" | awk -F/ '{n=0; for(i=1;i<=NF;i++){ if($i=="..") n--; else if($i!="." && $i!="") { parts[n]=$i; n++ } } out=""; for(i=0;i<n;i++) out=out (i?"/":"") parts[i]; print out}')
  [ -f "$DIR/$p" ] && return 0
  mkdir -p "$DIR/$(dirname "$p")"
  curl -fsS -o "$DIR/$p" "$RAW/$p" || { echo "wpt: missing $p"; rm -f "$DIR/$p"; return 0; }
  # what it links, relative (absolute /fonts/ and /css/ paths are not fetched: the Ahem face is built in)
  d=$(dirname "$p")
  for ref in $( { grep -E 'rel="?(match|stylesheet)"?' "$DIR/$p" | grep -oE 'href="?[^" >]*' | sed 's/^href="\{0,1\}//'; grep -oE 'src="?[^" >]*\.(png|jpg|gif|css)' "$DIR/$p" | sed 's/^src="\{0,1\}//'; } | sort -u); do
    case "$ref" in /*|http*|data:*) continue;; esac
    fetch "$d/$ref"
  done
}
grep -v '^#' "$LIST" | grep -v '^$' | while read -r t; do fetch "$t"; done
echo "$PIN" > "$DIR/PIN"
cksum < "$LIST" > "$DIR/LIST.sum"
echo "wpt: fetched $PIN ($(find "$DIR" -name '*.html' -o -name '*.xht' | wc -l | tr -d ' ') files)"
