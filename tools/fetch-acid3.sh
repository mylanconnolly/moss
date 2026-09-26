#!/bin/sh
# Fetch the Acid3 test (the web-platform-tests copy, adapted to relative
# URLs) at a pinned commit into tools/testdata/acid3 (ignored by git,
# like test262: fetched, never vendored). The web drill serves it from
# the fixture server and prints the score a page domain reaches; without
# these files the drill says so and skips that step. To move the pin,
# change PIN here and re-run.
set -e
PIN=bdadba91cf68adbfe90eaf264117218d02a3d94b
DIR="$(dirname "$0")/testdata/acid3"
if [ -f "$DIR/PIN" ] && [ "$(cat "$DIR/PIN")" = "$PIN" ]; then
  echo "acid3: at $PIN"; exit 0
fi
rm -rf "$DIR"
mkdir -p "$DIR"
for f in test.html empty.css empty.html empty.png empty.xml support-a.png support-b.png svg.xml xhtml.1 xhtml.2 xhtml.3; do
  curl -fsS -o "$DIR/$f" "https://raw.githubusercontent.com/web-platform-tests/wpt/$PIN/acid/acid3/$f"
done
echo "$PIN" > "$DIR/PIN"
echo "acid3: fetched $PIN"
