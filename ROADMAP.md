# Moss Roadmap

A clean-slate, capability-based microkernel OS in Zig. Modern hardware only, no
legacy personalities, sandboxed-by-construction, designed from day one to
compose multiple machines (virtual or physical) into pooled hardware.

This document is the plan of record: locked decisions first, then phased
milestones, each with a concrete exit criterion. Change decisions here before
changing them in code.

---

## Locked decisions

| Area | Decision | Rationale |
|---|---|---|
| First target | aarch64, QEMU `virt` machine (GICv3, generic timer, PSCI, virtio) | Near-native speed via Hypervisor.framework on the M3 Max dev machine; cleanest available platform (no BIOS/PIC/PS2 archaeology). |
| Second target | x86_64 (UEFI/Limine era only) — later, via a HAL boundary kept honest from day one | Debugging tooling and real-hardware reach; legacy avoided by policy. |
| Boot | QEMU direct `-kernel` load initially; UEFI later if/when real hardware matters | Zero bootloader yak-shaving in the loop that runs 10,000 times. |
| Kernel model | Capability-based microkernel. Kernel objects allocated from **per-domain quotas**, referenced only through cap tables. No global namespaces in the kernel, ever. | seL4's safety posture without untyped-retyping ergonomics; Zircon's pragmatism without ambient authority. |
| Handles | Generational: object identity = slot + generation counter. Raw kernel pointers and densely-reused small ints never cross the ABI. | Stale-handle resurrection is both a security bug and a distribution blocker. |
| Domains | Explicit kernel object owning threads, address spaces, cap tables, and **budgets** (user memory, kernel-object memory, CPU share). Domains form a tree; revoking one tears down the subtree. | The jail/sandbox/quota/teardown unit, and the unit a fabric server ships across nodes. |
| IPC semantics | Message passing is the contract; shared memory is a transport optimization. Self-contained messages + explicitly granted buffer caps. Sync call/reply fast path in registers; io_uring-style shared rings for bulk/async. | A channel that crosses the network is just a slower channel — no ABI change for distribution. |
| Failure | First-class everywhere: channel death is observable (peer-closed notification, distinct error on in-flight ops). No protocol may assume a shared clock. | Needed locally (crashes) and precisely what makes protocols network-ready. |
| Interposition | Guaranteed: any cap can be replaced by a proxy the holder cannot distinguish. **No kernel fast path may ever bypass a channel.** | This single invariant is what makes sandboxing, auditing, filtering, and virtualization ~100-line userspace programs. |
| Process creation | Spawn-only, from a blank address space + an explicit cap manifest. No `fork()`. No signals — faults and async events are messages to a supervisor-held cap. | Kills COW-on-fork complexity and ambient inheritance; gives debuggers/supervisors for free. |
| Namespaces | Per-process, Plan 9 style: a process's filesystem *is* the directory caps it was handed; its network *is* the network-service cap it was handed (or a filtered proxy, or nothing). | The empty sandbox is the zero value. |
| Init | Two layers: a tiny, near-finished **root task** (dispenses boot resources, supervises only init) and a replaceable, restartable **init service** with no special kernel status. Init = capability wiring + supervision + lazy start. | Init crashing must not take the resource ledger with it; no PID-1 mystique. |
| Service model | The sandbox manifest **is** the unit file (one typed Zig value: budgets + caps + restart policy). Dependencies are capability wiring, never ordering — no `After=`-style graph; the channel is the synchronization point. **Channel activation** by default: init retains server ends and spawns services on first message. | Boot-ordering bugs become unrepresentable; boot time = time to first useful service; systemd's good ideas without its ambient-authority sprawl. |
| Supervision | OTP-style supervision trees: crash-only services, restart strategies (one-for-one / all-for-one), restart budgets with backoff and escalation. Restart = domain revoke + respawn from manifest; dependents observe channel death and re-wire through init. Supervisors nest with domains. | Domain teardown makes restarts provably leak-free; crash-only means no separate graceful-shutdown protocol to get wrong. |
| Orchestration | A unit file, a sandbox manifest, and a remote-spawn request are the **same artifact**. Node-local init and the multi-node fabric are the same operation at different radii (fabric adds placement + cap proxying). | Cluster orchestration becomes an extension of init, not a k8s-shaped bolt-on. |
| Drivers | Userspace, virtio-first (blk, net, gpu, input). Driver interface = MMIO-mapping caps, IRQ-delivery-as-message, explicit DMA memory grants; IOMMU story designed in, stubbed initially. | Useful in VMs/cloud for ~5% of the effort of real hardware; real NICs/NVMe arrive later through the same interface. |
| SMP | Structural from day one: per-core run queues and per-core kernel state, no global "current thread". A big kernel lock is acceptable early; the *structures* are not allowed to assume one core. | Retrofitting SMP is the classic hobby-OS death. |
| Distribution stance | **No single system image.** Explicit-but-ergonomic distribution: cap delegation across nodes, remote channels, remote spawn — via a userspace fabric service per node. Membership/consensus/discovery live in userspace where they can iterate. | Transparent SSI has failed everywhere it was tried; the network's latency and partial failure must be legible to software. |
| Security posture | W^X unconditional, NX everywhere, separate address spaces per domain, kernel/user page-table hygiene from the start. Side channels: no cross-domain SMT sharing; seL4-style time partitioning as a later opt-in. Documented honestly — caps don't fix microarchitecture. | Cheaper to be born safe. |
| Word size | 64-bit only, permanently. The application/microcontroller divide is MMU vs. MPU, not word size: no-MMU hardware (Pico 2 / RP2350 class) cannot express per-domain address spaces at all, and 32-bit would break load-bearing design elements — the linear direct map doesn't fit in a 32-bit address space (hello highmem/kmap), generational handles lose generation width, and the IPC ABI forks. The 64-bit budget market is already the budget market ($5 RV64 Milk-V Duo, $15 aarch64 Pi Zero 2 W); new 32-bit application-class silicon serves vendor-BSP embedded lines that would never adopt a new OS. MCU-class devices join the pool as **fabric leaf nodes** instead (see Phase 12). | No second OS wearing the same name; no design pressure from hardware the architecture can't serve. |
| Language/toolchain | Zig, version pinned (currently 0.16.0). `build.zig` is the entire build: kernel, userspace, image packing, `zig build run`, `zig build run-cluster`. Comptime Zig types are the IDL — IPC protocols defined once in `shared/`, marshaling/stubs generated at comptime. | No Make, no shell scripts, no separate IDL compiler, ABI type-checked from one source of truth. |

