# The shell and its language

## In one breath

msh is the console you get when moss boots, and it is an ordinary
sandboxed program: it holds a console, one filesystem view, a line to
init, and the right to spawn, and nothing else. Its language, mshl, is
a small pipeline language with one unusual rule: what flows between
commands is **values** — records and tables that came straight out of
typed messages — never text to be split and re-parsed. `ps` is a table,
`stat` is a record, `ls | where size > 4kb | get name` works on columns
and rows, and text appears only at the very end, when a value is drawn
for the person at the keyboard. The same syntax that scripts are
written in is also what unit files, settings, and program manifests are
written in, so one parser reads them all.

## How it works

### One program, six capabilities

msh takes its whole world over its boot channel, the way every unit
does (see [Filesystems and views](filesystem.md) for what a view is):

| Capability | What it is for | Required |
|---|---|---|
| `console` | the byte pipe to the virtio-console driver; the line editor lives on it | yes |
| `view` | a filesystem view — the system root in the system boot, the home in a session | yes |
| `init` | init's front channel: `svc`, `start`, `stop` | yes |
| spawner (a kernel grant) | `ps`/`mem` introspection and `run` | yes |
| `fabric` | `nodes`, `rspawn` | no — a session has none |
| `store` | a read-only view of the system program store: programs to `run`, modules to `use` | no — the system shell finds it in its own view |

Everything the shell does is typed IPC over those: file commands over
the view protocol, service control over init's protocol, `ps` and `mem`
over the kernel's introspection syscalls. There is no text protocol
anywhere below the prompt.

### Values, not text

```mermaid
flowchart LR
  IPC["typed reply\n(FsResp, DomainRec, InitReply …)"] --> HOST["msh, the interpreter's host:\nturns the reply into a value"]
  HOST --> V["value\nnothing · bool · int · float · string · bytes · list · record · table\nfunction · result · handle · shape"]
  V --> VERBS["language verbs\nwhere · sort-by · select · get · first · last · reverse · len · keys · lines"]
  VERBS --> V2["value"]
  V2 -- "end of the pipeline" --> R["render: text, once,\nfor the human"]
  V2 -- "| save path  or  > path" --> F["file (rendered text)"]
  V2 -- "| to-data" --> D["data literal — the same syntax\nas unit files and manifests"]
```

A command in a pipeline receives the previous stage's value as its
input and produces a value. `ls` yields a table with columns `name`,
`type`, `size`, `mtime` (one `stat` per entry through the view);
`stat` a record with the same fields; `df` a record (`free_kb`,
`total_kb`, `encrypted`); `mem` a record (`free_mb`, `total_mb`,
`cores`, `uptime_s`); `ps` a table (`id`, `name`, `state`, `threads`,
`kobj_kb`, `kobj_max`, `user_kb`, `user_max`) built from the kernel's
own ledger records; `svc` a table (`id`, `name`, `state`, `restarts`,
`max`); `nodes` a table (`id`, `state`, `free_mb`); `cat` and `open` a
string; `tree` a drawn string; `write`, `mkdir`, `rm`, `mv`, `ln`,
`sync`, `install` and `source` nothing. Inside `where`, a bare word that
names a column of the current row *is* that column; everywhere else a
bare word is a string, so `hi.txt` and `10.77.0.1` stay whole.

**What the world decides is a result.** A command whose outcome is up
to a service — a file that may not be there, a view that may be
read-only, a program that may not be in the store, a peer that may
close — answers `ok v` or `err word`, never a failed line: `ls`,
`cat`, `stat`, `write`, `mkdir`, `rm`, `mv`, `ln`, `readlink`, `sync`,
`source`, `run`, `install`, `start`, `stop`, `share`, `accept`,
`unshare`, `rspawn`, `remote` and every network command. The err is a
*word* from the protocol's own enumeration (`not_found`, `denied`,
`exists`, `bad_path`, `refused`, `closed`, `no_peer` …), so a script
matches on it. A `?` after the stage unwraps the ok (`ls data? | get
name`, `(stat p)?.size`), `match` takes it apart (`match (cat p) { ok
$t => …; err not_found => …; err $e => … }`), and at the prompt an
`ok` renders as what it holds — `ls` on the screen is still a table —
while an `err` says so. Misuse, by contrast, is a typed error that
stops the line before the call: every host command carries a
*signature*, and `stat 1` is "stat: path is 1, not string". What no
service can refuse — `ps`, `mem`, `df`, `tree`, `now` — is a plain
value.

The rendering is the last step and the only one that makes text. A
value saved with `save` (or `> path`, which is sugar for `| save path`)
is that rendered text; a value passed through `to-data` first is a
*data literal*, the strict subset of the language that `from-data`,
init's unit-file loader, the settings library and the store's manifest
reader all parse with one entry point that accepts literals and nothing
else — no commands, no variables.

