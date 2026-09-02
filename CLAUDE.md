# moss — session orientation

Clean-slate capability-based microkernel OS in Zig (0.16.0, pinned via
mise), aarch64 on QEMU virt. Phases 0–11 of ROADMAP.md are complete and
tested; Phase 12+ items are the open pool.

## Commands

- `zig build check` — THE gate: 14 OS tests under QEMU + host unit tests,
  ~55s. Run before every commit. Failure logs: `zig-out/check/*.log`.
- `zig build test` — host unit tests only (shared ABI, dt parser, rings,
  lib/ lz4+xts+fabcert+mshl, the full mossfs suite incl. crash sweeps).
  `zig test lib/mshl.zig` alone is the fast loop for shell-language work.
- `zig build bench | bench-soft` — host perf baselines (DESIGN.md table).
- `zig build run-shell` — interactive msh console on your terminal.
- `zig build run | run-hvf | run-blk | run-net | run-cluster` — manual
  boots (pair with `-D<name>-test` flags; see README test matrix).

## Read before changing things

- ROADMAP.md: locked decisions + invariants (bottom). Change decisions
  there first, deliberately, never silently in code.
- DESIGN.md: per-subsystem "as built" sections + paid-for lessons.
- HACKING.md: how to add syscalls/programs/services/tests; debugging
  recipes; the sharp-edge list (asm→C-ABI only, no logging under the big
  lock, sentinel-vs-index bugs, image-list order coupling, idle-context
  starvation, doorbell draining).

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
