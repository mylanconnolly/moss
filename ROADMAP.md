# Moss Roadmap

A clean-slate, capability-based microkernel OS in Zig. Modern hardware only, no
legacy personalities, sandboxed-by-construction, designed from day one to
compose multiple machines (virtual or physical) into pooled hardware.

This document is the plan of record: locked decisions first, then phased
milestones, each with a concrete exit criterion. Change decisions here before
changing them in code.

**Status:** phases 0–11 are complete (✅) and covered by `zig build check`;
"Phase 12 and beyond" holds the frontier as one consolidated **Open**
list, followed by the story of what has **Landed** since.

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
| Filesystem hierarchy | Organized by **lifecycle and ownership**, never file type: `boot/` (immutable boot image), `img/` (immutable images, future), `conf/` (admin-written config), `state/<service>/` (private mutable state), `data/` (shared-by-grant payload), `volatile/<service>/` (cleared each boot). The hierarchy is the default view-grant policy: a service gets `state/X` + `volatile/X` rw and `conf/X` ro as separate derived views — isolation by construction, not discipline. No shared /tmp, ever. | FHS's failure modes are lifecycle confusion; capability views make the clean split enforceable for free. |
| Service model | The sandbox manifest **is** the unit file (one typed Zig value: budgets + caps + restart policy). Dependencies are capability wiring, never ordering — no `After=`-style graph; the channel is the synchronization point. **Channel activation** by default: init retains server ends and spawns services on first message. | Boot-ordering bugs become unrepresentable; boot time = time to first useful service; systemd's good ideas without its ambient-authority sprawl. |
| Supervision | OTP-style supervision trees: crash-only services, restart strategies (one-for-one / all-for-one), restart budgets with backoff and escalation. Restart = domain revoke + respawn from manifest; dependents observe channel death and re-wire through init. Supervisors nest with domains. | Domain teardown makes restarts provably leak-free; crash-only means no separate graceful-shutdown protocol to get wrong. |
| Orchestration | A unit file, a sandbox manifest, and a remote-spawn request are the **same artifact**. Node-local init and the multi-node fabric are the same operation at different radii (fabric adds placement + cap proxying). | Cluster orchestration becomes an extension of init, not a k8s-shaped bolt-on. |
| Drivers | Userspace, virtio-first (blk, net, gpu, input). Driver interface = MMIO-mapping caps, IRQ-delivery-as-message, explicit DMA memory grants; IOMMU story designed in, stubbed initially. | Useful in VMs/cloud for ~5% of the effort of real hardware; real NICs/NVMe arrive later through the same interface. |
| SMP | Structural from day one: per-core run queues and per-core kernel state, no global "current thread". A big kernel lock is acceptable early; the *structures* are not allowed to assume one core. (Retired 2026-09-02: per-core run-queue, per-thread and per-object locks; DESIGN "Locking".) | Retrofitting SMP is the classic hobby-OS death. |
| Distribution stance | **No single system image.** Explicit-but-ergonomic distribution: cap delegation across nodes, remote channels, remote spawn — via a userspace fabric service per node. Membership/consensus/discovery live in userspace where they can iterate. | Transparent SSI has failed everywhere it was tried; the network's latency and partial failure must be legible to software. |
| Security posture | W^X unconditional, NX everywhere, separate address spaces per domain, kernel/user page-table hygiene from the start. Side channels: no cross-domain SMT sharing; seL4-style time partitioning as a later opt-in. Documented honestly — caps don't fix microarchitecture. | Cheaper to be born safe. |
| Network addressing | **IPv6-native ABI**: every address in every protocol is 128 bits; IPv4 destinations travel v4-mapped (`::ffff:a.b.c.d`). There is no IPv4-only code path to depend on — the stack speaks both families on the wire (ARP for v4, NDP/ICMPv6 for v6), but the system's idea of an address is IPv6. Filters/allowlists compare full 128-bit addresses. | v4-only ABIs are the next legacy trap; v4-mapped addressing is the proven dual-stack shape and costs nothing. |
| Word size | 64-bit only, permanently. The application/microcontroller divide is MMU vs. MPU, not word size: no-MMU hardware (Pico 2 / RP2350 class) cannot express per-domain address spaces at all, and 32-bit would break load-bearing design elements — the linear direct map doesn't fit in a 32-bit address space (hello highmem/kmap), generational handles lose generation width, and the IPC ABI forks. The 64-bit budget market is already the budget market ($5 RV64 Milk-V Duo, $15 aarch64 Pi Zero 2 W); new 32-bit application-class silicon serves vendor-BSP embedded lines that would never adopt a new OS. MCU-class devices join the pool as **fabric leaf nodes** instead (see Phase 12). | No second OS wearing the same name; no design pressure from hardware the architecture can't serve. |
| Language/toolchain | Zig, version pinned (currently 0.16.0). `build.zig` is the entire build: kernel, userspace, image packing, `zig build run`, `zig build run-cluster`. Comptime Zig types are the IDL — IPC protocols defined once in `shared/`, marshaling/stubs generated at comptime. | No Make, no shell scripts, no separate IDL compiler, ABI type-checked from one source of truth. |
| Users | **A user is a key, a session is a domain tree, a home is a view.** No uid/gid, no passwd/shadow, no setuid/sudo, no groups or ACLs: a user record is an Ed25519 identity with its seed sealed under a passphrase-derived key; the session manager (userspace) unseals it, keeps the key in custody, and spawns the session under the record's budgets with a rw view of `home/<user>` and a settings view — logout is destroying that domain. Sharing is delegating a derived view. Settings are mshl data in two layers (`conf/<svc>.msh`, `home/<user>/conf/<svc>.msh`) merged per program with schema-declared locked keys. Admin authority is holding the caps, never a bit on a process. | Every legacy user mechanism is a number standing in for a capability or a way around not having one; the kernel already provides isolation, budgets and total teardown, so users are composition. |
| Code sharing | **Static linking only — no dynamic loader, ever.** Shared functionality lives in `lib/`: pure, freestanding-safe, host-testable Zig modules (lz4, xts, ...) compiled into each program that imports them. Where key custody matters, a capability *service* holds the secret instead of a library. Code-page dedup, if ever needed, comes from content-addressed images (`img/`), not load-time linking. | Relocation machinery, symbol versioning, and loader attack surface bought nothing at moss's scale; static modules keep every binary analyzable and every ABI a comptime-checked Zig type. |
| Homes across the fabric (decided 2026-09-04) | **One home per user, on the node where it was born; a session elsewhere mounts it — the home's node ships ciphertext, the session's node holds the key — under a lease that makes that session's home service the volume's only server.** Reaching the home is by proof of identity (a signature under the record's public key), never by trust between managers. No fallback home: a login whose home node is unreachable fails and names the node. Performance comes from a local block cache in the home service — exclusive under the lease, so it needs no coherence — and from wider transport frames, not from copying the home. Moving a home to another node is an administrative action, to be built. | A second home that quietly diverges is worse than a refused login; the key belongs where the passphrase was typed; the lease is what makes a cache sound. |
| The language (mshl v3, decided 2026-09-03; stage 1 built the same day) | **One small, regular syntax for programs and data; functional; pattern matching; capabilities as values.** Values are immutable; functions are values with closures over an immutable environment snapshot, recursion by *name* (never a self-pointer), so values form no cycles and memory is **reference counted, exact, deterministic** — no tracing, no pauses, and a capability held by a value drops at the last use, when the service can reclaim it. (As built: the one cycle is a *scope* — its slots hold its functions, its functions point at it to resolve names — and it is collected by a check the interpreter runs on unheld scopes at the end of every statement; values themselves stay acyclic.) Temporaries live in a per-evaluation arena; only what is bound escapes to counted storage; lists, records and tables share structure on update. Errors are values: `Result` (`ok` / `err`) with `?` propagation and `match` that must be exhaustive; `nothing` is absence, never failure; no tuples (a record is the grouping). Modules are files reached through views (`use` evaluates a file to a record of its exports); no global namespace; the standard library ships in the archive. Extensions are two tiers: services over typed channels (drivers, GUIs — a Zig program, a thin mshl binding) and in-process Zig host commands compiled into the runtime (parsing, hashing). No concurrency in the language: parallelism is spawning programs, here or on another node, and passing values and caps through channels. Config files stay the literal subset of the same syntax. **Strongly typed, not statically typed** (decided 2026-09-03): every value carries its type and nothing coerces — conditions take booleans, comparisons take matching types, `Result` and `match` never bend — checked when evaluated and at every boundary (a value read from a file or a message is checked against the shape a program states for it); host commands declare their signatures from the same protocol types the services use, so a pipeline's mistakes are reported as typed errors, never silently wrong; annotations are optional shapes, structural (`{ name: string, size: int }` matches any record with those fields), with enumerations as unions of bare words so `match` can be checked for exhaustiveness where it is evaluated; no mandatory annotations, no static checker. **Strings are UTF-8 by guarantee** (decided 2026-09-03): validated at every boundary, `len` and indexing by code point; binary data is a distinct `bytes` type (socket payloads, images), never a string. Open: floats and a numeric tower. | The shell already thinks in the OS's values; the language must keep the properties the OS gives — no ambient authority, failure in the vocabulary, deterministic release — rather than import a runtime that fights them. Go's discipline about smallness, with the two things it lacks. |

### Non-goals (permanently, unless revisited here)

`fork()`, signals, POSIX in the kernel (a POSIX *personality* may someday exist
as a userspace compat layer), TTY layer, text-blob `/proc`-style interfaces,
32-bit anything, BIOS/legacy-PIC/PS2 support, transparent process migration,
cross-machine shared memory with coherence pretenses, ordering-based service
dependencies (`After=`-style), graceful-shutdown protocols (crash-only instead).

---

## Phase 0 — Toolchain and boot skeleton ✅

Repo scaffolding and the ten-thousand-times loop.

- `build.zig` + `build.zig.zon` pinned to Zig 0.16.0; `aarch64-freestanding` kernel target.
- Layout: `kernel/`, `user/`, `shared/` (comptime IPC/ABI types), `tools/`, `DESIGN.md`.
- Linker script, entry stub, stack setup, BSS clear.
- PL011 UART serial output; kernel logger; panic handler that prints and halts.
- `zig build run` boots QEMU `virt` (HVF-accelerated) with `-kernel`; `zig build test` runs host-side unit tests of freestanding-safe code.

**Exit:** `zig build run` prints a banner over serial and panics cleanly on demand.

## Phase 1 — Kernel foundations ✅

- EL1 exception vectors; synchronous fault reporting with useful register dumps.
- Physical frame allocator from the devicetree memory map (minimal DT parsing).
- MMU on: kernel image mapped W^X, linear direct map of physical memory, user/kernel split.
- Kernel object allocator with quota accounting hooks (enforced when domains exist).
- GICv3 init; generic timer interrupts.

**Exit:** timer ticks are handled and logged; a deliberate bad access produces a readable fault report, not a hang.

## Phase 2 — Threads and scheduling ✅

- Kernel threads, context switch, sleep/wake.
- Per-core run queues and per-core state (structures SMP-honest from the start); big kernel lock at first, split into per-core/per-thread/per-object locks in Phase 12.
- SMP bring-up via PSCI; `-smp 4` in the run target.
- Preemptive round-robin; CPU budget accounting stubs on the scheduler path.

**Exit:** a multi-core test — threads pinned and migrating across 4 cores — runs clean under load.

## Phase 3 — User mode, capabilities, domains ✅

The security model becomes real here; everything later builds on it.

- User address spaces; syscall entry/exit; user ELF (or flat) loading.
- Cap tables with generational handles; cap derivation/revocation designed so a userspace proxy is a first-class participant (distribution depends on this).
- **Domain** object: owns threads/address spaces/cap tables; enforces user-memory and kernel-object quotas; CPU shares enforced by the scheduler (simple proportional version).
- Spawn-only process creation: blank address space + cap manifest.
- Domain teardown: revoke the domain cap → subtree of threads, memory, caps, in-flight state reclaimed in one operation.

**Exit:** a user process spawns with an explicit cap manifest, runs, syscalls, and is destroyed by one revocation with nothing leaked (verified by quota accounting returning to zero).

## Phase 4 — IPC ✅

- Channels: sync call/reply fast path in registers; typed messages via comptime stubs from `shared/`.
- Notification primitive (lightweight async wakeup).
- Buffer-cap grants for out-of-line data.
- Channel-death notification and distinct in-flight-op errors — in this milestone, not later.
- Fault-as-message: exceptions delivered to a supervisor-held cap.

**Exit:** two user processes RPC through typed stubs; killing one delivers a death notification to the other, which handles it and continues.

## Phase 5 — Root task, init, and userspace runtime ✅

- Root task receives boot caps (memory, device ranges, IRQ caps) from the kernel; stays minimal — it starts and supervises *only* the init service, retaining enough caps to restart it.
- Userspace runtime library: allocator, IPC stubs, spawn helper taking a **sandbox manifest** (typed Zig value: budgets + caps + restart policy).
- Init service v1: service topology compiled into the boot image as a typed constant; capability wiring between services; **channel activation** (init holds server ends, spawns on first message); supervision with one-for-one restarts, restart budgets, and backoff.
- Logging service as the first real service; service handles passed by manifest, discovered by *protocol*, never by global name.
- Crash-only discipline documented in DESIGN.md: services must tolerate being killed at any instant; restart is the recovery path.

**Exit:** init lazily spawns two services on first use from the compiled topology; killing one triggers a supervised restart, and its dependent observes channel death and re-wires through init.

## Phase 6 — Sandboxing demonstrated end-to-end ✅

Proves the invariants before drivers complicate the world.

- Interposition proxy example: a filtered view of a service (e.g., logging service that redacts), indistinguishable to the sandboxed child.
- Audit proxy: full request log of everything a child touches.
- Nested domains: a sandboxed process sub-sandboxes with subset caps and a budget slice; killing the parent kills the subtree.
- Teardown/re-setup benchmarked — setup and teardown must stay one-call cheap.
- Supervision-restart drill: a flapping service exhausts its restart budget, backs off, and escalates to its supervisor instead of spinning.

**Exit:** demo: parent spawns a child with a filtered+audited manifest; child cannot detect or escape the proxy; parent revocation reclaims the whole subtree. This demo and the restart drill become permanent regression tests.

## Phase 7 — Userspace drivers and virtio-blk ✅

- Driver interface: MMIO-mapping caps, IRQ-as-message, explicit DMA grants (IOMMU-shaped API, identity-stubbed under QEMU).
- Virtio transport (virtio-mmio first; PCI ECAM if/when needed). *Since 2026-09-02: PCI only — the SMMU sits in front of PCIe, so device caps name PCI endpoints (see Phase 12 "Real IOMMU").*
- virtio-blk driver as an ordinary sandboxed userspace process.

**Exit:** a user process reads and writes disk blocks through the driver over IPC; the driver runs under a manifest like any other process.

## Phase 8 — Async rings ✅

- io_uring-style shared-memory submission/completion rings as a first-class channel transport — same message semantics, no thread-per-request.
- Migrate virtio-blk to rings; measure against the sync path.

**Exit:** ring-based block I/O beats the sync path on a throughput benchmark; both transports pass the same protocol tests.

## Phase 9 — Filesystem service and namespaces ✅

- Read-only boot image filesystem first; a simple writable FS on virtio-blk second.
- Directory caps + per-process namespace trees; `readOnlyView`-style derivations.
- Init's service topology loads from disk (same manifest type as the compiled-in constant).
- The sandbox demo from Phase 6 re-run with real files: child sees only its granted subtree.

**Exit:** processes with disjoint filesystem views prove per-process namespaces on real storage.

## Phase 10 — Networking ✅

- virtio-net driver (userspace, rings).
- Small TCP/IP service (own minimal stack; scope ruthlessly — enough for the fabric protocol and a demo, not an RFC museum).
- Netfilter proxy cap: allowlist-shaped network access as the sandbox idiom.

**Exit:** two processes on one node talk TCP through the net service; a sandboxed child can reach only allowlisted destinations.

## Phase 11 — Multi-node: the fabric ✅

The pooling story stops being theory.

- `zig build run-cluster`: N HVF-accelerated QEMU nodes on a shared virtual network.
- Fabric service v0 per node: membership (static config first), remote channels via cap proxies, wire protocol versioned from day one.
- Remote spawn: ship a sandbox manifest to a peer's fabric server; caps in the manifest re-exported through proxies. Same manifest type init uses — the fabric is init at a larger radius, adding placement and cap proxying.
- Remote supervision: a fabric-spawned service restarts under the remote node's init; the originating node observes death/restart through the proxied channel.
- Failure drill: kill a node mid-RPC; peers observe channel death and recover.

**Exit:** cross-VM typed RPC hello; a *remote sandboxed spawn* runs a child on node B under node A's manifest; node-kill recovery test passes.

## Phase 12 and beyond

Two lists. **Open** is the frontier: every arc not yet started and every
residual the finished work left behind, consolidated here from the
narrative entries and from the "Known limits" sections of `docs/`, and
kept current — an item leaves this list only when it lands or is
retired with a note. **Landed** is the story of what was built, entry
by entry as it happened, with the bugs each piece found; nothing there
is a plan.

### Open

**Arcs**

- **Real aarch64 hardware via UEFI.** The strongest reason is the
  hypervisor: every VM drill runs only under TCG (Apple's Hypervisor
  framework exposes no nested EL2 with VHE), so EL2, stage-2 SMMU and
  device passthrough have never met silicon.
- **The x86_64 port** — the HAL's honesty test. ✅ Stage 1 (landed
  2026-09-04): `kernel/arch/x86_64/` boots to "boot complete" on the
  boot core under KVM — Limine on OVMF, 4-level paging, the TSC, x2APIC
  detected, ACPI power-off. ✅ Stage 2 (landed 2026-09-04): the local
  APIC timer in TSC-deadline mode, the I/O APICs and MSI vectors behind
  `intc`/`msi` from the MADT, every core through the loader's MP
  response, and the gate running the port's drills (`-Darch=x86_64
  check`: panic, fault, sched under KVM). Next, in order: (3)
  `syscall`/`sysret`, the TSS per core, SMAP behind `uaccess`, and the
  userspace seam (`user/usys.zig`, the image header stanza, the
  drivers' barriers) so programs build and run for the target; (4)
  PCIDs and TLB shootdown by IPI; (5) the MCFG behind `platform.pcie`,
  the MSI data word to the enumerator, virtio over PCIe; (6) VT-d or
  AMD-Vi behind `iommu` (the DMA-grant design needs the IOMMU to walk
  the domain's own tables); (7) the rest of the drills and the `+rs`
  pass on the port; SVM behind `vm` last. Modern hardware only: no legacy
  PIC, PIT, or BIOS paths, ever (locked decision); the 16550 is the
  debug console QEMU and a PCIe serial card speak, and the framebuffer
  console for real machines is owed.
- **Users, stage 3, residuals:** sharing offers are per session and in
  memory (standing grants that survive a logout are a later step);
  `apply` only creates and keeps (changing a passphrase or removing a
  user is a manual edit of `conf/users/`); a fabric login copies the
  record and gives the user a home per node — reaching a remote home
  needs a bulk transport across the wire (the view protocol moves data
  through an attached buffer, which does not cross), and records are
  fetched only at login, never refreshed.
- **mshl v3 — the language as a tool for the fabric** (decisions in the
  table above). In order: (1) ✅ the language core on the host (landed
  2026-09-03: closures, counted boxes and scopes, `match`, results and
  `?`, `try`, `use`, strong dynamic typing, UTF-8 strings and `bytes`);
  still open from it: shape annotations and host-command signatures
  from the protocol types (a wrong type is caught at use, not at the
  boundary), host commands returning results instead of failing, a
  module loaded from the store, floats; (2) ✅ scripts as programs
  (landed 2026-09-03: the `mshrun` image, `script:` in unit files, the
  file commands shared through `user/fscmds.zig`); still open: a script
  spawned on another node — `rspawn` takes a catalog number and carries
  no argument text, which the fabric surface (4) brings; (3) the network
  surface — ✅ sockets as capability-carrying values (landed 2026-09-03:
  handles in the language, `connect`/`listen`/`accept`/`send`/`recv`/
  `close`/`status` answering results, `user/netcmds.zig`); ✅ doorbell
  waiting and the netsvc upgrade (landed 2026-09-04: windowed sending
  against the peer's window and MSS, per-connection retransmission
  with backoff, lingering close, 32 sockets / 16 views); ✅ HTTP
  (landed 2026-09-04: `lib/http.zig`, `lib/json.zig`, `http-read`,
  `http-write`, `serve` with handlers as functions, `fetch`, `to-json`
  / `from-json`); still open: keep-alive and chunked transfer, name
  resolution (needs UDP), TLS, concurrent handling (needs the language
  to spawn), and, when a use case demands them, congestion control and
  out-of-order receive; (4)
  the fabric surface — ✅ the bulk transport across the wire and remote
  pipeline stages (landed 2026-09-04: session buffers diffed both ways,
  `fw_bulk`/`fw_bulk_resp`/`fw_release`, wire v6, `remote NODE { … }`
  with `mshrun` as the stage); ✅ one home across the fabric (landed
  2026-09-04: the lease, the identity proof, the remote backing view,
  the wiped-disk drill); ✅ its speed (landed 2026-09-04: a 32 KB
  read-ahead window in the home service, 32 KB per exchange end to
  end, a cold 64 KB read from 55 ms to 4 ms, measured on every gate
  run); still open: moving a home (an administrative action), a
  write-back cache beyond mossfs's own commit batching if a workload
  ever asks, publish and lookup from the language
  (a script serves no channel and a raw channel would be untyped — this
  waits for a typed channel surface), more than one buffer per session,
  notifications across nodes; (5) tooling, host-side in
  tools/: ✅ a tree-sitter grammar (landed 2026-09-04:
  `tools/tree-sitter-mshl`, highlights, a corpus recorded from the
  language's examples, every `.msh` in the tree parsing clean), ✅ a
  formatter on it (landed 2026-09-04: `mshfmt`, `zig build fmt` /
  `fmt-test`, the tree kept formatted), ✅ lint (landed 2026-09-04:
  `mshlint`, unbound/unused names, exhaustiveness, duplicate keys,
  unit keys; `lint-test`), ✅ a language server (landed 2026-09-04:
  `mshls` over stdio — the lint's diagnostics, hover, definition,
  symbols, completion, formatting; `ls-test`). Left for when an editor
  asks: rename, references, incremental sync, semantic tokens beyond
  the tree-sitter highlights. Rule: build the
  primitive, then the syntax around it; a feature that cannot reach a
  capability is a demo.
- **virtio-gpu and input devices** — the graphical console.
- **MCU leaf-node runtime**: a tiny bare-metal/RTOS runtime for MCU-class devices (Pico 2 / RP2350 and kin) that speaks Moss protocols over serial/USB/network and registers with a node's fabric server, appearing in the pool as typed channels (sensors, actuators) — sandboxed and interposable like any cap, no MMU required. The `shared/` protocol types cross-compile to `thumb-freestanding` unchanged; the device *joins* the OS rather than running it.
- POSIX personality as a userspace layer, if ever warranted.

**Kernel**

- Every pool is static and small: 16 domains, 64 threads, 64 channels,
  64 notifications, 64 shared buffers, 256 client badges, 16 devices,
  64 LPIs, 64 window mappings per domain. Shared-buffer pages are
  charged to one global account rather than the creating domain.
- Budgets are caps, not guarantees; a CPU partition keeps other domains'
  code off a core, not the tick or the shared caches.
- Reaping is polled once per tick; event-driven reaping is a cheap win
  if latency ever matters.
- `getrandom` is not interposable (randomness is not authority); a
  domain that must see deterministic randomness is a future manifest
  option, not a proxy.
- `dma_alloc` pages are never freed before the domain dies.
- The hang watchdog (dumps, trace ring) exists only in the system
  drills; the kernel-driven drills rely on the runner's timeout.
- Side channels are not addressed beyond the stated stance.

**IPC**

- Notifications and shared buffers do not cross the fabric (shm by
  design; notifications not yet).
- A call cannot be cancelled except by the caller's death; a server's
  `recv` waits on one channel only (no select — services multiplex
  with bound notifications and worker threads); one waiter per
  notification.
- The async ring transport exists for the block path only.

**Boot and init**

- Unit files carry test key material beside them (`conf/fs.key`,
  `conf/fabric/root.seed`).
- A `run` argument reaches a program only as the path of a view, and
  is 24 bytes of text.
- Restart budgets are per boot and never replenish.
- The session template is the archive's; a home's `conf/units/`
  replaces it wholesale.

**Devices**

- Bus 0 only: no bridges, no 64-bit BARs placed outside the 32-bit
  window.
- One interrupt line per device (`irq_bind` accepts offset 0 only).
- No MULTIPORT virtio-console: more seats mean more devices.
- Legacy and transitional virtio devices are not supported (by design).

**Storage and filesystems**

- Hard links are deferred until the view-exclusivity design answers how
  one file may appear under two views; rename across parent
  directories is refused (no ancestry walk).
- A directory holds at most 512 hash buckets (about 32 K entries); a
  two-level table is the next step.
- Rollback of up to eight transaction groups by zeroing newer
  superblock slots is possible for someone with the disk (no external
  anti-rollback state); MAC tags are 64-bit by format; plaintext
  allocation metadata leaks fill and churn patterns; torn writes are
  detected, not repaired.
- A home volume's 8 MB capacity is reported, not enforced.
- 32 views per filesystem service, 8 open files per view, 8-page view
  buffers (32 KB per operation).
- `save` (and `>`) writes rendered text; `to-data` is the data form.
- Whole-stack throughput headroom, in likely order: the Debug kernel's
  syscall and IPC paths, per-block XTS/MAC call overheads in fssvc's one
  thread, read pipelining beyond one readahead window.

**Networking**

- A minimal stack by design: stop-and-wait with one segment in flight,
  no congestion control, no UDP, no TCP options.
- Blocking is polling plus a doorbell; rings as the wakeup path are not
  built.
- 16 sockets and 8 views per service.
- Unit-file allowlists are IPv4 (`allow:` is parsed with `parseV4`);
  IPv6 filtering is reachable only through `derive` directly.
- Cluster addressing is static: node N is `10.77.0.N`.

**Users and sessions**

- At most 4 sessions open at once and 4 consoles; names up to 16
  bytes; the KDF cost a record may ask for is bounded by the manager's
  static work area.
- The record format carries no version and no expiry.
- A user's own program store is filled only by `install` from the
  system store; there is no other source of programs (no download, no
  build).
- A session's shell has no fabric (`nodes`, `rspawn` are errors).

**Fabric**

- Static addressing (dynamic addressing is a separate concern).
- Certificates carry no expiry: with no shared clock, revocation
  serials are the only clock.
- The multi-node drill's nodes have no disk, so their identity seeds
  are composed by the kernel driver each boot.
- One remote spawn in flight per node; a remote child's budget is
  fixed by the receiving node.
- Small static tables: 6 peers, 8 members, sessions, exports and
  in-flight exchanges.
- ML-DSA is a drop-in for the signatures if post-quantum ever matters.

**Hypervisor**

- TCG only (above).
- The emulated GIC is a register file with no distributor semantics:
  SPIs go to vCPU 0, as a moss guest routes them.
- A passed-through device must use MSI-X; a wired-INTx device would
  need level emulation.
- At most 4 vCPUs and 128 MB per VM, 4 VMs; the UART emulations are
  write-only.

**Shell**

- Interpreter limits: 32 variables and 16 functions per session, a
  512-character line, 16 lines of history; strings interpolate `$var`
  only; no globbing, no job control.

**Testing**

- The gate is serial and binds fixed TCP ports (31901–31905), so two
  cannot run on one machine at once.
- Timing races have no deterministic replay; the soak and the trace
  ring are the tools. `-Dsoak` repeats whole drills, not steps.
- Host unit tests cover the pure libraries and the ABI, not the
  kernel; kernel code is tested only under QEMU.

### Landed (the story, with the bugs each piece found)

- ✅ **x86_64, stage 2: interrupts, every core, the gate** (2026-09-04):
  x2APIC through MSRs, the APIC timer in TSC-deadline mode as the tick,
  I/O APICs and ISA overrides from the MADT behind `intc` (interrupt
  ids are vectors: lines 32 + GSI, messages 128..223), IPIs for
  `kick`, the interrupt path in the trap handler, the loader's parked
  cores brought up one at a time through a CR3-and-stack trampoline;
  `zig build -Darch=x86_64 check` runs panic, fault and sched under KVM
  (17 s). Found: the IDT's stub arithmetic assumed an aligned base the
  label did not have, so every gate pointed into the wrong stub and the
  first interrupt on each core panicked on a garbage vector — and a
  single trace address into a Debug build's panic blocks named the
  wrong function, so the panic handler now prints a frame-pointer
  backtrace on both ports.
- ✅ **x86_64, stage 1: boot to "boot complete"** (2026-09-04):
  `kernel/arch/x86_64/` — Limine base revision 5 on OVMF from a FAT
  directory on virtio-blk, the port's own direct map built in `_start`
  beside the loader's kernel mapping, the memory map and command line
  and RSDP and TSC frequency and CPU list copied out of the loader's
  memory, 4-level tables rebuilt W^X, `rdgsbase` for the per-core
  pointer, the 256-stub IDT with the syscall slot ABI fixed, SysV thread
  contexts, ACPI S5 power-off (verified: QEMU exits). One core, no
  interrupts, no user mode, no user programs built for the target yet.
  Found: a `pub const` copy of Limine's end marker landed in `.rodata`
  before the start marker and emptied the request window (the loader
  takes the last start and the first end marker); Zig's self-hosted
  x86_64 backend cannot build a no-SSE kernel (LLVM does); the kernel
  image is not inside the direct map on this port, so its reservation
  moved from kmain into the ports' `platform.reserved`.
- ✅ **The HAL, extracted** (2026-09-04): `kernel/arch.zig` selects a
  port at comptime and lists what one provides; `kernel/arch/aarch64/`
  holds the boot entry, vectors and frame, page tables, PAN, the GIC and
  ITS (as `intc` and `msi`), the generic timer, PSCI, SMP bring-up, the
  SMMU (`iommu`), the hypervisor, devicetree discovery (`platform`) and
  the PL011, plus three new modules for what had been scattered:
  `cpu.zig` (DAIF, TPIDR, the counter, WFI), `thread.zig` (the context,
  FP state, the switch and trampoline stubs, `eret` to user) and
  `platform.zig`. The generic kernel names slots, roots and lines
  (`frame.arg(i)`, `user_root`, `intc.line_base`) where it named
  registers. Only the selected port is compiled. Behaviour unchanged,
  gate green; `-Darch` in the build. Found on the way: nothing broken —
  the honest finding is that the boundary had existed as a habit, not a
  seam, in eleven files' assembly and three private copies of the
  interrupt-mask helpers.
- ✅ **The gate on a Linux host** (2026-09-04): the first run on an
  x86_64 machine (Framework 16, Gentoo). The runner's socket calls
  went through `std.c`, which macOS links implicitly and Linux does
  not; they are `std.Io.net.Stream` reads and writes now, host-neutral.
  Found on the first full gate: the `net` drill hung in `fetch` — the
  capture showed the handshake done and the canned server's reply and
  FIN in, but the script's request never sent. `connect` (both the
  language's and the HTTP host's) polled `tcp_status` until
  `established` and treated `close_wait` as "keep waiting", so a peer
  that answers and closes before the next poll parked the client on a
  bell no one would ring again; `tcp_accept` had the same hole for a
  backlog head. Both take `close_wait` as connected now. The race hit
  once in 33 runs here, so the fix closes the hole the capture shows
  without a deterministic reproduction.
- ✅ **mshl v3, stage 5d: the language server** (done, 2026-09-04):
  `mshls`, `tools/mshls.zig` — LSP over stdio, whole-document sync,
  built on the lint's `Analysis` (scopes, bindings, every reference
  resolved) and the formatter: diagnostics on open and change (errors
  are what would fail at run time, warnings what runs but probably not
  as meant), hover (the `let` line, a `def`'s header, what `$it`/`$in`/
  `$acc`/`$req` are, "builtin"), definition, document symbols,
  completion (names in scope, then the builtins), formatting as one
  edit. `Server.handle` takes one message and appends replies, so
  `zig build ls-test` drives it without a transport; the binary was
  also driven over a pipe with byte-exact frames. Bugs found: a null
  `result` came out as the string `"null"` (naming a union's void field
  through the type gives its tag, which the stringifier prints as a
  name — coerce to the union), and an optional result was omitted
  where JSON-RPC requires the key (unwrap before stringifying); the
  header reader left the newline in the stream (`takeDelimiterExclusive`
  does not consume it) so the second header read saw an empty line and
  the body started at the wrong byte. Editor setup (Helix, Neovim) in
  tools/README.md.
- ✅ **mshl v3, stage 5c: lint** (done, 2026-09-04): `mshlint`,
  `tools/mshlint.zig`, on the parser now shared as `tools/mshtree.zig`
  — the interpreter's run-time complaints, before: a `$x` bound nowhere
  in scope or used before its `let` (scopes as the interpreter has
  them: a function body is one, blocks under `if`/`for`/`while`/`try`
  and arms bind in the frame around them, names resolve across scopes
  in any order), a `let` in a function nothing reads, a `match` that is
  not exhaustive by the parser's own rule and an arm after a catch-all,
  a key given twice, a `def` shadowing a builtin, and in a unit file a
  key the loader does not read. `zig build lint-test` runs its tests
  and the lint over every `.msh` under `boot/`, which lints clean.
  Found on the first run over the tree: two unit keys the lint's list
  did not have (`after`, `install`) — the list mirrors `parseUnit` and
  HACKING says so — and nothing else, which is what a tree that has
  been through the drills should show.
- ✅ **mshl v3, stage 5b: the formatter** (done, 2026-09-04): `mshfmt`,
  `tools/mshfmt.zig` — the grammar's generated parser and the
  tree-sitter runtime linked into a host program; the tree's leaves in
  source order, the author's line breaks and comments kept, spacing
  and indentation decided by the kinds of neighbouring tokens, and in
  a record written one field per line the values of neighbouring
  one-line fields aligned. `zig build fmt` installs it, `zig build
  fmt-test` runs its tests (idempotence, and the formatted text parsing
  to the same tree) and `--check` over every `.msh` under `boot/`,
  found by walking the tree. The 25 files the rules changed were
  reformatted and the diff read: whitespace only. Lessons: the first
  alignment rule let a field that shared its line with others join a
  run (`run: true,` followed by `give:` on the next line), so a field
  aligns only when it has a line to itself; and the tree's hand
  alignment was itself inconsistent in places, which is the case for a
  formatter.
- ✅ **mshl v3, stage 5a: a tree-sitter grammar** (done, 2026-09-04):
  `tools/tree-sitter-mshl/` — the language's shape as tree-sitter sees
  it (commands vs. calls vs. expressions by the head of the stage,
  `where` with an expression, a glued `.` as field access even though
  `.` may start a word, keys with their colon, patterns), a highlight
  query, and twelve corpus entries recorded from the docs and drills;
  every `.msh` file in the repository parses without an error node.
  Lessons: tree-sitter forbids a syntactic rule that matches the empty
  string, so the statement list is non-empty and blocks hold an optional
  one; and a generator error hidden behind a filter left a stale parser
  that accepted adjacent statements — read the generator's output whole.
- ✅ **Users, stage 4b: the remote home's speed** (done, 2026-09-04): a
  32 KB read-ahead window in the home service's backing layer (sound
  under the lease), 32 KB per exchange through netsvc and the fabric
  (send ring 32 KB, receive 64 KB, 16 sockets, frames to match), `now`
  and `sleep` in the language, call frames pooled per line; the
  fabric-login drill prints write, warm-read and cold-read times: 2, 2
  and 4 ms for 64 KB, from 55 cold. Found: a struct-literal reset of a
  96 KB socket record overflowed the stack (buffers moved beside the
  tables); an empty 64 KB receive buffer advertised 65536 in a 16-bit
  field and the checked cast panicked netsvc silently (capped); the
  language made a frame per call and ran out of arena at ten thousand.
- ✅ **Users, stage 4: one home, wherever you log in** (done,
  2026-09-04): a fabric login leases the user's home from the node that
  holds it — a challenge, a signature under the identity key through
  the lease cap's buffer, a rw view of the ciphertext directory back —
  and spawns the home service locally over that remote backing: the
  key stays with the session, the home's node ships ciphertext, one
  server per home at a time, no fallback home. The drill wipes node 2's
  disk between boots and alice's file is still there. Found: the
  fabric's token-less control replies were delivered to the oldest
  parked caller (a remote stage got a `lookup`'s answer) — every fabric
  reply carries its token now; and eight fabric sessions/exports were
  too few for a node serving stages and homes at once (sixteen).
- ✅ **mshl v3, stage 4a: the bulk transport and remote stages** (done,
  2026-09-04): a shared-memory cap attached to a badged call becomes the
  session's buffer, the peer makes a twin for the exported channel, and
  the two are kept alike by diff frames before every call and after
  every reply (shadows as shared memory, made on attach); a session's
  death releases the export across the wire (channel, twin, a spawned
  child's control cap); wire v6. `x | remote NODE { … }` runs a block on
  another node with `$in` (`mshrun`'s remote-stage role; closures keep
  their source). The fabric-login drill's node 2 runs three stages on
  node 1. Found: the diff scan's off-by-one spun the serve thread until
  the peer dropped the node for silence (peer loss now says why); the
  fabric kept spawned children's control caps, so the second spawn was
  refused — memory accounts nest, and a fabric service pays for its
  children, so it has an explicit budget now (4 MB / 16 MB) and the
  kernel logs why a spawn was refused; `match` arms take any statement;
  init holds 48 units.
- ✅ **mshl v3, stage 3c: HTTP** (done, 2026-09-04): `lib/http.zig` and
  `lib/json.zig` (pure, host-tested), `user/httpcmds.zig` — `http-read`,
  `http-write`, `serve $l $handler [n]` with a handler's return value
  deciding the response (record, text, or data as JSON), `fetch URL
  [opts]` — and `to-json`/`from-json` in the language. The network
  drill's script serves four pages the check fetches through a port
  forward and fetches from a canned host server. Found: `mshrun`
  printed a script's output only at the end (it streams now); netsvc
  had no clock, so with doorbell-sleeping clients a lost SYN was never
  retransmitted (a kernel timer drives the scan now); a closed socket
  freed before the peer's FIN left slirp retransmitting it for a
  minute (it lingers for the peer's FIN, or two seconds). And msh
  itself outgrew the 256 KB loader stage (300 KB of ReleaseSafe code
  with every host in it): the stage is 512 KB now, which took the
  kernel's shared-buffer cap from 64 to 128 pages.
- ✅ **mshl v3, stage 3b: the stack upgraded** (done, 2026-09-04):
  windowed TCP in netsvc — a send ring, the peer's window and MSS
  honored, cumulative ACKs, an advertised receive window, per-connection
  retransmission with exponential backoff, a lingering close that
  delivers queued data and the FIN after the client is gone, 32 sockets
  and 16 views — and doorbell-driven waiting in the language's network
  commands. The drill's script step moves 5000 bytes each way through
  the wire echo and loopback. Bug found: a non-zero default in the
  socket table put 400 KB of it in the image, past the loader's (then 256 KB)
  stage, reported as "image missing"; the table is zero-initialized
  now.
- ✅ **mshl v3, stage 3a: sockets as values** (done, 2026-09-03): the
  handle value kind (a host capability with a drop, counted like a
  closure, released at the last use), `user/netcmds.zig` for any host
  with a network view — every network outcome a result, never a failed
  line — `shared.parseAddr`, `mshrun` reading scripts from the archive
  under `bootfs`, and the network drill's third step: a script doing
  the wire echo and a listen/connect/accept loop over loopback with a
  network view as its only authority.
- ✅ **mshl v3, stage 2: a script is a program** (done, 2026-09-03):
  `mshrun`, an image that runs the script named by its argument through
  the one view it is handed, with the file commands — moved from the
  shell into `user/fscmds.zig` so msh and mshrun share one host — as
  its whole authority. `run mshrun PATH` from the shell returns the
  script's last value (nothing rendered: a program returns a value);
  `script: path` in a unit file makes a script a unit (init passes the
  path as the argument text), its statements rendered to the log and
  its error a non-zero exit, so a drill step can be a script. The
  shell drill runs three scripts (a value, a table, an error) and
  requires the `script-hello` unit's log line.
- ✅ **mshl v3, stage 1: the language core** (done, 2026-09-03):
  functions as values (`fn`, `def`, blocks as functions of `$it`, `$f
  args`), closures over a snapshot of the enclosing call's locals plus
  the defining scope read by name at call time; `map`/`filter`/`reduce`
  /`any`/`all`/`find`; strong dynamic typing (conditions take bools,
  comparisons take one type, nothing converts; `str`/`int`/`type`);
  UTF-8 strings, `bytes`; `ok`/`err` results, `?`, `try`, exhaustive
  `match` with list/record/result patterns and guards; `use path` →
  a record of a module's bindings. Memory: the per-line arena plus
  counted **boxes** for what is bound at a top level (deep copy in,
  scalars inline, sharing on `let y = $x`, retain through records),
  freed at the end of the statement that dropped them; the scope↔closure
  cycle collected by an explicit check; every host test under the leak
  detector. msh got `lib/pool.zig`, a 1 MB freeing chunk pool, in place
  of its never-freed persistent arena. Found on the way: a closure made
  as a temporary (a block argument) had nowhere to be released from —
  closures are now born at count zero on the dead list and survive
  only if something binds them by the end of the statement; and the
  "acyclic" story needed the scope caveat now in the decisions table.
- ✅ **Real IOMMU (SMMU) backing the DMA-grant API** (done, 2026-09-02):
  an SMMUv3 in front of the PCIe bus, stage-1 translation, with a
  device's DMA translated through the **holder's own page tables** —
  the same TTBR0 the CPU uses for that domain, so device address ==
  the driver's virtual address and `dma_alloc` stops lying. Receiving a
  device cap binds the stream to the receiver (last holder wins);
  releasing it (cap_drop, teardown) unbinds and invalidates before the
  tables are freed. Streams without a holder abort; faults terminate,
  are recorded on the event queue and logged by the kernel (throttled).
  QEMU only puts PCIe behind the SMMU, so this arrived with the move
  from virtio-mmio to virtio-pci (ECAM enumeration + device caps, the
  stage before). The `smmu` test: the block drill with every DMA
  translated, then a rogue handed the disk that asks it to DMA into a
  kernel page — refused, 128 events recorded against that stream and
  sector, canary intact. Every other test now runs behind the SMMU
  too, under TCG and HVF. Since the same day, device interrupts are
  MSI-X through the ITS (LPIs; the doorbell reached through the SMMU
  as privileged DMA), so INTx line sharing no longer caps the number
  of endpoints. Residual: SMMU stage 2 is what a guest passthrough
  uses (see EL2).
- ✅ **Kernel: the big lock retired** (done): per-core run-queue locks,
  per-thread locks, per-channel/notification locks, leaf locks for the
  object tables, timers, IRQ bindings, sleepers and the thread table
  (discipline and lock order in DESIGN "Locking"). Blocking is a
  handshake — the object lock is released only once the thread holds its
  run-queue lock and has raised `switching` — so wakeups are never lost
  and a thread is never run or reaped mid-switch; teardown peeks, locks
  in order, verifies and retries. The ipc test carries a permanent
  call/reply benchmark (one pinned pair per core): three cores went from
  1.4x of one core to ~3x under both TCG and HVF (5–7 Mops/s on an M3
  Max), after cache-line padding of the per-core and per-object structs
  — the split alone bought 1.8x. Three bugs recorded in DESIGN: the
  first benchmark measured the tick; the first cut raised `switching`
  too late (a soak-run instruction abort into a thread stack); and a
  supervisor's recv lost a death signaled between its bits peek and its
  park (a 1-in-80 fs-drill hang) until the peek-and-park was made one
  step under the notification's lock.
- ✅ **Dynamic fabric membership + load-aware placement** (done): nodes
  join by dialing any seed; the hello_ack carries the acker's member
  view (gossip) and member_up/down broadcasts keep the mesh converging —
  the LOWER node id dials a learned member, so meshes form without
  coordination. Liveness is heartbeat pings on each node's own poll
  clock (no shared clock anywhere); a silent or unsendable peer becomes
  a membership down event immediately and is gossiped. Rejoin is just
  hello again: the stale peer entry is replaced and the member comes
  back up. Heartbeats carry free-memory adverts; remote_spawn{node=0}
  places on the least-loaded live member and reports where it landed.
  Wire protocol v2 (v1 peers dropped loudly). msh shows it all: `nodes`
  and `rspawn N I`. The check's fabric spec is the full drill — three
  nodes on one L2 segment (node 1's QEMU hosts a hub of socket
  listeners; mcast sockets do not deliver cross-process on macOS), join
  → gossip (node 3's own full-mesh log) → placement → node 2's drill
  poweroff detected purely via membership → the runner relaunches it →
  rejoin → respawn on the rejoined node. Scoping: node id → 10.77.0.N
  addressing stays static (dynamic addressing is a separate concern);
  remote channels do not survive a peer's reboot (they fail cleanly).
- ✅ **Fabric security v1: cluster key + sealed transport** (done, wire
  v3; superseded by v2 below — the sealed transport and fail-closed
  posture survive, the shared key does not): the fabric refuses to
  listen or dial until its root of trust stages its credentials; every
  frame after the handshake travels sealed (per-connection,
  per-direction **AEGIS-128L** keys, counter nonces over the ordered
  TCP stream); the check's drill includes an **imposter node** that
  must be refused. Handshake nonces are 16 bytes from getrandom
  (originally an HMAC over the cycle counter, until the entropy work
  below landed); attach_net refuses the network while the kernel pool
  is unseeded.
- ✅ **Images out of the kernel: the boot archive is the program store**
  (done). The kernel embeds exactly one blob — the boot archive (MARC),
  packed at build time by `tools/mkmarc` from every program image
  (`img/<name>`) plus `etc/` and `conf/` — and holds no image table.
  `spawn` takes an **shm capability holding a staged MOSS image**; the
  kernel's loader is a copy from that buffer into fresh pages (static
  linking makes that the whole loader — no relocation, no symbols, no
  paths in the kernel). Images are self-describing: the header carries
  the program's name, which becomes the child's domain name and must
  match the catalog entry it was staged from. Spawners hold the archive
  as a **shared read-only mapping** of the kernel's one page-aligned
  copy (no per-holder copy, no user-memory charge) and stage through one
  reusable buffer (`user/loader.zig`): root stages init, init stages its
  services, the fabric stages remote spawns, the sandbox parent stages
  its children. The kernel's boot drivers read the same archive
  (`bootImage`). `shared.ImageId` survives as the catalog — a compact
  name for the fabric wire, certificate image masks, and init's
  topology — coupled to nothing in the kernel; the three order-coupled
  image lists are gone. Two latent bugs surfaced and were fixed on the
  way: an shm cap dropped while mapped freed frames the domain still
  mapped (mappings now hold a ref until teardown), and netsvc's listener
  kept a single pending connection, so a burst of SYNs orphaned
  established sockets nobody would read (a real backlog now; the fabric
  also tears down a half-open dial before redialing).
- ✅ **The fabric's promise kept: a channel across the network is a
  slower channel** (done). Three v0 residuals fell together. **Cap
  transfer across nodes**: a channel cap attached to a call on a remote
  channel — or to a reply — becomes an *export* on its node (a small id
  peers may call) and a badged *session* on the other, so the receiver
  holds an ordinary channel cap that calls back through the reverse
  proxy; the drill hands a local calc service to a remotely spawned
  child, which calls back through it and returns the sum. **Many
  exchanges in flight per link**: the kernel's new deferred replies let
  the fabric park each caller under its reply token and carry on;
  responses are matched by sequence number, a peer's death or a timeout
  fails every exchange on that link cleanly (the drill drives three
  callers at once and asserts overlap). **No polling**: the fabric arms
  a kernel timer notification for its heartbeat clock and a netsvc
  socket *doorbell* on every socket (`NetReq.watch`), both on one bound
  notification that interrupts its recv; the test drivers no longer
  tick it and the shell boot never did. The proxy deadlock this
  uncovered — a callee calling back through the fabric that was
  blocked calling it — is why user domains can now create **threads**
  (`thread_create`/`thread_exit`, same cap table, a domain-supplied
  stack): inbound remote calls run on a small worker pool while the
  serve thread alone touches peers and the wire. ✅ **Identities
  persist** (done): under the system boot a node's identity is born on
  the node — a random seed from the kernel pool on first boot, kept
  with its certificate in `state/fabric/` on the encrypted volume (the
  unit's own state tier, created by init from the unit file's `mkdir`
  view give) — and restored on every later boot without the root of
  trust, which is needed only to certify a new identity; fabsvc keeps
  the revocations it accepts in the same state and reloads them at
  boot. The shell check boots the same volume twice: "identity born
  and certified", then "identity restored from state". Re-enrolling a
  node is deleting its state. Remaining fabric residuals: static node
  addressing; shm caps do not cross (by design), notifications do not
  yet; the fabric drill's nodes still take kernel-composed test seeds
  (they have no disk).
- ✅ **Boot orchestration into userspace** (done, three stages). The
  end state, now built: the kernel spawns root with log, spawner, the
  boot archive, and the device capabilities; root forwards them to init;
  init spawns every driver and service from **unit files** (mshl data
  literals under `boot/conf/units/`) that name the image, budget, spawn
  grants, and `give` lines — `give disk unit blk` is the whole
  dependency model, capability wiring driving lazy activation, no
  ordering anywhere. ✅ Stage 1: device authority became ordinary
  capabilities — the kernel mints the virtio-mmio window and SPI range
  from the **devicetree** (`dt.virtioWindow`, host-tested) instead of
  constants, authority caps (log, spawner, mmio, irq, entropy,
  introspect) travel in messages like any other cap, and one **boot
  protocol** (`shared.BootReq`: `cap{tag}` + attachment, `secret`,
  `arg`, `go`; `user/boot.zig` on the receiving side) replaces the
  run-tool handshake and is how rngd now receives its device from
  whoever spawned it. ✅ Stage 2: every driver and service takes its
  setup through the boot protocol — blk, net, and cons receive their
  device as `mmio` + `irq` caps; fssvc its root buffer, the volume key
  (a `secret`), and the disk channel; fabroot its buffer and the root
  seed; fabsvc its buffer, identity material, and net view — and the
  per-service setup requests are gone from the ABI (FsReq lost set_key
  and attach_disk, RootReq lost attach_buf and set_root, FabReq lost
  attach_net and set_identity). The one service-level setup step that
  remains is the fabric's certification (identity_key → root signs →
  set_cert opens the network), because a certificate can only exist
  after the key does. The kernel boot drivers speak the protocol through
  a handful of helpers (spawnDevice, spawnFs, certifyFabric); msh takes
  its console, view, init, and fabric caps the same way. ✅ Stage 3:
  **unit files and init as the orchestrator.** `boot/conf/units/*.msh`
  are mshl data literals (record literals joined the language; a strict
  `parseData` entry point accepts literals and nothing else) naming the
  image, budget, spawn grants, and `give` lines: a device (from the
  caps root forwards to init at boot), another unit's channel
  (activating it first — capability wiring is the dependency model, no
  ordering anywhere), a shared buffer, a secret from the archive, a
  filesystem view, a network view, init's own front channel. Units
  listing the boot's profile in `profiles:` start at boot and pull in
  the rest (the key was first written up as `start: eager`; the parser
  only ever knew `profiles`); `essential: true`
  means the system follows the unit's exit; `certify` runs the fabric's
  certification against a root-of-trust unit; `install: true` installs
  the program store once the filesystem is up. The kernel's shell boot
  is now "spawn root with log, spawner, the archive, and the devices";
  root forwards the devices to init; init starts rngd and msh eagerly
  and msh's unit pulls in cons, fs (and blk), fabsvc (and net, fabroot,
  certification); when msh exits, init revokes everything and exits,
  root follows, and the kernel holds the leak bar. `run` reads the
  program's unit file for its grants and views instead of a table in
  msh. Services are units named after ServiceId (the demo and flap
  drills run through the same init). The old init.topology is gone;
  the boot tree lives in the repo at boot/ and is packed as is.
  ✅ **Drills as unit files** (done): the block, filesystem, and network
  tests are boot **profiles** — `profile=blk|fs|net` in the boot
  arguments, passed kernel → root → init — and a unit lists the profiles
  it is eager under (`profiles: [net]`). Drill steps are `oneshot`
  units: exit 0 starts the units that wait on them (`after: fs-alice`),
  a non-zero exit takes the system down with that code; the last step is
  `essential`. Net views can carry a one-destination allowlist (`allow:
  10.0.2.100, port: 9000`). The kernel side of those three tests is one
  function: spawn root under the profile, hold the leak bar. The rng and
  fabric tests keep their kernel drivers — one asserts the kernel pool
  directly, the other is the three-node harness. Residuals: unit files
  carry test key material beside them; `run` arguments reach a unit only
  as a view path.
- ✅ **msh v2: a structured shell language, line editor, and typed
  pipelines** (done). The shell got the OS's own thinking: pipelines
  carry VALUES (records and tables straight from typed IPC), never bytes
  to be re-parsed, and text exists only when the final value is rendered
  for the human. The language, **mshl** (`lib/mshl.zig`), is a pure,
  host-tested `lib/` module — values (nothing/bool/int/string/list/
  record/table), a small regular grammar (commands with arguments,
  `|` pipelines, `>` redirection = `| save`, `let`, `if/else`, `for`,
  `while`, `$vars`, `"interpolated $text"`, `(sub | pipelines)`,
  `[lists]`, `.field` access, comparison/boolean/arithmetic operators,
  size units like `4kb`), and the table verbs (`where` with bare column
  names, `sort-by --desc`, `select`, `get`, `first/last`, `reverse`,
  `len`, `keys`, `lines`). msh is the interpreter's *host*: every
  command turns a typed reply into a value — `ls` is a name/type/size/
  mtime table, `stat`/`df`/`mem` are records, `ps`/`svc`/`nodes` are
  tables, `tree` draws a subtree, `cat`/`open` read, `write`/`save` and
  `> path` write rendered text. A line editor (`user/lineedit.zig`)
  gives history, cursor keys, ctrl-a/e/k/u, and tab completion of
  commands and paths (directories listed through the view, suffixed
  `/`). The interpreter's memory is two static arenas in msh's BSS (per-
  line, reset each line; persistent for variables). The shell check
  drives the language end to end: where/select/get over a real
  listing, let/if/for/while, `>` redirection round-tripped through
  `cat`, sub-pipelines, and the editor's tab and ctrl-c. ✅ **Follow-ups** (done): `run` programs
  hand back a **value**, not text — the `out` capability is a buffer
  the program writes an mshl data literal into (`user/result.zig`; the
  data syntax is the interchange form, a table is a list of records),
  and msh returns it, so `run ps | where state == alive | get name`
  works and ps/ls print text only when nobody gave them an `out`.
  `def name [params] { body }` defines functions (`$in` is the pipeline
  input; bodies persist across lines); `to-data`/`from-data` write and
  read the data form, so `x | to-data | save p.msh` and `open p.msh |
  from-data` round-trip through the strict parser; `source p` runs a
  script in the session, and the startup script (`conf/msh/startup.msh`
  on the volume, else the archive's `boot/conf/msh/startup.msh`) runs
  before the first prompt — it prints the motd and defines `alive`.
  Scripts render every top-level statement's value as they go, the way
  the prompt does. Residual: `save` alone still writes rendered text
  (use `to-data`); run arguments are 24 bytes of text.
- ✅ **Programs as files: the content-addressed `img/` store, the
  introspect cap, and `run`** (done). At the shell boot, init — the
  thing that already holds the archive and the catalog — installs every
  program into a view of `img/` alone as `img/<digest>` (hex of
  SHA-256[0..16]; present files are skipped, the name is the content)
  and writes `img/index` (name → digest). msh's `run NAME [path]` reads
  the image through its own filesystem view, verifies it against its
  digest before anything else, spawns it from msh's stage into a fresh
  domain, hands it the console over a boot channel (RunReq: console
  channel + byte buffer, optional view, 24 bytes of argument, go), and
  waits silently until it exits. A new `introspect` capability carries
  domain_list/sysinfo without spawn authority, so `ps` as a program
  holds exactly a log cap, its boot channel, and the ledger; `ls` as a
  program holds a read-only view whose root IS the requested path — it
  cannot name its parent because no such name exists in its domain.
  Both render through `user/tty.zig` (shared with msh's builtins; the
  ps table is one function). The shell check installs the store on a
  fresh volume every run and drives `ls img`, `run ps`, `run ls
  data/smoke`, and `run nope`. ✅ **Manifests beside images, and a
  per-user store** (2026-09-03): `img/index` and msh's built-in
  name→manifest table are gone — each program's manifest sits beside it
  as `img/<name>.msh` (digest, grants, gives; init builds it from the
  unit file), a shell consults its own store (`img/` in its filesystem)
  and then the system store (a read-only `store` cap), a session gets
  the system store from the manager and its home's `img/` as its own,
  and `install NAME` copies a program into it. The login drill runs
  `ps` from the system store inside a session, installs it, and runs
  the home's copy. Residuals: the system store is the only source of
  programs; `run` arguments are 24 bytes.
- ✅ **Entropy: virtio-rng + getrandom/rng_seed** (done): the kernel
  carries a ChaCha8 fast-key-erasure CSPRNG (`kernel/rng.zig`) that it
  never seeds itself — hardware entropy enters only through `rng_seed`,
  gated by a new `entropy` cap held by the userspace virtio-rng driver
  (`user/rng.zig`, device id 4, the fourth virtio device class through
  the unchanged mmio/IRQ/DMA grant interface). rngd keys the pool with
  64 bytes at boot and reseeds on its own clock. `getrandom` is the one
  ambient syscall besides the counter: random bytes are authority over
  nothing, so no cap is demanded — but it is **fail-closed** (bad_state
  until the boot seed lands; no cycle-counter stand-in ever), bounded to
  256 bytes per call, and it checks that the target is user-WRITABLE
  (text and the granted blob are refused — the same fix closed a latent
  domain_list hole where a caller could point the kernel at a read-only
  page). The check's rng drill: fail-closed before any driver, driver
  seeds, probe verifies fresh bytes/argument policing/cap gating,
  reseeds land, kernel-side draws, teardown leak bar. msh has `rand`.
  Every QEMU config now carries a virtio-rng; the shell and fabric boots
  start rngd first. Not interposable (like the counter) — a domain that
  must see deterministic randomness is a future manifest option, not a
  proxy.
- ✅ **Fabric security v2: per-node identities** (done, wire v4; v1's
  shared cluster key is gone). Every node holds an Ed25519 **identity**
  and a **certificate** signed by the cluster's **root of trust**
  (`lib/fabcert.zig`: node id, identity key, authorization flags + image
  mask, serial). Joining is a **signed ephemeral Diffie-Hellman**
  handshake — hello carries the certificate and an X25519 ephemeral key,
  each side proves its identity key over a transcript of the whole
  exchange (version, ids, nonces, ephemeral keys, both certificates), and
  the session keys come from the DH secret, so identity keys only ever
  sign and sessions have forward secrecy. **No shared secret exists
  anywhere**: a node cannot impersonate another, the cluster key on each
  node is public material, and per-link authorization is the peer's
  certificate — membership gossip is believed only from peers certified
  to gossip, and a spawn request needs the spawn flag plus that image's
  bit (a typed `denied`, not a timeout). Revocation is a root-signed
  record {node, min serial}: applied where it lands (live peers below
  the bar are dropped), gossiped once through the mesh, and enforced at
  every later handshake — a compromised node is a revocable identity,
  and it returns only with a fresh key and a fresh certificate. The root
  key lives in **fabroot**, a separate key-custody service (fabric role
  3) that certifies public keys handed to it and never sees a node's
  seed; fabsvc never sees the root key; the boot driver is the out-of-
  band channel. The check's fabric drill now also proves: an imposter
  with a certificate from a different root is refused; node 3's
  certificate carries no spawn authority and its spawn is refused on
  certificate grounds; node 1 revokes node 3 mid-life, node 2 learns it
  by gossip and cuts its own link, and node 3's rejoin attempts are
  refused at the handshake. Residuals: identity seeds are handed in by
  the boot driver each boot (persisting them in `state/fabric/` on the
  encrypted volume is the evolution; the protocol does not care where
  they come from); certificates carry no expiry (no shared clock —
  revocation serials are the only clock); ML-DSA is a drop-in for the
  signatures if post-quantum ever matters here.
- ✅ **CPU budgets and time partitioning** (2026-09-02): the third
  budget the Domains decision named is built — a hierarchical
  `CpuAccount` charged from the cycle counter, a limit in permille of a
  core per period, threads parked until the period resets, overruns
  carried as debt — and the opt-in partition: a core mask reserved for
  one domain alone, refused to a second. The `cpu` drill measures a
  quarter-core domain, an unlimited sibling, and an island on core 3.
  Honest scope: a cap, not a guarantee; and a partition keeps other
  domains' code off the core, not the tick or the shared caches.
- ✅ **EL2: Moss as hypervisor** (first cut, 2026-09-02): the kernel
  boots as a VHE host when entered at EL2 (nothing else changes: E2H
  redirects every EL1-named register; PSCI conduit and timer line are
  chosen at run time; the per-core pointer moves to TPIDR_EL2), and
  `kernel/arch/aarch64/vm.zig` runs an EL1 guest in its own stage-2 world through a
  **hypervisor capability**: `vm_create` (RAM at IPA 0x40000000, mapped
  into the VMM), `vm_set`, `vm_run` — every exit (stage-2 MMIO fault
  with the decoded access, WFI, HVC, trapped SMC/PSCI, a host interrupt)
  returns to the VMM's syscall by rewriting the exception frame so its
  `eret` lands in the host resume stub. The guest gets the virtual
  counter/timer (its PPI 27 fires at the host, which masks it and
  injects a virtual interrupt through ICH_LR0) and the virtual GICv3
  CPU interface. The `vm` test: a userspace VMM (`user/vmm.zig`) loads a
  bare-metal guest (`guest/hello.zig`) from the boot archive and runs
  it — hello over a trapped UART, three timer ticks, PSCI power-off —
  nothing leaked. HVF cannot host it (Apple's nested EL2 has no VHE), so
  guests are TCG-only until real hardware.
  ✅ **The pooling story** (same day, second and third cuts): a **moss
  kernel as a guest** (`guest` test: the VMM writes it a devicetree,
  emulates a PL011 and the GICv3 distributor/redistributor as trapped
  MMIO, answers PSCI over HVC; the guest boots its own archive, runs
  root/init/a unit, powers off), then **device passthrough** and a
  **VM as a fabric node** (`vmnode` test): the machine's second NIC and
  entropy device are handed to the VMM, which presents them to the
  guest on an emulated PCIe bus (config space from the real device,
  BARs virtual and placed by the guest, only the virtio BAR shown);
  `vm_attach_device` maps the BAR into the guest's stage 2, binds the
  device's SMMU stream to **stage-2 translation through the guest's
  tables** (the guest's DMA addresses are IPAs, and nothing else is
  reachable), and routes its LPI into the guest as a virtual SPI (the
  guest sees wired INTx; MSI-X stays the host's). The guest runs the
  same joiner path a physical node does — rngd, netsvc in cluster
  mode, root of trust, fabric service — joins node 1 as node 2, and a
  remote spawn placed on it answers an RPC: one box, two pool nodes.
  A vCPU idling in WFI sleeps in the kernel on a per-VM notification
  that timer fires and device interrupts signal.
  ✅ **Several vCPUs** (same day): a VM has up to four; PSCI CPU_ON
  brings one online at the guest's entry with a `cpu_on` exit that
  tells the VMM to run it on a thread of its own, the trapped
  ICC_SGI1R write becomes SGIs pended on the targeted vCPUs, each vCPU
  has its own idle wait, vGIC state and redistributor shadow, and the
  timekeeper watches the timer deadline of every descheduled vCPU
  (whose hardware timer another vCPU may have taken). The moss guest
  boots all four cores in both VM drills. PSCI policy moved from the
  kernel to the VMM the same day (`hvc`/`smc` exits answered through
  the resume value; the kernel keeps `vm_cpu_on`), so the guest\'s
  firmware interface is a program\'s — and an x86 or RISC-V port changes
  only the exit decoder. Residuals: the GIC shadow is
  a register file with no distributor semantics (SPIs go to vCPU 0, as
  a moss guest routes them), passthrough needs MSI-X on the device (a
  wired-INTx device would need level emulation), and everything is
  TCG-only.
- ✅ **PAN as a safeguard** (2026-09-02): kernel access to user memory
  goes through `kernel/arch/aarch64/uaccess.zig` only; PAN is detected (not
  assumed), armed on every core and by every exception entry, and
  opened just inside the copy helpers, so a kernel bug that
  dereferences a user pointer elsewhere is a fault report rather than
  an exploit primitive. The `pan` drill provokes and expects the
  refusal. On ARMv8.0 the range checks stand alone, as before; on
  x86_64 the same boundary becomes SMAP.
- ✅ **Users and sessions, stage 1** (2026-09-03): user records as
  data (`conf/users/<name>.msh`: Ed25519 public key, scrypt salt and
  cost, the seed sealed under the passphrase; `lib/usercred.zig`), a
  session manager and key custodian (`usersvc`) that unseals on login
  and spawns the session as a domain under the record's budgets with a
  rw view of `home/<user>` (a new hierarchy tier) and a settings view,
  layered settings with locked keys (`lib/settings.zig`), and the
  `users` drill: refused logins, two sessions at once, homes holding
  only their owner's work, clean teardown. Same day, **console login**:
  the `login` profile puts a prompt on every console (a seat is a
  virtio-console device; units pick devices and caps of one kind by
  `index:`), and a session opened there is an init instance running the
  user's own units (or the archive's `conf/session/` template: msh with
  the home as its whole filesystem) — the `login` drill logs two users
  in over two TCP consoles at once. Then **home volumes** (stage 2): each
  user's home is its own encrypted mossfs volume in a file on the system
  volume, keyed from the unlocked identity and served by a home
  filesystem service spawned per session and destroyed with it — the
  system volume holds ciphertext only, and the drill scans it to prove
  so. Residuals: an enforced home capacity.
  ✅ **Sharing between users** (2026-09-03): a session derives a view
  of a path in its home and offers it, under a name, to one user
  through the session manager — every session now holds its own badged
  channel to the manager, so requests name their caller by badge and a
  session can only share, never open or end sessions. The other user's
  shell lists offers, accepts one (the cap comes to it) and mounts it
  as `@name`; `unshare` revokes the view at the source (a new `revoke`
  in the view protocol, allowed from the root or the deriving view;
  the slot waits for the holder's last cap to die before reuse, so a
  stale cap never aliases a later view; `derive` now answers with the
  badge). The login drill shares alice's notes with bob read-only,
  reads through the mount, is refused a write, and reads nothing after
  the withdrawal. Bug found: the manager handed every session a copy of
  its own settings and store views — one badge, one buffer on the
  service, so two sessions trampled each other's attached buffer and a
  dead session's lingered; each session gets views derived for it now.
  ✅ **The desired state, and `apply`** (2026-09-03): `conf/system.msh`
  (the archive's copy as the default, the volume's taking precedence)
  lists users — name, bootstrap passphrase, budgets, kdf cost — and the
  system settings layer; `apply` (users role 2, the first step of the
  users and login profiles, and `run apply` from the shell) makes the
  volume match it idempotently and returns its actions as a table. A
  unit file with `run: true` is a program the shell can run under its
  name (init writes its manifest, with `arg`), and `run` honors `arg`
  and a `bootfs` grant. A fresh disk boots to a multi-user system with
  no manual step; the shell drill runs apply twice. Bug found: the
  role read the archive before its entry point recorded where it was,
  and a drill step accepted the resulting "exited with code 255"
  because it matched on a digit.
  ✅ **Published services, and fabric logins** (2026-09-03): the fabric
  gained `publish{service}` (a channel cap offered to the pool under a
  ServiceId, becoming an export) and `lookup{node, service}` (a
  proxied channel to it, the same shape as a remote spawn's answer;
  wire version 5), proven in the drill by node 3 — no spawn authority
  — reaching node 1's published calc. The session manager publishes
  itself, and a login for a user without a local record fetches it
  from a live member 24 bytes a chunk (nothing but words cross), caches
  it, and unseals locally; the home is born on the node of the session.
  A system boot is node-parameterized now (`node: boot` in a unit takes
  `node=N` from the boot arguments through root to init; `certify.seeds`
  dials the seeds once certified), and the `flogin` drill boots two
  system profiles on one segment, each with a disk, and logs alice in
  on node 2 with her record on node 1.
- ✅ **The gate hardened** (2026-09-03): the check runs the kernel-heavy
  drills a second time under a **ReleaseSafe kernel** (`+rs` rows), has
  a soak mode (`-Dsoak=N`) and a filter (`-Donly=a,b`). The first
  optimized boot found a bug the Debug kernel had hidden for the
  project's whole life: a non-volatile `mrs daif` reordered past its
  `msr daifset`, so every unlock restored interrupts masked and core 0
  never took an interrupt again (DESIGN "Zig conventions"). Every read
  of mutable CPU state is `asm volatile` now; all 22 drills pass
  optimized. The new rows and the soak then found four teardown bugs
  in a day (DESIGN "Users and sessions", "Domains"): a dead domain's
  slot reused under a live ctl cap, the reaper reading a slot after
  freeing it (stealing a fresh domain's death watch), a killed thread
  reaped mid-syscall (kills now wait for a safe point), and a dying
  sleeper freed without being counted — and, closed by design, the
  reaper reclaiming a cap table another core was still walking in
  `destroy` (a domain is drained only once nobody is inside it). Drills
  hang loudly now — 60s
  without shutdown dumps every thread, domain, notification and a
  lock-free trace ring of lifecycle events, then panics.
- ✅ **Client death per badge, and unmap** (2026-09-03): a service
  serving many badged clients on one channel now hears of each one's
  death — a badge is refcounted on its own, and `recv` reports the
  last cap's death as `client_dead` with the badge — and `shm_unmap`
  lets it release the client's buffer (the domain's window is a
  first-fit table, kernel copies pin it and their range checks consult
  it). fssvc and netsvc free the view, its buffer and, for netsvc, its
  sockets; the fabric frees the session slot. The fs drill runs a
  hundred clients through one domain and holds two dozen to the grave;
  the kernel IPC test proves the reporting, including the wake of a
  server parked in recv. Closes the residual that had the shm pool
  raised to 64 as a stopgap: sessions no longer drain it. Bug found on
  the way (DESIGN "Locking"): a thread exiting on its own core while
  its domain was destroyed from another hit an `unreachable` in thread
  teardown; `destroy` now claims a domain atomically and teardown
  tolerates a thread that died under it.
- ✅ **PCI enumeration out of the kernel** (2026-09-02): the kernel
  mints window capabilities (ECAM, MMIO) from the devicetree and keeps
  the device table, ITS routing and SMMU binding; a userspace `pcisvc`
  walks the bus, places BARs, programs MSI-X and registers endpoints
  through `device_register`. Root runs it before init; the kernel's
  drills spawn it to fill the table; the moss guest runs it against
  the VMM's emulated bus. The trusted kernel is ~250 lines smaller.
- ✅ **Developer shell and tooling** (done): **msh**, an interactive shell
  over a new virtio-console driver (moss's third virtio device class),
  holding exactly the caps a console needs — console channel, fs view,
  init front channel, spawner. The mossctl functionality is typed-IPC
  builtins: `ps`/`mem` via new spawner-gated kernel introspection
  syscalls (domain_list fills typed DomainRec records straight from the
  ledger — state, threads, kobj/user budgets; sysinfo reports pmem,
  cores, uptime; spawn authority is the gate on seeing the tree),
  `svc`/`start`/`stop` via init's extended protocol (deliberate stops
  are not restarted), and ls/cat/write/mkdir/rm/mv/ln/readlink/stat/
  df/sync over the ordinary fs view protocol. `zig build run-shell`
  boots it interactively (your terminal is the machine; kernel log in a
  file); the check's shell spec drives a real scripted session over a
  socket chardev and holds the usual leak bar. No text scraping
  anywhere — text exists only where a human reads it.
- ✅ **mossfs v2 — a filesystem you can trust** (done): replaced the
  Phase 9 teaching filesystem behind the same view-cap protocol, as a
  service swap with no migration. As built (`user/mossfs.zig` +
  `user/fs.zig`, design in DESIGN.md): CoW block tree, xxhash64-checked
  block pointers verified on every read, transaction groups committed via
  8 rotating full-slot-checksummed superblocks (FLUSH-bracketed), 128B
  dnodes in a CoW objmap (nlink reserved — hardlinks deferred for the
  view-exclusivity design pass), symlinks resolved relative to their
  containing directory under view rules, allocation groups with per-group
  CoW bitmaps + free-count table (mount cost independent of volume size),
  async deleting-set for TB-scale delete/truncate with bounded per-txg
  drain, quarantined frees, batched txg durability + explicit sync,
  delete/rename/truncate/stat/symlink/readlink/O_EXCL in the protocol,
  volatile/ cleared at mount, ENOSPC headroom reserve. The core is a pure
  std-only library; `zig build test` runs crash-injection sweeps (every
  cut point + torn final writes), corruption flips, superblock-election
  and model-based randomized-op tests against it on the host. Scoping
  notes: torn-write detection-only (CoW makes them harmless);
  cross-parent directory rename refused (no ancestry walk yet). ✅
  **Hashed directories** (done, format v4; a v3 volume mounts unchanged
  and is written as v4): a directory that fits one block stays a linear
  array in insertion order; the first entry that would not fit converts
  it to extendible hashing over the name's xxhash64 — a header block
  with a table of bucket block numbers indexed by the hash's top bits,
  63-entry buckets that split on their next bit (doubling the table
  when needed), all ordinary blocks of the directory object so CoW,
  checksums, and txg commits cover them. Lookup is one hash, one table
  read, one bucket scan; listing order is bucket order past one block.
  Host tests: 700 entries through several splits with removals and a
  remount, a crash-injection sweep across the conversion on plaintext
  and encrypted volumes (every cut leaves the old or the new directory,
  never a torn table), and the randomized model with a root directory
  that outgrows a block. Limit: 512 buckets (~32K entries; a two-level
  table is the next step). Hardlinks remain deferred: they let one
  file appear under two views, which the view-exclusivity design has
  to answer first.
- ✅ **mossfs v3 — compression + encryption** (done): format rev on v2, no
  migration. Per-block LZ4 (data blocks; stored only when it saves ≥1
  sector) over sector-granular, byte-aligned allocation (bitmap bit =
  sector; metadata/raw runs take one full free byte, compressed runs pack
  inside a byte; the free counter counts free bytes so the ENOSPC reserve
  survives fragmentation; frees and quarantine are range-aware).
  FS-native AES-256-XTS encryption (tweak = absolute sector): object
  data, indirect blocks, and the objmap are ciphertext; superblocks,
  group table, and bitmaps stay plaintext so mount/allocation are
  keyless. Encrypted blocks use keyed SipHash-2-4 MACs as their csums;
  the SB carries a keyed MAC verified at set_key (wrong keys fail there,
  cleanly; SB splices are caught). Keys: 256-bit master → HKDF → XTS +
  MAC keys, delivered badge-0-only via FsReq.set_key before
  FsReq.attach_disk; background work (drain/commit/volatile-clearing) is
  key-gated; auto-format only on an all-zero SB region (garbage disks are
  never wiped — degraded bootfs-only serving instead). lib/lz4 + lib/xts
  are the first `lib/` static modules (OpenSSL-cross-validated vectors).
  Documented residuals: ≤8-txg rollback via SB-slot zeroing (no external
  anti-rollback state), 64-bit MAC tags (format constraint), plaintext
  allocation metadata leaks fill/churn patterns, software AES until
  FP/SIMD lands.
- ✅ **FP/SIMD context switching + hardware crypto** (done): CPACR_EL1
  FPEN opened in trap.init (every core); the scheduler eagerly
  saves/restores per-thread v0-v31 + fpsr/fpcr for user threads only
  (528B in Thread, zero-initialized so a fresh thread can never see
  another domain's vector registers); the kernel remains FP-free by
  build flags, its only vector instructions the hand-written stubs.
  Userspace builds with NEON + AES features → std.crypto takes the
  armcrypto path, and lib/xts runs the AES cores 8-wide (XTS blocks are
  independent) with word-wise GF doubling: host XTS 1.5→2.3 GB/s (hw),
  and encrypted-random whole-stack throughput rose 3.7-4.5x on HVF
  (13.4/18.6 MB/s w/r). Correctness is pinned by an adversarial probe in
  the ipc test: both processes stamp all 32 vector registers with
  distinct patterns around blocking syscalls and verify bit-exact
  survival across context switches. Remaining whole-stack ceiling is
  the 2KB view-buffer protocol chunking (tracked below).

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
