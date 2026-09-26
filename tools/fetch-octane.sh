#!/bin/sh
# Fetch the Octane benchmarks the engine's bench row runs (base.js and
# Richards, DeltaBlue, Crypto) at a pinned commit into
# tools/testdata/octane (ignored by git, like test262: the corpus is
# fetched, never vendored — Octane is BSD-licensed Google code). The
# pin is what makes `zig build bench-js`'s numbers comparable across
# machines; to move it, change PIN here and re-run.
set -e
PIN=570ad1ccfe86e3eecba0636c8f932ac08edec517
DIR="$(dirname "$0")/testdata/octane"
if [ -d "$DIR/.git" ] && [ "$(git -C "$DIR" rev-parse HEAD)" = "$PIN" ]; then
  echo "octane: at $PIN"; exit 0
fi
rm -rf "$DIR"
git clone -q --filter=blob:none --no-checkout https://github.com/chromium/octane.git "$DIR"
git -C "$DIR" sparse-checkout set --no-cone base.js richards.js deltablue.js crypto.js LICENSE
git -C "$DIR" checkout -q "$PIN"
echo "octane: fetched $PIN"
