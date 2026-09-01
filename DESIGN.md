# Moss Design

The architecture narrative behind the locked decisions in
[ROADMAP.md](ROADMAP.md). The roadmap says *what* was decided; this document
says *how the pieces work together* and records reasoning detailed enough to
stop relitigation. When this document and the code disagree, one of them has a
bug — fix whichever is wrong, deliberately.

Sections marked **"As built"** describe the running system (phases 0–11, all
covered by `zig build check`) including the scoping compromises of each v0
and the lessons individual bugs paid for; the surrounding prose is the
destination those versions evolve toward.

## Kernel model

Moss is a capability-based microkernel. The kernel implements: address spaces,
threads, domains, capability tables, IPC, and interrupt/fault delivery as
messages. Everything else — drivers, filesystems, networking, init, the
multi-node fabric — is userspace reached over channels.

**Objects and authority.** Kernel objects are allocated by the kernel from
per-domain quotas and referenced exclusively through capability tables. There
is no global namespace of anything in the kernel: no PID table visible to
users, no path lookup, no service registry. Discovery is a userspace protocol
conducted over caps that were explicitly granted.

**Handles are generational** (`shared.Handle`: 24-bit slot + 40-bit
generation). Slot reuse bumps the generation, so a stale handle can never
resurrect authority. Raw kernel pointers and densely-reused small integers
never cross the ABI — this is both a security property and a distribution
prerequisite (remote proxies need identity that survives time and space).

**Cap derivation and revocation** are designed so that a userspace proxy is a
first-class participant: any cap can be re-exported through a proxy with the
proxy's own bookkeeping, because interposition and cross-node delegation both
depend on it.

**User address spaces** live in TTBR0 (39-bit low half), one tree per domain,
TLB-tagged with the domain's ASID (retired with `tlbi aside1is` at teardown).
Kernel-only threads run with TTBR0 walks disabled (TCR.EPD0), so stale user
mappings are unreachable outside the owning domain's threads. User mappings
are W^X and non-global; ARMv8.0 has no PAN, so syscalls may read user buffers
through the live TTBR0 mapping after explicit range checks (revisit on
v8.1+). Syscall ABI: x8 = number, x0..x5 args, x0 = result — numbers and
errnos defined in `shared/` like everything else that crosses the boundary.

## Domains

The domain is the unit of spawn, quota, sandboxing, and teardown — the
jail-equivalent. A domain owns threads, address spaces, and cap tables, and
carries budgets: user memory, kernel-object memory, CPU share. Domains form a
tree; a child's budgets come out of its parent's.

Teardown is total and transitive: revoking a domain cap reclaims the entire
subtree — threads, memory, caps, in-flight IPC (peers get death
notifications). Quota accounting returning to zero after teardown is the
correctness check.

**As built (Phase 6):** domains carry a parent pointer; destroy() recurses
over children before the parent, and the reaper finishes children first so
their credits cascade home before the parent's balance is verified. Quota
accounts are hierarchical — a child's account points at its parent's and
every charge walks the chain — so a parent's limit genuinely bounds its
subtree's total consumption, and the budget slice named at sys_spawn
(kobj/user KB packed in x5) is a local cap within that bound. Failed spawns
unwind completely (abortSpawn). Teardown latency is dominated by the
reaper's polling cadence (one 100ms tick per dependency layer), not by
work; the destroy call itself is ~hundreds of microseconds. Event-driven
reaping is a cheap future win if latency ever matters.

A lesson recorded in code: a notification bound to a thread must have its
latched bits checked *inside recv before blocking* — the interrupt-on-signal
path alone loses signals that arrive while the supervisor is busy between
recvs (the classic lost wakeup). Init also refuses to hand out a channel to
an instance it can see is already dead, closing the window where a death is
signaled but not yet processed. And its sibling (found by the Phase 8
benchmark): consumers of a bound notification must drain it with notify_wait
after every interrupted recv, or the latched bits make every future recv
return interrupted.

