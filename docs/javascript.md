# JavaScript

moss's JavaScript engine is `lib/js/`: ES2023, our own, a library with
no authority of its own — it knows no file, channel or DOM — that a
domain embeds. The page domain (`webpage`) will embed it with the DOM and
the HTML event loop; `jsrun` will embed it with a domain's capabilities
offered as modules, so a script gets exactly what its domain holds and
nothing ambient. No machine code is ever generated: a page executes what
the kernel mapped at spawn, and the interpreter is where the speed goes.
The decision and its reasons are ROADMAP's row "JavaScript"; the stages
are under "A web browser", stage 10.

## What exists

- `lib/js/lexer.zig` — the lexical grammar (ECMA-262 §12): tokens with
  cooked text, numbers in every radix, templates, regular-expression
  literals by rescan, the line-terminator flag ASI reads.
- `lib/js/ast.zig` — the syntax tree.
- `lib/js/parser.zig` — the syntactic grammar (§13–§16) with its early
  errors: scripts and modules, strict mode, classes with fields, private
  names and static blocks, generators, async functions, destructuring,
  optional chaining, the cover grammars.

Not yet: the compiler, the virtual machine, the collector, the builtins,
RegExp bodies (the lexer checks a literal's shape and flags, not its
pattern), the exact Unicode identifier tables (approximated by ranges).

## Measuring it

```
tools/fetch-test262.sh            # once: the corpus at its pinned commit
zig build test262                 # test/language, counts per directory
zig build test262 -- test/language/statements test/language/module-code
TEST262_VERBOSE=1 zig build test262   # each miss with the parser's reason
```

Every file is judged by its front matter: a `negative: phase: parse`
file passes when the parser refuses it in every mode it would run in
(sloppy and strict, or as a module — `onlyStrict`, `noStrict`, `raw` and
`module` flags honoured); any other file passes when it parses. The
counts are recorded in DESIGN.md as each stage lands; proposals beyond
ES2023 (`using`, `import defer`, decorators) stay in the count as misses
rather than being filtered out.
