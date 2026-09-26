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
  functions, the array and string iterators, Promise, generators and
  async functions (`generator.zig`: frames copied to the heap on yield
  or await, resumed by `next` or a promise reaction), RegExp
  (`builtins/regexp.zig`, the object and the string methods over the
  engine below), Map/Set/WeakMap/WeakSet (`map.zig`, with the ES2025 set
  methods and `getOrInsert`), Proxy (every trap with its invariants),
  BigInt (`bigint.zig`, cells of limbs over `std.math.big`), Date
  (`date.zig`, the calendar arithmetic of §21.4.1, the string formats
  and their parsers; local time is UTC until a host offers a zone),
  ArrayBuffer, SharedArrayBuffer and DataView (`arraybuffer.zig`: the
  bytes live outside the collected heap and are freed with the buffer;
  resizable, transferable, detachable and immutable buffers), the
  typed arrays (`typedarray.zig`: %TypedArray% and its twelve
  constructors including Float16Array, the integer-indexed exotic
  object's internal methods, `Uint8Array`'s base64 and hex methods),
  and Atomics (`atomics.zig`, for the one agent there is), and the
  Iterator constructor with the ES2025 helpers (`iterhelpers.zig`:
  helpers as native state machines that close what they hold open on
  `return`; `Iterator.from`, `concat`, `zip`, `chunks`, `windows`).
- `regexp.zig` — the regular expression engine: a parser for the
  ES2023 grammar with Annex B's tolerance (u/v modes, named groups,
  lookbehind, property escapes), a compiler to a small instruction set
  with counted loops and a greedy single-character fast path, and a
  backtracking matcher over UTF-16 units with an explicit backtrack
  stack and a step budget (a `RangeError` when exhausted, never a
  hang).
- `unicode.zig` + `unicode.bin` — the Unicode Character Database the
  engine needs (identifier classes, `\p{}` properties and scripts,
  case folding and the full case mappings), distilled from Unicode
  17.0.0 by `tools/ucdgen.zig` into a vendored table read in place.
- `module.zig` — module records, linking with live import bindings,
  namespace objects, evaluation with top-level await, `import()` and
  `import.meta`; sources come only from the embedder's `Vm.host_load`.
  Temporal is a later stage and counts as misses until it lands.

## Embedding it

`jsrun` (`user/jsrun.zig`) is the first host: a script domain in the
page domain's shape, spawned with one capability — a badged calling
end to whoever spawned it — that runs a program over its own static
heaps (the collector's region, and `lib/heapalloc` for the engine's
bookkeeping) and reports back through a shared buffer (`shared/js.zig`: the
attach, each `print` line, the ending). The shell's `js-run SOURCE`
(`user/jscmds.zig` over `user/jshost.zig`) is its host: it stages the
image from the program store, serves the run and destroys the domain,
answering `{ value, lines }` or an error naming the uncaught exception,
the syntax error or the death. A program gets exactly what its domain
holds, as modules: `js-run SOURCE { fs: DIR, module: true }` lends one
directory of the shell's view, derived for the run, as `moss:fs`
(`read`, `write`, `list`, `stat`, `exists`, all calls back to the host)
and as the place relative imports come from; `module: true` runs the
source as a module with `import`, `export` and top-level `await`;
`net: true` lends the shell's network view as `moss:net`, whose
`fetch(url, { method, body })` goes through the page host's broker
(redirects, keep-alive, the same refusals as a page's) and resolves to
`{ ok, status, url, type, text }`; `console` and `print` are the
output. A program lent nothing finds no `moss:fs` or `moss:net`, and
none can climb out of the directory it was lent. The
`jsrun` drill (`zig build check -Donly=jsrun`) is the integration test.

```
zig build check -Donly=jsrun            # the script-domain drill
```

```msh
(js-run "import { read, list } from 'moss:fs';
         import { helper } from './lib.js';
         console.log(list('.').map(e => e.name), read('note.txt'), await helper());"
        { fs: state/work, module: true })
```

The page domain (`user/webpage.zig`) is the second host: the engine
runs a page's `<script>`s over the DOM through `lib/web/script.zig`
(see `docs/web.md`, Scripts). A host sizes the engine with
`Vm.initWith(region, meta, .{ .stack_values, .max_frames })` — the
value stack and the call depth are allocated from the bookkeeping
allocator at init, 4 MB at the runner's defaults, which is why the page
asks for 64K values and 4,000 frames — and reads `Vm.embedder_roots`
and `Vm.host_data` as its hooks: the first traces the host's own tables
at collection, the second is what a native reaches its host through.

Nothing the engine links may be `threadlocal` (a user program has no
thread-local storage; the compiler's last-error slot was one, found by
the first syntax error in a domain).

## Running it

```
zig build js -- file.js [more.js]     # scripts in one realm, `print` on the global
zig build js -- entry.mjs             # a module graph (imports relative to the importer)
JS_DUMP=1 zig build js -- file.js     # the bytecode of each file first
JS_TRACE=1 ...                        # every instruction executed (debugging)
JS_GC_STRESS=1 ...                    # collect at every safe point, poison freed cells
```

The runner is also the host program test262 drives. Its clock is the
host's (`Vm.host_now`, what `Date.now` reads); an embedder without one
gets the epoch.

```
tools/fetch-ucd.sh                # once: the Unicode data files at the pinned version
zig build ucdgen                  # regenerate lib/js/unicode.bin from them
```

## Benchmarking it

```
tools/fetch-octane.sh             # once: Octane's base.js, Richards, DeltaBlue, Crypto at the pin
zig build bench-js                # the three scores and their geometric mean, ReleaseFast
```

DESIGN's baseline table carries the numbers, with `tools/bench-small.js`
timed on the host and, as the same text in the `jsrun` drill, on the
target.

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
mode unless a flag says one (`onlyStrict`, `noStrict`, `raw`); a `module`
file is the entry of a graph whose `_FIXTURE` imports come from its own
directory. A file passes when every mode
completes without an exception; a `negative:` file when it fails in the
named phase with the named error type; an `async` file when it prints
`Test262:AsyncTestComplete`. The counts are recorded in DESIGN.md as each
stage lands; proposals beyond ES2023 stay in the count as misses rather
than being filtered out. A runaway test is stopped by the VM's step
budget (a `RangeError` after 20M backward jumps or native-loop steps).