Two scheduler lessons from the same benchmark: (1) enqueueing a thread onto
another core must *kick* that core (SGI out of wfi; need_resched + a
preempt check on syscall return for the local core) — without it every
cross-core wakeup silently waits for the target's next 100ms tick, which no
functional test notices but which taxes every IPC round-trip ~2500x; and
(2) the resched SGI has to be enabled in each core's redistributor
(GICR_ISENABLER0), or the kicks vanish without any error.

**FP/SIMD (as built):** userspace owns the vector unit — trap.init opens
CPACR_EL1.FPEN on every core, and the scheduler saves/restores v0-v31 +
fpsr/fpcr **eagerly at context switch, for user threads only** (528B per
thread, zero-initialized at spawn so a fresh thread can never observe
another domain's vector registers). Kernel threads skip it entirely: the
kernel is compiled without FP/NEON features, so user vector registers
survive syscalls untouched in hardware, and the hand-written save/restore
stubs (admitted by `.arch_extension` in otherwise FP-free kernel text)
are the only vector instructions at EL1. Eager beats lazy here: no trap
choreography, no per-core owner tracking across migration, and the cost
(~a cacheline-friendly 1KB copy per user-thread switch) is noise at
moss's switch rates. Correctness is pinned by an adversarial probe in the
ipc test — both processes stamp all 32 registers with distinct patterns
around blocking syscalls and require bit-exact survival. Probe-writing
lesson: an inline-asm block that clobbers callee-saved v8-v15 inside a
non-inline function makes the compiler restore the *old* values right
after your asm (ABI-mandated epilogue) — the probe must be `inline` or
it corrupts itself and frames the kernel.

Because a fresh domain holds *nothing*, the empty sandbox is the zero value.
Sandboxing is not a mode; it is the absence of grants.

## IPC

**Message passing is the semantics; shared memory is a transport.** The
contract of a channel is self-contained messages plus explicitly granted
buffer caps — never an implied shared address space. A channel that crosses
the network (via a fabric proxy) is just a slower channel with identical
semantics.

Two transports, one contract:

1. **Sync fast path** — call/reply in registers, for RPC-shaped traffic. As
   built: four message words + one optional cap attachment per message; side
   A serves (recv/reply), side B calls; per-side refcounts close a side when
   its last cap dies. Cap transfer over messages is the buffer-grant
   mechanism — an shm cap granted in a call is how out-of-line data crosses.
2. **Async rings** — io_uring-style shared-memory submission/completion
   rings for bulk and streams, so services don't need a thread per request.
   As built (Phase 8): the ring is pure userspace over existing primitives —
   an shm grant holds the SQ/CQ pair (SPSC, acquire/release indices, defined
   in shared/ and host-tested), notifications are the doorbells, and
   notify_bind lets the server's blocked recv be interrupted by the
   submission bell, so one thread serves both transports. Entries carry the
   same typed message words as channels plus a correlation id — same
   semantics, different transport; the data plane costs no syscalls, only
   the doorbells do. Measured on virtio-blk at queue depth 8: ~6x the
   sync-channel throughput (19.5us vs 123us per 512B read under TCG; 7.9us
   per op under HVF).

**Failure is in the vocabulary.** Channel death is always observable: peers
receive a death notification and in-flight operations complete with a distinct
error. No protocol may assume a shared clock. Faults are messages delivered to
a supervisor-held cap — which is also the debugger interface.

**Typed protocols via comptime.** IPC protocols are Zig types in `shared/`;
marshaling and stubs are generated at comptime. No separate IDL compiler; the
ABI is type-checked from one source of truth that compiles identically for
kernel, userspace, host tests, and MCU leaf nodes.

**The interposition invariant.** Any cap can be silently replaced by a proxy
the holder cannot distinguish. Therefore **no kernel fast path may ever bypass
a channel** — the moment one service gets a kernel shortcut, filtering,
auditing, and virtualization stop being guarantees and become special cases.

## Init and supervision

Two layers. The **root task** receives all boot caps from the kernel and stays
tiny and near-finished: it starts the **init service**, supervises only it,
and retains enough caps to restart it. Init itself is an ordinary, restartable
process with no special kernel status.

Init is three small responsibilities on top of our primitives:

- **Capability wiring.** The sandbox manifest (typed Zig value: budgets + caps
  + restart policy) *is* the unit file. Dependencies are expressed as granted
  channels, never as ordering — the channel is the synchronization point, so
  boot-ordering bugs are unrepresentable.
- **Channel activation.** Init retains server ends and spawns services on
  first message: demand-start by default, boot time = time to first useful
  service.
- **Supervision, OTP-style.** Crash-only services; restart strategies with
  budgets and backoff; escalation on flapping. Restart = domain revoke +
  respawn from manifest, provably leak-free. Dependents observe channel death
  and re-wire through init. Supervisors nest with domains.

**Crash-only policy (in force since Phase 5):** every service must tolerate
being killed at any instant — no cleanup handlers, no shutdown handshakes,
no state that only survives a polite exit. Restart is the recovery path;
there is no graceful-shutdown protocol to get wrong. Clients hold up their
end: an in-flight call completing with peer_dead means the request may or
may not have been processed, so requests should be safe to resend (the
Phase 5 worker demonstrates the idiom: observe peer_dead, re-wire through
init, resend). Init itself and the root task are the only processes with
orderly exits, because they are the ones reporting system outcome.

**As built (Phase 5):** spawn authority is a `spawner` capability exercised
through sys_spawn against the kernel's embedded image table (a filesystem
replaces the table in Phase 9); a spawned domain is controlled through a
`domain_ctl` cap (stat/destroy — destroy is the one revocation). Deaths are
delivered to the spawner's registered death-watch notification, and a
notification bound to a thread (sys_watch_deaths) interrupts that thread's
blocked recv with Errno.interrupted — one thread can serve a channel and
supervise simultaneously, the seL4 bound-notification idea. A kernel reaper
finishes teardown of drained domains and fires the watch. Init keeps the
client end of every service channel it creates and hands out copies on
connect; a service's death closes the channel (init holds no serving-side
cap), so dependents learn of the death exactly the way any peer does.