### Non-goals (permanently, unless revisited here)

`fork()`, signals, POSIX in the kernel (a POSIX *personality* may someday exist
as a userspace compat layer), TTY layer, text-blob `/proc`-style interfaces,
32-bit anything, BIOS/legacy-PIC/PS2 support, transparent process migration,
cross-machine shared memory with coherence pretenses, ordering-based service
dependencies (`After=`-style), graceful-shutdown protocols (crash-only instead).

---

## Phase 0 — Toolchain and boot skeleton

Repo scaffolding and the ten-thousand-times loop.

- `build.zig` + `build.zig.zon` pinned to Zig 0.16.0; `aarch64-freestanding` kernel target.
- Layout: `kernel/`, `user/`, `shared/` (comptime IPC/ABI types), `tools/`, `DESIGN.md`.
- Linker script, entry stub, stack setup, BSS clear.
- PL011 UART serial output; kernel logger; panic handler that prints and halts.
- `zig build run` boots QEMU `virt` (HVF-accelerated) with `-kernel`; `zig build test` runs host-side unit tests of freestanding-safe code.

**Exit:** `zig build run` prints a banner over serial and panics cleanly on demand.

## Phase 1 — Kernel foundations

- EL1 exception vectors; synchronous fault reporting with useful register dumps.
- Physical frame allocator from the devicetree memory map (minimal DT parsing).
- MMU on: kernel image mapped W^X, linear direct map of physical memory, user/kernel split.
- Kernel object allocator with quota accounting hooks (enforced when domains exist).
- GICv3 init; generic timer interrupts.

