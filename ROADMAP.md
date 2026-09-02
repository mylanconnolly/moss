# Moss Roadmap

A clean-slate, capability-based microkernel OS in Zig. Modern hardware only, no
legacy personalities, sandboxed-by-construction, designed from day one to
compose multiple machines (virtual or physical) into pooled hardware.

This document is the plan of record: locked decisions first, then phased
milestones, each with a concrete exit criterion. Change decisions here before
changing them in code.

**Status:** phases 0–11 are complete (✅) and covered by `zig build check`;
the Phase 12+ pool below is the open frontier.

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
| SMP | Structural from day one: per-core run queues and per-core kernel state, no global "current thread". A big kernel lock is acceptable early; the *structures* are not allowed to assume one core. | Retrofitting SMP is the classic hobby-OS death. |
| Distribution stance | **No single system image.** Explicit-but-ergonomic distribution: cap delegation across nodes, remote channels, remote spawn — via a userspace fabric service per node. Membership/consensus/discovery live in userspace where they can iterate. | Transparent SSI has failed everywhere it was tried; the network's latency and partial failure must be legible to software. |
| Security posture | W^X unconditional, NX everywhere, separate address spaces per domain, kernel/user page-table hygiene from the start. Side channels: no cross-domain SMT sharing; seL4-style time partitioning as a later opt-in. Documented honestly — caps don't fix microarchitecture. | Cheaper to be born safe. |
| Network addressing | **IPv6-native ABI**: every address in every protocol is 128 bits; IPv4 destinations travel v4-mapped (`::ffff:a.b.c.d`). There is no IPv4-only code path to depend on — the stack speaks both families on the wire (ARP for v4, NDP/ICMPv6 for v6), but the system's idea of an address is IPv6. Filters/allowlists compare full 128-bit addresses. | v4-only ABIs are the next legacy trap; v4-mapped addressing is the proven dual-stack shape and costs nothing. |
| Word size | 64-bit only, permanently. The application/microcontroller divide is MMU vs. MPU, not word size: no-MMU hardware (Pico 2 / RP2350 class) cannot express per-domain address spaces at all, and 32-bit would break load-bearing design elements — the linear direct map doesn't fit in a 32-bit address space (hello highmem/kmap), generational handles lose generation width, and the IPC ABI forks. The 64-bit budget market is already the budget market ($5 RV64 Milk-V Duo, $15 aarch64 Pi Zero 2 W); new 32-bit application-class silicon serves vendor-BSP embedded lines that would never adopt a new OS. MCU-class devices join the pool as **fabric leaf nodes** instead (see Phase 12). | No second OS wearing the same name; no design pressure from hardware the architecture can't serve. |
| Language/toolchain | Zig, version pinned (currently 0.16.0). `build.zig` is the entire build: kernel, userspace, image packing, `zig build run`, `zig build run-cluster`. Comptime Zig types are the IDL — IPC protocols defined once in `shared/`, marshaling/stubs generated at comptime. | No Make, no shell scripts, no separate IDL compiler, ABI type-checked from one source of truth. |
| Code sharing | **Static linking only — no dynamic loader, ever.** Shared functionality lives in `lib/`: pure, freestanding-safe, host-testable Zig modules (lz4, xts, ...) compiled into each program that imports them. Where key custody matters, a capability *service* holds the secret instead of a library. Code-page dedup, if ever needed, comes from content-addressed images (`img/`), not load-time linking. | Relocation machinery, symbol versioning, and loader attack surface bought nothing at moss's scale; static modules keep every binary analyzable and every ABI a comptime-checked Zig type. |

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
- Per-core run queues and per-core state (structures SMP-honest from the start); big kernel lock for now.
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
- Virtio transport (virtio-mmio first; PCI ECAM if/when needed).
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

## Phase 12 and beyond (unordered)

- x86_64 port (the HAL's honesty test) and UEFI boot for real aarch64 hardware.
- Real IOMMU (SMMU) backing the DMA-grant API.
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
- Time-partitioning opt-in for side-channel-sensitive domains.
- EL2: Moss as hypervisor, partitioning one box into pool nodes — the pooling story from both directions.
- virtio-gpu and input devices (the graphical console).
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
  cross-parent directory rename refused (no ancestry walk yet); linear
  dirents (hashed dirs are a format-versioned evolution).
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
