# tools/

Host-side tooling: boot image packing, the cluster runner behind
`zig build run-cluster` (Phase 11), and `mossctl` (Phase 12). Everything here
is ordinary hosted Zig driven from `build.zig` — except
`tree-sitter-mshl/`, a tree-sitter grammar for the shell language
(editor highlighting and structure; its own README says how to
regenerate and test it).