## Drivers

Userspace, virtio-first. The driver interface is: MMIO-mapping caps,
IRQ-delivery-as-message, and explicit DMA grants shaped like an IOMMU is
present (identity-stubbed under QEMU until the SMMU lands). Drivers run under
manifests like any other process and are as sandboxable as anything else.

**As built (Phase 7):** an `mmio` cap names a physical window (mapped with
device attributes via mmio_map); an `irq` cap names an SPI range, and
irq_bind routes a line to a notification — delivery masks the line (level
sources must not storm) and irq_ack re-enables after the driver services
the device; dma_alloc returns contiguous zeroed pages with a VA and a
device address (== physical, but callers must treat it as opaque so the
SMMU can change the answer later). The virtio-blk driver speaks the modern
(version 2) virtio-mmio interface with a split virtqueue, probes the slots
its window covers, and serves a typed block protocol; bulk data crosses via
a client-granted shm buffer. QEMU note: virtio-mmio devices default to
force-legacy — run with `-global virtio-mmio.force-legacy=false` (run-blk
does).

## Filesystems and namespaces

Per-process namespaces are pure capability topology (Plan 9 in spirit): a
process's filesystem is the view caps it holds, nothing more, and there is
no path syntax for what lies outside a view.

### The system namespace

There is no global root in moss, so the "filesystem hierarchy" is two
conventions: what the root-of-trust view looks like, and which views are
granted to whom by default. Directories are organized by **lifecycle and
ownership**, never by file type — no /usr-vs-/bin archaeology, no /etc
dumping ground, no shared /tmp (a classic cross-service attack surface that
capability views make unrepresentable).

