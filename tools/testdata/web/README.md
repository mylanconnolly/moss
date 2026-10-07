# Web conformance corpora

The public test suites the web libraries (`lib/web/`, `lib/js/`) are
measured against on the host, vendored at pinned commits so a pass count
means the same thing on every machine. Each library's `zig build test`
runs its corpus and prints the count; the numbers are recorded in
DESIGN.md as each stage lands. Nothing here is edited; to move a pin,
replace the directory wholesale and update the hash below.

| Corpus | Source | Pinned commit | What it holds |
|---|---|---|---|
| `html5lib-tests/` | https://github.com/html5lib/html5lib-tests | `9329e64694e7835d0dcff9811e22856ef6ad16f9` (2026-06-22, the last commit carrying `tree-construction/`; the suite moved to WPT on 2026-06-26) | `tokenizer/*.test` (JSON, the tokenizer's states and outputs) and `tree-construction/*.dat` (document in, expected tree out); `LICENSE` (MIT) |
| `wpt/url/` | https://github.com/web-platform-tests/wpt (`url/resources/`) | `e547b11ab65083ac34ca76910622b2f8c2fc72dc` | `urltestdata.json` (parse/resolve/serialize), `setters_tests.json`, `toascii.json` (IDNA), `percent-encoding.json`; `LICENSE.md` (3-Clause BSD) |
| `css-parsing-tests/` | https://github.com/SimonSapin/css-parsing-tests | `203ce36bffd617db7f118c551e32794561fb273d` | CSS Syntax Level 3: component values, declarations, rules, stylesheets, colours, `An+B`; `LICENSE` (MIT) |
| `reftests/acid1.html` | https://www.w3.org/Style/CSS/Test/CSS1/current/test5526c.htm | as served 2026-09-18 (the page says "last modified: 1 Dec 98") | Acid1, the CSS1 box-model test, byte for byte; `acid1.gif` is W3C's reference rendering for a human eye (real fonts, so never compared by pixel). W3C Software and Document License |

## Reftests

`reftests/` holds the layout engine's own tests in the WPT style: each
`NAME.html` must paint, on the fixed test fonts, exactly the pixels of
`NAME-ref.html`, a page that reaches the same picture by simpler means
(explicit sizes, absolute positioning, no floats). The harness in
`lib/web/paint.zig` runs every pair on a 320×240 canvas (a reference may
ask for another with `<meta name="reftest-size" content="WxH">`), prints
`reftests: N/M agree`, and requires all of them. The Acid1 reference is
every box of the page placed by hand at the coordinates CSS 1 gives it,
derived from the page's em values on paper, not from the engine.

## test262

The JavaScript engine's corpus is not vendored — 200 MB of tests beside
3 MB of corpora — but fetched at a pinned commit into `test262/` (ignored
by git) by `tools/fetch-test262.sh`: `7ab7fafa0003f73fc85c1b95d88094d33f7eb8bd`,
`harness/`, `test/language`, `test/built-ins`, `test/annexB`. `zig build
test262 [-- test/language/...]` runs the engine over it — each file with
the harness and its includes in a fresh realm, sloppy and strict — and
prints pass/total per directory; `TEST262_VERBOSE=1` names each miss
with the exception or the parser's reason (docs/javascript.md has the
other switches). The pin is what makes the count mean the same on every
machine; to move it, change `PIN` in the script and re-run it. Not part of
`zig build check` (like `bench`).

## Acid2

Fetched, not vendored, like test262: `tools/fetch-acid2.sh` puts WPT's
`acid/acid2/` (the test, its pixel-for-pixel CSS reference and the 404
page it probes) under `acid2/` at the pin in the script. The reftest
harness renders the test scrolled to `#top` on a 400×300 canvas beside
`px-reference.html`, with the `data:` pictures decoded, and asserts the
pixels agree (`acid2 (host): agrees with its reference`); without the
files it says so and skips.

Still to vendor, with the stage that first reads them: WPT reftest
subsets per layout module (stages 4 and 9).
