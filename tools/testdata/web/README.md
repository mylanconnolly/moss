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

Still to vendor, with the stage that first reads them: a curated test262
slice (the JavaScript engine, stage 10) and WPT reftest subsets per layout
module (stages 4 and 9).
