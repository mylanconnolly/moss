# JavaScript

moss's JavaScript engine is `lib/js/`: ES2023, our own, a library with
no authority of its own — it knows no file, channel or DOM — that a
domain embeds. The page domain (`webpage`) will embed it with the DOM and
the HTML event loop; `jsrun` will embed it with a domain's capabilities
offered as modules, so a script gets exactly what its domain holds and
nothing ambient. No machine code is ever generated: a page executes what
the kernel mapped at spawn, and the interpreter is where the speed goes.
The decision and its reasons are ROADMAP's row "JavaScript"; the stages
are under "A web browser", stage 10; DESIGN.md's "JavaScript" section is
the as-built account with the test262 numbers.

## What exists

- `lexer.zig`, `ast.zig`, `parser.zig` — the lexical and syntactic
  grammars (ECMA-262 §12–§16) with their early errors: scripts and
  modules, strict mode, classes with fields, private names and static
  blocks, generators, async functions, destructuring, optional
  chaining, the cover grammars.
- `value.zig` — a value in 64 bits (NaN-boxed: doubles offset, int32s
  tagged, cells as pointers, the four constants).
- `heap.zig` — cells in a region the embedder hands over, precisely
  collected (mark from explicit roots, sweep to size-class free lists);
  collection only at the interpreter's safe points.
- `string.zig` — Latin-1 and UTF-16 strings, ropes for concatenation,
  atoms (interned property keys).
- `object.zig` — objects behind hidden classes (`Shape`s shared by
  objects that got their properties the same way; a dictionary shape
  once one diverges), dense array elements, the internal methods under
  the specification's names.
- `scope.zig`, `bytecode.zig`, `compiler.zig` — scope analysis (which
  bindings are captured, which functions contain `eval` or `with`), a
  register-machine instruction set, and the compiler: uncaptured
  bindings in registers, captured ones in environment cells, `finally`
  through a completion register, eval and `with` by name.
- `interp.zig`, `vm.zig`, `realm.zig` — the interpreter (frames on one
  register stack, JS-to-JS calls without Zig recursion, inline caches
  at property and global sites, the handler stack for exceptions), the
  abstract operations, and the realm's intrinsics.
- `builtins/` — Object, Function, Array, String, Number, Boolean,
  Symbol, Math, JSON, Error and the native errors, Reflect, the global
  functions, the array and string iterators. Generators, async,
  modules, RegExp matching, BigInt, Proxy, Map/Set, Date and Promise
  are later stages and count as misses until they land.

## Running it

```
zig build js -- file.js [more.js]     # scripts in one realm, `print` on the global
JS_DUMP=1 zig build js -- file.js     # the bytecode of each file first
JS_TRACE=1 ...                        # every instruction executed (debugging)
JS_GC_STRESS=1 ...                    # collect at every safe point, poison freed cells
```

The runner is also the host program test262 drives.

## Measuring it

```
tools/fetch-test262.sh            # once: the corpus at its pinned commit
zig build test262                 # test/language, counts per directory
zig build test262 -- test/built-ins/Array test/language/statements
TEST262_VERBOSE=1 ...             # each miss and why (the exception, or the parser's reason)
TEST262_FILTER=substring ...      # only paths containing it
TEST262_GC_STRESS=1 ...           # every test under a collection at every safe point
TEST262_TRACE=1 ...               # print each path before running it (finding a crash)
```

Every file runs as the harness would: `assert.js`, `sta.js` and its
`includes:` first, in a fresh realm, then the test in sloppy and strict
mode unless a flag says one (`onlyStrict`, `noStrict`, `raw`; `module`
files are stage c and count as misses). A file passes when every mode
completes without an exception; a `negative:` file when it fails in the
named phase with the named error type; an `async` file when it prints
`Test262:AsyncTestComplete`. The counts are recorded in DESIGN.md as each
stage lands; proposals beyond ES2023 stay in the count as misses rather
than being filtered out. A runaway test is stopped by the VM's step
budget (a `RangeError` after 20M backward jumps or native-loop steps).