### The language

```
let n = (ls data? | len)
if $n == 1 { echo "one file" } else { echo many }
for f in (ls data? | get name) { echo "file: $f" }
def twice [x] { $x * 2 }; twice 21
ls data? | where size > 4kb | sort-by name --desc | select name size
ls data? | filter { $it.size > 0 } | map { $it.name }
[1, 2, 3, 4] | reduce 0 { $acc + $it }
let inc = fn [x] { $x + 1 }; $inc 41
match (int $text) { ok $n => $n * 2; err $e => echo "not a number: $e" }
def total { $in | map { (int $it)? } | reduce 0 { $acc + $it } }
let math = (use math); [1, 2, 3] | $math.sum
let e: { name: string, size: int } = (stat data/x)?
def size-of [p: string] -> int { (stat $p)?.size }
match (stat $p)?.type: dir | file | symlink { dir => "d"; file => "f"; symlink => "l" }
```

Statements are separated by `;` or newlines. A pipeline is stages
joined by `|`; a stage is a command name with arguments, a function
value with arguments (`$inc 41`, `$math.double 21`), a function value
alone with the pipeline's input (`[1, 2] | $math.sum` calls it; `$f` by
itself is the value), or an expression.
Arguments and expressions may be words, `"strings"` (which interpolate
`$var`), `$vars`, `(sub | pipelines)`, `[lists]`, records
`{ key: value, … }` (a `{` followed by `word:` is a record, otherwise a
block), and blocks. Numbers take size units — `4kb`, `8mb`, `1gb`,
case-insensitive. Operators: `== != < <= > >=`, `+ - * / %`, `not`,
`and`, `or`; `.field` and `.index` reach into records and lists.
`source path` runs a script in the session, rendering every top-level
statement's value as it goes, the way the prompt does.

**Types are strong, not static.** Every value is one of nothing, bool,
int, float, string, bytes, list, record, table, function, result,
handle, shape, and nothing coerces: `if 1 { }` is the error "if:
condition is a int, not a bool", `1 == "1"` is "cannot compare a int
with a string", and `1 + "a"` is refused. Only `null` compares with
anything (absence is a fair question). Conversions are commands with
typed answers: `str v` renders a value, `int text` gives a *result*
(`ok 42` or `err …`), and `type v` names the type. Strings are UTF-8
by construction — a literal that is not valid UTF-8 is a syntax error
— with `len` in code points; `to-bytes` makes bytes of one,
`from-bytes` gives an `ok` string or an `err` when the bytes are not
UTF-8, and `+` joins bytes with bytes.

**Two kinds of number.** An int is 64 bits and wraps; a float is
written with a fraction or an exponent (`1.5`, `2e3`, `0.25kb`) and
is a double. They never mix on their own: `1 + 1.5` is "cannot add a
int and a float", and `2 * 1.5` is refused the same way — `float v`
(always `ok` for an int, a result for text) and `int v` (truncation
toward zero, `err` when a float is out of range) convert, `round`,
`floor` and `ceil` take a float to a float. A float always shows its
fraction (`3.0`, never `3`) so it reads back as what it is, and the
very large and small use exponent form; `nan` and `inf` cannot be
written and are not data. Floats travel through data files and JSON as
floats (`to-json` writes `2.0`, `from-json` reads `1e3` as a float).

**Shapes.** A shape says what a value must look like, and is optional
everywhere: written after a name in a `let` (`let e: { name: string,
size: int } = …`), after a parameter (`def f [n: int, p]`), after `->`
for what a function returns (`def f [p: string] -> ok int | err
string`), or after a `match` subject. The forms are the type names
(`any`, `nothing`, `bool`, `int`, `float`, `string`, `bytes`, `list`,
`record`, `table`, `function`, `result`, `shape`, `handle`, `handle
socket`), a bare or quoted word for exactly that string (`dir | file |
symlink` is an enumeration), `[S]` for a list — or a table — of `S`,
`{ key: S, … }` for a record with at least those fields (open: more
are fine), `ok S` and `err S` for a result's sides, `S | S` for any of
them, and `$Name` for a shape bound in scope. Shapes are structural:
any record with a `name` and a `size` of the right types fits `{ name:
string, size: int }`, whatever else it carries. A shape is checked
where it runs, not before — there is no static checker — and a value
that does not fit is a typed error saying what and where: "let: e.size
is x, not int", "size-of: p is 3, not string", "f: return is 1, not
string". `match v: S { … }` checks the subject against `S` and then
checks the arms *cover* it before any arm is tried, so `match $t: dir
| file | symlink { dir => …; file => … }` is "match: the arms do not
cover symlink" whatever `$t` is — an enumeration written as words is
matched exhaustively, `bool` needs both literals, `ok S | err T` needs
both sides covered, a record shape is covered field by field
(`{ a: dir, b: true }` and `{ a: file }` do not cover `{ a: dir |
file, b: bool }`, because `{ a: dir, b: false }` is not matched). A
shape is also a value: `shape { name: string }` makes one (one term;
write `shape (a | b)` for a union), `let S = shape [int]` names it,
`type $S` is `shape`, and `x | check $S` answers `ok x` or `err "it.size
is x, not int"` — the check at a boundary, for a value read from a
file or a message. Every host command declares its arguments, input
and answer as shapes, derived in the host from the same protocol types
its values are built from: `signature stat` is a record of them (`(signature
stat).returns` is `ok { name: string, type: file | dir | symlink, size:
int, mtime: int } | err (denied | not_found | …)`), the interpreter
checks the arguments before the call and the answer after it, and a
host that answers something other than what it declared is blamed by
name ("the host's slip, not yours"). The builtins have signatures too
(`signature first` is `first [count?: int] (input: list) -> list`),
checked the same way, and an editor's hover shows them.