**Exit:** timer ticks are handled and logged; a deliberate bad access produces a readable fault report, not a hang.

## Phase 2 — Threads and scheduling

- Kernel threads, context switch, sleep/wake.
- Per-core run queues and per-core state (structures SMP-honest from the start); big kernel lock for now.
- SMP bring-up via PSCI; `-smp 4` in the run target.
- Preemptive round-robin; CPU budget accounting stubs on the scheduler path.

**Exit:** a multi-core test — threads pinned and migrating across 4 cores — runs clean under load.

## Phase 3 — User mode, capabilities, domains

The security model becomes real here; everything later builds on it.

- User address spaces; syscall entry/exit; user ELF (or flat) loading.
- Cap tables with generational handles; cap derivation/revocation designed so a userspace proxy is a first-class participant (distribution depends on this).
- **Domain** object: owns threads/address spaces/cap tables; enforces user-memory and kernel-object quotas; CPU shares enforced by the scheduler (simple proportional version).
- Spawn-only process creation: blank address space + cap manifest.
- Domain teardown: revoke the domain cap → subtree of threads, memory, caps, in-flight state reclaimed in one operation.

**Exit:** a user process spawns with an explicit cap manifest, runs, syscalls, and is destroyed by one revocation with nothing leaked (verified by quota accounting returning to zero).

## Phase 4 — IPC

- Channels: sync call/reply fast path in registers; typed messages via comptime stubs from `shared/`.
- Notification primitive (lightweight async wakeup).
- Buffer-cap grants for out-of-line data.
- Channel-death notification and distinct in-flight-op errors — in this milestone, not later.
- Fault-as-message: exceptions delivered to a supervisor-held cap.

**Exit:** two user processes RPC through typed stubs; killing one delivers a death notification to the other, which handles it and continues.

## Phase 5 — Root task, init, and userspace runtime

- Root task receives boot caps (memory, device ranges, IRQ caps) from the kernel; stays minimal — it starts and supervises *only* the init service, retaining enough caps to restart it.
- Userspace runtime library: allocator, IPC stubs, spawn helper taking a **sandbox manifest** (typed Zig value: budgets + caps + restart policy).
- Init service v1: service topology compiled into the boot image as a typed constant; capability wiring between services; **channel activation** (init holds server ends, spawns on first message); supervision with one-for-one restarts, restart budgets, and backoff.
- Logging service as the first real service; service handles passed by manifest, discovered by *protocol*, never by global name.
- Crash-only discipline documented in DESIGN.md: services must tolerate being killed at any instant; restart is the recovery path.

**Exit:** init lazily spawns two services on first use from the compiled topology; killing one triggers a supervised restart, and its dependent observes channel death and re-wires through init.

## Phase 6 — Sandboxing demonstrated end-to-end

Proves the invariants before drivers complicate the world.

- Interposition proxy example: a filtered view of a service (e.g., logging service that redacts), indistinguishable to the sandboxed child.
- Audit proxy: full request log of everything a child touches.
- Nested domains: a sandboxed process sub-sandboxes with subset caps and a budget slice; killing the parent kills the subtree.
- Teardown/re-setup benchmarked — setup and teardown must stay one-call cheap.
- Supervision-restart drill: a flapping service exhausts its restart budget, backs off, and escalates to its supervisor instead of spinning.

**Exit:** demo: parent spawns a child with a filtered+audited manifest; child cannot detect or escape the proxy; parent revocation reclaims the whole subtree. This demo and the restart drill become permanent regression tests.

## Phase 7 — Userspace drivers and virtio-blk

- Driver interface: MMIO-mapping caps, IRQ-as-message, explicit DMA grants (IOMMU-shaped API, identity-stubbed under QEMU).
- Virtio transport (virtio-mmio first; PCI ECAM if/when needed).
- virtio-blk driver as an ordinary sandboxed userspace process.