| Path | Lifecycle | Contents |
|---|---|---|
| `boot/` | immutable, from the boot image | system identity (`boot/etc/`) and boot-time config (`boot/conf/` — init's topology lives at `boot/conf/init.topology`); later: verified/signed |
| `img/` | immutable, content-addressed (future) | service and application images once they move out of the kernel's embedded table |
| `conf/` | admin-written, service-read | per-service configuration: `conf/<service>/...` |
| `state/` | service-owned, survives reboot | each service's private mutable state: `state/<service>/` |
| `data/` | user/application payload | the only tree where sharing between services is expected, always via explicit view grants |
| `volatile/` | cleared every boot | per-service scratch: `volatile/<service>/` — the FS service empties it at every mount |

Default grant policy — the hierarchy *is* the default cap topology: a
service named X conventionally receives `state/X` (rw), `volatile/X` (rw),
and `conf/X` (ro), each as a separate derived view. Services cannot see each
other's state not by discipline but by construction; anything in `data/` is
granted case by case. The root-of-trust view (init's) sees everything.

**As built (Phase 9):** channel caps can carry a *badge* (seL4-style),
minted only by the serving side (chan_mint) and delivered to recv with
every call — one channel serves many scoped clients with unforgeable
identity. A filesystem view is a badged cap into the FS service, whose
badge selects server-side {subtree root, read-only}; derive() mints
narrower views (readOnlyView is derive with ro set), and privilege only
ever shrinks — deriving rw from an ro view yields ro. Path resolution
starts at the view root and strictly descends ("." and ".." are rejected),
so escape is unpronounceable rather than forbidden. The FS service
(userspace) serves a union namespace: boot/ is a read-only MARC archive
granted at spawn (the boot image filesystem — init loads its typed topology
from it); everything else is mossfs on the virtio-blk driver.

### mossfs v2

**As built (mossfs v2):** the disk backend is a copy-on-write block tree
in the ZFS family — `user/mossfs.zig`, a pure std-only library written
against a 4K BlockDev vtable, with the service (`user/fs.zig`) riding the
blk driver's ring transport (flush goes over the sync channel; the reply
is the barrier ack).

- **Never update in place.** All state is reached from a superblock
  through `{addr, xxhash64}` block pointers; every read verifies its
  checksum, so corruption, bit rot, and misdirected or torn writes are
  *detected* — bad bits are never returned (a torn 4K write is 8
  non-atomic sectors: detection-only by design, CoW makes it harmless).
  A transaction group writes a complete new subtree, FLUSHes, writes one
  of 8 rotating superblock slots (full-slot checksum, embedded txg and
  slot index), FLUSHes again. Mount elects the highest-txg slot that
  fully verifies; a torn superblock just loses that slot. Crash = the
  last committed tree, always; there is no fsck because there is nothing
  to fix.
- **Objects, not inodes**: 128-byte dnodes (type, size, mtime, 3 direct +
  1 indirect pointer, level ≤ 4 → 16TB max file) live in the objmap,
  itself a CoW tree keyed by object id. `nlink` is reserved but always 1:
  hardlinks are deferred deliberately — a second dirent to the same
  object would defeat subtree-view exclusivity, and that wants its own
  design pass. Directories are packed 64B dirents (linear scan; hashed
  dirs are a format-versioned v3 option).
- **Symlinks** store their target verbatim and resolve *relative to the
  containing directory* under the same component rules as any path (no
  "..", no absolute targets, 8 follows max, stat/delete/readlink do not
  follow). A link that points outside a view fails at resolution — for
  every view — rather than being a hole.
- **Allocation groups** (format-time size; 128MB on real volumes) each
  own CoW bitmap blocks referenced from a group table with per-group free
  counts: mount reads nothing proportional to volume size, and commit
  cost tracks *dirty groups*, not the volume. Commit assigns addresses in
  a fixpoint (allocations dirty bitmaps, which need addresses; preferring
  already-dirty groups bounds it), then fills, checksums bottom-up, and
  writes. Blocks freed this txg are quarantined until the superblock
  lands.
- **Deletes are asynchronous**: delete/truncate detach whole subtrees
  onto a persisted deleting-set object and return; each later txg drains
  a bounded slice, and mount resumes draining — a TB-scale delete cannot
  stall a commit, and crashing mid-delete is handled for free. `sync`
  drains fully, then commits.
- **Durability is batched**: ops are acknowledged in memory and committed
  in groups (between ops only, never inside one); `FsReq.sync` is the
  explicit barrier. A crash loses recent unsynced acks, never structure.
  (Run QEMU disks with default writeback cache — never `cache=unsafe`,
  which drops the FLUSH barriers the design depends on.)

The protocol grew delete, rename (atomic within a txg; directory moves
across parents are refused pending an ancestry walk), truncate, stat,
symlink/readlink, O_EXCL create, and sync; `volatile/` is emptied at every
mount. Deleting an object invalidates any fd or derived view rooted at it.

Lessons paid for (both found by the host harness, neither by inspection):
an allocation bitmap block can cover more bits than its group owns — the
scan must stop at the group boundary or it silently allocates another
group's blocks; and a block cache must never hold two entries for one
address — freed blocks legitimately re-read during a commit re-enter the
cache, and when a later txg reuses that address, hits can return the stale
entry (cache hits skip checksum verification, so nothing catches it). The
symptom was spectacular: a directory dnode whose size read as 5.7×10¹⁸.

The core is host-testable by construction: the same file runs under
`zig build test` with a RAM BlockDev doing write-sequence recording, crash
injection (a cut after every write, plus torn final writes), corruption
flips, superblock-election checks, and a randomized op sequence mirrored
against an in-memory model. Persistence is proven in QEMU by the fs
check's double-run on one disk image.

### mossfs v3: compression and encryption

**As built (mossfs v3):** a format rev on v2 (no migration; disks
reformat), adding per-block compression and FS-native encryption. The
first consumers of the locked code-sharing model: `lib/lz4.zig` and
`lib/xts.zig` are pure, freestanding-safe static modules, host-tested
against OpenSSL-generated vectors and interop-checked both directions
against the reference LZ4.

- **Sector-granular, byte-aligned allocation.** A `BlockPtr` packs
  `[flags u8 | psize u8 | sector u48]` + 8-byte csum; the bitmap bit is
  now a 512B sector. Allocation policy: metadata and raw data take one
  full free bitmap *byte* (8 aligned sectors); compressed runs (1..7
  sectors) pack inside a single byte and never cross byte boundaries.
  The per-group free counter counts free **bytes** — an exact lower bound
  on full-block capacity — so compressed-run fragmentation can never
  invisibly starve a commit, and the ENOSPC reserve keeps its guarantee.
  Frees and the quarantine are range-aware (overlap-checked): a freed
  5-sector run and a fresh 3-sector allocation must never intersect.
- **Compression** (LZ4, data blocks only — file, dir, and symlink
  content; indirect blocks are pointer+MAC soup and stay raw): a 4K block
  is stored compressed only when that saves at least one sector. The
  csum/MAC covers the *stored* plaintext form, so verification always
  precedes decoding; the decoder is additionally output-driven and fully
  bounds-checked (LZ4 is not self-terminating, and stored runs carry
  sector padding — the decoder stops at 4096 output bytes and ignores
  trailing pad).
- **Encryption** (AES-256-XTS per 512B sector, tweak = absolute physical
  sector — the dm-crypt convention; CoW rewrites land at fresh sectors).
  Encrypted classes: object data, indirect blocks, the objmap.
  Plaintext classes: superblocks, group table, bitmaps — so mount and
  allocation work keyless, while every object op (and all background
  work: deleting-set drain, commits, fssvc's volatile-clearing) is gated
  on the key. Encrypted blocks use SipHash-2-4-64 keyed MACs as their
  pointer csums, so a plaintext parent (the SB's objmap-root pointer)
  leaks no plaintext digest. Compress, then encrypt.
- **Key flow**: 256-bit master key → HKDF-SHA256 → XTS key pair + block
  MAC key + SB MAC key. The key arrives capability-shaped: badge-0-only
  `FsReq.set_key` (32 bytes through the view buffer, zeroized after
  reading) before `FsReq.attach_disk`. On encrypted volumes each SB slot
  carries a keyed MAC over the slot; slot election stays keyless
  (xxhash), and `setKey` verifies the elected slot's MAC — a wrong key
  fails there, immediately and cleanly, and an at-rest attacker who
  splices old-but-individually-valid pointers into a superblock is
  caught at the same check. **Security invariant: every pointer is
  protected by a MAC'd parent rooted at the MAC'd superblock** — the
  per-block MAC does not (and need not) bind sector identity; do not
  break the chain when "optimizing" the SB.
- **Auto-format is guarded**: a mount failure formats only a genuinely
  blank disk (all-zero SB region). Garbage, wrong-format, or
  wrong-version disks are never wiped — fssvc logs loudly and serves
  bootfs only, leaving the disk for the operator.
- **Documented residuals** (honesty section): rolling back ≤8 txgs by
  zeroing newer SB slots is undetectable without external anti-rollback
  state, as is whole-disk replay; MAC tags are 64-bit (the format
  constraint — upgrade path is a wider BlockPtr in a future rev);
  plaintext bitmaps/group table leak volume fill and churn patterns;
  AES is the software implementation until FP/SIMD context switching
  lands (ROADMAP), and XTS is tamper-*evident* (with the MAC), not AEAD.

The read cache is keyed by masked sector address and holds the logical 4K
plaintext, inserted only after MAC verification — cache hits may skip
verification precisely because inserts never bypass it (the v2
duplicate-entry lesson, restated for packed pointers). The host harness
runs the crash-injection sweep and the randomized model test on both
plaintext and encrypted volumes, plus: wrong-key and SB-splice rejection,
ciphertext-flip fail-closed, compression space accounting, and
hostile-input decoder fuzzing; the OS fs-test runs on an
encrypted+compressed volume end to end, and the disk image was verified
to contain no plaintext (content or names).

### Performance baselines (v3, 2026-09-01, M3 Max)

`zig build bench` (native, hardware AES) and `zig build bench-soft` (AES
feature stripped ≈ today's no-NEON moss userspace) measure primitives and
the core over a RAM device (ReleaseFast, 4K blocks, 8MB file); the fs
check's alice logs whole-stack numbers (IPC + fssvc + mossfs + ring +
blkdrv + virtio, 2KB chunks, 512KB, encrypted volume).

| Primitive (4K blocks) | hw AES | soft AES |
|---|---|---|
| xxhash64 | 7.9 GB/s | 7.0 GB/s |
| SipHash-2-4 MAC | 1.2 GB/s | 1.2 GB/s |
| **AES-256-XTS encrypt / decrypt** (8-wide) | **2.32 / 2.49 GB/s** | **0.12 / 0.13 GB/s** |
| LZ4 compress text / random | 2.3 / 1.2 GB/s | 3.0 / 1.3 GB/s |
| LZ4 decompress text | 5.7 GB/s | 7.1 GB/s |

(The original serial XTS measured 1.48/1.58 GB/s hw; running the AES
cores 8-wide over XTS's independent blocks plus word-wise GF doubling
brought it to 2.3/2.5.)

| mossfs core (RAM dev), write+sync / read | hw AES | soft AES |
|---|---|---|
| plain, compressible | 1421 / 3333 MB/s | 1482 / 3548 MB/s |
| plain, random | 789 / 4946 MB/s | 777 / 4864 MB/s |
| encrypted, compressible | 1187 / 2557 MB/s | 435 / 688 MB/s |
| encrypted, random | 476 / 893 MB/s | **93 / 110 MB/s** |

Whole-stack (encrypted volume, alice's bench through IPC + fssvc +
mossfs + ring + blkdrv + virtio), the full progression on HVF (w/r MB/s,
incompressible / compressible):

| stage | raw | comp |
|---|---|---|
| v3 as first landed (soft AES, Debug userspace, 2KB ops) | 3.6 / 4.1 | 9.6 / 11.2 |
| + hardware AES (FP/SIMD enablement) | 13.4 / 18.6 | 20.6 / 28.4 |
| + transport & build work (below) | **128 / 264** | **275 / 385** |

Even TCG (pure emulation) now reaches 38/54 raw and 44/66 comp. The
transport & build work, in order of what the digging found:

- **Userspace was running Debug.** The single biggest factor (~5x): the
  crypto and FS hot paths live in userspace, and the OS build never got
  an optimize flag. User programs now default to **ReleaseSafe** (every
  bounds/overflow check retained; `-Duser-optimize` overrides), while
  the kernel stays on `-Doptimize`. Fallout fixed en route: ReleaseSafe
  emits `.eh_frame` sections that spilled past the accounted load image
  (discarded in user.ld — the spawn header check caught it as BadImage),
  and deeper inlining of the commit recursion's 4K frames needed 96KB
  user stacks.
- **32K protocol ops**: view buffers are 8 pages (`shm_map` now reports
  the mapped size so services bound IO by the real window) and one
  read/write moves up to 32KB — 16x fewer IPC round trips, and
  block-aligned full writes skip the read-modify-write entirely (a
  `full` flag on the overlay claim skips fetching + decrypting the
  committed block).
- **Coalesced, pipelined block writes**: the blk protocol takes
  64-sector (32K) requests into per-slot 32K driver DMA regions; fssvc
  merges the allocator's mostly-sequential runs into open 32K staging
  slots and keeps up to 7 requests in flight. This is sound because of a
  core invariant now load-bearing: **mossfs orders writes only at
  dev.flush() and never reads back a sector written since the last
  flush except through its cache** — writes between barriers may
  complete in any order.
- **32K readahead** on the read side (slot 0 of the window): sequential
  file reads get the next 7 blocks free; a write overlapping the
  readahead range invalidates it.
- **Commit threshold 96 -> 144 dirty blocks**, so a 512KB stream is one
  txg (one flush pair, not two).
- Ruled out empirically: host fsync behind virtio FLUSH (`cache=unsafe`
  changed nothing — QEMU absorbs flushes for this image cheaply).

Remaining headroom, in likely order: the Debug kernel's syscall/IPC
paths, per-block XTS/MAC call overheads in fssvc's single thread, and
read pipelining beyond one readahead window.

## Networking

**As built (Phase 10):** the net service is one userspace process holding
the virtio-net driver and a deliberately tiny dual-stack TCP/IP: ARP (v4)
and NDP/ICMPv6 (v6) resolve the slirp gateways at startup; TCP is
stop-and-wait (one unacked segment per socket), in-order receive, fixed
windows, no options — enough for the fabric protocol, not an RFC museum.
The ABI is IPv6-native: addresses are always 128 bits (two words), IPv4
rides v4-mapped, and there is no v4-only path to fossilize. Local
destinations (own addresses, ::1, 127/8) short-circuit through the stack,
so same-node processes speak real TCP without touching the wire. Network
access is a badged view (same idiom as filesystems): filtered views carry a
one-destination outbound allowlist and may not listen, ping, or derive —
allowlist-shaped network access as the sandbox default. Blocking ops are
polled (would_block); rings are the future wakeup path. Lessons paid for:
on loopback, emit-is-synchronous means all TCP bookkeeping must precede
emission; virtio config space must be read at aligned offsets; and severing
an IRQ binding must also mask the line or a level-triggered device storms
into the void.

## Distribution: the fabric

**No single system image.** Sprite/MOSIX/OpenSSI-style transparency fails on
physics: latency and partial failure must be legible to software. Moss ships
explicit-but-ergonomic distribution instead: cap delegation across nodes,
remote channels, remote spawn.

Each node runs a userspace **fabric service**: membership, channel proxying,
remote spawn. A unit file, a sandbox manifest, and a remote-spawn request are
the same artifact — the fabric is init at a larger radius, adding placement
and cap proxying. Membership/consensus/discovery live in userspace where they
can iterate without touching the kernel.

MCU-class devices (no MMU) never run the kernel; they run a tiny leaf-node
runtime speaking Moss protocols over serial/USB/network and appear in the pool
as typed channels.

**As built (Phase 11, fabric v0):** each node's fabric service serves one
channel; peers speak a versioned wire protocol over TCP (frames
[len][type][ver], hello/spawn/call), membership is a static table (node N =
10.77.0.N on a private segment, cluster netsvc mode). A *remote channel* is
a badged cap on the local fabric service: badged calls forward verbatim as
call_req frames and return the peer's reply words — the same four typed
message words that cross local channels, so remote services are
indistinguishable to callers (the remote-echo server literally runs
unmodified CalcRequest-serving code). Remote spawn ships {image, arg} to
the peer, which spawns under a local manifest and proxies the child's
channel back. Peer death surfaces as an error-sentinel reply on in-flight
calls (fabric error codes; the drill kills a node via PSCI SYSTEM_OFF
mid-RPC and the survivor recovers). v0 honesty notes: one outstanding wire
exchange at a time, no cap transfer across nodes beyond spawn-time grants,
polling-driven pumping (the node driver ticks the fabric), and death is an
error reply rather than a full channel-death notification — each a known
evolution point, none an ABI change.

## Security posture

- W^X unconditional, NX everywhere, separate address spaces per domain,
  kernel/user page-table hygiene from the start.
- No ambient authority anywhere; all power arrives via manifests.
- **Side-channel honesty:** capabilities stop architectural leaks, not
  microarchitectural ones. Stance: per-domain address spaces, no cross-domain
  SMT sharing, and seL4-style time partitioning as a later opt-in for
  sensitive domains. We do not claim caps fix Spectre.

## Platform and boot

First target: aarch64 on QEMU `virt` (GICv3, generic timer, PSCI, virtio),
chosen because Hypervisor.framework makes the edit-compile-boot loop
near-native on the Apple Silicon dev machine and the platform has essentially
zero legacy. The HAL boundary is kept honest for a later x86_64 (UEFI-era
only) port.

Boot contract (Phase 0): the bootable artifact is a raw arm64 Image (Linux
boot protocol) objcopy'd from the kernel ELF, which is kept for symbols and
debugging. The 64-byte Image header in `kernel/boot.zig` requests loading at
RAM base + `0x80000` (the link address, `0x40080000`); QEMU honors the
protocol by placing the DTB in RAM (observed at `0x48000000`) and passing its
physical address in `x0`, entering with MMU/caches off. QEMU `virt` provides
*no* DTB for plain ELF loads — that is why the Image header exists. Only core
0 runs at boot (secondaries arrive via PSCI in Phase 2).

The kernel links in the high half (39-bit VAs; TTBR1 space at
`0xffffff8000000000`, direct map virt = phys + that offset — see
`kernel/mem.zig`). The boot assembly parks non-zero cores, clears BSS, builds
one coarse L1 table (1GB blocks; shared by TTBR0-identity and TTBR1 since
both index identically), enables the MMU, and jumps to `kmain` high. `kmain`
then rebuilds TTBR1 from the devicetree's memory map with 4K-granular W^X
over the kernel image and disables TTBR0 walks (TCR.EPD0), dropping the
identity map.

## Zig conventions

- Version pinned in `build.zig.zon`; bumps are deliberate, standalone commits.
- `build.zig` is the entire build: kernel, userspace, images, QEMU targets.
- Kernel code avoids FP/SIMD (enforced by disabled target features): CPACR
  resets with FP trapped and trap handlers won't save vector state.
- All Zig code runs with the MMU on: boot.zig enables it (coarse map) before
  jumping to kmain, so compiled code never touches Device-typed memory where
  unaligned accesses fault. Pre-MMU work is confined to the hand-written,
  aligned assembly in boot.zig — keep it that way, or bring `strict_align`
  back.
- `shared/` may not import kernel or userspace code and may not allocate; it
  must compile for every target including `thumb-freestanding` leaf nodes.
- Kernel code allocates only through the quota-accounted kernel allocator —
  no hidden allocation, no global general-purpose heap.
- Assembly may only call `export`/`callconv(.c)` functions, never a
  Zig-calling-convention function or function pointer: Zig's unspecified
  convention is free to add hidden parameters (and does, in Debug builds —
  an error-trace pointer in x0). The thread trampoline learned this the hard
  way; entry points reached from asm go through C-ABI shims like
  `schedThreadRun`.
