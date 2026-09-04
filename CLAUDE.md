# moss — session orientation

Clean-slate capability-based microkernel OS in Zig (0.16.0, pinned via
mise), aarch64 on QEMU virt. Phases 0–11 of ROADMAP.md are complete and
tested; ROADMAP.md's "Open" list (under Phase 12 and beyond) is the
frontier — every unstarted arc and every residual, kept current; the
"Landed" entries below it are the story, not a plan.

## Commands

- `zig build check` — THE gate: 23 OS tests under QEMU, 6 of them again
  under a ReleaseSafe kernel (`+rs` rows), + host unit tests; ~2 min. Run
  before every commit. Failure logs: `zig-out/check/*.log`.
  `-Donly=a,b+rs` for a subset, `-Dsoak=N` to repeat (flaky hunts).
- `zig build test` — host unit tests only (shared ABI, dt parser, rings,
  lib/ lz4+xts+fabcert+mshl+usercred+settings, the full mossfs suite incl.
  crash sweeps).
  `zig test lib/mshl.zig` alone is the fast loop for shell-language work.
- `zig build fmt-test` — mshfmt's tests + `--check` over every `.msh`
  under boot/ (needs the tree-sitter runtime, `brew install tree-sitter`);
  run after touching any .msh or the grammar. `zig build fmt` installs
  `zig-out/bin/mshfmt` to reformat.
- `zig build bench | bench-soft` — host perf baselines (DESIGN.md table).
- `zig build run-shell` — interactive msh console on your terminal.
- `zig build run-login` — multi-user boot: login prompts on your terminal
  and on `nc 127.0.0.1 31905` (alice / alice-pass, bob / bob-pass).
- `zig build run | run-hvf | run-blk | run-net | run-cluster` — manual
  boots (pair with `-D<name>-test` flags; see README test matrix).

## Read before changing things

- ROADMAP.md: locked decisions + invariants (bottom). Change decisions
  there first, deliberately, never silently in code.
- DESIGN.md: per-subsystem "as built" sections + paid-for lessons.
- HACKING.md: how to add syscalls/programs/services/tests; debugging
  recipes; the sharp-edge list (asm→C-ABI only, `asm volatile` for any
  mutable CPU-state read, no logging under any sched/IPC lock, kills land
  at safe points not mid-syscall, nothing touches a domain slot after its
  teardown, sentinel-vs-index bugs, image-list order coupling, idle-context
  starvation, doorbell draining). A hung drill dumps threads, domains,
  notifications and the lock-free trace ring (`kernel/trace.zig`) after
  60s — read that before guessing.

## Habits that fit this repo

- Every phase/feature ends with: all tests green (`zig build check`),
  docs updated (DESIGN "as built" + lesson notes), one well-written
  commit telling the story including bugs found.
- Tests are self-terminating: PASS line + `psci.systemOff()`; panics are
  failures. New tests need build.zig variant + runner.zig Spec + driver.
- Verify empirically in QEMU rather than reasoning from memory — serial
  logs, fault dumps, debugDump(), pcap via filter-dump. QEMU runs use the
  scratchpad for logs when experimenting manually.
- Quota/leak checks (pmem byte-identical, accounts at zero) are part of
  every teardown test — keep that bar.
