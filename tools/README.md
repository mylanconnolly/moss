# tools/

Host-side tooling: boot image packing, the cluster runner behind
`zig build run-cluster` (Phase 11), and `mossctl` (Phase 12). Everything here
is ordinary hosted Zig driven from `build.zig` — except
`tree-sitter-mshl/`, a tree-sitter grammar for the shell language
(editor highlighting and structure; its own README says how to
regenerate and test it), and `mshfmt.zig`, the formatter built on that
grammar's generated parser and the tree-sitter runtime the host provides
(`brew install tree-sitter`, or `-Dtree-sitter=PREFIX`): `zig build fmt`
installs `zig-out/bin/mshfmt`, `zig build fmt-test` runs its tests and
checks every `.msh` under `boot/` is formatted.
