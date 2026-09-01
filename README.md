# moss

A clean-slate, capability-based microkernel OS in Zig. Modern 64-bit hardware
only, sandboxed by construction, designed to compose multiple machines into
pooled hardware.

- [ROADMAP.md](ROADMAP.md) — the plan of record: locked decisions, phased
  milestones with exit criteria, and the invariants no phase may break.
- [DESIGN.md](DESIGN.md) — the architecture narrative behind those decisions.

## Requirements

- Zig **0.16.0** (pinned; version bumps are deliberate commits)
- QEMU (`brew install qemu`)

## Commands

| Command | What it does |
|---|---|
| `zig build` | Build the kernel ELF into `zig-out/bin/` |
| `zig build run` | Boot in QEMU `virt` (TCG). **Ctrl-A X** exits QEMU. |
| `zig build run-hvf` | Boot with Hypervisor.framework acceleration (Apple Silicon) |
| `zig build run -Dpanic-test` | Boot, then deliberately panic to exercise the panic handler |
| `zig build run -Dfault-test` | Boot, then read unmapped memory to exercise fault reporting |
| `zig build run -Dsched-test` | Boot, then run pinned + migrating threads across all 4 cores |
| `zig build run -Ddomain-test` | Boot, then spawn/revoke/leak-check user domains (EL0 + caps) |
| `zig build test` | Host-side unit tests of `shared/` |

## Layout

| Path | Contents |
|---|---|
| `kernel/` | The microkernel (aarch64-freestanding) |
| `shared/` | ABI/protocol types — the comptime IDL, compiled identically everywhere |
| `user/` | Userspace: root task, init, services, drivers (from Phase 3) |
| `tools/` | Host-side tooling (image packing, `mossctl`, cluster runner) |
