# tools/

Host-side tooling: boot image packing, the cluster runner behind
`zig build run-cluster` (Phase 11), and `mossctl` (Phase 12). Everything here
is ordinary hosted Zig driven from `build.zig` — except
`tree-sitter-mshl/`, a tree-sitter grammar for the shell language
(editor highlighting and structure; its own README says how to
regenerate and test it), and the tools built on that grammar's
generated parser and the tree-sitter runtime the host provides (`brew
install tree-sitter` on macOS, the distro's `tree-sitter` package on
Linux — the static archive if the prefix has one, else the shared
library — or `-Dtree-sitter=PREFIX`) — `mshtree.zig` (the
parser and its helpers), `mshfmt.zig` (the formatter: `zig build fmt`
installs `zig-out/bin/mshfmt`, `zig build fmt-test` runs its tests and
checks every `.msh` under `boot/` is formatted), `mshlint.zig` (the
lint: `zig build lint`, `zig build lint-test` runs its tests and lints
the tree) and `mshls.zig` (the language server: `zig build ls`,
`zig build ls-test`).

## Editors

`zig build fmt lint ls` installs the three under `zig-out/bin/`. The
grammar gives highlighting; the server gives diagnostics, hover,
go-to-definition, symbols, completion and formatting.

Helix (`~/.config/helix/languages.toml`):

```toml
[language-server.mshls]
command = "/path/to/moss/zig-out/bin/mshls"

[[language]]
name = "msh"
scope = "source.msh"
file-types = ["msh"]
comment-token = "#"
indent = { tab-width = 2, unit = "  " }
language-servers = ["mshls"]
formatter = { command = "/path/to/moss/zig-out/bin/mshfmt", args = ["--stdin"] }

[[grammar]]
name = "msh"
source = { path = "/path/to/moss/tools/tree-sitter-mshl" }
```

then `hx --grammar build` and copy `tools/tree-sitter-mshl/queries/`
to `~/.config/helix/runtime/queries/msh/`.

Neovim (0.10+, in `init.lua`):

```lua
vim.filetype.add({ extension = { msh = "msh" } })
vim.api.nvim_create_autocmd("FileType", {
  pattern = "msh",
  callback = function(ev)
    vim.lsp.start({ name = "mshls", cmd = { "/path/to/moss/zig-out/bin/mshls" },
                    root_dir = vim.fs.root(ev.buf, { "build.zig" }) })
  end,
})
```

with the grammar registered for nvim-treesitter as `msh` pointing at
`tools/tree-sitter-mshl` (its README) and the queries copied under
`queries/msh/`.
