#!/bin/sh
# Fetch test262 at its pinned commit into tools/testdata/test262 (ignored
# by git: 200 MB of tests do not belong beside 3 MB of corpora). The pin
# is what makes `zig build test262`'s counts mean the same on every
# machine; to move it, change PIN here and re-run.
set -e
PIN=7ab7fafa0003f73fc85c1b95d88094d33f7eb8bd
DIR="$(dirname "$0")/testdata/test262"
if [ -d "$DIR/.git" ] && [ "$(git -C "$DIR" rev-parse HEAD)" = "$PIN" ]; then
  echo "test262: at $PIN"; exit 0
fi
rm -rf "$DIR"
git clone -q --filter=blob:none --no-checkout https://github.com/tc39/test262.git "$DIR"
git -C "$DIR" sparse-checkout set harness test/language test/built-ins test/annexB
git -C "$DIR" checkout -q "$PIN"
echo "test262: fetched $PIN"
