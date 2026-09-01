# Hacking on moss

The practical companion to [ROADMAP.md](ROADMAP.md) (what was decided) and
[DESIGN.md](DESIGN.md) (how it works). This file is about getting things
done without rediscovering the sharp edges.

## Build & run

- Zig is **pinned** (0.16.0, `mise.toml` + `build.zig.zon`). Version bumps
  are deliberate, standalone commits — kernel code touches the parts of the
  language that churn.
- `zig build` produces `zig-out/bin/moss-kernel.bin` (a raw arm64 Image;
  the `.elf` sits beside it for symbols) plus every user program.
- `zig build check` is the gate: 12 OS tests under QEMU plus host unit
  tests, ~45s. Run it before committing. Logs land in `zig-out/check/`.
- Interactive boots: `run` (TCG), `run-hvf` (Apple Silicon acceleration),
  `run-blk` (adds a scratch virtio disk), `run-net` (slirp + a guestfwd
  echo at 10.0.2.100:9000), `run-cluster` (two nodes on a socket segment).

## Adding things

**A syscall**: number + doc in `shared/lib.zig` (`Syscall` enum) → dispatch
arm + implementation in `kernel/syscall.zig` (args in `frame.regs[0..6]`,
results written back to the frame) → wrapper in `user/usys.zig`. Anything
that names a kernel object goes through a capability lookup — no syscall
takes a raw object id.

**A user program**: new file in `user/` with the MOSS header stanza (copy
the `comptime { asm(...) }` block and the `uPanic` handler from any
existing one; entry args are x0=log handle, x1=channel handle, x2=arg,
x3/x4=blob va/len) → add to `user_progs` in `build.zig` **and** to
`shared.ImageId` **and** to the `domain.init` image table in
`kernel/main.zig` — the three lists must stay in the same order.

**A service**: serve one channel; scope per-client state by **badge**
(mint scoped caps with `chanMint`, hand them out in replies). Blocking is
polled (`would_block`) so one loop serves everyone; a bound notification
(`notifyBind`) can interrupt your blocked `recv` — drain it with
`notifyWait` after every `interrupted` or the latched bits will spin you.

**An OS test**: write a driver in `kernel/main.zig` gated on a new
build option; make it log a unique `"<name>-test: PASS ..."` line and then
call `psci.systemOff()` (panic on failure — the harness treats panics as
failures). Add the option to `build.zig` (both the `-D` flag and the
`variants`/`all_test_opts` lists) and a `Spec` to `tools/runner.zig`.

## Debugging techniques that have paid off

- **Read the fault dump.** ESR class is decoded for you; `far` is the bad
  address; `elr` locates the code (`objdump -d zig-out/bin/moss-kernel.elf`
  and search). Most bugs in this repo's history fell to the dump alone.
- `sched.debugDump()` and `irq.debugDump()` print thread states, queues,
  and GIC line state — wire them into a watchdog loop when something hangs.
- QEMU `-d int -D log` traces exceptions; an ESR of `0x...21` is an
  alignment fault, `0x...04`/`0x...46` translation faults.
- For networking, `-object filter-dump,id=d0,netdev=n0,file=x.pcap` gives a
  pcap per NIC; `tcpdump -r` it. This settled in minutes what serial logs
  could not.
- A **failed build leaves the previous kernel in zig-out** — if a QEMU run
  shows stale behavior, check the build actually succeeded.

## Conventions and invariants (the short list)

- Assembly may only call `export`/`callconv(.c)` functions. Zig's
  unspecified convention has hidden parameters in Debug builds.
- All scheduler/IPC state shares the big kernel lock; **never log while
  holding it** (the logger has its own lock).
- Enqueueing a thread kicks the target core (SGI); do long-running work
  from a spawned thread, not from kmain's idle context — idle, once
  displaced by non-yielding threads, does not come back.
- Sentinels must not collide with valid values (sockets and slots start at
  0; use `0xffff...` or an optional).
- Handle-slot conventions for spawn grants are fixed by insert order in
  `domain.spawn`: log→chan→spawner→mmio→irq; user programs hardcode
  the slots they expect (documented per program).
- The three image lists (build.zig, shared.ImageId, kernel image table)
  are order-coupled.
- `shared/` may not import kernel or user code and may not allocate; it is
  the ABI and compiles for every target.
- Kernel W^X, no ambient authority, no kernel channel bypasses — see the
  invariants section of ROADMAP.md before "optimizing" anything.

## Known scoping notes (deliberate, tracked)

- Blocking-op polling and single-outstanding fabric exchanges are v0
  choices; async rings are the upgrade path.
- mossfs v1 is a teaching filesystem; mossfs v2 (checksums, CoW, delete)
  is specified in ROADMAP Phase 12+.
- No PAN (ARMv8.0), no IOMMU yet, no cap transfer across nodes beyond
  spawn-time grants. All recorded in DESIGN.md "as built" sections.