**Exit:** a user process reads and writes disk blocks through the driver over IPC; the driver runs under a manifest like any other process.

## Phase 8 — Async rings

- io_uring-style shared-memory submission/completion rings as a first-class channel transport — same message semantics, no thread-per-request.
- Migrate virtio-blk to rings; measure against the sync path.

**Exit:** ring-based block I/O beats the sync path on a throughput benchmark; both transports pass the same protocol tests.

## Phase 9 — Filesystem service and namespaces

- Read-only boot image filesystem first; a simple writable FS on virtio-blk second.
- Directory caps + per-process namespace trees; `readOnlyView`-style derivations.
- Init's service topology loads from disk (same manifest type as the compiled-in constant).
- The sandbox demo from Phase 6 re-run with real files: child sees only its granted subtree.

**Exit:** processes with disjoint filesystem views prove per-process namespaces on real storage.

## Phase 10 — Networking

- virtio-net driver (userspace, rings).
- Small TCP/IP service (own minimal stack; scope ruthlessly — enough for the fabric protocol and a demo, not an RFC museum).
- Netfilter proxy cap: allowlist-shaped network access as the sandbox idiom.

**Exit:** two processes on one node talk TCP through the net service; a sandboxed child can reach only allowlisted destinations.

## Phase 11 — Multi-node: the fabric

The pooling story stops being theory.

- `zig build run-cluster`: N HVF-accelerated QEMU nodes on a shared virtual network.
- Fabric service v0 per node: membership (static config first), remote channels via cap proxies, wire protocol versioned from day one.
- Remote spawn: ship a sandbox manifest to a peer's fabric server; caps in the manifest re-exported through proxies. Same manifest type init uses — the fabric is init at a larger radius, adding placement and cap proxying.
- Remote supervision: a fabric-spawned service restarts under the remote node's init; the originating node observes death/restart through the proxied channel.
- Failure drill: kill a node mid-RPC; peers observe channel death and recover.

**Exit:** cross-VM typed RPC hello; a *remote sandboxed spawn* runs a child on node B under node A's manifest; node-kill recovery test passes.

## Phase 12 and beyond (unordered)

- x86_64 port (the HAL's honesty test) and UEFI boot for real aarch64 hardware.
- Real IOMMU (SMMU) backing the DMA-grant API.
- Dynamic fabric membership; smarter placement ("any node with 4 free cores").
- Time-partitioning opt-in for side-channel-sensitive domains.
- EL2: Moss as hypervisor, partitioning one box into pool nodes — the pooling story from both directions.
- virtio-gpu/input; developer shell and tooling (`mossctl`: typed-IPC introspection of init, domains, and budgets — no text scraping).
- **MCU leaf-node runtime**: a tiny bare-metal/RTOS runtime for MCU-class devices (Pico 2 / RP2350 and kin) that speaks Moss protocols over serial/USB/network and registers with a node's fabric server, appearing in the pool as typed channels (sensors, actuators) — sandboxed and interposable like any cap, no MMU required. The `shared/` protocol types cross-compile to `thumb-freestanding` unchanged; the device *joins* the OS rather than running it.
- POSIX personality as a userspace layer, if ever warranted.

---

## Invariants (never break, regardless of phase)

1. No ambient authority: a blank process can do nothing; all power arrives via caps in a manifest.
2. No kernel-level global namespaces; discovery is a userspace protocol over caps.
3. No channel bypass: every service interaction is interposable.
4. Message semantics never assume shared memory or a shared clock.
5. Channel death is always observable.
6. Handles are generational; identity never leaks kernel internals.
7. Domain teardown is total and transitive.
8. Per-core kernel structures; nothing may assume a single core.
9. W^X, NX, per-domain address spaces — unconditionally.
10. One `build.zig`; the Zig version stays pinned and bumps are deliberate commits.
