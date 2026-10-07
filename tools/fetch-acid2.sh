#!/bin/sh
# Fetch the Acid2 test (the web-platform-tests copy: the test, its
# pixel-for-pixel CSS reference and the 404 page it probes) at a pinned
# commit into tools/testdata/acid2 (ignored by git, like test262 and
# acid3: fetched, never vendored). The reftest harness in lib/web/paint.zig
# renders test.html scrolled to its "Hello World!" anchor on a 400×300
# canvas beside px-reference.html and prints whether they agree; without
# these files it says so and skips. To move the pin, change PIN here and
# re-run.
set -e
PIN=bdadba91cf68adbfe90eaf264117218d02a3d94b
DIR="$(dirname "$0")/testdata/acid2"
if [ -f "$DIR/PIN" ] && [ "$(cat "$DIR/PIN")" = "$PIN" ]; then
  echo "acid2: at $PIN"; exit 0
fi
rm -rf "$DIR"
mkdir -p "$DIR"
for f in test.html px-reference.html reference.html 404.html; do
  curl -fsS -o "$DIR/$f" "https://raw.githubusercontent.com/web-platform-tests/wpt/$PIN/acid/acid2/$f"
done
echo "$PIN" > "$DIR/PIN"
echo "acid2: fetched $PIN"
