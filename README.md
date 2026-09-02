# moss

A clean-slate, capability-based microkernel OS in Zig — modern 64-bit
hardware only, sandboxed by construction, IPv6-native, and designed from the
first commit to compose multiple machines into pooled hardware.

Every numbered phase of the original roadmap (0–11) is built and covered by
an automated test suite: from boot-to-banner, through user-mode capabilities
and domains, IPC with typed comptime-generated stubs, a userspace init with
supervision, interposition sandboxing, userspace virtio drivers, async
rings, a filesystem with per-process namespace views, dual-stack TCP/IP,
and a multi-node fabric doing cross-VM RPC with node-kill recovery under
per-node cryptographic identities.

## The three documents

- **[ROADMAP.md](ROADMAP.md)** — the plan of record: locked decisions with
  rationale, phased milestones with exit criteria, invariants no change may
  break, and the Phase 12+ pool of future work.
- **[DESIGN.md](DESIGN.md)** — the architecture narrative: how the pieces
  work together, with "as built" sections and the lessons each phase paid
  for.
- **[HACKING.md](HACKING.md)** — the practical guide: building, running,
  debugging, and extending (new syscalls, services, tests).

## Quickstart

Requirements: Zig **0.16.0** (pinned — see `mise.toml`) and QEMU
(`brew install qemu`).

```sh
zig build check      # the whole test suite: 14 OS tests under QEMU + host unit tests (~55s)
zig build run        # boot interactively (TCG; Ctrl-A X exits)
zig build run-hvf    # boot with Hypervisor.framework acceleration (Apple Silicon)
```

## Architecture at a glance

```
        node 1                                node 2
  ┌───────────────────────────────┐    ┌──────────────────┐
  │ apps      services   drivers  │    │                   │
  │ ┌─────┐  ┌────────┐ ┌──────┐  │    │  fabric peer      │
  │ │alice│  │fssvc   │ │blkdrv│  │    │  (remote spawn,   │
  │ │boxed│  │netsvc  │ │      │  │TCP │   proxied         │
  │ └──┬──┘  │fabsvc ─┼─┼──────┼──┼────┼──▶ channels)      │
  │    │caps │init,...│ │ EL0  │  │    │                   │
  │ ┌──▼─────┴────────┴─┴──────┐  │    └──────────────────┘
  │ │ microkernel (EL1): caps, │  │
  │ │ domains, IPC, sched, MMU │  │      Everything above the
  │ └──────────────────────────┘  │      kernel line is an
  └───────────────────────────────┘      ordinary sandboxed
                                         userspace process.
```

The kernel provides exactly: address spaces, threads, domains (the unit of
spawn/quota/teardown), capability tables with generational badged handles,
synchronous channels + notifications, and interrupt/fault delivery as
messages. Everything else — drivers, filesystems, networking, init,
supervision, the multi-node fabric — is userspace reached over channels,
and therefore interposable, sandboxable, and revocable.

## Test matrix

`zig build check` builds one kernel variant per test (in parallel) and
boots each under QEMU with the right machine config; tests self-report a
PASS marker and power off. Individual tests can still be run by hand:

| Test | Proves | Manual invocation |
|---|---|---|
| panic, fault | Panic handler; decoded fault reports | `zig build run -Dpanic-test` / `-Dfault-test` |
| sched | SMP: pinned + migrating threads under load | `zig build run -Dsched-test` |
| domain | Spawn/revoke/leak-check; no ambient authority | `zig build run -Ddomain-test` |
| ipc | Typed RPC, cap grants, fault-as-message, peer death | `zig build run -Dipc-test` |
| init | Userspace root+init: lazy activation, supervised restart, re-wiring | `zig build run -Dinit-test` |
| sandbox | Interposition proxy, nested domains, one-call subtree revocation | `zig build run -Dsandbox-test` |
| flap | Restart budget exhaustion escalates up the supervision tree | `zig build run -Dflap-test` |
| blk | Userspace virtio-blk; sync channels vs async rings, raced | `zig build run-blk -Dblk-test` |
| fs | Namespace views (badged caps) on real storage; persistence | `zig build run-blk -Dfs-test` |
| net | Dual-stack TCP through userspace netsvc; allowlist views | `zig build run-net -Dnet-test` |
| rng | Userspace virtio-rng seeds the kernel CSPRNG via the entropy cap; getrandom fail-closed and policed | `zig build run -Drng-test` |
| fabric | Per-node identities (root-signed certs, signed DH, sealed transport): join, gossip, placement, death, rejoin, imposter refused, spawn authorization, revocation | `zig build run-cluster -Dfabric-test` |
| shell | msh scripted console session: ps/mem/svc + file ops on the encrypted volume | `zig build run-shell` (interactive) |

Host-side unit tests (`zig build test`) cover the shared ABI: handles,
typed message codecs, rings, and the devicetree parser.

## Layout

| Path | Contents |
|---|---|
| `kernel/` | The microkernel (aarch64-freestanding, boots as an arm64 Image; embeds only the boot archive) |
| `shared/` | The ABI/IDL: types that compile identically for kernel, userspace, and host tests |
| `user/` | Userspace: root task, init, services, drivers, demo programs |
| `tools/` | Host-side tooling (`runner.zig` = the `check` harness, `mkmarc.zig` packs the boot archive, `bench.zig`) |
