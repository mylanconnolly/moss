# tools/

Host-side tooling: boot image packing, the cluster runner behind
`zig build run-cluster` (Phase 11), and `mossctl` (Phase 12). Everything here
is ordinary hosted Zig driven from `build.zig` — except the Python
validation helper described below and `tree-sitter-mshl/`, a tree-sitter grammar for the shell language
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


## Repeatable validation

Python 3.11+ and the pinned Zig from `mise.toml` are required:

```sh
python3 tools/validate.py host
python3 tools/validate.py smoke --jobs 2
python3 tools/validate.py full --jobs 2
python3 -m unittest discover -s tools -p test_validate.py
```

`host` runs native Debug and ReleaseSafe tests. `smoke` runs AMD64 TCG,
then ARM64 TCG: boot/panic, fault containment, domain accounting, IPC,
PAN/SMAP, DMA refusal, compositor pixels and ReleaseSafe storage.
The interactive gallery stays in the full gates; its TCG editing failure
is tracked in ROADMAP. `full` runs all
83 rows on AMD64 KVM, then all 83 on ARM64 TCG. It requires an AMD Linux
host with readable/writable `/dev/kvm` and nested AMD-V enabled; a QMP
probe verifies acceleration, and `-Drequire-kvm` forbids TCG fallback in
the AMD64 gate itself. Runtime
preflight checks both QEMUs, OpenSSL, and the supported VT-d properties.
The tested QEMU version is 10.2.3; the newer-QEMU compatibility problem in
ROADMAP remains open.

On Linux, loader and firmware defaults are `/usr/share/limine/BOOTX64.EFI`,
`/usr/share/qemu/edk2-x86_64-code.fd` and
`/usr/share/qemu/edk2-i386-vars.fd`; macOS uses `/opt/homebrew/share`.
Override `MOSS_LIMINE` (directory), `MOSS_OVMF` and `MOSS_OVMF_VARS` (files)
when packaging puts them elsewhere. Each is hashed in the result record.

Every run creates `zig-out/validation/<UTC timestamp>-<mode>/result.json`,
with revision, working-tree state, versions, accelerator, firmware hashes,
commands, timings and exit codes. `working-tree.patch` holds tracked edits.
Each architecture gets its own subdirectory of fresh serial logs, diagnostic
dumps, screenshots and packet captures, plus `build.log`; old failed logs and
large disk/ESP images are excluded. A failing phase does not skip the next
phase or turn the final exit code green. Only one helper can run at a time;
raw `zig build check` processes must also be kept sequential.

`.github/workflows/validation.yml` runs the native AMD64 tests on GitHub's
Ubuntu runner for pushes to main, pull requests, manual runs and a weekly
schedule. The runtime job runs TCG smoke followed by both full gates on
trusted main-branch code, retaining artifacts for 14 days. To activate it:

1. Provision a dedicated Linux AMD64 runner with the `self-hosted`, `Linux`,
   `X64`, `moss-amd64` labels. Install Python 3.11+, mise, QEMU with both
   system emulators, OpenSSL, Limine and OVMF; arrange access to `/dev/kvm`
   and enable nested AMD-V. Use the tested QEMU until VT-d compatibility
   work is complete. Set firmware environment overrides if needed.
2. From that runner account, run `python3 tools/validate.py smoke` and
   `python3 tools/validate.py full` successfully. Do not share the machine
   with another gate: file locks do not span independent checkouts.
3. Register the runner with GitHub, set the repository Actions variable
   `MOSS_KVM_RUNNER_ENABLED=true`, then dispatch Validation on main and
   inspect the uploaded `runtime-*` artifact. Runner registration and this
   repository variable are deployment steps, not performed by these files.

The runtime job is serialized and excludes pull-request code. Native checks
run on pull requests; runtime evidence arrives on main after activation.
A green hosted job alone does not establish that either OS port boots.