**Functions are values.** `def name [params] { body }` binds one to a
name; `fn [params] { body }` makes one anywhere. Inside, `$in` is the
pipeline input and the parameters bind for the call; a `let` in the
body is local to the call. A block written as a *command argument* is
a function of `$it` (and `$acc`, for `reduce`), which is what the
higher-order verbs take: `map`, `filter`, `reduce init`, `any`, `all`,
`find` — on lists, or on tables row by row. A function is a closure: it
carries a snapshot of the locals of the function that made it (an
`adder [n]` returning `fn [x] { $x + $n }` remembers its `n`), and it
reads the *scope* it was defined in — the session's, or a module's —
by name when it runs, so functions call each other, and themselves, by
name (`fact` calls `fact`), and see a scope's names as they are at call
time.

**Failure is a value.** `ok v` and `err e` make results. `?` after an
expression or a stage unwraps an `ok` and returns the `err` from the
enclosing function — at the prompt, where there is nothing to return
to, it is the error "unhandled err …". `try { … }` (or `try (expr)`)
turns a command that *fails* into an `err` carrying its message and a
value into an `ok`; a result passes through it unchanged. `match`
takes a result apart:

```
match (cat $path) {
  ok $text if ($text | len) > 0 => $text | lines | first 1
  ok _                          => "empty"
  err not_found                 => "no such file"
  err $e                        => echo "cannot read: $e"
}
```

**Match.** `match value { pattern [if guard] => body … }` tries the
arms in order; a body is a block or one statement on the same line. Patterns are
`_` (anything), `$name` (anything, bound), literals (`1`, `"text"`, a
bare word as a string — `dir`, `file` — `true`, `false`, `null`),
`ok p` and `err p`, lists `[p, p]`, `[$head, ..$tail]`, `[1, ..]`, and
records `{ name: $n, size: 0 }` or `{ name }` (which binds `$name`);
a record pattern matches a record that has at least those fields.
Bindings are local inside a function and session variables at the
prompt, like `for`'s. A `match` must be exhaustive, and that is checked
when it is parsed, not when the missing case arrives: a catch-all arm
(`_` or `$x`, unguarded), both `ok _` and `err _`, or both `true` and
`false` — a list or record pattern never counts as covering, so
`match $l { [] => …; [$h, ..$t] => … }` needs a `_ =>` too.

**Handles.** A capability the host holds for the program — a socket, a
listener — is a value of its own kind (`type $s` is `socket`), counted
like a function: bind it, put it in a record, capture it in a closure,
and it lives; drop the last of those and the host is told to release
it (a socket is closed). A handle made and not bound is released when
the statement ends. Handles are not data (`to-data` refuses them).

