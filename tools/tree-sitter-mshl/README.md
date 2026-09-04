# tree-sitter-mshl

A [tree-sitter](https://tree-sitter.github.io/) grammar for **mshl**,
the moss shell language (`lib/mshl.zig` is the reference; the grammar
comment at its head is the source of truth for the shape). It gives
editors highlighting and structure for `.msh` files — scripts, unit
files and config alike, since data files are the literal subset of the
same syntax.

- `grammar.js` — the grammar; `src/` is generated from it and committed
  so an editor can build the parser without the tree-sitter CLI.
- `queries/highlights.scm` — the highlight captures.
- `test/corpus/` — parses recorded from the language's own examples;
  `tree-sitter test` checks them.

Regenerate and test after editing the grammar:

```
cd tools/tree-sitter-mshl
tree-sitter generate
tree-sitter test
tree-sitter parse ../../boot/scripts/net-drill.msh   # any script or unit file
```

What the grammar decides, as the interpreter does: a stage that starts
with a bare word is a command with arguments; one that starts with a
variable followed by arguments is a call of a function value; anything
else is an expression. `where` takes an expression. Statements are
separated by newlines or `;`, never merely adjacent. A `.` glued to a
primary is field access even though `.` may begin a word (`cat .hidden`
is a word; `$m.double` is a field). Keys carry their colon
(`name:`), numbers take size units, `?` unwraps a result.