**Modules.** `use path` reads a file through the view, evaluates it in
a scope of its own, and returns its bindings as a record: `let m = (use
data/m.msh)`, then `$m.double 21`, `$m.version`, `[1, 2] | map
$m.double`. `use name` — a bare name, no `/` and no `.msh` — reads a
module from the program store instead: the shell's own store first,
then the system's, where the archive's library (`lib/msh/` in the
tree, `lib/` in the archive; host-tested with the interpreter) is
installed at boot as content-addressed sources with a manifest each
(see [the store](filesystem.md#programs-are-files-in-a-store)), so
`let math = (use math); [1, 2, 3] | $math.sum` works in any session and
in a script `mshrun` runs, and `install math` copies the module into a
home's own store like a program. The module's functions find each
other in the module's scope, never in the session's, and the scope
lives as long as any of them does. There is no global namespace: a
module reaches another only by `use`.

### The interpreter's memory

```mermaid
flowchart TB
  subgraph msh["msh's own memory (static, inside its 8 MB budget)"]
    L["per-line arena — 2 MB\nreset before every line:\nparse tree, temporaries, locals of every call,\nthis line's values, rendered output"]
    P["box pool — 1 MB, 256-byte chunks, freed and reused\none BOX per binding at the prompt or in a module:\nits own arena holding a deep copy of the value\n(or a closure: tree, captured locals, its scope)"]
  end
  LINE["a line from the editor"] --> L
  L -- "let x = [..]  copies into a new box" --> P
  L -- "let y = $x  shares x's box (count 2)" --> P
  L -- "def f … a closure box" --> P
  P -- "$x, f … read in place" --> L
  P -- "rebinding drops the old box:\ncount 0 → freed when the statement ends" --> L
```

Calls allocate nothing lasting, and not much that is temporary: a
call's frame (its parameters, captures and locals) comes from a pool
the line keeps, returned when the call returns, so ten thousand `map`
calls reuse one frame and a recursion fifty deep costs fifty — the
first version made a frame per call and ran a 64 KB `join` out of its
arena. Values are immutable, so memory is a matter of counting who
holds what. Everything a line makes lives in its arena and is gone when the
next line starts. What must outlive the line — a variable bound at the
prompt, a function, a module's bindings — is a *box*: a small arena of
its own with a reference count. `let` deep-copies the value into a
fresh box (a scalar — nothing, a bool, an int — needs no box and lives
in the binding itself), `let y = $x` shares x's box instead of copying,
a record holding a function keeps the function's box alive, and
rebinding or unbinding a name drops a reference. A box at zero is
freed when the top-level statement ends — not the instant it hits
zero, because `for v in $l { let l = … }` is still walking the old
list — and a box freed drops everything it held. The count is exact:
the host tests run every test under Zig's leak-detecting allocator and
the interpreter's `deinit` must give every byte back. Calls allocate
nothing lasting: a function's parameters, captures and locals are a
frame in the line arena.

Scopes — the session's, and one per `use` — are where names live, and
they hold the one cycle in the whole graph: a function points at the
scope it was defined in (that is how it calls its siblings by name),
and the scope's slots hold the function. The interpreter knows this
cycle and collects it deliberately: a scope nobody holds (the session
until `exit`; a module once `use` has returned) whose functions are
referenced only from its own slots is garbage, checked at the end of
every statement; there is no other tracing anywhere. A closure made
inside a function copies the locals it names *at that moment* — a
snapshot — never a pointer to a frame, so frames stay in the arena and
closures never form a cycle among themselves.

### Running a program

`run NAME [path]` looks the program up in the shell's own store and
then the system store (the lookup and what a manifest is are on the
[filesystem page](filesystem.md#programs-are-files-in-a-store)), stages
the image, verifies it against its digest, and spawns it in a fresh
domain under a small budget. The tool then takes its world over a boot
channel, exactly as a unit does from init:

```mermaid
sequenceDiagram
  participant U as you
  participant M as msh
  participant K as kernel
  participant T as the program (a new domain)
  U->>M: run ls data/smoke
  M->>M: find ls.msh, read the image into the stage, verify the digest
  M->>K: spawn(stage, manifest grants, side A of a fresh channel)
  M->>T: cap console — the console channel
  M->>T: cap console_buf — the console's byte buffer
  M->>T: cap out — an 8-page result buffer
  M->>T: cap view — a read-only view of data/smoke (the manifest said fs: arg)
  M->>T: arg "data/smoke" (24 bytes of text)
  M->>T: go
  T->>T: does its work, writes its result into out as a data literal
  T-->>K: exit
  M->>K: domain_stat until dead
  M->>M: parse out, the value flows into the pipeline
  M-->>U: … | get name → hi.txt
```

The console is the program's until it exits; a program that was given
no `out` (run some other way) renders text for a human instead. A
non-zero exit is reported as a line; a missing program, an unreadable
image or a digest mismatch is an `err` (`not_found`, `unreadable`,
`bad_digest`) and nothing is spawned — `run` answers a result, the
program's value its `ok`, so `run ps? | where …`. `install NAME` copies
a program (or a module) from the system store into the shell's own
store, blob verified on the way. A manifest may carry `arg` (the
program's role, as in a unit file), grant `bootfs` besides
`introspect`, and ask for the system store with `{ tag: store }` in its
`give` list (`mshrun`'s does, so a script's `use name` finds the
library); a run tool gets 1 MB of kernel-object and 8 MB of user
memory. `run apply` makes the volume match `conf/system.msh` (see
[Users and sessions](users.md)) and returns what it did as a table.

### Scripts as programs

A script is a program when `mshrun` runs it. The image takes one view
and an argument — the script's path in that view — evaluates the script
with the shared file commands (`ls`, `tree`, `cat`, `open`, `write`,
`save`, `stat`, `mkdir`, `rm`, `mv`, `ln`, `readlink`, `sync`, `df`,
`source`, `module` — and so `use`) as its whole host, and has exactly
the authority its manifest or unit file gives it: no console, no
spawner, no fabric unless given. Three ways to run one:

- **From the shell**: `run mshrun data/s.msh`. The archive's manifest
  for `mshrun` gives it the shell's whole filesystem as a writable view
  (`fs: ""`), the system store (`{ tag: store }`, for `use name`), the
  console, and an `out` buffer; the script's *last*
  statement's value comes back as the command's value (`run mshrun
  data/report.msh | where size > 1kb`), and nothing is rendered on the
  way — a program run by msh returns a value, like `ls` and `ps`. A
  failing script exits 1 with its error on the console, which `run`
  reports as an exit code.
- **As a unit**: a unit file naming the image and the script —
  `{ image: mshrun, script: scripts/hello.msh, give: [ { tag: view, fs:
  boot, ro: true } ], oneshot: true, profiles: [system] }` — runs it at
  boot with the view the unit gives; every statement's value is
  rendered to the log, one `mshrun: …` line each, and an error is a
  non-zero exit (which, for a `oneshot` step, takes the boot down: a
  script can be a drill step). The archive's `script-hello` unit is
  that example: it counts the unit files and logs the count.
- **Anywhere a manifest goes**: the manifest decides the view and the
  grants, so a copy in a user's store with a narrower `fs:` is a script
  that sees one directory, and `install mshrun` puts the runner in a
  home's store.

In a user session the shell also holds a badged channel to the session
manager, and five commands use it: `share PATH NAME USER [rw]` derives
a view of a path in the home and offers it; `shares` lists offers made
to and by this user as a table (with each offer's `path` and `rw`);
`accept NAME` takes an offer and mounts it as `@NAME`, so `ls @NAME`,
`cat @NAME/file` and the rest work on it; `unshare NAME` withdraws an
offer at the source; `passwd OLD NEW` changes this user's passphrase.
A path beginning with `@` names a mount; `mv` refuses to cross between a
mount and the home. An offer **stands**: the manager remembers it and
re-offers it every time the owner logs in, until `unshare`; the taker
accepts once per session of theirs.

### Startup, the prompt, and the editor

```mermaid
flowchart TD
  A["boot channel: console, view, init, [fabric], [store]; spawner from the manifest"] --> B["console: create a 1-page byte buffer, hand it to the driver (setup)"]
  B --> C["stage (512 KB) and result buffer (8 pages) for run"]
  C --> D["attach a buffer to the view; derive img/ as the own store; attach the system store if given"]
  D --> E["banner"]
  E --> F{"conf/msh/startup.msh in the view?"}
  F -- yes --> G["run it as a script"]
  F -- no --> H{"boot/conf/msh/startup.msh?"}
  H -- yes --> G
  H -- no --> I["no startup script"]
  G --> J["REPL: read a line, reset the line arena, run, render"]
  I --> J
  J --> J
```

The startup script runs in the same interpreter, so its variables and
functions belong to the session. The archive's default prints the
message of the day and defines `alive` as `ps | where state == alive`.
An admin's `conf/msh/startup.msh` on the volume replaces it; in a
session, the home's own `conf/msh/startup.msh` is the only candidate
(a home has no `boot/`), so a session starts silent unless the user
writes one.

The line editor owns the console between commands: a 512-character
line, 16 lines of history (up/down), cursor keys, home/end/delete,
ctrl-a and ctrl-e (start and end of line), ctrl-k (kill to end), ctrl-u
(kill the line), ctrl-l (clear the screen, like the `clear` command),
ctrl-c (abandon the line, echoed as `^C`), and tab completion: command
and language names in command position, otherwise paths — the prefix's
directory listed through the view, directories marked with `/`. Errors
print as `error: <message>`; `exit` prints `bye` and ends the shell,
which in the system boot ends the system (msh is the essential unit)
and in a session ends the session.

### Tooling for the language

`tools/tree-sitter-mshl/` is a [tree-sitter](https://tree-sitter.github.io/)
grammar for mshl: highlighting and structure for `.msh` files in any
editor that speaks tree-sitter, one grammar for scripts and data files
alike (data is the literal subset). It makes the same decisions the
interpreter makes — a bare word at the head of a stage is a command,
a variable with arguments is a call, `where` takes an expression, a
glued `.` is field access, a `name:` before a shape keeps its colon as
one token like a key — and its corpus tests are parses recorded from
this page's examples and the drills' scripts; every `.msh` file in the
repository parses without an error node.

`mshfmt` is the formatter, built on that grammar's generated parser and
the tree-sitter runtime (`zig build fmt` installs it to
`zig-out/bin/mshfmt`; it needs the runtime on the host, `brew install
tree-sitter`, or `-Dtree-sitter=PREFIX`). It keeps what the author
decided — line breaks, blank lines (at most one), comments where they
were, the insides of strings — and normalizes the rest: one space
between tokens, none inside `()` and `[]`, spaces inside `{ }`, `key:
value`, spaced operators and pipes, indentation two spaces per level,
no trailing whitespace. In a record written one field per line, the
values of neighbouring one-line fields line up (`image:     shell`
under `essential: true`); a field spanning lines, a blank line or a
comment ends the run, and fields sharing a line never align. A file
that does not parse is left alone and reported.

```
mshfmt FILE...          # rewrite in place
mshfmt --check FILE...  # exit 1 naming any file that would change
mshfmt --stdin          # standard input to standard output (editors)
```

`zig build fmt-test` runs its tests and `--check` over every `.msh`
under `boot/`: the tree is always formatted, and formatting is checked
to be idempotent and to parse to the same tree as the original.

`mshlint` (`zig build lint`; `mshlint FILE...` or `mshlint --stdin
[NAME]`) says before a line runs what the interpreter would only say
then, as `path:line:col: message` with exit status 1 if there was
anything:

- **syntax** — a file that does not parse, and where.
- **unbound** — `$x` with no `let x`, parameter, `for x`, pattern or
  implicit name (`$it`, `$in`, `$acc`, `$req`) in any enclosing scope;
  and `$x` used before its `let` in the same scope. A function body is
  a scope; a block under `if`, `for`, `while`, `try` or an arm binds in
  the scope around it, as it does when it runs. Order does not matter
  across scopes (`def f { $x }` may run after `let x`), so a name bound
  anywhere in an enclosing scope counts.
- **unused** — a `let` inside a function that nothing reads. Not at a
  file's top level: those are a module's exports.
- **match** — not exhaustive, by the interpreter's rule (a catch-all
  arm, or `ok _` and `err _`, or `true` and `false`; a guarded arm
  never counts) — not when the subject carries a shape, which the
  interpreter checks the arms against where the match runs — and an
  arm after a catch-all, which cannot match.
- **record** — the same key twice in one literal.
- **def** — a `def` that shadows a builtin command.
- **unit** — under `conf/units/` and `conf/session/`, a top-level key
  the unit loader does not read (it ignores unknown keys, so `imgae:`
  is a unit that never starts).

`zig build lint-test` runs its tests and the lint over every `.msh`
under `boot/`, which must be clean.

`mshls` (`zig build ls`) is the language server, over stdio: the lint's
diagnostics as you type (errors are what would fail when the line runs,
warnings what runs but probably not as meant), hover on a `$name` or a
command's name (the `let` line, a `def`'s header, what an implicit name
like `$it` is, a builtin's signature), go-to-definition to the binding, the file's
`def`s and `let`s as document symbols, completion of the names in scope
and the builtins, and formatting by `mshfmt`. Whole-document sync — a
script is small and re-analysis is cheap. `zig build ls-test` drives it
message by message. Editor setup is in `tools/README.md`.

### Running it

- `zig build run-shell` boots the system topology with msh on your
  terminal; the kernel log goes to `zig-out/shell-kernel.log`. `exit`
  shuts the machine down.
- `zig build run-login` boots the multi-user profile: a login prompt on
  your terminal and another on a TCP console at `127.0.0.1:31905`
  (`nc` to it); the drill users are `alice` / `alice-pass` and `bob` /
  `bob-pass`, and each gets msh with their home as its whole
  filesystem.
- The `shell` row of the gate drives a real scripted session over a
  socket console — every line of the language above is a step in that
  script, with its expected output asserted — and then `exit` must land
  the leak bar.

## In detail

- **Grants and budget.** The system shell's unit gives `console` (the
  `cons` unit), `view` (the root, rw), `init` (self) and `fabric`
  (`fabsvc`), with `grant: [log, spawner]` and an 8 MB user-memory
  budget; the spawner cap sits in slot 2 of its table. A session's
  template unit gives `console` and `store` from the session's own caps,
  `view` as the home root, and `init` as the session's init.
- **Console.** One 1-page shared buffer, handed to the driver with a
  `setup` message; output goes in 2 KB chunks; reads are blocking calls
  for up to 64 bytes. `\n` in rendered text becomes `\r\n` on the way
  out.
- **Values and verbs.** `where cond` filters rows (bare words are
  columns; `$it` is the row or item); `sort-by col [--desc]`;
  `select cols…`; `get col` (a list of that column); `first n`,
  `last n`, `reverse`, `len`, `keys` (a record's keys), `lines` (a
  string into a list), `echo`, `to-data`, `from-data`; `map f`,
  `filter f`, `reduce init f`, `any f`, `all f`, `find f` (a function
  or a block of `$it`); `range a b`; `join sep`, `split sep`; `str`,
  `int` (a result), `type`; `to-bytes`, `from-bytes` (a result);
  `to-json`, `from-json`; `ok`, `err`; `use path`. The reserved words are `let`, `def`, `fn`, `if`,
  `else`, `for`, `in`, `while`, `match`, `try`, `not`, `and`, `or`,
  `true`, `false`, `null`; `_` and `..` mean something only in a
  pattern. A scope holds up to 128 bindings (variables and functions
  together); modules nest 8 deep.
- **Network commands** (when the unit gives a `net` view; the system
  shell's does not, `mshrun`'s may): `connect ADDR PORT`, `listen PORT`,
  `accept $l`, `send $s DATA`, `recv $s [max]`, `close $s`, `status $s`
  — sockets and listeners are handles, results carry the outcome; and
  HTTP on them: `http-read $s`, `http-write $s RESP`, `serve $l $handler
  [n]`, `fetch URL [opts]`; see [the networking
  page](networking.md#sockets-as-values-the-language-surface).
- **The fabric** (when the unit gives a `fabric` cap: the system
  shell's does, a user session's does not): `x | remote NODE { … }`
  runs the block on another node with `$in` = `x` and returns its
  value; `nodes`, `rspawn`. A function remembers its source text for
  this (`remote NODE $f` ships `$f`'s body; captures do not cross). See
  [the fabric page](fabric.md#remote-stages-a-functions-body-on-another-node).
- **`sleep MS`** waits, rounded up to the kernel's tick (a tenth of a
  second); **`now`** is milliseconds since boot, a clock for measuring
  (the drills time things with it); **`date`** is the wall clock.
- **JSON.** `to-json` writes the data subset (a table as an array of
  objects), `from-json` reads it back (an array of same-shaped objects
  becomes a table); numbers with a fraction or exponent are refused.
- **Commands.** `ls [p]`, `tree [p] [--depth n]` (default depth 8),
  `cat p`, `open p`, `write p text`, `save p`, `stat p`, `mkdir p`,
  `rm p`, `mv a b`, `ln p target` (a symlink), `readlink p` (up to 256
  bytes), `sync`, `df`, `ps`, `mem`, `svc`, `start N`, `stop N` (a
  deliberate stop is remembered and not restarted), `nodes`,
  `rspawn NODE IMAGE` (a record with the node it landed on and the
  answer to a 40+2 RPC), `rand` (16 bytes from the kernel pool as 32
  hex characters; refused while the pool is unseeded), `run`,
  `install`, `source`, `help`, `clear`, `exit`.
- **run.** The stage is a 512 KB buffer (128 pages; it was 256 KB until msh itself outgrew it); the image is read
  through the store's view in 32 KB pieces and verified before anything
  else. The child gets a 512 KB kernel-object and 2 MB user-memory
  budget, `log`, side A of its boot channel, and `introspect` only if
  the manifest grants it. The result buffer is 8 pages; a program's
  value is a NUL-terminated data literal there, a table being a list of
  records. The run argument travels as three words: 24 bytes.
- **Memory.** Per-line arena 2 MB; box pool 1 MB in 256-byte chunks
  (`lib/pool.zig`: first fit for a run of chunks, freed by clearing
  their marks; a box whose value outgrows the pool is "out of memory");
  both static in msh's image. A program's result-building arena
  (`user/result.zig`) is 128 KB.
- **Editor.** Line 512 bytes, history 16, completion up to 32
  candidates of 64 bytes.
- **mshrun.** Reads the script through its view (`open`-style, whole
  file), runs it with a 1 MB arena and a 512 KB box pool, delivers a
  data value (never a function, result or bytes — those are not data)
  through `out` when it has one, else logs or prints the rendering;
  exits 0, or 1 with `mshrun: <path>: <error>`. The script path is the
  24-byte argument text (`script:` in a unit file, the `run` argument
  from the shell).
- **Data files.** `parseData` accepts one literal: numbers with units,
  strings, bare words, `true`/`false`/`null`, lists, records, comments —
  and refuses anything executable. A `.msh` file is a program or data
  depending only on which entry point reads it; `write data/s.msh "let
  n = 7; $n + 1000"` followed by `source data/s.msh` prints 1007, while
  `ls data? | to-data | save data/l.msh` followed by `open data/l.msh?
  | from-data` gives the table back.

## Known limits and bugs

- `save` alone (and `> path`) writes *rendered text*; only a `to-data`
  value round-trips as data.
- A run argument is 24 bytes of text; a longer path cannot be passed —
  a script's path included.
- A script run by `mshrun` prints nothing when it has an `out` (its
  value is its result); a script that wants to talk and return must
  build a value that says both.
- The system store is the only source of programs and modules for
  `install`; the archive's `lib/` (the tree's `lib/msh/`) is the only
  source of the system store's modules.
- At most 8 mounted shares; a mount's buffer stays mapped after the
  share dies or is replaced (the cap is dropped, the page is not).
- A session's shell has no fabric: `nodes` and `rspawn` are errors
  there. `rspawn`'s image argument is a catalog number, not a name.
- 128 bindings per scope; a 512-character line; 16 lines of history;
  one 2 MB arena per line (a very large `open` or `tree` is "out of
  memory", not a crash); a 1 MB pool for everything bound at the prompt.
- Two numbers, int and float, and no tower above them: no big
  integers, no decimals, no rationals. `nan` and `inf` cannot be
  written and are refused as data. No tuples, by decision: a record is
  the grouping.
- A `?` at the prompt has no function to return from and is an error;
  wrap the line in a function or `match` instead.
- A block argument sees only `$it` (and `$acc` in `reduce`); write
  `fn [a, b] { … }` for anything else.
- A handle's release happens at the end of the statement that dropped
  its last reference (the same rule as every box), not the instant of
  the drop.
- Shapes are checked where they run and nowhere earlier: a wrong
  annotation deep in a function is found when that function is called.
  The `shape` keyword takes one term (`shape (a | b)` for a union),
  since a `|` after it would otherwise never be a pipe. A bare word or
  a number as a `match` subject keeps its colon in one token, so
  `match dir: dir | file` is read by the interpreter but not by the
  tools' grammar; put the subject in a variable or parentheses.
  `shape` is a keyword, so a field or column of that name is reached
  with quotes (`get "shape"`). A record shape is checked field by
  field, so a match over two enumerated fields must cover every
  combination or end in `_`.
- Rebinding a list-valued variable inside a loop that walks it keeps
  the old value until the statement ends — deliberate, and memory a
  long loop should not spend; `map`/`reduce` are the shape for that.
- Every command whose outcome the world decides answers a result, so
  an interactive `ls | get name` is "cannot take .name of a result":
  write `ls? | get name`. The words a command may answer are its
  signature's (`(signature cat).returns`); the shell's own words
  (`run`, `install`, the sharing commands) are the shell's, not a
  protocol's.
- A module path (`use data/m.msh`) is relative to the view like any
  file; a module name (`use math`) is looked up in the stores the host
  holds — a script run as a system unit has none unless its unit
  gives a `store` view.
- A module's functions cannot be called by a bare name from the session
  (`$math.double`, never `double`) — by design, there is no global
  namespace.
- The line editor accepts UTF-8 but counts bytes: the cursor keys and
  delete move one byte at a time, so editing inside a multi-byte
  character can split it — the line is then refused as invalid UTF-8,
  not run.
- Strings interpolate `$var` only — no expressions inside strings; no
  globbing; no job control or background commands; the console has one
  client, so a `run` program owns it until it exits.
- The startup script in a session comes only from the home; there is no
  system default there.
- Bare words are strings everywhere but inside `where`; a column name
  used elsewhere is a string, not a lookup.

## Dig deeper

- DESIGN.md — "Developer tooling" (msh as built, msh v2, programs
  return values, the run handshake and the introspection authority).
- ROADMAP.md — "Developer shell and tooling", "msh v2", "Programs as
  files", "Manifests beside images, and a per-user store".
- Tooling — `tools/tree-sitter-mshl/` (`grammar.js`, `queries/`,
  `test/corpus/`; `tree-sitter generate && tree-sitter test`),
  `tools/mshtree.zig` (the parser for the tools), `tools/mshfmt.zig`
  (`zig build fmt`, `fmt-test`), `tools/mshlint.zig` (`zig build lint`,
  `lint-test`), `tools/mshls.zig` (`zig build ls`, `ls-test`).
- Source — `user/shell.zig` (the host: every command, `run`,
  `install`, startup, the REPL), `user/fscmds.zig` (the file commands
  msh and mshrun share), `user/mshrun.zig` (a script as a program),
  `lib/mshl.zig` (the language: grammar
  in the header comment, values, boxes and scopes, closures, `match`,
  results, verbs, `parseData`, `writeData`, `evalScript`; host-tested
  with `zig test lib/mshl.zig`, every test under the leak-checking
  allocator), `lib/pool.zig` (the box pool),
  `user/lineedit.zig`, `user/tty.zig`, `user/result.zig`,
  `boot/conf/msh/startup.msh`, `tools/runner.zig` (`shell_script`: the
  session the gate drives).
