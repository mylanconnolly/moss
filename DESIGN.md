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
are W^X and non-global. Kernel access to user memory goes through one
door, `kernel/arch/aarch64/uaccess.zig`: every syscall range-checks the pointer
against the domain's image, stack and shm window, then copies through a
window that is the only place the hardware is told to allow it — PAN
(ARMv8.1+, detected at boot from ID_AA64MMFR1_EL1, armed on every core
and by every exception entry) makes any other privileged touch of a
user page a fault report rather than a read or write on the caller's
behalf; on an ARMv8.0 CPU the window is a no-op and the range checks
stand alone, as they always did. The `pan` drill touches a
range-checked, mapped user byte with the window closed and expects the
refusal. The same boundary is where x86_64's SMAP will go. Syscall ABI: x8 = number, x0..x5 args, x0 = result — numbers and
errnos defined in `shared/` like everything else that crosses the boundary.

### Locking (as built, 2026-09-02)

The kernel started under one big lock shared by the scheduler and IPC —
the structures were per-core from day one, the serialization was not.
Now every core's run queue has its own lock, every thread its own,
sleepers theirs, and each channel and notification theirs; slot
allocation for the object tables, timers, IRQ bindings, shm and the
thread table are leaves. The discipline that makes this sound:

- A thread's state is protected by the run-queue lock of the core it is
  queued on or running on, and by its own lock while blocked or sleeping.
  Anyone else who wants to change it (a waker, teardown, a bound
  notification's interrupt) takes the thread lock first to discover
  which, then that lock, and re-verifies. Lock order, outer to inner:
  notification → channel → thread → run queue → sleepers.
- Blocking is a handshake: `sched.block(list, slot, obj_lock, outer)` marks the
  thread blocked under thread + run-queue locks, then releases the object
  lock, then switches. A waker can therefore find the thread the instant
  it is parked, but never before it is committed to leaving — no lost
  wakeups, no double enqueue. The thread carries `block_lock` (the object
  it waits on) so teardown can unlink it in order.
- A thread being switched away from carries `switching` until the other
  side of the switch (`finishSwitch`, run by the incoming thread) clears
  it; whoever dequeues or frees a thread waits for that first, so a
  thread woken on core B while still saving registers on core A is never
  run — or reaped — early. `schedule()` is entered with the run-queue
  lock held and always returns with it released, either directly or via
  `finishSwitch`.
- Preemption puts the running thread back on the *local* queue; migration
  happens on wakeups, where the target core's lock is taken in order.
- Teardown (`destroyThreadsOf`) peeks without locks, locks in order,
  verifies, and retries anything caught mid-transition (a thread between
  queue and core, a stale object lock). A running thread is only marked;
  its core reaps it at the next switch.
- The tick and IRQ delivery collect their targets under the timers / IRQ
  lock and signal after releasing it, because notification teardown
  takes those locks the other way round. A signal that lands on a
  notification freed in that window is dropped by `signal` itself.
- Freed objects keep their lock word (`.{ .lock = x.lock }`) so the
  freer's own unlock, and a late unlock by a racing peek, cannot clobber
  a fresh owner.

**Measured** (ipc test's built-in call/reply benchmark: one server+client
pair per core, pairs pinned, 60k round trips each, M3 Max):

| | 1 core | 3 cores | scaling |
|---|---|---|---|
| TCG, big lock | 302–308 kops/s | 435–436 kops/s | 1.4x |
| TCG, split locks | 200–245 kops/s | 672–734 kops/s | 2.9–3.5x |
| HVF, big lock | 1.6–2.4 Mops/s | 3.1–3.2 Mops/s | 1.3–1.8x |
| HVF, split locks, no padding | 2.1–2.4 Mops/s | 4.1–4.5 Mops/s | 1.8–1.9x |
| HVF, split + cache-line padding | 1.7–2.2 Mops/s | 5.0–7.1 Mops/s | 2.5–3.5x |

Four lessons bought here. First, the initial benchmark reported a
perfect 3.0x *under the big lock* — because 4000 rounds finished inside
one 100ms tick and the driver's wait loop slept in ticks, so it measured
the tick, not the IPC. Every client now stamps its own finish with the
cycle counter, and runs last long enough to matter. Second, splitting the
lock bought HVF only 1.8x until `PerCpu`, `Channel` and `Notification`
were padded to a cache line: adjacent per-core structs shared lines, and
the lock traffic of one core evicted its neighbour's. TCG's single-core
number dips (each extra atomic is a helper call there); real hardware's
does not. Third — caught by the fabric drill on the first soak run, as a
kernel instruction abort with PC pointing into a thread stack — the
first cut raised `switching` inside `schedule()`, i.e. *after* `block()`
had released the object lock. A waker on another core could see the
thread blocked, enqueue it, and have its core pop and run it while the
original core had not yet saved its registers: the thread resumed with a
garbage context and returned into its own stack. The flag now goes up
before the thread is published as blocked or asleep, and the two
"never actually left" paths in `schedule()` take it down. Under the big
lock this ordering was free; it is the one thing a fine-grained
scheduler has to get right by hand. Fourth — a 1-in-80 hang of the fs
drill's second boot, init never seeing alice's death — the supervisor
pattern (a notification bound to a thread that serves a channel) has
two steps in recv: peek the latched bits, then park. Under the big lock
they were one atomic step against `signal`; split, a death signaled
between them found the thread neither aware nor yet blocked, and the
bits sat latched behind a recv that would never return. recv now holds
the bound notification's lock from the peek until `sched.block` has
published the thread (block takes an optional outer lock to release),
so a signal lands either before the peek or after the park. Rule of
thumb from both: whatever a waker checks must be published under the
lock the waker holds, before the sleeper lets go of it. The "no logging
under the big lock" rule is now "no logging under any scheduler or IPC
lock".

A fifth, bought by client-death reporting (2026-09-03): a running
thread's state belongs to its core's run-queue lock, so `destroyOne`'s
guard (under the thread lock) can read `running` and its switch, a few
instructions later, find `exited` — or `unused`, the slot already
reaped and recycled — because the thread called `exit()` on its own
core in between. That arm was `unreachable`, and it fired once the
session manager's logout made it likely: dropping the home service's
last channel cap and destroying its domain in the same breath, against
a service that was already awake collecting its dead clients and so
reached `peer_dead` → `exit` at the same instant. Now the arm returns
"not freed" (the exiting core reaps and counts it), and `destroy`
claims a domain with one compare-and-swap, so a domain exiting on its
own core and a holder revoking it on another can never both walk its
threads and cap table.

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

**The third budget: CPU (as built, 2026-09-02).** Every domain carries a
`CpuAccount` beside its two memory accounts, chained to its parent's the
same way. The scheduler charges it from the cycle counter whenever a
thread of the domain is switched away and at every tick while one runs
(so a long run shows before it ends), walking the chain so a parent's
limit bounds its subtree. A limit is permille of one core per period —
1000 is a core, 4000 the whole machine, 0 no limit of its own — and the
period is ten ticks (1s). When any account in a thread's chain has spent
its limit, the scheduler parks the thread on its core's throttled list
instead of running it (at pick, and when a running thread is preempted
or ticks over); the timekeeper's period reset returns every parked
thread to its queue. Enforcement is tick-grained — a thread per core can
run one whole tick past the limit — so an overrun is carried into the
next period as debt, and the long-run average converges on the limit:
the drill's quarter-core domain of two spinners averages 279‰ with
single periods swinging to 365‰. The budget is a cap, not a guarantee;
a guarantee would need priorities the design has not asked for.

**Partitions (the time-partitioning opt-in).** A manifest may name a
core mask reserved for the domain alone: its threads carry the mask and
are placed only there; nothing else is placed on a reserved core, and a
second reservation of the same core is refused (`CoresBusy`). Core 0
cannot be reserved — it is the timekeeper's and the kernel's own. What a
partition does not remove is the tick interrupt on that core and the
core's share of caches with its neighbours: caps do not fix
microarchitecture, and the honest claim is "no other domain's code runs
on this core", which the drill checks by sampling every core every tick
for three periods (35 of 35 samples of core 3 ran the island; it never
ran elsewhere). One lesson: a preempted thread went back onto its core's
*local* queue, so the reservation only governed fresh placements and a
kernel thread that happened to be on core 3 squatted there; the pick and
the preempt path now evict a thread that may no longer be placed on the
core, and the core's next tick re-places it under the thread's own lock.
Unit files say `budget: { cpu: 250 }` (or `"25%"`) and `cores: [3]`;
`ps` shows last period's spend and the limit.

A lesson recorded in code: a notification bound to a thread must have its
latched bits checked *inside recv before blocking* — the interrupt-on-signal
path alone loses signals that arrive while the supervisor is busy between
recvs (the classic lost wakeup). Init also refuses to hand out a channel to
an instance it can see is already dead, closing the window where a death is
signaled but not yet processed. And its sibling (found by the Phase 8
benchmark): consumers of a bound notification must drain it with notify_wait
after every interrupted recv, or the latched bits make every future recv
return interrupted.

A teardown lesson bought by an intermittent hang (the shell arc's check
caught it at ~1-in-3): destroyThreadsOf marks a RUNNING thread exited and
nudges its core — but that thread may concurrently be entering sleep() or
an IPC block on another core, and blindly setting .sleeping/.blocked there
overwrote the death mark, resurrecting the thread into the sleepers list
or a wait queue so its domain never drained. Every voluntary state
transition now checks for a pending kill under its locks and dies
instead of parking. The race was as old as SMP teardown itself; today's
faster userspace merely widened the window until a 45-second suite could
hit it.

A second teardown race, from the same SMP shape, cost the `users` drill
its leak bar about one run in eight (2026-09-05). `destroy` marks a
thread on another core to die — it finishes the syscall in hand and
dies at the next safe point — then walks and releases the cap table.
A thread finishing `shm_create` in that window allocates the buffer and
inserts its cap *after* the walk, into a table `finishTeardown` then
freed without a second look: the buffer's ref orphaned, held by no
domain and no mapping, 8 pages (32 KB) that never came back. The fix is
a backstop: `finishTeardown` releases whatever caps remain before it
frees the table, and by then every thread is truly dead (`drained`), so
nothing can insert again — it catches exactly the stragglers, for any
cap-inserting syscall, not just this one. The buffer with one reference
and no owner in the shutdown dump was the tell; a trace ring widened to
catch the failing lifecycle showed the create with no matching insert.

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

**The loader (as built):** the kernel holds no image table and no paths.
`spawn` names an image by an **shm capability** the caller has staged it
into, and the loader is a page-by-page copy from that buffer into fresh
pages — the same routine the kernel's own boot drivers use with a byte
slice out of the boot archive (`ImageSource` is a two-way union; static
linking makes a copy the entire loader). Images are self-describing: the
MOSS header carries the program's name (written by each program's entry
stanza), which becomes the child's domain name and which the staging
side checks against the catalog entry, so a mislabeled archive is
refused rather than run. The archive itself — packed at build time by
`tools/mkmarc` from every program image plus `etc/` and `conf/` — is the
one blob the kernel embeds; at boot it is copied once into page-aligned
contiguous frames, and a `grant_bootfs` manifest maps those frames
**shared and read-only** into the holder (no copy, no user-memory
charge, unowned so teardown leaves them). Spawners stage through one
reusable 256K buffer (`user/loader.zig`): the kernel's copy is complete
when spawn returns, so the buffer is free again immediately, and no
per-spawn map/unmap churn exists. Budgets: staged pages sit in the shm
account, not the child's; the child's image pages are charged to the
child, whose budget is a slice of the spawner's — so init's and the
fabric's slices bound the programs they start, as intended.

Lessons paid for: (1) objcopy trims trailing zero padding, so an archive
image is usually shorter than its header's load_size — the missing tail
is zeros, not an error. (2) A domain could drop an shm cap it still had
mapped, and the object's last ref freed frames that stayed mapped in
that domain: a use-after-free waiting for the first stage-and-drop
pattern. Mappings hold a ref on the object for as long as they exist —
originally until teardown, with no unmap and no VA reuse, so services
kept one buffer per purpose. **Unmap (2026-09-03):** `shm_unmap(va)`
undoes an `shm_map`. The domain's window is a table of mappings
(buffers, the archive, DMA and device frames; 64 entries, first-fit
placement so a freed range is reused and page-table pages are not
burnt by a service that maps a buffer per client). Order matters:
the entry leaves the table first, so no new kernel copy can be aimed
at it; copies in flight are waited out (`uaccess_users`, pinned by
every syscall that copies, incremented before its range check); then
the pages are unmapped with the ASID's TLB and SMMU entries retired
on every core; only then is the mapping's ref released, so a frame
is never freed while anything still maps it. One more rule, bought
by the new ReleaseSafe gate row on its first day, before kills learned
to wait for a safe point (see "Users and sessions"): the window table
must tell teardown the truth at every instant, so a thread reaped
between two steps of a map or unmap leaves nothing ambiguous. Each buffer mapping carries a state — `reserved` (pages
going in, no ref yet), `live`, `unmapping` (pages going out, ref still
held) — and the ref changes hands only under the window lock with
IRQs masked, where no reap can land between the two steps. The first
cut removed the entry, did the work, then dropped the ref; a home
filesystem service reaped between those steps (the session manager
destroys it the moment the session ends, while it is still collecting
the session's dead views) left one buffer with a ref nobody held, and
`users+rs` failed its leak bar once in about ten runs.

The same row then hung — and the hang watchdog the gate gained that
day (60s without shutdown: every thread, domain and IRQ line dumped,
then a panic) named it: the session manager sleeping in its poll of a
dead session's `domain_stat`, the drill parked in its `wait` call, and
no session domain anywhere in the list. A domain slot in state `dead`
was reusable by the next spawn while a ctl cap still pointed at it, so
the manager was polling bob's home service, alive, under alice's
handle. Debug timing had always let the poll win the race; the
optimized kernel let alice finish before bob spawned. Slots are now
free only once `unused`, which a dead domain becomes when its last ctl
ref drops (or at teardown, if none is held), under a slot lock — and
allocation itself is under that lock, which it never was.

Then a third hang, in the Debug row, on the first run after a build
(a fresh disk image shifts the boot's timing), and this one needed a
better tool than a dump of the end state: `kernel/trace.zig`, a ring
of lifecycle events (spawn, destroy, the reaper's signal, domain_stat,
every notification signal and which path it took) recorded without
locks or logging and printed only by the hang watchdog. Logging in a
race's window moves the race — forty instrumented runs never hung —
and the ring does not. It showed the reaper signaling "useradmin's
death" *at the tick useradmin was spawned*: the reaper finished the
dead pcisvc's teardown, which freed its slot; init's spawn took that
slot and installed its watcher; the reaper, resuming, read `d.watcher`
after the teardown, signaled it, nulled it, and dropped its ref —
stealing the new domain's death watch. When useradmin really died,
nobody heard. The reaper now takes everything it needs before the
teardown and never touches the slot after; and only a domain that ever
had a ctl cap recycles its slot — one the kernel's own drivers spawned
has none and stays dead, so its state and exit code remain theirs to
read (the first cut recycled those too, and six kernel drills stopped
seeing their children die).

The same afternoon closed three more teardown truths. A running
thread marked dead by another core used to be reaped at its next
preemption, which the IRQ path takes in kernel mode too — so a thread
could be switched out and freed *in the middle of a syscall*, leaking
whatever that syscall held between allocating and publishing it (a
session logged out the instant after logging in leaked its fresh view
buffer that way, one ref, nobody's). A kill is now `kill_pending`,
honored only at a safe point: syscall exit, an interrupt from user
mode, or the moment the thread tries to block or sleep — never inside
kernel work; a thread found preempted mid-syscall is left on its queue
to finish. One consequence needed its own fix: a killed thread that
reaches `block` now dies there routinely, and that path had never
released the cap in its mailbox — a call's attachment nobody received
— so a session logged out while attaching its buffer left the buffer
one ref nobody held. `block`'s death releases the mailbox first, with
every lock dropped (a cap release may take a channel lock, which comes
before the run-queue lock). And the last window closed by design
rather than by a failure: when a domain is revoked from another core,
its running threads die at their safe points while the revoker is
still walking the cap table, and the last death drains the domain —
so the reaper could reclaim the table under the revoker. `drained`
now also requires nobody to be inside `destroy` (a `destroying` flag
held for its duration), and `finishTeardown` panics if it ever finds
one there. Self-exit was never exposed: the exiting thread is reaped
only after its own `destroy` returns. A dying sleeper caught in the tick's hand is *reaped*, not
merely freed, so its domain's thread count reaches zero. And
`destroyOne` returns "not freed" for a thread that exited on its own
core between its guard and its switch (above). The range checks that
gate kernel copies now consult the table — a hole in the window is a
`fault`, not a kernel data abort the caller provoked. Services unmap
a dead client's buffer (client_dead, above) and a re-attached view's
old one, and drop the shm cap handle once mapped (the mapping keeps
its own ref; the handle only ate a cap slot). The fs drill's `churn`
step runs a hundred clients through one domain — more than the shm
pool, the window table or fssvc's view table hold — unmapping and
dropping as it goes, checks that the kernel refuses to copy through
the hole and refuses a second unmap, then exits holding two dozen;
`churn2` opens two dozen more at once, which the view table fits only
because the dead client's went. With reclamation disabled the drill
fails at the first churn step (exit 180: the view table full).
(3) netsvc's listener kept a single pending connection; a second SYN
before accept overwrote it, orphaning an *established* socket whose data
the server would never read while the client saw every send succeed.
The fabric drill hit this when the imposter's redials landed in node 3's
join window: node 3's first dial timed out, its redial joined, and its
spawn request went out on the stale first socket — a five-second
timeout with nothing logged anywhere. Listeners now keep a FIFO backlog
(a SYN past it is dropped for the client's retransmit to retry), and the
fabric closes a half-open attempt before dialing the same node again;
RPC only ever travels on an authenticated peer.

**Programs as files (as built):** `img/` on the volume is content-
addressed — a program lives at `img/<digest>`, and its manifest beside
it, `img/<name>.msh`, names the digest and what the program is handed
(`{ image: "<digest>", grant: [..], give: [..] }`, built by init from
the program's unit file) — so an image can never change under its name,
identical images are one file, and a loader verifies what it staged
before it spawns. Init is the installer (at the shell boot it receives a
view of `img/` alone and writes what is missing); fssvc knows nothing
about programs; msh only reads. `run NAME [path]` in msh reads the image
through msh's own view into its stage, checks the digest, spawns a fresh
domain, and feeds it its world over a boot channel — the console
(channel + the byte buffer msh already shares with the driver, so the
tool writes where msh writes and msh waits silently), an optional view,
argument text — then `go`. What a program is handed is decided by its
kind: `ps` gets the **introspect** capability (a new cap type carrying
domain_list/sysinfo without spawn authority — the ledger, not the power
to change it; a spawner cap still implies it), `ls` gets a read-only
view whose root is the requested path. That is the point of running
them as programs rather than builtins: each holds exactly what it needs
and could not reach anything else if it tried, and the shell script
proves it on every check. msh keeps its builtins (it holds a spawner
anyway); the tool table in msh is the manifest for now — a manifest
file beside each image is the evolution.

Lesson paid for by `zig build run-shell` on a volume from before `img/`
existed: the root's children ARE the hierarchy — fssvc refuses to create
or remove top-level names through the protocol, from any view, by
design — so a tier added after a volume was formatted can only be added
by fssvc itself. Mount now upgrades an existing volume by creating any
missing standard tier (logged), the installer runs through init's root
view (the one view that sees everything, by design), and the boot
driver's image-store setup reports a typed error and carries on instead
of asserting: an old disk must never cost the console.

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
   **Deferred replies (as built):** a server may recv again before
   replying — up to eight callers sit in a channel's pending slots, and
   recv returns a token (slot + serial) that reply names; token 0 answers
   the oldest, which is what one-at-a-time servers keep doing. A proxy
   can therefore hold many exchanges open while its loop runs on. **A
   timer is a notification** (timer_arm: a period and the bits to
   signal), delivered on the same path as an IRQ, so a serving thread's
   recv is interrupted on time and nothing needs to be polled by whoever
   spawned it. **Threads (as built):** a domain may create more threads
   (thread_create: entry, two registers, a stack from its own memory;
   thread_exit ends just that thread) sharing its cap table and counted
   in its teardown; a service that must make blocking calls on others'
   behalf runs them on workers so its serve thread never stalls.
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

**Lesson paid for (in-transit caps, 2026-09-03):** a cap attached to a
call lives in the caller's thread mailbox until a server's recv copies
it out, and its ref was released only by that receiver's delivery. Two
paths skipped delivery: a client torn down while parked in a caller
queue (the session manager exiting while a console thread's `setup`
call, buffer attached, waited on a driver still busy with a dead
shell), and a call completed with `peer_dead` before anyone received
it. Each leaked exactly one shared-buffer page, and only when shutdown
timing lined up — the login drill failed its leak bar three runs in
four, then passed seven in a row after an unrelated edit. Now recv
clears the caller's mailbox cap as it copies it (the ref rides the
message), `call` hands the mailbox's cap back with the result whether
the reply came or the peer died (the syscall delivers or drops it), and
thread teardown releases whatever is still in the mailbox. The IPC test
runs both paths deterministically, and the leak bar names every
still-active buffer with its creator.

**Client identities (as built, 2026-09-03).** A side's refcount says
when the *last* client is gone; a service serving many badged clients
on one channel (fssvc's views, netsvc's views, the fabric's sessions)
never heard of one client's death while the others lived, so whatever
it kept for that client — above all the buffer it had mapped — stayed
for the service's lifetime. Now a badge is an object of its own: a
`Badge` entry (channel, badge, refs) created by `chan_mint`, ref'd by
every cap transfer of a badged cap and released by every cap_drop,
dropped attachment and teardown — the same paths that count the side,
with the badge threaded through `refSide`/`unrefSide`/`releaseCap`.
When an identity's last cap dies the entry turns dead and the channel's
server is woken; its next `recv` returns **`Errno.client_dead` with
the badge in x6**, before serving anyone, and every remaining death is
reported before the side's own `peer_dead`. Badge 0 is unbadged and
untracked. The server's contract: on client_dead, release what the
badge named and only then mint that badge again. Lock discipline: the
badge table's lock is a leaf (taken under a channel's lock in recv and
channel teardown; released before the channel's lock is taken in
unrefSide). The IPC test proves it in the kernel — a copy's death is
not news, the last cap's wakes a parked server with the badge, a
second client keeps the side open, and after the last client
client_dead precedes peer_dead, badge table empty — and the fs drill's
churn steps prove the whole path from userspace (below, Domains).

## Init and supervision

**As built (unit files):** every program init can start is a **unit** —
`boot/conf/units/<name>.msh`, an mshl data literal read by the strict
data parser (literals only; a command in a unit file is a syntax error).
A unit names its image, budget, spawn grants, and `give` lines: what it
is handed over its boot channel before `go` — a device (`device: mmio`,
from the caps the kernel minted from the devicetree and root forwarded
to init), another unit's channel (`unit: blk`, activating that unit
first: capability wiring IS the dependency model and there is no
ordering anywhere), a shared buffer (`shm: 1`), a secret from the
archive (`secret: conf/fs.key`, staged through the unit's buffer and
wiped by the receiver), a filesystem view (`fs: "", ro: false`, derived
through the filesystem unit's control channel), a network view, or
init's own front channel (`self: true`). Units whose `profiles:` list
the boot's profile start at boot and pull in everything they need
(there is no `start:` key); `essential: true` means the
system follows the unit's exit; `certify` runs the fabric's
certification against a root-of-trust unit; `install: true` installs
the program store once the filesystem is up. A unit lists
the boot **profiles** it is eager under (`profiles: [system, net]`; the
kernel reads `profile=` from the boot arguments), which is how one
archive serves the interactive system and every drill. A `oneshot`
unit is a step: exit 0 starts the units that name it in `after`, a
non-zero exit takes the system down with that code. Supervision is
unchanged in shape — one-for-one, a restart budget, linear backoff —
and a restarted unit is re-wired the same way it was started. The kernel's
part of the shell boot is now one manifest: spawn root with log, spawn
authority, the archive, and the devices, then hold the leak bar when
the system has shut itself down.

Lessons paid for: a give entry with an unknown tag was dropped
silently, so a typo in a unit file produced a filesystem formatted
without its key and a fabric that could not certify; secrets are bytes,
not capabilities, and now need no tag at all, and an unrecognized entry
is reported. And every unit must take the boot handshake even when it
is handed nothing — init says `go` to everyone, and a service that
starts serving its own protocol first never answers.

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

Userspace, virtio-first. The driver interface is: a **device
capability** (its registers, its interrupt line, and — with the SMMU —
its DMA identity), IRQ-delivery-as-message, and explicit DMA grants
shaped like an IOMMU is present. Drivers run under manifests like any
other process and are as sandboxable as anything else.

**PCI and device capabilities (as built, 2026-09-02; enumeration moved
to userspace the same day):** devices are virtio over PCI, modern
transport only. The kernel does not walk the bus. `dt.pcieHost` finds
the host bridge (ECAM window, 32-bit MMIO range, the INTx→SPI base;
host-tested against a synthetic tree) and the kernel mints two
**window capabilities** from it for root — the ECAM window (bus 0) and
the MMIO window — which `window_map` maps in parts. Root hands them to
`pcisvc` (`user/pcisvc.zig`: firmware's job, done by a program), which
walks bus 0, sizes and places every memory BAR in the MMIO window,
enables decoding and bus mastering, finds the BAR the virtio structures
live in and the MSI-X capability, and registers each endpoint through
`device_register` — the ECAM holder's authority — naming its requester
id, kind, BAR and INTx pin. The kernel keeps what only it can do: the
device table a `device` cap names (config page, BAR, requester id — the
SMMU's stream id), the INTx intid it derives from the pin and the
devicetree's rotation (QEMU virt: INTA..D per slot from SPI 3), and the
LPI it routes through the ITS, whose number and doorbell address it
hands back so pcisvc programs the MSI-X entry itself. pcisvc then serves
the device caps to root (`PciReq.next` until `done`), which forwards
them to init; the kernel's own drills spawn it told to register and
exit. Registering a requester id twice returns the existing entry, so a
drill's enumerator and root's agree. Trust: the ECAM holder can describe
devices however it likes, and it is root's delegate — the level that
dispenses every device anyway. A `device` cap is an index into that table; `mmio_map` maps the BAR and
the config page (a driver reads the capability list itself), `irq_bind`
routes the line, `device_info` says what it is. Kinds are the virtio
device ids (`shared.DeviceKind`: net, blk, console, rng), so root can
forward what it was granted without knowing anything, and init files
each cap by kind for unit files' `{ tag: device, device: blk }`.
Interrupts are MSI-X through the **ITS** (`kernel/arch/aarch64/its.zig`, as built
2026-09-02): after the ITS is up (device and collection tables, a
command queue, a shared LPI configuration table, a per-core pending
table and collection), every device with an MSI-X capability gets
entry 0 of its table pointed at GITS_TRANSLATER with event 0, the
capability enabled, and an LPI routed to it (MAPD, MAPTI, INV, SYNC);
its `intid` becomes that LPI, and the four INTx wires stop limiting how
many endpoints a boot may carry — six is what the pool-node topology
needs. LPIs are messages: `irq.deliver` does not mask them and
`irq_ack` is a no-op; the virtio-pci transport points the config and
every queue at vector 0. The MSI write is DMA, so it goes through the
SMMU: the doorbell page is mapped into a holder's tables at its own
address, privileged-only (a driver's code cannot ring it), and the
stream entry marks the device's transactions privileged. INTx remains
the fallback for a device without MSI-X or a machine without an ITS —
and is what a guest will see for a passed-through device. Authority capabilities (log,
spawner, device, entropy, introspect) are plain object words with no
refcount, and they travel in messages exactly like shm and channel caps:
delegation is copying. So a driver never needs the kernel's manifest to
hand it a device — whoever holds the device cap (root, then init) gives
it away over the program's **boot channel**. The boot protocol
(`shared.BootReq`) is the one setup handshake every program starts
with: `cap{tag, kind}` with the cap attached (tags say what a cap is
FOR: console, view, device, entropy, disk, net, init, fabric, ...; kind
files a device), `secret{off,len}` for key material staged in the `buf`
cap (copied out and zeroized), `arg` text, then `go`. `user/boot.zig`
takes it, and every program starts with it: the block, net, console and
rng drivers receive their `device`; fssvc its root buffer, the volume key as a `secret`, and
the disk channel; fabroot its buffer and the root seed; fabsvc its
buffer, identity material, and net view; msh its console, view, init,
and fabric channels. The per-service setup requests left the ABI with
that. What remains service-level is only what cannot be a boot
message: the fabric's certification (`identity_key` hands the public
key back, the root signs it, `set_cert` installs it and opens the
network), because a certificate can only exist after the key does.

Lesson paid for by exactly that step: the first cut had fabsvc write
its public key into the shared buffer as a side effect of taking its
secret, and the spawner read the buffer the moment `go` was
acknowledged — before the service had run. A shared buffer is not a
reply. Anything a program hands back is a request with a reply, never a
promise about buffer contents after an ack.

**As built (Phase 7, transport replaced 2026-09-02):** irq_bind routes
a device's line to a notification — delivery masks the line (level
sources must not storm) and irq_ack re-enables after the driver services
the device; dma_alloc returns contiguous zeroed pages with a VA and a
device address (callers treat it as opaque: the SMMU decides what it
is). `user/virtio.zig` is the one virtio-pci transport every driver
shares: it maps the device, walks the PCI capability list for the
common/notify/ISR/device-config structures, resets and negotiates
(VERSION_1 always, ACCESS_PLATFORM whenever offered — which is what a
driver behind an IOMMU wants), programs split virtqueues, rings
doorbells, and reads the ISR byte (which also deasserts INTx). The
virtqueues stay in the drivers, whose layouts differ. Boots pass
`-nic none`: QEMU otherwise adds a transitional virtio-net that would
sit on the bus as an unclaimed endpoint.

### The SMMU (as built, 2026-09-02)

An SMMUv3 (`kernel/arch/aarch64/smmu.zig`) sits in front of the PCIe bus; every boot
runs with it (`iommu=smmuv3`, `iommu_platform=on` on each device, so the
devices honour it and offer ACCESS_PLATFORM). Stage-1 translation only,
and the IO page table of a device **is the page table of the domain
holding its capability**: the context descriptor's TTB0 is that
domain's TTBR0, its ASID the domain's ASID, MAIR as the CPU programs
it. So a device sees exactly the driver's view of memory — user pages
carry AP[1] (EL0-accessible), and PCI transactions are unprivileged, so
the CPU's permissions apply unchanged — and `dma_alloc` returns the VA
as the device address. A shared buffer mapped into a driver is DMA-able
for precisely the reason the driver can read it; a kernel page, another
domain's memory, or an unmapped address is not, and the transaction
aborts. Streams are requester ids (slot << 3 on bus 0), the stream
table is linear (256 entries) and starts empty: a device nobody holds
cannot DMA at all.

Binding follows the capability: `syscall.deliver`, installing a
received `device` cap, calls `smmu.attach` (CD, then STE, then
CFGI_STE + SYNC) — the last holder handed the cap owns the stream, so
root → init → driver ends with the driver. `cap_drop` and domain
teardown call `detachIfHolder` (STE invalid, CFGI_STE, TLBI by ASID,
SYNC) **before** the domain's tables are freed — teardown does it in
`destroy` while releasing capabilities, and `finishTeardown` frees the
tables later. Faults terminate (CD.S=0) and are recorded (CD.R=1,
CD.A=1); the event queue is drained on the SMMU's interrupt and logged
(the first few, then counted), the global-error line reports an
overflowed event queue.

Lessons: (1) QEMU's model rejects an STE with S1STALLD set ("stalling
fault model not allowed yet" under `-d unimp`), the opposite of what
the name suggests; leave it clear, the CD's S=0 already terminates.
(2) The SMMU's wired interrupts are edge-triggered pulses; the GIC's
default level-sensitive configuration never sees them — `configureEdge`
before enabling. (3) A refused burst is retried by QEMU's DMA helpers
word by word: one rogue sector is 128 events, enough to fill the queue;
the drill checks a range and the kernel throttles the log. (4) The
drill's first cut overflowed its 16K kernel stack — iterating the 4K
canary by value copied it onto a stack already crowded by Debug-mode
formatting frames — and corrupted its own locals; the fault reporter
now dumps the stack top, and kernel stacks are 32K.

### Entropy

**As built:** the kernel entropy pool (`kernel/rng.zig`) is a ChaCha8
fast-key-erasure CSPRNG (std.Random.ChaCha, pure integer code — the
kernel stays FP-free) that the kernel never seeds itself: no cycle-counter
mixing, no boot-time guesswork. Entropy enters only through `rng_seed`,
gated by the `entropy` capability, which the manifest grants to exactly
one domain — the userspace virtio-rng driver (`user/rng.zig`, device id 4,
one request virtqueue of device-writable buffers; the fourth virtio device
class through the unchanged mmio/IRQ/DMA grant interface). rngd harvests
64 bytes at boot to key the pool, wipes its landing buffer after every
copy, and reseeds on its own sleep clock; it serves no channel, because
consumers do not talk to it — they call `getrandom`.

`getrandom(buf, len)` is ungated: random bytes are authority over nothing,
so it stands where the counter does (the only two ambient reads in the
ABI). It is fail-closed — `bad_state` until the boot seed has landed, so a
service that starts before rngd gets an honest error, never a weak number
— bounded to 256 bytes per call (a bound on time under the pool lock, not
a throughput limit; the pool has its own spinlock, outside the
scheduler's), and it writes only into user-WRITABLE ranges. Every QEMU
configuration carries a `virtio-rng-device`; the shell and fabric boots
start rngd before anything that needs a nonce. msh's `rand` prints a draw.

Lesson paid for while adding it: `userRangeOk` answered "may the kernel
touch this?" for reads and writes alike, but text pages and the granted
bootfs blob are read-only to EL0 *and therefore to EL1* (AP=RO applies to
both), so a caller pointing `domain_list` at its own text would have
faulted the kernel — a permission fault at EL1, i.e. a user-provokable
panic. Writable syscalls now check `userRangeWritable` (data + stack +
shm window minus the blob). Residual, deliberate: getrandom is not
interposable, like the counter; a domain that must observe deterministic
randomness needs a manifest option, not a proxy.

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
| `img/` | immutable, content-addressed | program images as `img/<digest>` (SHA-256[0..16] hex) plus a manifest `img/<name>.msh` beside each (digest, grants, gives); installed from `boot/img/` by init at boot, read by msh's `run`; the same layout in a home is the user's own store |
| `conf/` | admin-written, service-read | per-service configuration: `conf/<service>/...` |
| `state/` | service-owned, survives reboot | each service's private mutable state: `state/<service>/` |
| `data/` | user/application payload | the only tree where sharing between services is expected, always via explicit view grants |
| `volatile/` | cleared every boot | per-service scratch: `volatile/<service>/` — the FS service empties it at every mount |
| `home/` | user-owned, survives reboot | one subtree per user, `home/<user>/` — reachable only through the view a session is handed; user settings live at `home/<user>/conf/` |

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
  design pass. Directories are packed 64B dirents (linear within one block; hashed past it since format v4 — below).
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

**Hashed directories (as built, format v4):** a directory that fits one
block is a flat array of 64-byte entries scanned in insertion order —
what every small directory is, and what a v3 volume's directories all
are (it mounts unchanged and is written as v4). The first entry that
would not fit converts the directory to extendible hashing over the
name's xxhash64: block 0 becomes a header {depth, bucket count, a table
of 2^depth bucket block numbers indexed by the hash's top `depth`
bits}; every other block is a bucket {local depth, 63 entries}. Lookup
is one hash, one table read, one bucket scan. A full bucket splits on
its next hash bit, doubling the table when its local depth equals the
global one; buckets are ordinary blocks of the directory object, so
CoW, checksums, and transaction groups cover a split like any write —
the crash sweep across a conversion proves every cut leaves either the
old directory or the new one, never a torn table. Entry index = byte
offset / 64 in both layouts, so removal is one zeroed entry either way.
Listing order is bucket order past one block (nothing may rely on
insertion order there; the shell has `sort-by`). Limit: 512 buckets,
about 32K entries; a two-level table is the evolution.

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

## Developer tooling

**As built (msh + typed introspection):** the developer console is an
ordinary user process wired from exactly four capabilities — nothing about
it is special to the kernel:

- **The console** is a userspace virtio-console driver (`user/cons.zig`,
  device id 3 — the third virtio device class through the same mmio/IRQ/
  DMA grant interface). It serves a raw byte pipe to one client over a
  channel + shared buffer; reads block the driver on the RX interrupt
  (single client, and the kernel channel deliberately refuses recv while
  a reply is pending). Echo and line discipline live in the client.
- **msh** (`user/shell.zig`) holds the console channel, an fs view (the
  same badged view protocol as every service), init's front channel, and
  a spawner cap. Its command set is typed IPC end to end: ls/cat/write/
  mkdir/rm/mv/ln/readlink/stat/df/sync over the fs protocol
  (`user/fsclient.zig` — the client stubs shared with the fs demo roles),
  svc/start/stop over init's protocol, ps/mem over the kernel's
  introspection syscalls. Text exists only at the human boundary.
- **Introspection authority = spawn authority**: domain_list and sysinfo
  are gated on the spawner cap — the right to create domains carries the
  right to see the ledger. domain_list fills the caller's buffer with
  typed `shared.DomainRec` records (state, threads, name, exit code,
  kobj/user used-and-limit) straight from the kernel's accounts; sysinfo
  reports pmem, cores, uptime. domain_stat (per-ctl-cap) also reports
  budgets now, so supervisors can watch their children's consumption.
- **init grew a granted-channel mode** (a spawner hands it its front
  channel; it serves until every client cap dies, then revokes its
  services and exits) plus status/stop requests — a deliberate stop is
  remembered and not restarted; connect doubles as start.
- `zig build run-shell` boots the whole topology with the console on the
  terminal (kernel log in zig-out/shell-kernel.log). The check's shell
  spec boots the same topology with the console on a TCP chardev and
  drives a real scripted session — every response asserted — then
  `exit` must land the usual leak bar (pmem byte-identical, accounts
  zero).

**msh v2 (as built): a structured shell.** The shell took the OS's own
position on interfaces: a pipeline carries *values*, never bytes to be
re-parsed, and text exists only when the final value is rendered for
the human. The language, mshl, is a pure `lib/` module tested on the
host like the filesystem core: values (nothing, bool, int, string,
list, record, table), a small regular grammar (commands with arguments;
`|` pipelines; `> path` as sugar for `| save path`; `let`, `if/else`,
`for`, `while`; `$vars`; `"interpolated $text"`; `(sub | pipelines)`;
`[lists]`; `.field`/`.index` access; comparison, boolean, and
arithmetic operators; size units), and the table verbs — `where` (bare
words name columns of the current row, elsewhere they are strings),
`sort-by`, `select`, `get`, `first`/`last`, `reverse`, `len`, `keys`,
`lines`. msh is the interpreter's *host*: it maps command names to
typed IPC and returns values — `ls` is a name/type/size/mtime table
(one stat per entry through the view), `stat`/`df`/`mem` are records,
`ps`/`svc`/`nodes` are tables, `tree` draws a subtree, `cat`/`open`
read a file, `write`/`save` write rendered text. Unknown names fall
through to the interpreter's error. The line editor (`user/lineedit.zig`)
owns the console between commands: history, cursor keys, ctrl-a/e/k/u/l,
and tab completion — command names in command position, otherwise
paths, listing the prefix's directory through the view and marking
directories with `/`. Memory is two static arenas in msh's BSS: a
per-line arena reset before every line and a persistent region into
which `let` deep-copies its values (a fixed-buffer allocator; msh's
manifest budget covers it). Field access is parsed as a postfix glued
to a primary rather than as a token, so bare words keep their dots
(`hi.txt`, `10.77.0.1`) while `(stat p).type` and `$row.size` work.
**Programs return values (as built):** a program `run` by msh is handed
an `out` capability — a buffer it writes its result into as an mshl
*data literal*, the same syntax the strict parser reads (a table is a
list of records; `tableize` turns one back). msh parses it and the
program's value flows into the pipeline; ps and ls render text only
when nobody gave them an `out`. The data syntax is thus the interchange
form everywhere: `to-data`/`from-data` write and read it, `save` of a
`to-data` result is a file `open | from-data` reads back, and a unit
file is the same syntax read by the same parser. `def name [params] {
body }` defines functions whose bodies persist across lines (`$in` is
the pipeline input; parameters bind in a scope that ends with the
call); `source p` runs a script in the session and the startup script
(`conf/msh/startup.msh` on the volume, else the archive's) runs before
the first prompt. A script renders every top-level statement's value as
it goes, the way the prompt does — the first cut rendered only the
last, and a startup script ending in a `def` printed nothing.

**mshl v3, stage 1 (as built, 2026-09-03): the language core.** The
decisions in ROADMAP's locked table, built on the host first, with the
shell as the only host so far. *Functions are values*: `fn [params]
{ body }` anywhere, `def` as its named form, a block in argument
position as a function of `$it`; `map`, `filter`, `reduce`, `any`,
`all`, `find` take one; a `$var` (or `$rec.field`) with arguments is a
call. A closure snapshots the locals of the function that made it and
points at the *scope* it was defined in, reading names there at call
time — recursion and mutual recursion by name, never a self-pointer in
a value. *Memory is counted, exactly*: a line's arena as before; what
`let`/`def` bind at a top level is a **box** (an arena of its own with
a count; scalars inline, `let y = $x` shares, a record retains the
functions inside it); rebinding drops; a box at zero is freed at the
end of the top-level statement, never mid-statement, because the loop
rebinding a name may still be walking the old value. Frames (params,
captures, locals) are arena memory: a call allocates nothing lasting.
The one cycle — a scope's slots hold its closures, its closures point
at the scope — is collected knowingly: at every reclaim, an unheld
scope whose closures are referenced only from its own slots is freed
(`scopeGarbage`); the tests run under the leak-detecting allocator and
`deinit` must return every byte. msh's boxes come from a 1 MB chunk
pool (`lib/pool.zig`: first fit, marks cleared on free) — the first
freeing allocator in moss userspace. *Strong, dynamic typing*:
conditions take bools, `==` and `<` take one type, `+` never converts;
`str`, `int` (a result) and `type` are the conversions; strings are
validated UTF-8 with `len` in code points and `bytes` is its own type
(`to-bytes`, `from-bytes` → result). *Failure is a value*: `ok`/`err`
results, `?` unwinds to the enclosing function (an internal flag and
`Error.Runtime`, so the public error set did not change), `try { }`
turns a failing host command into an `err` with its message — the
bridge until host commands have signatures. *`match`* with patterns
over literals, bare words (the enumeration story), `ok`/`err`, lists
with `..$rest`, open records with `{ name }` shorthand, guards; the
exhaustiveness check is at parse time and deliberately blunt (a
catch-all, both result arms, or both bools). *Modules*: `use path`
evaluates a file in a fresh scope and returns its bindings as a record;
the scope lives while any of its functions does; no global namespace.
Two decisions taken while building: `?` at the prompt is an error, not
a print (nothing to return to); a one-line match arm is a pipeline, so
a bare word there is a command, as everywhere else — quote it. The
shell drill's language lines in QEMU (closures, `match` on a result
and on `try`, `?` inside a function, a module written to the volume
and `use`d, a typed error, a UTF-8 `len`) and seventeen host tests
cover it; the line editor had been dropping every byte above 0x7e, so
no UTF-8 could ever be typed — found by the drill's `"héllo" | len`.

**mshl v3, stage 2 (as built, 2026-09-03): a script is a program.**
`mshrun` (`user/mshrun.zig`) is an image like `ls`: it takes its world
over the boot channel — one view, an argument (the script's path in
that view), a console and an `out` when msh runs it — and evaluates
the script with the file commands as its entire host. Those commands
moved out of the shell into `user/fscmds.zig`, parameterized by a
resolver (msh: its view plus mounted shares; mshrun: its one view), so
the two hosts cannot drift. The rules: with an `out` the last value is
the result and nothing is rendered (a program returns a value); without
one every statement's value is rendered to the console or, as a unit,
to the log a line at a time; an error is exit 1 with `mshrun: path:
message`. A unit file gained `script: path`, which init hands over as
the argument text, so a script is a unit — eager, `oneshot`, `after`,
`essential` all apply, and a drill step can be a script (the archive's
`script-hello` unit runs `scripts/hello.msh` from a read-only view of
`boot/` in the system profile and the shell drill requires its log
line). The manifest `mshrun.msh` gives `fs: ""` — the whole filesystem
the shell holds, writable — and a narrower copy in a store is a script
confined to one directory. Not done: a script spawned on another node
(`rspawn` takes a catalog number and carries no argument text) waits
for the fabric surface, stage 4.

**mshl v3, stage 3a (as built, 2026-09-03): sockets as values.** The
language gained a value kind, the **handle**: a capability the host
holds for the program, with a kind, a number and a drop callback, in a
counted box like a closure — born on the dead list, kept by a binding,
released (drop called once) when the last reference goes, at the end of
that statement. `user/netcmds.zig` is the first host surface built to
the language's rules: `connect`, `listen`, `accept`, `send`, `recv`,
`close`, `status` on a network view, every outcome the network decides
a *result* (`err refused`, `err closed`, `err "timed out"`) rather than
a failed line, socket and listener handles whose drop is `tcp_close`.
Addresses parse in `shared.parseAddr` (dotted v4 mapped, v6 with one
`::`, host-tested). Waiting is polling with a tick's sleep, bounded;
doorbells are the next step. `mshrun` gained the `bootfs` grant (a
script read from the archive, no view needed) and the `net` cap; msh
offers the same commands when its unit gives it a view (the system
shell's does not). The network drill's third step is a script run from
the archive with nothing but a network view: the wire echo, then
listen–connect–accept over loopback in one program (the loopback
handshake completes inside `connect`), then a closed peer and a
refused destination as `err` values — it passed on the first boot.

**mshl v3, stage 3b (as built, 2026-09-04): the stack upgraded.** TCP
in netsvc is windowed now: a 4 KB send ring per socket (`tcp_send`
queues whole or answers `would_block` — a partial send would tear a
message for every client that assumes all-or-nothing, and they all
do), segments of the peer's MSS (the SYN option parsed, 1440 announced)
sent while the peer's advertised window has room, cumulative ACKs
freeing the ring, an 8 KB receive buffer whose free space is the
window we advertise. Retransmission is per connection with backoff
(200 ms doubling to 3.2 s, eight retries) and resends whichever is the
oldest unacknowledged thing — SYN, first in-flight segment, FIN. A
closed connection lingers in the stack, unaddressable, until its FIN
is acknowledged, so a program may close and move on and its last bytes
still arrive. Tables grew to 32 sockets, 16 views, backlogs of 8. The
loopback lesson held and gained a corollary: an emit runs the peer,
whose ACK runs our input, which wants to send more — `tcpOutput` is
guarded per socket so the nested call returns to the outer loop. The
language's network commands wait on a doorbell now, one notification
per host hung on every socket, instead of ticking. Bug found: giving
the socket table a non-zero default (the MSS) moved 400 KB of it from
`.bss` into the image, past the stage (then 256 KB) init loads images
through, which reports "image missing from the boot archive" for one
that does not fit — so the table is zero-initialized and `sockAlloc`
sets the defaults, and a misleading message has a story behind it.

**mshl v3, stage 3c (as built, 2026-09-04): HTTP.** Two pure modules
carry the format — `lib/http.zig` (requests and responses parsed
incrementally out of bytes, `incomplete` until the head and the body
it announces are all there; formatting with `Content-Length` and
`Connection: close`; URLs with IPv6 literals in brackets) and
`lib/json.zig` (the data subset out, objects as records and arrays as
lists in, `\u` escapes and surrogate pairs, floats refused because the
language has none) — and `user/httpcmds.zig` moves the bytes over the
network commands' raw socket operations. `http-read` and `http-write`
are the primitives; `http-serve $listener $handler [n]` is the loop, with
a handler as an ordinary function of the request record and its return
value deciding the response (a record is explicit, a string is text,
data is JSON; a failing handler is a 500 and the server goes on) — one
connection at a time (for concurrency across connections, the worker-pool
`serve` hands each socket to a worker whose handler may itself call
`http-read`/`http-write`);
`fetch URL [opts]` is the client, address-only hosts. `to-json` and
`from-json` joined the language. One request per connection, no
keep-alive, no chunked transfer: what a script needs, not a proxy.
The network drill's script serves four pages that the check itself
fetches through a slirp port forward — text, JSON, a POST echoed with
a custom header, a 404 — and `fetch`es from a canned server the host
runs as a slirp `guestfwd` command. Two bugs found by the drill: a
script that serves forever must say so *before* serving, and `mshrun`
had been printing a script's rendering only at its end — it streams
each statement's output now (`evalScriptEach`); and with clients
asleep on doorbells nobody called `netsvc`, so its retransmission scan
never ran and a lost SYN was never resent — the service has a clock
now (a kernel timer on its interrupt notification, ten ticks — a
second, as it turned out; one tick since the clock arc). Also
fixed on the way: a closed connection freed as soon as its own FIN
was acknowledged left the peer's FIN unanswered, and slirp retransmitted
it at us for a minute; a lingering socket now waits for the peer's FIN
too, or two seconds. And the shell itself, with the interpreter and
the file, network and HTTP hosts compiled in, passed 256 KB of code and
stopped loading — "image missing from the boot archive" again — so the
loader stage is 512 KB (128 pages) and, since a stage is one shared
buffer, `shm_max_pages` went from 64 to 128.

**mshl v3, stage 4a (as built, 2026-09-04): the bulk transport and
remote stages.** A shared-memory cap attached to a badged call does not
cross the fabric; its *contents* do now. The caller's fabric maps the
cap as the session's buffer and tells the peer its size in the
`call_req`; the peer makes a twin and attaches it to the exported
channel with the caller's own words, so the service sees an ordinary
`attach_buf`. Every forwarded call is preceded by `fw_bulk` frames
carrying what changed in the caller's buffer since the last exchange,
every reply by `fw_bulk_resp` frames carrying what the service changed
in the twin, each side diffing against a shadow of what the other
holds — a call costs the bytes that moved. Frames are capped at the
network view's page (4 KB sealed), the peer's receive buffer grew to 8
KB, and wire version is 6. A session's death crosses as `fw_release`:
the peer drops the export — channel, twin, and a spawned child's
control cap, so the child dies and its memory returns. On top of it,
`x | remote NODE { … }`: `mshrun` in a remote-stage role, spawned by
the fabric, served one `run` — script text and input as a data
literal in, the value as a data literal out — and closures remember
their source so a block can be shipped. Three bugs, all found by the
fabric-login drill's new script. The diff's run scan ended one byte
short after a quiet gap and re-scanned that byte forever, spinning the
serve thread and silencing the node until its peer dropped it —
`peerFailed` now names every reason in its log line, because "peer
lost" without a cause cost an hour. The fabric kept every spawned
child's control cap, so a finished stage kept its 4 MB reserved and
the second spawn was refused with a bare `no_space` — the kernel now
logs a refused spawn's cause (`QuotaExceeded`), the export holds the
control cap and drops it on release. And half a megabyte of static
shadow memory pushed the drill's fabric service — spawned with the 1
MB default — past its budget once a child's pages were charged up the
chain to it: shadows are shared-memory pages made on attach and freed
on release, and a fabric service has an explicit budget (4 MB / 16 MB)
in its unit and in the kernel drill, because *it pays for the children
it spawns*. Along the way: `match` arm bodies are statements (an `if`
in an arm was parsed as a command and its `>` as a redirect), and
init's unit table grew to 48.

**Users, stage 4 (as built, 2026-09-04): one home, wherever you log
in.** A user's home stays on the node where it was born; a session
elsewhere reaches it through a lease. The manager where the user logs
in fetches the record (cached with `home: <node>`), unseals it, asks
the home's manager for a challenge, signs the nonce with the identity
key, and — on the lease cap the challenge came with, through a buffer
the bulk transport carries — hands over the signature; verified under
the record's public key, and with no session or lease holding the
home, the answer is a rw view of the home's ciphertext directory. The
session's home service is spawned *locally* with that view as backing
and the key derived from the identity: the key never leaves the node
where the passphrase was typed, the home's node ships only ciphertext,
and every mossfs block crosses as one proxied exchange. One server per
home: a lease refuses a local login and a local session refuses a
lease; the lease dies with its cap (logout, or the node). No fallback
home: a login whose home node is unreachable fails and says so — a
second home that silently diverges is the worst outcome. Decided with
the user: this is the model, a local block cache in the home service
is the performance step (the lease makes the cache exclusive, so it
needs no coherence), and moving a home is an administrative action to
come. The drill proves it with a wiped disk: alice writes on node 2,
node 2 forgets everything, alice reads it back on node 2 from node 1.
Two bugs found, one of them old. The fabric answered control requests
with token-less replies, which the kernel delivers to the *oldest*
parked caller — with a remote stage's call parked, the session
manager's `lookup` answer landed on it (a `FabResp.num` read as
`RunResp.refused`); every fabric reply now carries its request's
token, and the rule is in HACKING. And a node hosting both remote
stages and remote homes ran out of the fabric's eight sessions and
exports; both are sixteen. Also: the session manager's badge-death
handler and lease table, and `usersvc`'s gate now admits `attach_buf`
on a lease cap and nothing else there.

**Users, stage 4b (as built, 2026-09-04): the remote home's speed.**
Measured first: a cold 64 KB read from a remote home took 55 ms, one
fabric exchange per 4 KB block. Two changes and a measurement in the
gate. The home service's backing layer keeps a **read-ahead window**:
a miss fetches a whole 32 KB window aligned to its size, later blocks
in it are served from memory, and writes go through it (patched, or
the window dropped) — sound because the lease makes this service the
volume's only writer. And the transport carries a window in one
exchange: netsvc's `tcp_send`/`tcp_recv` take 32 KB (a view attaches
8 pages), the send ring is 32 KB and the receive buffer 64 KB, the
fabric's frame cap and bulk chunk follow (32 KB frames, 64 KB peer
receive buffers), 16 sockets per service, budgets raised where the
network runs (8 MB). The same read is 4 ms now; the warm read and the
deferred write about 2 ms; the fabric-login drill prints all three on
every gate run. Two bugs paid for it. Resetting a socket or a peer by
struct literal built the 96 KB record on the stack and overflowed the
thread; the buffers live in arrays beside their tables now. And the
empty 64 KB receive buffer advertised a window of 65536, which a
16-bit field cannot hold — the checked cast panicked netsvc silently
and every client saw `peer_dead`; the window is capped at 65535. Also
in this step: `now` and `sleep` as shared host commands, and the
language pools call frames per line (a `map` of ten thousand made ten
thousand frames from the arena and ran out at a 64 KB `join`).

**mshl v3, stage 5a (as built, 2026-09-04): a tree-sitter grammar.**
`tools/tree-sitter-mshl/` describes the language for editors: the same
decisions the interpreter makes, made by GLR and precedence instead of
by hand — a stage headed by a bare word is a command (dynamic
precedence over reading the word as a string), one headed by a
variable with arguments is a call, `where` takes an expression, and a
`.` glued to a primary is field access even though `.` may begin a word
(an immediate token with lexical precedence beats a longer word; with
whitespace before it, `.hidden` is a word). Statements are separated,
never adjacent — a rule that must not match the empty string, so the
list is non-empty and blocks hold an optional one. The corpus is
recorded parses (`tree-sitter test -u`) read and corrected: the first
recording had every argument of a command as its own statement, because
a generator error hidden behind a grep left the previous parser in
place. Every `.msh` file in the repository parses clean, and the
highlight query covers keywords, operators, variables, commands,
fields and keys. Not in the gate: the grammar is host tooling, checked
with `tree-sitter test`; the rule that a syntax change updates it is
in HACKING.

**mshl v3, stage 5b (as built, 2026-09-04): the formatter.**
`tools/mshfmt.zig` is the first tool on the grammar: the generated
`parser.c` and the host's tree-sitter runtime (`libtree-sitter.a`,
`brew install tree-sitter`; `-Dtree-sitter=PREFIX` elsewhere) linked
into a hosted Zig program through `@cImport`. It does not pretty-print
from the tree; it walks the tree's leaves in source order — atomic
nodes (strings, variables, numbers, keys, comments) copied whole — with
the count of line breaks before each, and emits them with two decisions
per leaf: whether a line break survives (the author's do, capped at one
blank line; the leaf then indents by bracket depth) and whether a space
goes before it (by the kinds of the two neighbours: none inside `()` and
`[]`, spaces inside `{ }`, none around a glued `.`, before `?`, `,`,
`;`). The one rule that looks across leaves is alignment: in a record
written one field per line, a run of one-line fields on consecutive
lines — each with the line to itself — pads its keys to the longest, as
gofmt does; a multi-line field, a blank line or a comment ends the run.
A file with an error node is left alone. The tests format, format
again, and compare the S-expressions of both parses; `zig build
fmt-test` adds `--check` over every `.msh` under `boot/`, found by
walking, so a file that is not formatted fails the step and a new one
cannot be forgotten. Not in the gate (host tooling; needs the runtime),
but part of finishing a change to anything under `boot/`.

**mshl v3, stage 5c (as built, 2026-09-04): lint.** `tools/mshlint.zig`
shares the parser with the formatter (`tools/mshtree.zig`: the C
runtime behind a few helpers — kind, text, field, positions) and adds
the one analysis a language server will need too: scopes. A scope is a
function body (`def`, `fn`, a block argument) or the file; a block
under `if`, `for`, `while`, `try` or a match arm is not one, because at
run time it binds in the enclosing frame. Each scope is collected
first — every `let`, `def`, `for` name, pattern binding and record
shorthand anywhere in it, with function bodies skipped — then checked:
a `$x` or a `$x` inside a string resolves up the chain, counting a use
on the binding it finds; none anywhere is "not bound", and a use in the
same scope that starts before every `let` of that name there is "used
before" (across scopes order is not checked: `def f { $x }` is fine
with `let x` after it, which is how closures resolve). The implicit
names (`it`, `in`, `acc`, `req`) are bound in every function scope and
the file's. Unused is reported only for a `let` in a function: a file's
top level is what `use` exports. The `match` check is the parser's
exhaustiveness rule transcribed (catch-all; `ok _` and `err _`; `true`
and `false`; guards never count) plus the arm after a catch-all;
duplicate record keys and a `def` over a builtin name (the list is
`lib/mshl.zig`'s, imported) round out the language checks. The one
host-specific check is the unit file: under `conf/units/` and
`conf/session/`, a top-level key `parseUnit` does not read, because
init ignores unknown keys and a misspelled `image:` is a unit that
silently never starts. Diagnostics are `path:line:col: message`, sorted,
exit 1 if any; `--stdin NAME` for editors. `zig build lint-test` runs
its tests and the lint over the tree.

**mshl v3, stage 5d (as built, 2026-09-04): the language server.**
`tools/mshls.zig` is the lint and the formatter behind the Language
Server Protocol: stdio, `Content-Length` frames, JSON-RPC parsed into
`std.json.Value` and answered with typed structs through the
stringifier. Documents are synced whole (a script is small; analysis
is a parse and one walk) and re-analyzed per request rather than
cached — simpler, and fast enough that nothing else is worth it yet.
Every query starts from the lint's `Analysis`: diagnostics are its
diagnostics with byte ranges turned into line/UTF-16 positions and its
severities (an error is what would fail when the line runs); hover and
definition look up the reference or binding under the cursor (a `$x`,
a `$x` in a string, a command naming a `def`) and describe it from its
binding — the `let` line, the `def` header up to the body, what an
implicit name is — or, failing that, say "builtin" for a builtin's
name; symbols are the file scope's `let`s and `def`s; completion is
`Analysis.visible` at the cursor (innermost first, each name once) and
then the builtins; formatting is `mshfmt.format` as one edit over the
whole document, none when unchanged, none when the text does not
parse. The server is a struct that takes one message and appends its
replies to a buffer, so the tests are the protocol itself (framing
checked, JSON parsed back) with no transport; `main` is the frame
reader. Not built: rename, references, incremental sync, semantic
tokens — the tree-sitter highlights cover the last, and the rest wait
for an editor to ask.

**mshl v3, stage 6 (as built, 2026-09-04): shapes, signatures,
results, floats, the library.** The residuals of stage 1, closed
together because they are one idea: the boundary is where a type is
checked. *Shapes* are a value kind and a small grammar of their own —
type names, bare words as an enumeration's members, `[S]`, open
records `{ k: S }`, `ok S` / `err S`, `S | S`, `$Name` — written after
a `let name:`, a parameter, a `->`, a `match` subject, or the word
`shape`; the checker (`Interp.mismatch`) walks value and shape
together and names the first thing that does not fit by path
(`e.size is x, not int`, `t[0].name`, `r (ok)`). Checked where they
run and nowhere earlier; a `$Name` in an annotation resolves in the
closure's own scope (captured like any name) and a shape *value*
never carries one (`shape` resolves them when it evaluates).
`match v: S` checks the subject and then that the arms *cover* S
before any arm is tried — words by literal, `bool` by both literals,
results side by side, records by case splitting on the first field a
pattern names (the first cut asked one pattern to cover every field,
which refused `{ a: dir } / { a: file }` over `{ a: dir | file }`; the
split is the textbook one, and the two-field counter-example is in the
tests). *Signatures*: a host says, per command, its parameters, its
input and its answer as shapes (`Host.signature`), and the
interpreter checks the arguments and the input before the call and
the answer after it, blaming the host for the latter ("the host's
slip, not yours"); `mshl.shapeOf(T)` derives a shape from a Zig type
at compile time — struct to open record, enum to a union of words,
slice to `[S]`, `?T` to `S | nothing` — and `mshl.toValue` builds the
value from the same type, so `fscmds.Stat`, `Df`, the shell's `Proc`,
`Svc`, `Node`, `Mem` and the protocol's error enums are each declared
once; `signature NAME` hands the record back with its shapes as shape
values (`ls data? | check (signature ls).returns`); the builtins carry
signatures in a table of their own (`builtin_sigs`), checked at the
call the same way — which retired the hand-written argument checks in
the dispatcher — and rendered on an editor's hover (`first [count?:
int] (input: list) -> list`). *Results*: every
command whose outcome the world decides answers `ok v` / `err word`,
the word from the protocol's own enumeration (`shared.FsErr`, `NetErr`,
`FabErr`, `@tagName`), through new error-reporting variants in
`fsclient` (`fsListR` and kin) so the word is the service's, not a
guess; misuse is the signature's typed error; infrastructure that did
not answer is still `fail`. The prompt renders a top-level `ok` as
what it holds and an `err` as `err word`; `try` passes a result
through unchanged (it was wrapping `ok (err x)`); `use` reads a
result. *Floats* are a second number in a two-level tower with the first
(added 2026-09-06): two ints stay an int, but a float on either side
of an operator promotes the int and the result is float (`1 + 1.5`,
`7 / 2.0`), and `==` crosses the two by value; a shape annotation stays
strict, so `let x: float = 5` is still a mismatch (the lint now flags a
literal against a primitive shape without running). `float`/`int`
convert explicitly, `round`/`floor`/`ceil` round; floats are lexed by a
fraction or an exponent so `1.2.3` and `10.77.0.1` stay words, rendered
with a fraction always (`3.0`) and in exponent form when huge or tiny,
data and JSON on both sides. *The library*: `lib/msh/*.msh` — host-tested
through the interpreter's test host, packed into the archive as
`lib/` — is installed into the store by init beside the images — the text under its digest,
a manifest `{ source: "<digest>" }` — and `use name` (no `/`, no
`.msh`) asks the host for `module name`, which reads the shell's own
store then the system's, verifies the blob against the digest, and
evaluates it; `install name` copies a module like a program; `run`
gives a program the system store when its manifest says `{ tag: store
}` (mshrun's does). The grammar, formatter, lint and language server
learned the syntax (`typed_name` aliases the key token so `x:` keeps
its colon; the lint skips exhaustiveness when a shape is present; a
`:` leaf glues to its subject). Decisions taken while building: the
`shape` keyword takes *one* term (`shape (a | b)`), because a greedy
union read `check shape int | len` as the enumeration `int | "len"`
and silently ate the stage — a delimited annotation position takes a
bare union; a word spelt like a type name renders quoted (`"int"`) or
it would read back as the type, while `true`/`false`/`null` render bare
in a shape since they are words there; a bare word or number before
the match colon is one token (`dir:`, `5:`) and is split by the
interpreter, but the tools' grammar wants a variable or parentheses.
A function value alone in a stage with pipeline input is called with
it (`[1, 2] | $m.sum`): there was no other way to call a function of
no parameters reached through a record, and `$f` by itself stays the
value. In Zig, `shapeOf` and `resultShape` build their slices at
compile time and refuse a runtime call, so a host keeps its shapes in
container constants. Two runner lessons: the console tap was a 64 KB
buffer whose reader thread quietly stopped when it filled, so once
the scripted session said more than that every later step looked
like a shell that hung on a line it had in fact answered — the tap is
4 MB now and an overflow is a named failure, a failed step prints what
the console said on one line and keeps the whole transcript beside the
kernel log (a raw carriage return in that dump hid an answer behind
its echo, and a grep that read only the echo's line made an answered
step look like a hang twice); and a userspace panic exited with 255 and no
word, which reads the same way from a console, so msh and mshrun log
the panic message first. The shell drill grew a dozen steps (a result matched on
its word, a wrong argument refused by a signature, a float, an
annotated `let`, an uncovered enumeration, `use math` from the store,
a script that `use`s it under `mshrun`) and the login drill installs
a module into a home.

**mshl v3, stage 3d (as built, 2026-09-04): keep-alive and chunked
transfer.** `lib/http.zig` frames a body three ways now — a length,
chunked (decoded in place of the sizes and trailers, `len` still the
bytes consumed as sent so the next request is found behind it), or
the close — and every parsed message says `keep`: HTTP/1.1 unless
`Connection: close`, HTTP/1.0 only with `keep-alive`, never after a
body that ran to the close; 204, 304 and 1xx end with their head.
What is written always carries a length and the Connection header the
caller decides. In `user/httpcmds.zig`, `serve` answers every request
a connection carries: bytes past the end of one request wait in a
per-socket leftover (eight slots of a receive's size, static, since the
interpreter's arena is a line's) so pipelined requests parse whole,
and the connection ends when the peer says close, a handler's record
says `close: true`, the count runs out, or it sits idle three seconds
— the wait is `Net.recvSomeFor`, a kernel timer (`timer_arm`) ringing
the host's doorbell with a bit of its own beside netsvc's, and since
that bit may still be latched from the last arming, a wake counts as
the timeout only once the clock agrees. `fetch` keeps up to four idle
connections by address and port; a kept connection the peer closed
while it sat answers nothing, which is the one case worth a single
retry on a fresh connection (the drill's canned server, a `printf`,
does exactly that). The network drill's server now serves seven
requests over six connections — the runner pipelines two on one and
sends a chunked POST on another — and the script fetches twice.

**Networking, UDP (as built, 2026-09-04).** Datagrams joined the stack
as the first step toward name resolution: a table of eight UDP sockets
in netsvc, each a bound port, a doorbell and a queue of eight datagrams
kept with their sources; `udp_bind` (0 for an ephemeral port; a
filtered view may bind only so, and hears only from its one allowed
peer), `udp_send` with the destination address in the view buffer
ahead of the bytes (a request carries three words, and an address is
two), `udp_recv` answering the source the same way; UDP socket numbers
start at 1000 so `watch` and `tcp_close` serve both kinds. The
checksum is the pseudo-header sum TCP uses with protocol 17 and a
zero folded to 0xffff; loopback goes straight back into `udpInput`,
as TCP's does. `shared.formatAddr` renders an address as text (dotted
for v4-mapped, RFC 5952 `::` for the longest zero run) so a datagram's
`from` is a string a script can match. In the language: `udp-bind`,
`udp-send`, `udp-recv` (a `{ from, port, data }` record), `close` and
`status` on a `udp` handle. The network drill's script sends to a
bound port from an ephemeral one over `::1` and `10.0.2.15` and
answers back.

**Networking, names (as built, 2026-09-04).** Three pieces on top of
UDP. `lib/dns.zig` is the wire format and nothing else — build a
query (recursion desired, an OPT record announcing 1232 bytes), parse
a message (labels, compression pointers with a hop limit and no
forward references, the question echoed, records raw with their
offset so a CNAME can be read), gather the addresses for a name
following a CNAME chain within the answer with the smallest TTL, and
build an authoritative response — host-tested against hand-written
packets. The resolver lives in netsvc, which has the timers, the
clock and the sockets: a lookup asks the current resolver for AAAA
and A at once (two ids stepping through the id space from a boot-time
seed, one source port chosen at boot), the tick resends after half a
second and moves to the next resolver after two tries, a REFUSED or
SERVFAIL moves on at once, and the lookup finishes when both questions
are answered or the last resolver gave up — with what came, or
`nxdomain`, `refused`, `timeout`; answers are cached by TTL (bounded
to an hour, a minute for a negative one) in sixteen slots. The
protocol is `resolve` (the name in the buffer; answers a lookup
number a `watch` can ring) and `resolve_check` (the addresses in the
buffer, or the error, freeing the lookup); any view may resolve, since
a name is a question and the allowlist judges the address that comes
of it. Resolvers come from the unit's settings file — `conf/net.msh`,
delivered by init's new `file:` give, the `secret` mechanism for bytes
that are not secret (kept, not wiped, up to 2 KB) — `::1` first for
the node's own dnsd, then slirp's forwarder. `dnsd` (`user/dnsd.zig`)
is that server: one zone from `conf/dns.msh` given the same way, UDP
53 on its own network view, A or AAAA by the address's family,
NXDOMAIN in the zone, REFUSED outside it. In the language: `resolve`,
and a name wherever an address goes; `Net.connectHost` tries the
addresses in order with a bounded attempt (a kernel timer on the
doorbell, as the timed receive) while more remain. Found by the
one-off wire test the gate cannot run: with a public name answering
two IPv6 and two IPv4 addresses and slirp routing only IPv4, connect
by name sat through the stack's whole retransmission run per IPv6
address and the drill's hang watchdog fired — the bounded attempt is
the fix, and dnsd answering NXDOMAIN for every unknown name had kept
the resolver from ever asking slirp, hence REFUSED outside the zone;
and `fetch` had taken its socket from a single-address connect and
keyed its pool by that address, so it never got past the first IPv6
answer — it connects through the whole list now and keys the pool by
the host as written. With those three, the test fetched a public
page by name: status 200, chunked and keep-alive, from a real server,
in about a second — the arc's two stages meeting.

**The clock (as built, 2026-09-05).** Built ahead of TLS, whose
certificate checks want the time, and small by design. The kernel
keeps one number, the Unix time at which the cycle counter read zero,
and where it came from: `kernel/clock.zig`; the port reads the
real-time clock once at boot through a HAL entry
(`arch.platform.rtcSeconds` — on aarch64 the PL031 found in the device
tree by compatible string, its data register mapped live and read
once; on x86_64 the loader's date-at-boot response — firmware's clock
through UEFI, the modern path, the CMOS ports being legacy — plus the
seconds since boot from the TSC), and two
syscalls expose it: `clock_get`, for anyone, since reading time is not
authority, and `clock_set` behind a new `clock` capability, the grant
a unit asks for by name. Userspace adds its own cycle count
(`usys.wallMs`). The time service (`user/clock.zig`) is SNTP both
ways — `lib/sntp.zig` builds and reads the packets and turns a round
trip into an offset and a delay, `choose` takes the median of the best
half — asking each configured server (names resolve) four times and
setting the clock by the winner, refusing an offset over a day, asking
every thirty seconds until it knows the time and hourly after; and it
answers SNTP on UDP 123 so a node learns the time from a peer. Its
loop is one doorbell over two datagram sockets, and while its own
question is out it keeps answering others — which is how the drill
syncs a node from itself over loopback (offset 0, delay 0, four
samples). `lib/civil.zig` is Hinnant's days-from-civil arithmetic and
ISO 8601 text, round-tripped across four thousand years of dates in
its test; `date` in the language answers the record or `err
no_clock`. Two things the tests caught: an NTP fraction converted by
truncation lost a millisecond each way (rounded now), and a signed
year zero-padded by `std.fmt` prints with a plus sign. One thing the
first boot caught: a "never synced" sentinel of `minInt(i64)`
overflowed the first subtraction, and the service's panic — logged
now, thanks to the earlier lesson — said so in one line. And the wire
check found the day's largest bug, older than the day: the kernel
tick is a tenth of a second, and `sleep` and `timer_arm` count ticks,
but the language's `sleep`, and every timed wait written this day —
HTTP's idle and stall limits, the bounded connect attempt, the SNTP
reply wait, netsvc's own retransmission scan ("every tenth of a
second", armed for ten ticks) — had assumed ten milliseconds, so each
was ten times what it said (a 3 s idle was 30, a 1.5 s attempt 15, and
one silent IPv6 address cost an SNTP sync eight seconds). `usys.tick_ms`
and `msToTicks` are the single conversion now; every caller speaks
milliseconds; the scan runs every tick.

**The clock, part two (as built, 2026-09-05): what it changed.** The
re-evaluation the clock arc promised, done as code where a decision
had been a workaround. mossfs had stamped every change with seconds
since boot — `fs.zig`'s `nowSec` was the cycle counter over its rate
— so a file written a minute into day two sorted before one written an
hour into day one; it stamps wall seconds now, and 0 when the system
does not know the time, the same "unknown" the archive's files always
reported. The log had no time at all: one `stamp` in `kernel/log.zig`
now leads every line, the kernel's and a unit's alike — `03:14:22.123`
once the clock is known, `+12.345` seconds since boot before — and the
runner's `readLog` removes stamps before matching, so no marker
changed and a `grep` on a kept log still sees the time (the guest and
vmnode drills caught the case missed on the first pass: a guest's line
arrives inside the host VMM's stamped line, `19:27:50 [vmm] guest|
+0.502 [info ] …`, so both stamps must go); the calendar
moved to `shared/civil.zig` for the kernel's sake (lib/ cannot see
shared, and http.zig takes its Date text from the host instead).
HTTP responses carry `Date` when the clock is known. And the clock
became the fabric's: `clock-cluster` runs in the system profile, node
1 serving SNTP from its RTC and every node asking for it — by *name*,
`node1.moss.test` (2026-09-09), asking again every ten seconds until the
first answer since a peer may still be booting; the fabric-login drill
requires node 2 to have synced from node 1 (the `fabric` drill is the
kernel's own driver — no init, no units — which the first cut of this
check forgot).

**Fabric node names (2026-09-09).** The cluster addressed its nodes by
literal — `10.77.0.N` in the clock's settings, the fabric's own transport
by node id. Now the cluster profiles run `dnsd-cluster`, a name server
beside the clock, serving the static node-name zone (`conf/dns.msh`:
`node1`/`node2` under `moss.test`, each its `10.77.0.N` A record and
`fdcc::N` AAAA); the cluster network view (`net-cluster`) points every
node's resolver at its own dnsd on loopback (`::1`), so a name resolves
without a slirp gateway (there is none on the fabric segment). Each node
runs its own dnsd over the shared static zone — a deployment-wide hosts
file, served, not a dynamic membership map (that would learn addresses
from the fabric's member view — a later step). The proof rode an existing
path: the SNTP sync's server became `node1.moss.test`, and because the
clock retries resolution every ten seconds until it syncs, the
boot-ordering race (dnsd not up when the clock first asks) resolves
itself; the flogin drill's cross-node sync now goes by name end to end.

**The dynamic node map (2026-09-09): names track membership.** The later
step above. `dnsd-cluster` is now handed a fabric front channel
(`give: { tag: fabric, unit: fabsvc }`), and a `nodeN.moss.test` query
consults fabsvc's live membership instead of a hardcoded list: an up
member answers `10.77.0.N`/`fdcc::N` — built directly as the OS's address
words by the same convention netsvc assigns itself (`nodeIp4`,
`fdcc::<node>`), so `fdcc::10`'s hex-vs-decimal trap never arises — a
member the node has seen but that is now down is NXDOMAIN, and a node the
fabric has never heard of falls through to whatever the static zone says.
So a name appears when its node joins and stops resolving when it leaves,
across whatever set of nodes is actually up — no zone edit. `node1` stays
in the static zone as the bootstrap seed name (a joiner resolves its seed
before it is a member of anything, and the plain net-drill `dnsd`, which
has no fabric, still needs it); every other `nodeN` is left to the
overlay. The query fabsvc answers is `member_state{node}` → a single word
(2 up, 1 down, 0 unknown), deliberately *not* the buffer-based `members`
listing: `fab_buf` is one shared global that every client's `attach_buf`
overwrites, so a third concurrent reader (dnsd, beside usersvc and the
shell) would race it — a word reply needs no buffer and cannot. The proof
(the flogin drill): `node2.moss.test`, removed from the static zone,
resolves on node 2 only because node 2 is a live member of its own
fabric — `fabname: node2 -> fdcc::2 10.77.0.2` in the log, a joiner-side
oneshot the runner checks. What stood: liveness on monotonic
time, certificates without expiry (a node with no RTC cannot judge
one), records without expiry, the resolver's monotonic TTLs, shares
that end with the session — the roadmap entry says why for each.

**TLS, the client (as built, 2026-09-05).** `lib/tls.zig` wraps the
standard library's TLS 1.3 client (`std.crypto.tls.Client`) so that
nothing in it touches a socket, a clock or an entropy source: a
`Transport` is two function pointers (send every byte; receive some),
the wall clock and 240 random bytes are handed in, and the trust roots
are a `Certificate.Bundle` built from PEM text by our own loop (the
library's loader wants an OS file). The client's `Reader`/`Writer`
seams made this a hundred lines: a `stream` that receives into the
reader's buffer and a `drain` that sends the writer's; the `.bundle`
option wants an `Io` and a lock the client only reaches to fetch a
missing root from the OS, which never happens off one — the lock is
uncontended and the `Io` is `undefined`, and the comment says so. A
session owns four record-sized buffers (the two the client asserts on
its wire side, its own read buffer, a 4 KB write buffer), so
`user/tlscmds.zig` keeps a table of four sessions and the roots' arena
in a buffer mapped on first use, and answers for `send`/`recv`/
`status`/`close` on its own handles before the socket commands do;
`fetch https://` goes through a `Conn` that is a socket or a session.
The roots reach a program as a *file given under a tag* — `{ tag:
roots, file: tls/roots.pem }` — a new delivery: init copies the archive
file into a shared buffer of its own (a u64 length, then the bytes)
and gives the cap, since the 2 KB `file:` delivery is for settings.
The gate proves it against `openssl s_server -www` on the host, the
certificate for `tls.moss.test` (the drill's zone maps it to slirp's
host address) signed by a root only the drill trusts; the wire was
proved once by hand against example.com and cloudflare with the
Mozilla bundle. What it took to get there, each a lesson: a TLS 1.3
server's first records after the handshake are session tickets that
yield no application data, and a `read` that took an empty fill for
end of stream ended every response at zero bytes; the client with its
cipher suites and certificate parsing is 450 KB of ReleaseSafe code,
which put msh past the 512 KB program stage (the shared-buffer cap
went to 256 pages, the stage to 1 MB); the `net` profile ran no `rngd`,
so the first handshake found an unseeded pool (`no_entropy` — the
profile has it now, and the drill's QEMU an entropy device); and the
handshake — hybrid key share, a certificate chain on the stack — needs
more than the 96 KB user stack, which faulted 27 KB below its floor
(256 KB now, eagerly mapped, sixteen domains at most).

**TLS, the server (as built, 2026-09-05).** The standard library ships
no TLS server, so `lib/tls.zig` grows one — TLS 1.3 only, written on
the same primitives the client is (`tls.hkdfExpandLabel`, the AEAD and
hash suites, `Certificate.der`), over the same `Transport` and `Wire`
adapters, so it too touches no socket, clock or entropy. One key
exchange (x25519), the three IANA AEAD suites chosen from what the
client offers, a certificate chain and an ECDSA P-256 or Ed25519 key
loaded from PEM into an `Identity` (SEC1 and PKCS#8 both parsed); no
client certificates, no resumption, no HelloRetryRequest — a client
with no x25519 share is refused. The handshake is one function
generic over the negotiated suite: read the ClientHello, derive the
handshake secrets, write ServerHello + an encrypted flight
(EncryptedExtensions, Certificate, CertificateVerify signing the
transcript, Finished), then read and verify the client Finished.
Application records dispatch on the AEAD alone, since all three share a
12-byte nonce and 16-byte tag. In the language it is `tls-listen PORT`
(a TCP listener the host presents as a `tls-listener`) with `accept`
and `serve` shaking hands over it — httpcmds runs its accept/read/
handle/write loop over a `Conn` that is a plain socket or a tls
connection, so a handler is the same ordinary function either way, and
`http-read`/`http-write`/`serve`/`accept` type-check against a
`one_of` of the plain and tls kinds (tlscmds owns `accept`'s
signature). The identity reaches the program as a tagged-file
certificate and a `secret` key, the same capability shapes as the
roots. The gate proves it the hard way: `openssl s_client` connects to
the drill's server through a slirp forward, verifies the chain against
the drill's root, and reads the page — an independent implementation
on the other end, the mirror of the client's `openssl s_server`. Two
lessons on the way there: openssl negotiates a SHA-384 suite where our
own client took SHA-256, so a CertificateVerify buffer sized for the
32-byte transcript overflowed on the 48-byte one; and a listener made
by `tls-listen` must be hung on the network doorbell (`n.watch`) like
any other, or `accept` sleeps forever while the client waits — the
handshake deadlock reads on the wire as "shutdown while in init".
Not built beyond the client's list: client certificates, resumption,
revocation, and RSA server keys.

**DNS over TLS (as built, 2026-09-06).** The resolver in `netsvc` is
event-driven and non-blocking; a TLS handshake is a blocking,
multi-round-trip exchange, and pumping one inside netsvc would either
starve the stack or demand reentrant event processing. So DoT is a
separate program, `dotd`, shaped exactly like `dnsd`: one thread, one
query at a time. It binds UDP 53 on its view, which makes it an
ordinary local resolver as far as netsvc is concerned — point
`conf/net.msh`'s `resolvers` at `::1` and the existing forwarding path
carries queries to it, no netsvc change at all. For each datagram it
opens a TLS 1.3 connection (the `lib/tls.zig` client over its own TCP
socket, verifying the upstream against the roots its unit gave and the
wall clock), frames the query as DNS-over-TCP does — a two-byte length
then the message — reads the reply the same way, and sends it back. It
never parses the DNS; it moves opaque messages, so it is purely the
resolver's private path out. The gate's upstream is `tools/dot-
responder.zig`, moss's own TLS server (again `lib/tls.zig`) run over
stdio by a QEMU `guestfwd ... -cmd`, answering a fixed zone from
`lib/dns.zig`'s `buildResponse`; the `dot` drill points netsvc at dotd
and watches a name only that responder knows resolve to its address.
The lesson this arc paid for was in the responder, not the forwarder:
`std.Io.Reader.readVec` returning zero is transient, not end of stream
(only `error.EndOfStream` is a close), and a transport that took the
first zero for a close aborted the handshake on its very first read —
the moss socket API says `closed` explicitly, but a raw byte reader
does not. Not built: keep-alive (a fresh connection per query),
DNS-over-HTTPS, and a resolver that speaks DoT itself rather than
through dotd.

**Assets, updated in a running system (as built, 2026-09-06).** Trust
roots expire and rotate, and timezone and locale databases will follow;
baking them into the read-only archive would mean a rebuild to change
one. So the archive became a *seed*, and `assets/` a new filesystem
tier (a top-level tier is fixed at format, so it is in `std_hierarchy`
beside `img/` and `home/`, not something a program may `mkdir`). At
first boot init lays every archive entry under `assets/` into the tier,
skipping ones already present so an update survives reboots — the same
installer pass that content-addresses programs into `img/`
(`installAssets` beside `installImages`, sharing one attached buffer:
the first cut attached a second buffer to the same view and every write
silently failed, because a view holds one). A program reads its asset
from a view it holds and reloads when the file's mtime *or* size changes
— mtime alone is second-grained, so a bundle swapped within the same
second as the read would be missed, and size catches the common case;
`fsclient.readWhole` is the no-allocator read a service uses. The
authority to update is nothing new: a read-write view of the path. dotd
and the msh TLS hosts both moved their trust roots off a spawn-time
capability onto `assets/tls/roots.pem` this way; the `dot` drill proves
the whole loop — seed, resolve over TLS, overwrite the roots with a
root that does not vouch for the upstream, and watch the next resolve
turn untrusted with no restart. This is the one way reference data ships
and updates; a package manager, if it ever comes, would sit on top of
it, not replace it.

**Locale formatting from CLDR (as built, 2026-09-09).** The locale
database the assets note foretold. Numbers, dates and money read
differently in every place — `1,234.56` / `1.234,56` / `1 234,56`,
`$1,234.56` / `1.234,56 €` / `￥1,235`, `Sep 9, 2026` / `2026年9月9日` — and
that knowledge is Unicode CLDR's, ~50 MB of it. moss carries a distilled
slice: `lib/locale.zig` is a pure, freestanding, host-tested formatter
over a compact 1 KB blob (`assets/locale/cldr.db`) holding, per locale,
the number symbols and grouping/fraction rules, month and day names, am/pm
markers, the CLDR date/time patterns, and a small currency table. It
parses the blob with no allocator (borrowing its bytes) and renders CLDR
patterns straight — a run of a letter is a field of that width, quotes and
non-ASCII bytes like 年月日 pass through — so the 12-hour-with-a-marker vs
24-hour clock, the month names, and the field order all follow the locale.
Region tags fall back to language (`de-AT` → de-DE), and JPY's zero
fraction digits come from CLDR's supplemental data, not a guess.

The pipeline stays hermetic. `third_party/cldr/*.json` are faithful
projections of CLDR 48.2.0 — a few hundred bytes each, every value
verbatim; `tools/cldrgen` distills them into the blob (parsing the CLDR
number patterns into structured fields, and reusing `lib/locale`'s own
serializer so writer and reader cannot drift), run offline as `zig build
cldrgen` like `mkfont`. The blob is seeded into the assets tier and read
the same self-owned, live-reload way trust roots are: `user/localecmds.zig`
holds a read-only `assets/locale` view (given under `{ tag: locale }`),
loads `cldr.db`, and reloads it when the file's mtime or size changes — so
the auto-updater dropping a fresher database in takes effect with no
restart. It adds the shell/script commands `fmt-number`, `fmt-int`,
`fmt-money`, `fmt-date`, `fmt-time`, and `locales`, compiled into mshrun
(no service — the formatter is pure and the data is small). The GUI login
clock, which had hardcoded English month names, now reads `fmt-time` /
`fmt-date`. The `locale` drill boots the fs stack from a lone view give
(lazily, like fontcli), formats the four launch locales, and asserts the
groupings; the `gsession`/`gisession`/`guishell` drills still pass with
the localized clock. The four launch locales are en-US, de-DE, fr-FR,
ja-JP; more, plurals, and relative time are a schema extension away.

**A shared locale service (as built, 2026-09-10).** The formatter began
as a per-process library: each program parsed `cldr.db` itself and held its
own default locale, so a locale choice in one program (the settings app)
never reached another (the top-bar clock). `user/localesvc.zig` centralises
it into a system service, the way fontsvc centralises type — it parses the
CLDR db once (through the `assets/locale` view, live-reloaded when the
updater swaps it), holds the session's current locale, and formats numbers,
integers, money, dates and times on request. `user/localecmds.zig` is now a
thin client: `fmt-*` marshal the value and locale tag over the service's
request buffer and read the formatted string back, and `sessionlocale`
sets the service's default — so one push drives the whole session's
formatting at once. The client model is fontsvc's exactly: a client
`register`s for a badged channel and attaches its own buffer, keyed by
badge so concurrent clients (a greeter's clock and a settings sample) never
trample one buffer; the `.locale` cap changed from a read-only view into
the service channel, and the service holds the view instead. A typed
message carries only its tag plus three payload words, so the format
request packs `kind`, the tag length and the width/currency length into one
`meta` word beside the value (the same four-word ceiling that shaped
statfs). The service logs the applied locale on a push (a durable trace,
and what a drill keys on). Every locale consumer — the `locale` drill, the
auto-updater, the top bar, the greeters, the settings app — now formats
through the one service; formatting output is unchanged (still the pure
`lib/locale`), so the drills pass verbatim.

**The locale auto-updater (as built, 2026-09-09).** The mechanism that
keeps the database fresh — and moss's first service that reaches the
internet on a timer. `user/localeupd.zig` is the dotd model turned around:
where dotd *reads* trust roots from a view, this *writes* a locale database
into one. On a schedule it fetches a fresher `cldr.db` from a configured
upstream over TLS (the same `lib/tls` client dotd uses — roots loaded from
the assets view and hot-reloaded, certificates dated by the wall clock),
validates it by parsing it (`lib/locale`, so a truncated or garbage blob is
refused and the good one kept), and, if it differs from what is installed,
writes it to a temp file and renames it over `assets/locale/cldr.db` — an
atomic swap a reader never catches half-written. The consumers reload on
mtime/size, so the new data flows out with no restart and no coordination.
It fetches the *pre-built blob* (cldrgen's output, served upstream), never
raw CLDR — no megabytes of JSON parsed on-device. Config
(`conf/locale.msh`, read from the boot data buffer like clock's): the
upstream URL, the certificate name (the upstream is reached by IP, so the
name is separate), the roots path, and `interval` — 0 fetches once and
exits, > 0 loops on a `timer_arm` notification every that-many seconds. It
is not in the `system` profile: a test OS has no real CLDR upstream, so it
runs only in its drill (and a deployment adds it with a real endpoint).

The `localeupd` drill is the assets-swap loop end to end, the way the `dot`
drill is for trust roots: `openssl s_server -WWW` serves a rel-bumped
fixture blob (`tools/testdata/cldr-fixture.db`, cldrgen with `--rel`) over
TLS on the host, the guest reaches it through slirp as 10.0.2.2, and the
updater fetches, validates, installs, and logs `installed CLDR
48.2.0-upd` — a release string only the fetched blob carries, so the log
proves the new bytes came off the wire and landed in the tier.

**Concurrency, stage 1: workers (as built, 2026-09-06).** The language
has no threads — shared mutable interpreter state is the race the model
refuses. Concurrency is *domains*: `spawn { handler }` starts a worker
(an mshrun run with arg 2, `serveWorker`) in its own domain behind a
typed channel, and `x | call $w` sends `x` and gets the handler's value
back — the handler runs there with `$in = x`, and one worker answers
many calls. The channel and a shared buffer are the remote stage's exact
shape: a small `WorkReq`/`WorkResp` carries lengths, the value is an
mshl data literal in the buffer. Only data crosses (the `remote` rule);
captures do not, so a block sees `$in` and nothing of the caller's
scope. The handler runs as a *function* (`fn { src }` called with `$in`)
so a `?` inside it returns the err's own value as the call's `err`,
never an "unhandled err" — a bad number to `spawn { (int $in)? * 2 }`
comes back as the call's err, a good one `ok`. A worker is a handle like
a socket: dropping it at the end of the statement, or `close $w`,
destroys its domain totally (crash-only), so a script's exit kills its
live workers and leaves no orphan; `status $w` is `alive` or `closed`,
and every teardown meets the leak bar.

A worker is also its caller's *filesystem agent*. Before the handler,
the caller derives a **fresh** view from its own — a new badge, read
write — and hands the cap over `attach_view`; the worker attaches its
own shared buffer to that badge and serves its handler's fs commands
through it. The fresh badge matters: a view holds one attached buffer,
so a *shared* badge would make the worker's buffer displace the
caller's and quietly break the caller's own reads (the shell lost
`open data/l.msh` to exactly this before the fix). This is the first
cap to cross the worker channel; passing an arbitrary open handle (a
socket handed to a worker) is the residual. The shell drill spawns a
worker that `stat`s a file through its view and checks the size comes
back.

Workers are not the interactive shell's alone: any mshl host that holds
a spawner may `spawn`, so a *script* offloads work too. `run mshrun`
grants the child a spawner (the shell delegating its own authority, as
init does), and the finding, staging and verifying of a program image
— the shared step `run` and a worker both need — moved to `progload`,
which the shell's `run` and mshrun's worker loader now both call over
their own stores. mshrun cannot read its own grants, so it *probes* for
a spawner (a spawn-gated `sysinfo` on the fixed slot) and offers
`spawn`/`call` only when the probe answers. Two sizings had to give:
`max_domains` went 16 → 32 (a script spawning up to four workers, itself
a child of the shell, is nested spawning 16 could not host, ~48K more
static kernel memory), and a spawner-holding `run` child gets 20M rather
than 8M — room for its workers plus the transient overlap while a
finished worker's memory is still being reclaimed by the reaper (the
QuotaExceeded the shell itself paid for at 24M). A boot-time script
*cannot* stage a worker: the program store is installed post-boot, after
units spawn — so scripts-with-workers are a post-boot capability, proven
by the shell drill running one through `run mshrun`.

**Concurrency, stage 3a: parallel workers (as built, 2026-09-07).**
`call` is a synchronous rendezvous — the kernel parks the caller until
the worker replies — so a script that only `call`s runs its workers one
at a time. Parallelism splits the call: `x | dispatch $w` writes the
input and sends `WorkReq.dispatch`, to which the worker replies `.ok`
*before* running the handler, so the caller does not block on the work
— it goes on to dispatch other workers while this one computes. The
result waits in the worker's buffer for `await $w`, which sends
`collect` and reads it back. Two workers dispatched before either is
awaited run at once, each in its own domain on its own core; `await`
joins them in turn. This needs no new kernel primitive — it is the
existing call/recv/reply, with the worker choosing to answer the
dispatch early and stash its result. One unclaimed result at a time:
`dispatch` on a busy worker, or `call` on a dispatched one, is refused;
`await` with nothing outstanding is an err, not a hang. `select` (the
first of many to finish, via `notify_bind`) and a concurrent `serve`
build on this.

Two limits grew to make room for the language's own weight. Every
program image is copied through a *stage* — an shm buffer — into the
child; msh, now carrying every command module (files, net, TLS, HTTP,
fabric, workers) and the whole mshl interpreter, crossed 1M. So the
stage went 256 → 384 pages (`loader.default_pages`), and the kernel's
`shm_max_pages` with it (256 → 384): the ceiling on any one shm object
existed precisely for the program stage, and the stage had outgrown it.
Each shm object's page table grew by the same factor; the cost is a few
kilobytes per live buffer.

**Concurrency, stage 3b: race — the first of many (as built, 2026-09-07).**
`await` joins one worker; `race $workers` returns whichever of a list
finishes first, so a script can collect results in completion order
rather than dispatch order. The mechanism is the approved cooperative
one: a single doorbell notification the caller holds and hands to each
worker (a notification cap over the worker channel, `attach_bell`, with
the worker's slot as its bit). A worker rings the doorbell with its bit
the moment a dispatch finishes; `race` waits on the doorbell
(`notify_wait`) until one of the workers it was given has rung, and
returns that worker for the caller to `await`. A `ready_mask` remembers
bits seen but not yet collected, so bells that arrive together are not
lost. `await` was routed through the same doorbell (not a bare blocking
collect) so that every completion's bell is consumed by exactly one of
the two — otherwise a bell from a finished-and-collected run could
linger in the notification and make a later `race` on a reused slot fire
early. No kernel primitive was added: `notify_wait` already returns
immediately when bits are latched and blocks otherwise, which is exactly
a doorbell. This is the "cooperative select" of the model, over workers;
the same doorbell, bound into a serving recv with `notify_bind`, is how
a concurrent `serve` over many sources will wait.

Two more name collisions were paid for here, both because the shell's
verbs and the worker verbs share one namespace: `start` was already the
service-start command (so async dispatch is `dispatch`), and `select`
was already the table's column projection (so the first-of-many is
`race`). The lesson is that a new worker verb must be checked against
every host command module, not just the workers'.

**Concurrency, stage 2: publish/lookup (as built, 2026-09-07, same-node
first).** A worker can be offered to the pool: `publish SERVICE $w`
hands the worker's channel (our client end) to the fabric under a
service id — a small number, like `rspawn`'s catalog, in the fixed
`ServiceId` space rather than a string, so the fabric wire is unchanged
— and `lookup NODE SERVICE` gets a channel back wrapped as a `service`
handle that `call` drives with its own buffer, speaking the same
`WorkReq` the worker already serves. A published worker is reached only
through `lookup` (a direct `call`/`dispatch` errs — its buffer is now
the looker-up's), one client at a time. The cross-node hop is the
existing machinery: the fabric's `forwardCall` already turns a call's
attached shm cap into a proxied session buffer with a twin on the
service's node (this is how `remote` ships a script and its input), so a
looked-up service's `call` proxies the same way — nothing new on the
wire. The fabric-login drill proves it end to end: node 1 publishes a
doubling worker as service 3 and stays alive, node 2 looks it up and
calls it with 21, and its request crosses the wire to node 1's worker
and 42 comes back — a script as a pool service, reached from another
node. (The publisher self-guards the boot-time race: the program store
installs post-boot, so it retries the spawn until img/ is ready, then
publishes and sleeps.) One command was mis-gated: a fabric-only script
with no spawner could not `lookup`, because mshrun turned the worker
commands on only for a spawner; now it turns them on for a spawner OR a
fabric, and each command self-guards (spawn needs the spawner, lookup
the fabric). Multiple clients work: the fabric-login drill opens two sessions to the
one published service and calls them alternately with different inputs,
and each answer is correct. It works even over the shared per-export
buffer because every call carries its own length and the worker reads
exactly that many bytes, and the diff shipped for a call patches that
range — so a session's data is always right where the worker looks, no
matter what a prior session left beyond it. The one case this does not
cover is *simultaneous* calls to the same service: two fabric jobs
writing that one export buffer at the same instant would race. Making
that safe means a buffer per caller session on the service's node
(rather than per export) — correct by construction, but a change whose
only failure mode is a race the deterministic drills cannot reproduce,
so it is deferred rather than made blind. The other standing limit: a
published worker dies with the script that spawned it, so a durable
service needs a host that outlives the request.

**Concurrency, stage 2: durable service units, `dial`, and names (as
built, 2026-09-07).** A published worker's life is its script's; a
durable service should not be. The answer is the one the system already
had at a smaller radius: a *unit*. A service is `conf/units/<name>.msh`,
and init starts it, keeps it up (crash-only restart on a budget), and
stops it only when told — its life is init's, not any caller's. mshrun
grew a service mode (arg 3): after setup it does not run its script once,
it serves `WorkReq` on its boot channel with the script pinned as the
handler, until init stops or restarts it — the worker serve loop given a
fixed handler instead of one over the wire.

`dial NAME` reaches it locally: init `connect_named` looks the unit up by
name, lazily starts it, and hands back the channel, wrapped as the same
callable `service` handle `lookup` produces (`x | call $s`). `dial NODE
NAME` reaches one on another node: the fabric carries a `remote_connect`
to the peer, whose fabsvc (holding its own init's front channel, given
`{ tag: init, self: true }`) asks *its* init to connect the unit and
exports the channel back — the remote-spawn path, but connecting a
supervised unit rather than spawning a raw image, so the service's life
is the hosting node's init. Starting a service on a peer takes the peer's
spawn authority, signed into its certificate. The fabric-login drill
dials the `doubler` unit on node 1 from node 2 and 7 comes back 14; no
keep-alive loop anywhere — the sleep-loop the publish drill needed was an
artifact of launching a service as a script-spawned worker rather than a
unit. (One bug: a fabric-only script with no spawner could not `lookup`
until mshrun turned the worker commands on for a spawner *or* a fabric,
each command self-guarding.)

The identity is a *name*, not a number, end to end. `dial`, `publish`
and `lookup` take a string (up to 16 bytes, two words, carried in the
request and every fabric frame that once held a service number); the
fabric's published registry is not a separate table but a flag and a
name on the exports table already there — a published service *is* an
export that carries a name — so there is no `fab_max_services`, and the
count of services a node can offer is bounded by the exports it already
has, not a second, smaller, arbitrary limit. `start NAME`, `stop NAME`
and `svc` moved off numbers too: init gained `stop_named` and a `list`
that fills a buffer with a `UnitRec` per unit it knows, so `svc` shows
the whole supervised set (filter with `where state == up`) rather than a
hardcoded pair. With nothing left using it, the `ServiceId` enum was
deleted. The native session manager rode the change (it publishes and
looks itself up as `"usersvc"`, proven still cross-node by the flogin
drill), as did the Phase-5 init demo (`connect_named`) and the
fabric-security drill's `"calc"`. This is what the fabric's own header
meant by "init at a larger radius": the same verbs, the node just an
address, the service just a name.

**Networking: a socket handed to another view (as built, 2026-09-07).**
A socket in netsvc is owned by a badge — the net-view client that opened
it — and `sockOf(badge, idx)` gates every operation on that ownership.
`handoff(sock)` moves ownership: netsvc reassigns the socket to a fresh
view badge, mints a channel cap to that view, and hands it back; the
socket keeps its number and its whole connection (the send/receive rings
are per-socket and global, so nothing is copied — only the owning badge
changes). Whoever holds the returned cap owns exactly that socket and
nothing else, and the caller's own view can no longer touch it — so the
cap *is* the authority, with no badge to guess. This is the mechanism
for a socket to cross to another domain: a server will hand an accepted
connection to a worker, which serves it while the server goes back to
accept. The net drill proves the primitive: the echo client connects,
hands the socket to a fresh view, watches its old view refused, and
echoes on the new view. The new owner re-`watch`es the socket for its
own doorbell (the handoff clears the old bell).

A worker can now be handed a socket. `x | call $w` already takes data;
when `x` is a socket handle instead, workcmds hands the socket off (the
socket's value carries its net view as the handle's context and the
number as its id), gives the worker the resulting view cap over a new
`attach_net`, and sends a `serve { idx }` — and the worker runs its
handler with `$in` a socket for that number on its own net view, so the
handler's `recv`/`send` work the connection. The caller's socket handle
is consumed (closed) since the socket has moved. Workers gained a net
view the way they already had a filesystem view; the net-drill script
(now holding a spawner) proves it: it accepts a loopback connection,
hands it to a `spawn`ed worker whose handler echoes on it, and reads its
own bytes back — "socket to worker ok".

And `dispatch` a socket rather than `call` it, and the serve is
concurrent: the worker's `serve` became async like `dispatch` — it acks
at once, runs its handler on the socket, and rings the doorbell when
done — so a server hands each accepted connection to its own worker with
`socket | dispatch $w` and goes back to accept, and `await`/`race` reaps
whoever finishes. `call` a socket is now just that plus an immediate
`await`. The net drill accepts two connections, dispatches each to its
own worker before awaiting either, and reads both echoes back —
"concurrent serve ok", worker per connection. What the deterministic
drill cannot show is that the two are served at the *same instant*: it
proves each connection gets its own worker and its own answer, not the
timing, since forcing genuine overlap is the same unreproducible thing
as the simultaneous-call race. The structure is the point — a slow
handler on one connection no longer blocks accepting the next.

**Concurrency: a built-in `serve` over a worker pool (as built,
2026-09-07).** The accept-and-dispatch pattern above became a command:
`serve $listener { handler } [count]` accepts connections and hands each
to a fresh worker running the handler block (with `$in` the socket), up
to `max_workers` serving at once, reaping finished workers to make room
for more, and draining the rest before it returns the number served.
The reaping is the same doorbell `race`/`await` use: when the pool is
full the accept loop waits on it for any worker to finish (its handler
returned, so its response is already sent), tears that worker down, and
spawns a fresh one for the next connection. It lives in `workcmds` (which
already imports `netcmds`), because it needs both a spawner and a net
view — the listener handle carries its view as the handle's context — and
it drives the raw handoff directly (`startServeRaw`), so a long accept
loop makes no per-connection interpreter handle. The deliberate design
choice is a worker *per connection* bounding concurrency, not a fixed
set of workers reused across connections: `handoff` mints a *fresh* net
view per socket, so a reused worker would re-`attach_net` a new view on
every connection and leak the previous one — whereas a per-connection
worker attaches exactly one view, torn down with its domain when it is
reaped. The old request-level HTTP server kept its own name, `http-serve`
(it belongs beside `http-read`/`http-write`, does its own parsing and
keep-alive, and handles TLS listeners a raw handoff cannot); the new
`serve` is plain-socket and worker-level, and a worker's handler may
itself speak HTTP. The net drill runs five connections through a pool of
four — proving the fill-then-reuse path, not just one worker each — and
reads all five echoes back: "pool serve ok".

### The gate (as built, 2026-09-03)

`zig build check` builds one kernel per drill and boots each under QEMU
(`tools/runner.zig`), scoring serial markers. Two things make it a
harder gate than "every test once, Debug": the kernel-heavy drills
(sched, domain, ipc, sandbox, fs, users) boot **a second time under a
ReleaseSafe kernel** — the `+rs` rows, separate logs and disks — because
the optimizer reorders and merges what a Debug build leaves in source
order, so a data race or a non-volatile system-register read shows up
there and nowhere else (the first optimized boot found one: see "Zig
conventions"); and the runner takes `--repeat N` (`-Dsoak=N`), running
each drill N times and stopping at the first failure with its log kept,
because the bugs that matter most here — a one-in-four teardown race, a
one-in-eighty recv hang — are only visible under repetition. `--only
a,b` (`-Donly=…`) runs a subset without rebuilding anything else. The
whole gate is about two minutes; `-Doptimize=ReleaseSafe` runs all 22
drills optimized (they pass; the IPC benchmark runs ~3x faster per core
under TCG that way, and its three-core scaling drops to ~1x — the
syscall is no longer the bottleneck the lock contention hides behind).

## Networking

**As built (Phase 10):** the net service is one userspace process holding
the virtio-net driver and a deliberately tiny dual-stack TCP/IP: ARP (v4)
and NDP/ICMPv6 (v6) resolve the slirp gateways at startup; TCP was
stop-and-wait (one unacked segment per socket) until the mshl v3 network
step below made it windowed; receive is in-order, there is no congestion
control — enough for the fabric protocol and a script's, not an RFC
museum.
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

## Graphics: the display server

**Stage 1: virtio-gpu and a scanout (as built, 2026-09-07).** The M3's
aarch64 QEMU virt boot brings no framebuffer — only x86's Limine boot
does, which `kernel/fbcon.zig` rides — so on the development machine
virtio-gpu is the only way to a pixel at all, and it is a userspace
driver like every other device (`user/gpusvc.zig`, virtio device type
16, `1af4:1050`, brought up through the same transport as blk/net/cons:
device cap over the boot channel, IRQ-as-notification, DMA grant). The
deliberate shape — decided before any code, because a GUI is the goal
and the invariants would be expensive to retrofit — is that **the
console does not own the framebuffer; a display server does, reached
over a channel.** That single choice pays for three things at once:
supervision (a GPU fault kills and restarts one crash-only domain, not
the system), fabric-transparency (a surface is a channel, so a remote
surface is just `dial NODE display` — no new mechanism), and an mshl GUI
layer later (surfaces are the substrate a declarative toolkit renders
into). Stage 1 builds the driver and proves the 2D path end to end;
the surface protocol clients drive is the next stage.

Bring-up is the virtio-gpu control queue speaking its command set:
negotiate (VERSION_1 + ACCESS_PLATFORM behind the SMMU, no optional
features), set up the control virtqueue, then `GET_DISPLAY_INFO`,
`RESOURCE_CREATE_2D` (a B8G8R8X8 host resource), `RESOURCE_ATTACH_BACKING`,
`SET_SCANOUT`, `TRANSFER_TO_HOST_2D` and `RESOURCE_FLUSH` — each a
two-descriptor chain (the command device-readable, a response
device-writable) submitted one at a time and waited on the device's
interrupt. The one wrinkle is the framebuffer's size: 1024×768×4 is 768
pages, past `dma_alloc`'s 16-page cap, so the backing is a scatter-gather
list of chunks — which is exactly what `ATTACH_BACKING` takes (an array
of `{addr, length}` entries). A solid fill needs no cross-chunk offset
arithmetic (every chunk holds the same pattern); glyph rendering will,
when the terminal — the first surface client — arrives.

The drill proves it **both** ways, the verification decision for the
whole arc. Deterministic, in the gate's serial-marker model: gpusvc
confirms the device returned OK to every command and reads its own
backing back before it logs `gpu: scanout up` — the driver drove the
device correctly and the memory is coherent. And real pixels: the test
runner learned a minimal QMP-over-TCP client (`tools/runner.zig`), so
once the marker appears it `screendump`s the scanout and asserts the
centre pixel is exactly the fill colour (`0x3399CC` written as
B8G8R8X8 reads back as RGB `51,153,204` — the byte order maps through
with no fudge). The device drill boots a full system under a new `gpu`
profile: gpusvc is the profile's one essential eager unit, and after
holding the scanout up a moment for the screendump it exits, so the
boot ends on a clean shutdown and the usual leak check. Extending
`DeviceKind` for this (gpu at 16, input at 18 — the sparse virtio
type numbers) meant the kernel's `device_register` had to validate a
kind by enum membership (`std.enums.fromInt`) rather than a numeric
range, since `@enumFromInt` over a gap is illegal behaviour.

**Stage 2: the surface protocol (as built, 2026-09-07).** This is the
seam the whole arc turns on made real — `gpusvc` stops being a
self-contained drill and becomes a *server* clients drive over a channel
(`shared.GpuReq`/`GpuResp`, the display cap tag). `create_surface` hands
back a surface id, its size, and a shm cap — a pixel buffer the client
maps and draws XRGB into; `commit{surface, rect}` copies that damage
rectangle from the surface into the scanout's framebuffer and flushes it
to the host. The copy is the isolation boundary: the client scribbles its
own buffer, never the device's DMA memory or the scanout, and a future
compositor arbitrating many surfaces is an evolution of this same
protocol, not a rewrite — which is what makes it a GUI foundation rather
than a console with a framebuffer under it. It is also why the display
is reachable over a channel at all: a channel is fabric-transparent, so a
remote surface will be `dial NODE display` with no new mechanism.

Committing a rect is where Stage 1's deferred cross-chunk arithmetic
lands. The surface buffer is one contiguous shm (the framebuffer's size,
300 pages — under `shm_max_pages`, since only *DMA* allocations carry the
16-page cap), but the scanout's backing is the 19-chunk scatter-gather
list, so `fbWrite` walks a linear framebuffer offset across chunk
boundaries, and commit copies the rect row by row through it. At this
stage the transfer to the host was still the whole framebuffer per commit
(correctness only needs the damage rect to bound the *copy*, which it
does); per-rect transfer landed later — see "per-rect composition" under
the compositor. The drill proves it with
a client (`user/gpucli.zig`): it fills the surface with one colour and
commits the full rect, then paints a centred 200×120 rectangle in a
second colour and commits only that rect. The host screendumps the result
and asserts the centre pixel is the second colour and a corner is the
first — the surface path, a full commit, and a partial damage-rect commit
all at once. The client is the drill's essential unit and pulls the
display server up through a `unit` give, so its exit ends the boot
cleanly; the next stage is the terminal, a surface client that renders a
glyph grid.

**Stage 2: the terminal (as built, 2026-09-07).** The first real surface
client: `user/term.zig` keeps a character grid and renders it into a
surface from gpusvc — the userspace analog of the kernel's framebuffer
console, but an ordinary program drawing into a surface, so it coexists
with any other graphical client rather than owning the screen. It has a
cursor, wraps at the right edge, and scrolls when it reaches the bottom;
text is the shared 8×16 font. That font moved out of the kernel
(`kernel/font/console8x16.zig` → `shared/font8x16.zig`, re-exported as
`shared.font8x16`) so the kernel's `fbcon` and the terminal draw the same
glyphs from one source — the ROADMAP's "font as a shared asset." Rendering
is a `writeText(bytes)` over the grid, so wiring a console channel and a
keyboard so the shell runs here (the graphical seat, stage 4) will only
have to feed it bytes. The drill renders a demo of more lines than fit,
forcing a scroll, and leaves the cursor bottom-left; the host screendumps
and checks the cursor cell is a solid white block (font-independent, so a
deterministic anchor), the text region has glyph pixels, and a blank cell
stayed black — glyphs, scroll, cursor, and no bleed, all at once.

**Stage 3: input (as built, 2026-09-07).** The other half of a console is
the keyboard, and it is another userspace virtio driver on the same
recipe: `user/inputsvc.zig` drives virtio-input (device type 18,
`1af4:1052`). It posts device-writable buffers on the event queue and
reads back `virtio_input_event`s — `{type, code, value}` — decoding key
presses (`EV_KEY`, value 1). The one thing that cannot be faked in the
deterministic gate is real input, so this is where the runner's QMP grew
its second verb: `input-send-event` injects key presses into the virtio
keyboard from the host. The drill boots inputsvc, which posts its buffers
and says `input: ready`; the runner then injects `h` then `i`, and the
driver logs the evdev keycodes (35 and 23) as it decodes them and exits
once it has the expected count — so the clean shutdown is itself the proof
the events crossed. Routing these events to the terminal, so the shell
reads the keyboard on the graphical console, is the seat (stage 4); this
stage proves the device and the decode.

**Stage 4: the graphical seat (as built, 2026-09-07).** The pieces meet:
a session runs on the graphical console, reading the keyboard and writing
the screen through nothing but the ordinary console protocol. The join is
that the terminal serves `ConsReq` — the very interface the virtio-console
driver serves — so a client that speaks it (a shell) runs on the terminal
with no change: `write` renders as glyphs, `read` returns keystrokes. In
serve mode `term` holds a surface from the display server, and a session
binds `term` as its console. (Input was later unified: `term` no longer
holds its own `inputsvc` channel — it reads the keyboard through the
*compositor's* `next_input`, so it is an ordinary compositor client that
receives keys only while its surface holds focus. That is what lets a
terminal coexist with other windows on the one display and keyboard —
the groundwork for an interactive session launched from a GUI login, and
it moves every input path through the one focus-routing point.) The seat is
wired entirely as `unit` gives — the session pulls up the terminal, which
pulls up the display server and the keyboard — so init starts and
supervises the whole tree from one dependency. The drill's session is a
small stand-in shell (`user/gsh.zig`) rather than the full msh, but it is
a real console loop (prompt, read a line echoing each key, run it); the
host types `hi⏎` over QMP, and the line travels keyboard → inputsvc →
terminal → session (logged `gsh: line hi`) and back out to the screen,
which the screendump confirms has glyphs. And the real msh binds the same
`ConsReq`, so it runs here with no shell change at all: a `gseat` profile
boots the actual shell (`msh.msh`'s wiring, only its console coming from
the terminal instead of a virtio-console) on mossfs over the block device.
That drill types `echo hi` then `exit` on the virtual keyboard; the
screendump shows msh's banner, its `msh>` prompt, the echoed command and
its `hi` output, and `exit` (read from the keyboard) makes the real shell
exit and end the boot — the developer shell, running on the graphical
console. The one piece left is the interactive `zig build run` window
(`-display cocoa` and the device flags), which lives in the arch build
sections (the Framework 16).

*Lesson paid for here (a one-in-eight hang under load):* `notifyBind`
means "wake my `recv` on this notification's signal" — and a serve loop
that treats the resulting `interrupted` as a generic retry **must drain
the notification**, or a still-latched bit re-fires the instant it loops
back and spins forever, starving the core (its per-CPU timer stops
ticking — the tell in `sched.debugDump`, which grew per-thread `park`/
affinity and per-core evict/throttled counts while this was chased).
gpusvc had inherited the `notifyBind` from the drivers it was modelled on
(cons/blk/inputsvc) — but those *serve the device from `recv`* and do
drain; gpusvc serves a channel protocol and waits on the device IRQ
directly (`notifyWait` in `submitCmd`), so it must not bind the IRQ to
its `recv` at all. The seat's higher commit rate and multi-domain load
made the race likely; the simpler gpu/term drills almost never hit it.

**Stage 5: the compositor (as built, 2026-09-08).** The surface protocol
was built for this from the start, and now the display server delivers on
it: many surfaces, each with a position and a stacking order, composited
onto the scanout. `create_surface` gained a rect — `{xy, wh}` places and
sizes the surface (a zero size still means the whole scanout at the
origin, the single-window case that keeps `term`/`gpucli` unchanged);
later surfaces stack above earlier ones. `commit` no longer copies one
surface straight to the framebuffer — it recomposites: paint the ground,
then blit every surface bottom to top (each row through `fbWrite`, clipped
to the scanout), then transfer and flush. It began as a full recompose
per commit — the simple, correct choice; per-rect composition (below) and
focus, input routing, the focus cue, and the trusted path all followed.
The drill opens two
overlapping windows — red at (40,40), green at (200,150) — and the host
screendumps and checks each region: red where only the first covers,
green where only the second does, green again in the overlap (it was
created later, so it wins), and the ground where neither reaches. A
compositor in one screendump. It cost one ceiling: init's `max_units`
went 48 → 64, since the arc's units (display server, terminal, keyboard,
their seat and drill clients) crossed the old bound.

**Stage 5, focus and input routing (as built, 2026-09-08).** A compositor
that shows many windows must also decide which one the keyboard reaches —
so the compositor takes the keyboard. When the seat gives gpusvc a `keys`
channel (the `compositor` unit does; the plain `gpusvc` for the
display-only drills does not), gpusvc reads inputsvc itself and owns
focus: `create_surface` gives the new surface focus, `GpuReq.next_input`
returns the next keystroke tagged with the focused surface, and Tab is
absorbed by the compositor to cycle focus rather than reaching a client.
Routing input through the display server (Wayland's shape, not X's) means
a client only ever sees the keys sent to it while it holds focus — the
compositor is the single point that reads the device and steers it. The
drill opens two windows and, since the second is created last, it starts
focused; the host types `a`, Tab, `b`, and the client confirms `a`
reached the second window and `b` the first (Tab moved focus between
them). At first the compositor served one input reader synchronously
(`next_input` blocked on the keyboard), which stalled every other client
until that read completed; the deferred-reply rework (below) lifted that,
and a trusted path for the login window followed.

**Stage 5, the focus cue (as built, 2026-09-08).** Focus you cannot see
is focus you cannot trust, so the compositor draws a yellow border just
inside the focused surface's edges — but only when it holds a keyboard
(the display-only drills have no focus to show). The cue is composited
_last_, on top of every surface, so a focused window that overlaps others
wears an unbroken border in the overlap too; the drill's two windows
overlap by design (A at x40..340, B at x200..500), and after Tab moves
focus to A its border sits over B in the shared strip, while B's own
strip (x>340) stays unbordered green — which is what the screendump
asserts. **Lesson (paid for here):** filling a span reaches the
framebuffer's scatter-gather chunks 256 words at a time, and the chunk
size came from `@min(remaining, buf.len)` against a comptime length —
which narrows the result type to just fit that bound, so the following
`take * fb_bpp` overflowed the narrow type and tripped a Debug safety
panic. gpusvc's panic handler exits silently (255), and a supervised
domain's faults are delivered to its supervisor rather than logged, so
the symptom was a compositor that vanished mid-composite with no fault
line — invisible until the panic handler was made to log its message. The
same `@min`-narrowing bite had already cost a `@as(u64, pages) * 4096`
earlier in this file; annotate the `@min` result `: usize` when its
product feeds an offset.

**Stage 5, the trusted path (as built, 2026-09-08).** A login prompt is
only safe if the user can tell the real one from a hostile window
painted to look like it, and if the passphrase they type cannot be read
by anyone but the login. Both are the compositor's job, because it is the
one process that owns the scanout and the keyboard. Three mechanisms,
each small:

- _Per-client identity._ The compositor had none — every client shared
  one display channel (badge 0). A client proves the boot-provisioned
  trust token over `attach_trusted` and the compositor mints it a badged
  channel (`chanMint`, the fs/net/fabric idiom) to drive instead; every
  surface made over it is owned by that badge and flagged the login
  surface. A wrong or absent token is refused — the hostile client stays
  badge 0.
- _Keystroke isolation._ Each surface records its owner badge, and
  `next_input` returns a key only to the owner of the _focused_ surface.
  A client reading the keyboard while another's window has focus gets
  nothing back — a keystroke for one window never reaches another, and
  the passphrase stays with the login. (Every pre-existing client is
  badge 0 and owns its own focused surface, so nothing changed for them.)
- _An unspoofable indicator + secure attention._ A strip along the very
  top of the scanout is painted last of all, after even the focus
  border, so no client surface can draw over it; it is a distinct secure
  colour only while the focused surface is the login surface. And a
  non-trusted surface may not steal focus from the login surface — a
  hostile client cannot pull the keyboard (or the indicator) away from a
  prompt the user is answering.

The gating token is a boot-provisioned shared secret (an archive file the
seat gives both the compositor and the greeter, staged through a `buf`
and read via `boot.Setup.secret()` — the same shape as the fabric root
seed). A pure capability would be tidier, but the kernel has no
cap-identity compare and no receive-on-any for a private trusted channel
served alongside the public one, so the token is the pragmatic authority;
possession of it is the right to make the login surface. The drill
(profile `trust`, `user/trustcli.zig`) runs a greeter (good token → login
surface, focused, secure strip, receives the typed key) beside a hostile
client (no token → refused the trusted path; its twenty keyboard reads
all come back empty — "fake blind" — while never stealing focus). The
runner types one key and checks the verdict logs, the absence of any
leak, and the secure strip in a screendump. One coupling to remember:
the compositor is single-threaded, so while the greeter blocks reading
the keyboard the hostile client's requests queue behind it — the drill
must type the key before waiting on any of the hostile client's logs, or
it deadlocks (the synchronous `next_input` = one reader limitation, again).

**Stage 5, per-rect composition (as built, 2026-09-08).** A commit
carries a damage rect, and until now it was ignored — every commit
recomposed the whole scanout and DMA'd all of it to the host. Now
compositing is expressed in rectangles: a `Rect`, an `intersect`, and
three primitives — `fillRect` (ground/strip), `blitRect` (a surface's
overlap with a rect), and a rect-clipped focus border — over which the
one `compositeRect(clip)` recomposes just `clip` and ships just `clip`
(`TRANSFER_TO_HOST_2D` and `RESOURCE_FLUSH` now take the rect, the
transfer's backing offset being the rect's scanline offset since the
scatter-gather backing is laid out as the linear resource). A commit
translates its surface-local damage to the scanout, clips it to the
surface, and recomposes only that; the full-scanout `composite()` is the
same function over the whole framebuffer, kept for the events a single
rect can't capture — bring-up, a focus switch (the cue moves and the
secure strip can flip), and a destroy (it uncovers what was beneath). The
correctness rule the per-rect path rests on: pixels outside `clip` are
never touched, so the host keeps the value it already holds — which is
only right if some earlier full composite established the whole scanout.
So the **first** commit is a full composite (it lays the ground across
the scanout, exactly as before); every commit after it stays bounded to
its damage. The win shows directly in the gpu drill, which commits a
full-surface fill and then a small centred rect and checks the area
outside the rect is untouched — now that outside genuinely is never
re-shipped. Watch the `@min`-narrowing trap once more: the border width
`bw = @min(focus_border, …)` narrows to a type that just fits the border,
and `2 * bw` overflows it — the third time this exact bite has been paid
in this file, so `bw` is annotated `: usize`.

**Stage 5, concurrent input readers (as built, 2026-09-08).** Reading the
keyboard is a blocking call to inputsvc, and the compositor made it on the
serve loop — so a single client sitting in `next_input` froze the whole
display server, and every other client's request queued behind it. (Both
the trusted path and per-rect drills had to tiptoe around this.) The fix
is the standard event-loop shape (fabric and blk already use it): a
dedicated **reader thread** does the blocking read, pushes each key into a
single-producer/single-consumer ring, and rings a **doorbell** notification
bound to the serve loop's recv; the serve loop **parks** each `next_input`
(remembers its reply token) and, woken by the doorbell, hands each key to
the parked reader that owns the focused surface. Now any number of clients
can have a read outstanding and the loop never blocks. Tab is still
absorbed here (it cycles focus, reaches no client); a key with no reader
on the focused surface stays buffered in the ring, delivered when one
parks — never handed elsewhere. Binding a doorbell to recv is the same
move the earlier livelock warned about, but safe here for the reason the
warning gives: the loop *drains* it (`notifyWait` + dispatch) on every
`interrupted`, and it is a software signal, not a latched device IRQ that
re-fires — the device IRQ stays unbound, waited on directly in `submitCmd`.

The bug this shook out was latent all along: every reply used
`replyTyped` with **token 0**, which the kernel routes to the *oldest*
outstanding call. While reads completed synchronously that was always the
one call in flight, so it was correct by accident. The moment a read is
parked, a later commit's token-0 reply lands on the parked reader instead
— it answered the reader with a commit's `ok`, and the committer hung
forever. The readers drill (a client parks a read while another commits
in a loop and must reach "done") caught it deterministically; the cure is
to reply to every request by *its* token, never 0, now that several calls
can be in flight at once. The drill also stands as the regression guard: on
the old synchronous compositor the parked read would wedge the mover, and
the boot would hang instead of finishing.

### Pointer input

**The tablet driver (as built, 2026-09-09).** The whole input stack was
keyboard-only; a mouse is the biggest missing UI primitive. The device
choice is a **virtio tablet** (`virtio-tablet-pci`), not a mouse: a tablet
reports *absolute* position (EV_ABS, 0..32767 per axis), so there is no
pointer acceleration or warp to model — the position maps straight to the
scanout. A tablet is a second `virtio-input` device beside the keyboard,
and the device model already carries it: root enumerates every PCI device
and hands init all of them, and init files devices by kind at the next
free index, so two `input` devices land at `input[0]` (keyboard) and
`input[1]` (tablet) with no kernel change — a unit addresses the tablet
with `give { device: input, index: 1 }`. `inputsvc` grew two pointer modes
beside its two keyboard ones (one binary, the device the unit gives decides
which it is): a **pointer serve** mode reads the tablet and answers
`PtrReq.read` with the current absolute position and button bitmask (bit0
left), and a **pointer drill** mode logs frames. It accumulates EV_ABS
position and EV_KEY buttons across an event group and, on EV_SYN, pushes a
frame into a small ring that **coalesces pure moves but never a button
change** — a fast click (down then up) between two reads is preserved,
while a stream of moves collapses to the latest, so the reader is never
flooded and never misses a press. The raw device range (0..32767) crosses
the wire unscaled; the compositor, which knows the display geometry, does
the scaling and hit-testing. Drilled (`ptr`): the host moves the cursor to
the tablet's centre and clicks over QMP (`input-send-event` `abs`+`btn`),
and the driver logs the frame at 16384 and the press.

**The cursor and routing (as built, 2026-09-09).** The compositor owns the
cursor, as it owns focus. Given a `ptr` channel (a second inputsvc, the
`compositor-ptr` unit), it runs a **second reader thread** beside the
keyboard's — the same shape, its own SPSC ring, ringing the same input
doorbell the serve loop already drains. Each frame scales the tablet's
0..32767 to the scanout, and the cursor is a small arrow the compositor
draws **last in `compositeRect`** — over every surface and even the secure
strip, since it is the compositor's own (trusted) pixels. A move recomposits
only the union of the rectangle the cursor left and the one it entered, so
it is cheap. Routing follows the display server's rule (Wayland's shape):
a **button change, or a move while a button is held (a drag), goes to the
surface *under the cursor*** — hit-tested topmost-by-z — not the focused
one, and a press also gives that surface focus (click-to-focus). A bare
move only slides the cursor; a hovering pointer never wakes a client. The
event reuses `next_input`'s parked-reader machinery (delivered to the hit
surface's owner) and rides the existing `GpuResp.input` reply, now a
tagged event — `kind` 0 a key (the character in `arg`), `kind` 1 a pointer
event (surface-local x/y and the button bitmask packed into `arg`, since a
message payload is only three words). Drilled (`pointer`): the host moves
the cursor over a client's window and clicks; the client confirms the
routed event landed on its surface at the right local coordinates
(150,99 — the window's centre), and a screendump confirms the arrow drawn
there over the window's fill.

**Clickable mshl widgets (as built, 2026-09-09).** The last piece makes the
declarative GUI runtime pointer-driven. `renderTree` already lays each
widget out top-to-bottom; now it records each focusable's clickable box
(the button box, the field's value box) alongside its id. `next_input`
became a tagged event, and the input loop handles a pointer press: it
hit-tests the widget box under the surface-local click, focuses it, and —
for a button — fires it, exactly as Enter does (so `update` runs on the
same coarse event, still a pure function). A release or a click on empty
space just keeps waiting; the runtime re-renders only when focus or state
changes, as before. Nothing about the app changes — the same
`view`/`update` counter now responds to clicks as well as the keyboard.
Drilled (`guiclick`): the runtime logs each widget's scanout centre, and
the host clicks "increment" then "quit" (over the pointer-capable
compositor); the counter reaches `count=1` by click alone. With that,
pointer input runs the whole stack — tablet → inputsvc → compositor cursor
and hit-test → routed event → the mshl widget under it.

**Movable windows, stage 1 of the desktop (as built, 2026-09-09).** The
compositor could stack surfaces but never restack or move them — their
x/y and z were frozen at creation, so a "window" could not be dragged or
brought to front. This is the window-management foundation. The compositor
gained `move_surface { surface, xy }` (its owner repaints the vacated and
newly-covered rects only, clamped to the scanout) and raises the surface a
pointer press lands on to the front (a click brings its window forward,
like a desktop); `max_surfaces` went 4 → 16. The mshl runtime turned its
decorative titlebar into a real one: three macOS traffic-light dots (close
/ minimize / maximize) at the left, the title centred, and the rest a drag
handle — a titlebar drag sends `move_surface` (the window follows the
cursor, the grab point staying under it), the red dot closes the window,
minimize/maximize are stubs for now. A `width` and an `at { x, y }` on the
`gui` spec let a desktop lay several narrower windows out instead of one
centred one.

Two gaps surfaced and closed on the way. First, **every ordinary GUI
client reached the compositor unbadged (badge 0)** — fine for one window,
but two windows then shared an owner and the compositor misrouted one's
input to the other. So a client now `register`s once for a
uniquely-badged channel (the same mint the trusted login earns, but badges
2..), and its surfaces and input reader are keyed by that badge. Second,
**a fast drag dropped pointer events — a button release above all** —
because the compositor delivered a pointer event only if a reader was
parked at that instant and dropped it otherwise, and a window would stick
to the cursor when its release vanished. The first cut left an
undeliverable event at the ring's head and stopped draining until that
client re-parked — which turned out to be a worse bug (see below), so the
compositor now drains the ring unconditionally and **queues** what it
cannot deliver onto the target surface, one small FIFO per surface (moves
coalesce onto the tail; every button transition is kept), flushing one per
re-park. A stale focus border (a new window took
focus but the old window's yellow cue was never repainted over) closed by
laying the whole ground again on the next commit after a surface is
created. The `desktop` drill is the repo's first multi-window scene: two
processes open a window each on one pointer-capable compositor, and the
host raises one by clicking its titlebar, drags it by the titlebar (the
runtime logs where it lands), and closes both by their red dots — move,
raise, and close, proven end to end.

**The top bar, stage 2 of the desktop (as built, 2026-09-09).** A resident
macOS-style menu bar pinned at the top: menu titles at the left, a live
clock and date at the right. `gui { bar: true, … }` selects a distinct
render and loop in the runtime (chrome-less, pinned, no titlebar), leaving
the window path untouched; its `view(state)` returns `{ left, right }` of
`{kind:menu}` / `{kind:label}` items, the clock a `label` reading
`fmt-time` refreshed by the tick. Windows open below a reserved top strut,
so the bar is never covered. The hard part was the dropdown: moss surfaces
are opaque, so a menu that overlays windows cannot be an overlay inside the
bar — it is its own **second surface**, created below the menu title when
clicked and destroyed on a selection, a click elsewhere, or Escape. The bar
process now drives two surfaces on one input stream — pointer events carry
the surface id (added to the runtime's event), so a click routes to the bar
or the popup by which surface it landed on — and the popup is drawn by
briefly retargeting the shared primitives at its buffer. A selected item
fires `update(state, { menu, item })`; the topbar app's "Log Out" returns
`done`, ending the session. The `topbar` drill opens the system menu (the
runtime logs the dropdown's geometry so the click is exact) and selects
Log Out — the bar renders, the menu opens a real popup surface, the item
fires `update`, and the bar exits, all end to end.

**The dock, stage 3 of the desktop (as built, 2026-09-10).** A resident
macOS-style dock pinned at the *bottom*: a centred row of rounded app
pills, each of which **launches** its app on a click. `gui { dock: true }`
selects a third render/loop in the runtime (`runDock`, a sibling of the
top bar's `runBar`); `view(state)` returns `{ items: [ { title, unit,
running? } ] }`, and clicking a pill fires `update(state, { item, unit })`.
The launch itself is the point: an app is a *unit*, and a GUI process that
holds init's front channel (`{ tag: init, self: true }`) can ask init to
start one. mshrun now wires that cap through to the worker commands (it was
being dropped), and a new `launch NAME` command sends init a
`connect_named` and lets go — fire-and-forget, unlike `dial`, which keeps a
callable handle. init starts the unit; the unit's own `{ tag: display,
session: true }` give opens its surface on the compositor; the dock never
talks to it. So the dock's `update` is just `launch $ev.unit`, and a real
second process — a movable window from stage 1 — appears. The launched
app is marked *running* (a primary-filled pill with a dot), state the app
threads through `view`. Escape ends the dock (and, since the dock is the
session's essential unit, the session) — which meant teaching the keyboard
map Escape (linux keycode 1 → ASCII 27); that also lit up the top bar's
until-now-dead Escape-to-dismiss. The `dock` drill clicks the Alpha pill
(the runtime logs each pill's centre so the click is exact), waits for the
launched window to come up, closes it, and presses Escape to shut down
clean. Two things fit this to moss's grain: launching reuses init's
ordinary lazy-start path (no new "spawn a window" syscall — a launched app
is a supervised unit like any other, `connect_named` ignoring the boot
profile so a lazy unit starts on demand), and a dead app is init's to
reap, not the dock's — closing the launched window leaves the dock
untouched. Owed next: the dock does not yet clear *running* when an app it
launched exits (that needs the dock to watch the app's domain); today
*running* means "launched from here this session".

**Settings, stage 4 of the desktop — capability-gated system settings (as
built, 2026-09-10).** The post-login shell became a two-pane settings app
(`boot/scripts/gui-shell.msh`): a **you** pane editing this user's own
appearance (scale/theme/contrast/colours, saved to the home layer and
pushed live as before) and a **system** pane showing the system default
locale, editable only by an administrator. Two mechanisms landed under it.

*The admin gate.* moss had no notion of a privileged user — `usercred` is
identity-only, and every session got the same caps. Stage 4 adds one
policy bit: a user entry in `system.msh` may carry `admin: true`; `apply`
writes it into the user's record (alongside the budget — a policy field,
not an identity one), and at login the session manager reads it. An admin's
GUI session is handed a **read-write** view of the system settings tier
(`conf/app`); everyone else's is read-only — the only difference between an
admin session and any other is the writability of that one cap. The manager
holds `conf/app` read-write itself now (it did read-only before) and
derives the per-session view read-only unless the user is an admin *and* the
session is graphical (a console session, whose manager still holds it
read-only, cannot escalate). So "may this user change the system defaults?"
is answered by whether they hold a writable cap, nothing more.

*Reaching the tier from a script.* mshrun gained a small `sysconf-*`
command group (`user/confcmds.zig`) over the one `conf` view a unit or
session was handed: `sysconf-read NAME` and `sysconf-write NAME TEXT` read
and write `conf/app/<name>.msh`, and `sysconf-admin` reports whether the
view is writable. That last is the honest capability check — it asks the fs
service, over `statfs`, whether the view is read-only (the service tracks it
per badge); there is no admin flag in the script to spoof, only the cap. To
carry the read-only bit, `statfs` folded `encrypted` and `read_only` into
one `flags` word — a typed message holds only its tag plus three payload
words, and a fourth field overflowed it (a paid-for lesson: the four-word
IPC is a hard ceiling on a message's fields). The settings app reads the
system locale with `sysconf-read locale` and, as an admin, writes it with
`sysconf-write`; the write logs its outcome to the kernel log from Zig,
because a GUI script runs its writes inside its event loop where mshl
discards a statement's value — the shell cannot echo the result itself.

*Locked keys.* `lib/settings.merge` already took a locked-key list but every
real caller passed none. fontsvc now reads a `locked: [ ... ]` list from its
system font layer and honours it in every per-user merge, so a key the
system locks cannot be overridden by a user's home layer. `boot/conf/font.msh`
locks `theme` (an org mandate for the dark theme): the drill has the user set
theme=light and apply it, and the effective appearance the font service
reports is still `dark high-contrast cb-safe` — contrast and colours (both
unlocked) took, the theme did not.

The `guishell` drill drives it end to end: alice (an admin) logs in, the
shell reports `settings: admin=true`, the appearance apply proves the theme
lock held, and changing + saving the system locale writes the tier
(`sysconf: saved locale`) — a write an ordinary user's read-only view would
have refused.

**Stage 4b, part 1 — a per-user locale (as built, 2026-09-10).** The
you-pane gained a locale preference: the user cycles among the shipped
locales and a live sample renders a date and a number in the choice
(`fmt-date`/`fmt-number` called straight from the view, the way the login
clock is). "apply" saves it to the home layer (`conf/locale.msh`) alongside
the appearance and pushes it with `sessionlocale`, which sets this session's
default locale for bare `fmt-*` — so it parallels the font-scale push
exactly. The session manager forwards a locale cap to each GUI session
(like the display and font caps) so the shell can format; `sessionlocale`
sets the shared locale service's default. The `guishell` drill cycles the
user's locale to de-DE and confirms `locale: de-DE` after apply. This became
truly *session-wide* when the locale turned into a shared service (see "A
shared locale service" above): a push now reaches every process on the
session's localesvc, not just the one that made it.

**Stage 4b, the rest (as built, 2026-09-10).** Two finishing touches. (1)
*Locked keys shown non-editable.* The font service now reports which
appearance axes the system layer locks — the `locked` list it already reads
for the merge is packed into byte 3 of the `appearance` reply's flag word
(bit per axis) — and the settings app renders a locked control (theme, here)
as a muted label, not a button, so it is visibly not editable rather than a
button whose press is quietly ignored. (2) *The non-admin path, proven.* A
`guishellro` drill reuses the guishell profile but the host signs in as bob,
who has no `admin: true`: his session's conf view is read-only, so the shell
reports `settings: admin=false` and renders the system pane read-only. bob's
panel has no write controls at all — the gate is the cap, not a checked
button — so there is nothing for him to be refused; the refusal lives one
layer down, where a read-only view denies a write (the fs drill's ground).
Between alice (guishell) and bob (guishellro) both sides of the admin gate
are now exercised.

**The composed desktop (as built, 2026-09-10) — the end product.** The four
desktop pieces (movable windows, the top bar, the dock, the settings app),
each built and drilled in isolation, are now assembled into one running
desktop: the post-login GUI session (`conf/sessiongui/`, the `guishell`
profile) went from a single settings window to a full desktop. The session
runs, together on the one shared compositor/fontsvc/localesvc, the **top
bar** and the **dock** (both `profiles: [session]` → eager at login) and
launches app **windows** on demand. Nothing new in the kernel or the session
machinery made this possible — it is purely composition of what already
existed: a session is a mode-3 init running the units in its template dir,
and those units already knew how to take forwarded caps (`session: true`) and
the session init's own front channel (`init: self`).

Roles: the **top bar** is the session's persistent identity and the owner of
its appearance — at login it reads the user's home `conf/font.msh` /
`conf/locale.msh` and pushes them, so the whole desktop (its own clock
included, which reads the shared session locale) renders in the user's
choices; its system menu's "Settings…" runs `launch "settings"` over the
session init's front channel, and "Log Out" reverts to the system defaults
and exits. It is the session's one **essential** unit, so its exit tears the
whole session down. The **dock** (eager, non-essential) launches the settings
app and a demo window — session units that are *lazy* (no `profiles:`), so
they exist in the session's unit set but start only when the dock's `launch`
issues a `connect_named` for them. The **settings app** and **demo window**
are ordinary non-essential app windows; closing one ends only that app.

Two things the composition taught, both paid for on the drill: a mode-3
session's whole memory budget is the user's record budget, and it must cover
*every* concurrent unit — four mshrun processes (bar, dock, settings, demo)
overflowed the old 12 MB, so the session budget went to 96 MB and each unit's
to 16 MB (a spawn refused with `QuotaExceeded` is the signature); and a unit
`script:` path is capped at 24 bytes, so `scripts/desktop-topbar.msh` (26)
silently truncated to `…topbar.m` and failed to open — the session scripts
are `dtopbar.msh` / `ddock.msh`. The `guishell` drill is now the full
integration test: sign in, the bar + dock come up in the user's scale, the
dock launches a window and the settings app (admin-editable for alice), and
the top bar's menu logs out — login, a multi-process session sharing all
three services, launching, and teardown, end to end. `guishellro` runs the
same for bob (non-admin: settings read-only). `run-gui -Dgui-profile=guishell`
boots it to play with by hand.

**Minimize and restore (as built, 2026-09-10).** The amber traffic-light
was a stub since stage 1 (it logged "minimize (not yet)"); it now hides the
window, and the app's dock pill brings it back. A minimized window is not
destroyed — it stops compositing but keeps its buffer and its process — so
minimize is a new compositor state, not a teardown. The compositor gained
three requests. `set_visible { surface, visible }` (owner-only) toggles a
surface's `hidden` flag: hiding drops focus to the topmost *visible*
surface and recomposits (the window's area returns to the ground); showing
raises and refocuses it. `set_title { surface, a, b }` (owner-only) names a
surface with up to 16 bytes, sent once right after `create_surface`, so a
window can be found again by name. `restore_titled { a, b }` finds the
surface with that title, shows + raises + focuses it, and **wakes its
owner** — a new `kind` 3 input event delivered to the owner's parked
reader — so the app clears its minimized state and repaints. `hidden`
surfaces are skipped everywhere they must be: compositing, `focusTopmost`,
and the pointer hit-test.

The window runtime wires it to the traffic-light: the amber dot sends
`set_visible false`, sets a local `minimized` flag, and keeps looping
(ignoring ticks while hidden — nothing is on screen to update); a `kind` 3
restore event clears the flag and re-renders. The dock is the restore
trigger. `restore_titled` is *not* owner-gated — any display client may
ask, but it only shows and focuses an existing surface, never creates or
hides one, so it cannot spy — which lets the dock, a different process,
restore an app it does not own. A new `restore-window TITLE` mshl command
sends it (over the shared display cap) and returns `ok`/error; the dock's
`update` is now `match (restore-window $ev.title) { ok _ => …; _ => launch
$ev.unit }`, so a pill click restores a running window (unhiding a
minimized one, or just raising a visible one) and falls back to launching
when nothing by that title is up. The pill's title is therefore the window
title the compositor keys on, so the two must match — the settings window
is titled "Settings" to match its pill (it was "moss settings"). The
runtime's per-click log went from "dock: launch" to the neutral "dock:
activate", since a click no longer always launches.

The `guishell` drill exercises the round trip: after the demo window opens
it clicks the amber dot (the runtime logs the traffic-light centres, like
it logs widgets, so the click is exact), confirms `gui: minimized`, clicks
the Demo pill again, and confirms `gui: restored` with no new `gui: ready`
— the running window came back rather than a fresh one launching. One
subtlety worth keeping: because the retained buffer is what reappears, a
restore needs no cooperation from the app for the *pixels* — the wake event
is for the app to resume its own logic (a clock that paused while hidden),
not to redraw. Owed next: a wallpaper (the ground is a solid fill).

**Maximize (as built, 2026-09-10).** The green traffic-light, a stub since
stage 1, now maximizes the window to fill the work area — full width, from
just below the top bar's strut down to just above the dock — and a second
press restores it to its previous geometry (the runtime remembers it).
moss surfaces are fixed-size at create, so a resize is a destroy + recreate
of the surface at the new geometry — which the runtime already does for
close/open, so maximize reuses `closeSurface` + `openSurface`; the recreated
surface re-takes focus and the front, and the title is re-set. The work
area is computed the same way the dock sizes itself (`dockHeight`, from the
UI font role and paddings at the current scale, so it matches the real
dock), and the maximized window stops above it so the dock stays visible.
The runtime re-logs the traffic-light centres after the resize (they move
with the window) so a host can find the green dot again to restore; the
`guishell` drill maximizes the demo window, confirms `gui: maximized`, then
clicks the dot at its new position and confirms `gui: unmaximized`.

**A higher-resolution scanout — 1280×1024 (as built, 2026-09-10).** The
scanout grew from 1024×768 to 1280×1024 for more desktop room. The size
lives in two constants — gpusvc's `fb_w`/`fb_h` (the resource it creates and
the backing it allocates) and the runtime's `scanout_w`/`scanout_h` (window
layout) — plus the `run-gui` device's `xres`/`yres`; the drills' screendump
asserts are mostly relative (`img.w/2`, or a fixed app-window position), and
the pointer/click helpers convert scanout→tablet through named `scanout_w`/
`scanout_h`, so they followed. Three limits had to move with it, all paid
for on the first run: a full-scanout surface is now 1280 pages, so
`ipc.shm_max_pages` went 768→1280 and the global `shm_account` 16→64 MB (a
maximized window is ~5 MB, and several surfaces plus the font atlas share
that pool); and — the subtle one — the framebuffer's scatter-gather backing
is one address-space mapping per chunk, and at the old 16-page `dma_alloc`
cap 1280 pages meant 80 chunks, past a domain's `max_mappings` (64), so the
compositor ran out of mapping windows before it could map its keyboard and
surfaces. Raising the `dma_alloc` per-call cap to 64 pages makes the
framebuffer 20 chunks (20 mappings), well clear of the cap with room for
surfaces — bigger DMA chunks, not a bigger mapping table.

**Cascading overlapping windows (as built, 2026-09-11).** Every GUI app
that does not name an `at:` opens where the runtime centres it — so the file
explorer and the settings window both asked for the same spot, and the
second landed within a dozen pixels of the first, all but hiding it. It read
as "only one window opens at a time" (both were up; one sat squarely behind
the other). The fix is a **cascade** in the compositor: when a client sets
`gpu_place_cascade` on `create_surface`, `cascadePlace` nudges the origin by
28px steps off any visible surface it would land right on top of, stopping
before it runs off the scanout. The client owns window position (it drives
`create_surface` and, on a drag, `move_surface`), so the compositor cannot
silently move a window without desyncing the client's hit-testing — the
`created` reply now carries the origin it actually placed the window at, and
the runtime adopts it as its `win_x`/`win_y`. The flag is opt-in: only
movable app windows set it (they adopt the reply), while menus and the
single-window test clients place exactly. A full-scanout window never
cascades (the off-scanout guard stops it at once), so maximise still fills.
Windows the client places at distinct spots — the desktop drill's Alpha and
Beta — are far apart and never trigger it. The `cascade` drill is the guard:
two windows both open centred and it confirms they land at least a titlebar
apart, then closes both by their traffic-light dots.

**A busy client must not wedge the pointer ring (as built, 2026-09-11).**
Opening one app, then a second from the dock, would leave the second never
launching — no window, no running dot — on real hardware, though every
drill launched several apps fine. The cause was the pointer dispatch's
"leave the undeliverable event at the ring's head until the client
re-parks" rule. When you click a dock pill, the dock is handed the press,
then blocks for tens of milliseconds in the `launch` (init spawns and wires
a whole domain) with no reader parked. The click's *release* arrives during
that window, cannot be delivered, and pins the head of the 64-slot ring —
so nothing drains. A real mouse pours a steady stream of motion events into
the ring while it travels to the next pill (a high-poll mouse easily fills
64 slots in those milliseconds), and `ptrRingPush` drops on a full ring —
so the *next* click's button event is silently lost. QMP could never
reproduce it: the monitor delivers input far too slowly to fill the ring
inside a launch, so the harness always saw the release drain and the next
click land. The fix drains the ring unconditionally and, when a client has
no reader, queues the event on the target surface (a small per-surface FIFO
that coalesces consecutive moves but keeps every button transition),
delivering one per re-park. The ring can no longer wedge or overflow, so no
click is dropped; a busy client still catches up to the whole gesture — a
whole press-then-release that lands while it launches still arrives in
order — the moment it parks again. Raising and focusing on a press are the
compositor's own bookkeeping, so they now happen immediately, before the
per-client delivery, whether or not the client is ready.

**The dock clears a pill when its app exits (as built, 2026-09-10).** Stage
3 left *running* as dock state set at launch and never cleared — the dock
had no signal that a launched app had gone. Rather than teach the dock to
watch each app's domain (a cap it does not hold), the pill's dot is now
*polled live* against init's own truth. A new `unit-up NAME` mshl command
(`user/workcmds.zig`, reachable from a program that holds init's front
channel) asks init for its unit list — the same `list` request `svc`
renders — and reads that unit's `up` bit; init already reports a unit whose
domain has died as down, so this is the honest "is the app still running".
The dock's `view` calls `unit-up` per pill and a `tick: 1000` re-renders
once a second (the same clock-refresh path the top bar uses), so the dot
lights when the app comes up and clears on its own when it exits — no
teardown signal has to reach the dock, and it is correct across a crash as
much as a clean exit. The dock's `update` no longer threads any *running*
state; it is derived, not remembered. `renderDock` logs a pill's state only
when it flips (`dock: running <unit>=<bool>`), so the change is observable
without spamming every tick; the `guishell` drill launches the demo (the
dot lights), then closes it and confirms the dot clears.

**A subtler focus cue — dimmed chrome (as built, 2026-09-10).** The focus
cue had been the compositor painting a thick yellow border around the
focused surface (stage 5). It read as loud and web-like on the composed
desktop, so it is replaced by the macOS convention: the focused window
shows full-colour chrome (red/amber/green traffic lights, a crisp title);
an unfocused window dims its own — the dots go a uniform grey, the title
muted. The border is gone entirely. Because a window draws its own chrome
(the compositor owns focus), the compositor must tell a window when its
focus changes: a new `kind` 4 input event (arg 1 = focused, 0 = not),
delivered by `pumpFocus` to the owner's parked reader whenever the focused
surface changes — a click, a new window, a minimize, a restore, or a Tab
switch. `pumpFocus` runs after every request and after the input doorbell,
diffing each surface's real focus against what its owner was last told
(`Surface.notified_focus`, seeded true to match a client's assumption that
a fresh window is focused, so a window that opens *behind* the focus is the
one told to dim). A window busy at the instant focus changes has no parked
reader; its state stays pending and is flushed the moment it re-parks. The
window runtime tracks `win_focused` and redraws its titlebar accordingly;
the `desktop` drill (two real windows) asserts the one losing focus logs
`gui: unfocused`, and the `focus` drill keeps proving the routing itself
(its plain solid-colour windows have no chrome to dim, so its old
border-pixel screendump assertion is retired). Raw input clients that only
want keystrokes (`focuscli`, `readercli`, `trustcli`) now filter to `kind`
0, since the compositor delivers ticks, restores, and focus changes on the
same channel — a keystroke is no longer the only thing a `next_input` can
return.

### GUIs in mshl

The console arc gave the substrate — surfaces, a compositor, keyboard
routing. The point of it is that a GUI should be written in mshl, not
zig, and the model (chosen once the substrate worked) is **a GUI as a
service with a pure `update`/`view` split**: the app is two mshl
functions — `view(state)` returns a declarative widget tree (an ordinary
record), `update(state, event)` returns the next state — and a runtime
owns the surface, renders the view, routes input, and threads state
forward. The app has no loop and never blocks. Everything that crosses
between app and runtime is *data* — the view tree, an event `{id}`, the
state — so the same app runs with its renderer on another node unchanged
(the fabric's "remote" rule holds), it is supervised and crash-only
(restart re-derives from state), and the view is declarative. Handlers
are *not* closures in the tree: a closure can't cross the fabric, so
behavior is the one `update` function keyed by the event's id. This is
the Elm Architecture, or a BEAM GenServer with a render function.

**Stage 1 (as built, 2026-09-08).** `gui` is a hosted mshl command
(`user/guicmds.zig`), wired into mshrun beside `net`/`fs`/`http` and
offered only when the host holds a `display` cap — exactly how the other
drivers are exposed. `gui { init, view, update }` opens a surface on the
compositor and runs the loop *in zig* (so the mshl app has none): render
`view state`, wait for a key, and on a fire call `update state {id}`,
thread the returned state, re-render; a state with `done: true` closes
the window and `gui` answers with the final state. The runtime calls the
app's mshl closures in-process through `Interp.callValue` — the same
entry `map`/`reduce` use — and builds the event record in the interp's
arena. Rendering is client-side: the runtime rasterises the tree into the
surface's shm with the shared 8×16 font (as the terminal does), a single
column of `label` and `button` widgets, the focused button highlighted.
Input is keyboard-only (no pointer yet): Tab moves focus between the
buttons, Enter fires the focused one. That needed one compositor change —
Tab cycles *surfaces* only when there is more than one; with a single
window it is delivered to the app, so a GUI can use Tab for its own
widget focus (the focus and trust drills, with two surfaces, are
unaffected). The drill (profile `gui`, `boot/scripts/gui-demo.msh`) is a
counter written entirely in mshl — `view` shows `count: N` and two
buttons, `update` matches on `$ev.id`; the host types Enter/Tab/Enter, the
count reaches 1, and mshrun logs the final value. A GUI, defined in mshl,
with no zig in the app.

**Stage 2 (as built, 2026-09-08).** A `field` widget — a text input, and
with it the first form. The tension a text field creates against a pure
`update` is: who owns the half-typed text? Not the app — calling `update`
per keystroke would make it manage edit buffers in its state, and drown
the "coarse event" idea. So the *runtime* owns the live text: a small
table of edit buffers keyed by field id (seeded from the field's `value`
on first sight, `secret: true` renders it masked). Typing edits the
focused field's buffer and re-renders; the buffers reach the app only
when a button fires, in the event's `fields` record — `{ id: "login",
fields: { user: "alice", pass: "secret" } }`. So `update` still sees a
submit, not keystrokes, and stays a pure function of coarse events; the
field defaults still come from state (the view seeds them), so the app
owns the committed data and the runtime owns only the ephemeral edit.
Tab moves focus across fields and buttons; Enter fires a button or
advances past a field. The drill (profile `guilogin`,
`boot/scripts/gui-login.msh`) is a login form written entirely in mshl:
two fields (the password masked) and a button, `update` matching the
credentials out of `$ev.fields`. The host types a username, Tab, a
password, then submits; the app accepts `alice`/`secret` and logs
`who=alice` — proof the typed text crossed to `update` intact.

**Stage 3 (as built, 2026-09-08).** The GUI login on the trusted path —
the vision's "users log in via the GUI", made safe. The two halves were
already built: the trusted-path compositor (a client proves the boot
token over `attach_trusted`, earns a badged channel whose surfaces are
the login surface, wears the secure strip, and has the keyboard to
itself) and the mshl login form. Stage 3 joins them with one spec flag:
`gui { trusted: true, ... }`. When set, the runtime — given the same
boot token as a `secret` — calls `attach_trusted` before opening its
surface and drives everything (create, commit, `next_input`) over the
minted channel instead of the shared display; so the login form's
surface *is* the trusted surface. Everything else about the app is
unchanged: the same declarative `view`, the same pure `update` reading
`$ev.fields`. Only the flag and the token differ, and a client without
the token is refused (`gui` fails), which is the gate. The drill (profile
`gtrust`, `boot/scripts/gui-tlogin.msh`) renders the login form, the host
screendumps and checks the compositor's secure strip is lit at the top of
the scanout — the unspoofable proof this is the real login — then signs
in and confirms the app accepted the credentials. A login prompt written
in mshl, on a path a hostile window cannot spoof or eavesdrop.

**Stage 4 (as built, 2026-09-08).** A real session behind the login —
the front door actually opens. Where the credentials went was the
question: not into the pure `update` (a login is a side effect, and
`update` reads no caps), and not per-keystroke. The answer follows the
model's own grain — the `gui` form *collects* the credentials and
returns them in its final state, and the script then does one more step:
`login`. So authentication is an ordinary pipeline action after the
form, a `login NAME PASS` hosted command (`user/sesscmds.zig`, offered
when the host holds a `sess` cap) that hands the name and passphrase to
the session manager over `SessReq.login`. usersvc unseals the identity,
spawns a session domain under the user's budgets with a view of their
home, and the command runs it to completion (`wait`) and answers `ok {
who }`. Only data crosses — the name and the passphrase — and the key
never leaves usersvc. The greeter is thus a thin trusted front end: the
trusted-path form for input, `login` for the effect, nothing hardcoded.

The drill (profile `gsession`, `boot/scripts/gui-session.msh`) stands up
the whole users volume stack (the encrypted volume, `apply` writing the
records, usersvc in serve mode) *and* the graphical stack in one boot —
the heaviest yet. The host types the real user (`alice` / `alice-pass`,
which is why the keymap and the runner learned `-`), the form's
credentials reach `login`, and the log tells the story: `apply: created
user alice`, `usersvc: session opened for alice`, the session proving
`nothing above the home is nameable` and computing its effective
settings, `usersvc: session closed for alice`, and the greeter's `gui:
session ok who=alice`. A login prompt written in mshl, on the trusted
path, opening a real authenticated session on the user's home.

The session here is the console-less verifier (it does its home I/O and
exits); the *interactive* session is the next stage.

**Stage 5 (as built, 2026-09-08).** The front door opens onto a real
shell. Login now carries a console: `SessReq.login` takes an attached
cap, and with it `authenticate` spawns the interactive session (an init
instance running msh on that console) instead of the verifier. The
greeter holds a graphical terminal (`console = unit termsvc`) and hands
its `ConsReq` cap to `login`; the session's msh runs on it, so the shell
renders on the terminal's surface and reads the keyboard through it —
and because the terminal is now a compositor client (the input
unification above), the greeter's login form and the shell's terminal
coexist on the one display: the form is focused while you type
credentials, and when it closes on submit, focus falls to the terminal
(`focusTopmost`) so the shell has the keyboard. The form's own Tab stays
its own — a trusted surface never yields focus to `cycleFocus` (secure
attention). Two bugs were paid for getting here. One was the same token-0
reply hazard as the compositor: making `wait` *deferred* (a helper thread
replies when the session dies, so the manager keeps serving the session's
own calls and does not deadlock) left a second call outstanding, and
usersvc's `reply` answered the *oldest* pending — the session's
`attach_buf` reply landed on the parked `wait`, so the shell hung in
setup; usersvc now replies to each caller's own token. The other was
prosaic: a script path is passed in the 24-byte arg, so a 25-byte name
was silently truncated and not found — names for `script:` units stay
short. The drills: `lconsole` proves the mechanics with a plain `login`
(no GUI); `gisession` is the whole path — the trusted mshl login form,
then msh on the graphical terminal, `echo hi` and `exit` typed on the
virtual keyboard. A login prompt written in mshl, on a trusted path,
opening a real interactive shell on the user's home.

**Stage 6 (as built, 2026-09-08).** `update` crash-isolated in a worker
domain — invariant 1 (let-it-crash) for a GUI app. Today the runtime
calls `update`/`view` in-process through `Interp.callValue`, so a blow-up
in the app's `update` (a runaway, or any raised error) takes down the
whole display runtime — we watched it happen: an error propagated out of
`callValue` and the greeter's script died. Opt in with `gui { isolate:
true }` and the runtime runs `update` in a *separate* mshrun worker
domain (the same worker machinery `spawn`/`call` use, `user/workcmds.zig`)
— only data crosses, exactly the GUI-as-a-service rule, so nothing is
lost by the move. The runtime reconstructs `update`'s source (its
`Closure.params` + `.src` body) as a small script that reads `$in` —
`let state = $in.state; let ev = $in.ev; <body>` — spawns the worker once
on first use, and per fired event `call`s it with a `{ state, ev }`
record. A call that does not return a value — the worker *raised* (it ran
and errored, still alive) or its whole domain *crashed* (a fault) — is
handled the same way: log it, tear the worker down, spawn a fresh one
(a runaway leaves the old worker's heap spent, so it is never reused),
drop the offending event, and keep the last good state. The runtime lives
on. Two paid-for lessons. First, the worker's reply is wrapped in an
ok/err *result* envelope by the worker protocol; a new `workcmds.callConn`
returns the *unwrapped* value and keeps "raised" and "crashed" distinct
from a clean value (the older `call` folds a crash into an err result).
Second — and this bit generally — an **empty record could not cross the
worker channel**: `writeData` renders `{}`, but the strict data parser
read `{}` back as an empty *block* (→ `nothing`), so any value carrying an
empty record (here an event with no fields) failed to re-parse with "the
input is not data". Data has no blocks, so `parseData` now reads `{}` as
the empty record — an empty record round-trips, on the worker channel and
anywhere data is serialized. The drill (profile `gboom`,
`boot/scripts/gui-boom.msh`): an isolated GUI whose "boom" button's
`update` runs away in unbounded self-recursion; the host fires it, the
runtime logs `update crashed — recovering`, then the host fires
"increment" and the app reaches `count=1` — proof the runtime survived
and `update` still works — and the kernel's leak bar (pmem byte-identical,
shm at zero) proves the discarded worker was reclaimed clean.

**Stage 7 (as built, 2026-09-09).** The post-login GUI shell — what the
front door opens *onto*, made graphical. Stage 5's interactive session
ran msh on a terminal; here the session's whole UI is a GUI, rendered
through the shared font service, running as the logged-in user in their
own session domain. The honest model was the one chosen: the graphical
shell runs *in the user's session domain*, not in a system service, so
the per-user isolation the session model already gives (home view,
budgets, `nothing above the home is nameable`) holds for the desktop too
— a compromised shell is the user's problem, confined to the user's
domain, and the trusted-path login above it is untouched.

The mechanism reuses the session machinery whole. The GUI front door's
session manager (`usersvc-guishell`) is `users` in serve mode as before,
but it now *holds a display and a font cap*. That single fact makes every
session it opens graphical: `spawnSession` sees a display and picks the
`init` image (not the verifier) in mode 3, passes a one-bit flag in the
spawn arg (`3 | (1 << 8)`) telling init "this is a GUI session", and
forwards the display and font caps into the new domain. init reads the
flag and, instead of the console session template (`conf/session/`),
loads the GUI one (`conf/sessiongui/`) — a unit that runs mshrun on
`scripts/gui-shell.msh`, a minimal desktop (a `gui { }` with a "log out"
button) given the forwarded display and font. The login form and the
session's shell are thus two GUIs on the one compositor, exactly as the
terminal case: the trusted form is focused while you type, closes on
submit, and the session shell's fresh surface takes focus
(`createSurface` gives a new surface focus when no *trusted* surface
holds it) so its logout button has the keyboard. `login` blocks in the
greeter until the shell's `update` returns `done: true`, which closes the
window, exits mshrun, unwinds the session domain, and lets `login` report
who signed in — the same unwind as a console session, no new teardown
path. The drill (profile `guishell`, `boot/scripts/gui-shell.msh`): the
host signs in as the real `alice`, waits for the session shell's own
second `gui: ready`, presses Enter to fire the focused logout, and the
log tells it whole — `usersvc: session opened for alice`, `init: session
for alice`, the shell's `gui: ready` then `gui: shell exited`, `usersvc:
session closed for alice`, and the greeter's `gui: session ok who=alice`,
then clean shutdown. Nothing new was needed in the compositor or the GUI
runtime; the shell is a GUI service like any other, and the session
domain is where a user's own software has always belonged.

**Stage 7b — automatic per-user font scale on login (as built,
2026-09-09).** The per-user font-scale *push* mechanism landed earlier
(fontsvc's `reconfigure` merges a user's font layer over the system one,
a `fontscale` drill proving it with a stand-in client); what it waited on
was a post-login GUI that runs *as the user* to drive it. Stage 7 is that
GUI, so the loop closes: the GUI session applies the logged-in user's own
font preference for the life of the session, and reverts it on logout —
automatically, no app or template author asking for it, the accessibility
scale where it belongs.

Two small pieces, each in the user's own session domain (never the
sensitive session-key custodian). First, a **home skeleton**: a fresh
home has no config of its own, so on first login the session's init
(mode 3, holding the home's rw view) copies the archive's `conf/skel/*`
into the home's `conf/` for any file it lacks — today `conf/font.msh`, a
`{ scale: 1.5 }` starter (larger type, an accessibility-forward default a
user can lower). An existing file is never touched: the user's own choice
always wins, and the copy is a first-run event, not a per-login one.
Second, the **push itself** is an ordinary step in the session shell's
mshl, the same grain as `login`: a new `sessionfont TEXT` hosted command
(offered by the GUI runtime, `user/guicmds.zig`, when it holds a font
cap) pushes a font layer to fontsvc via `reconfigure`; an empty push
reverts. The shell script reads its own `conf/font.msh` with `cat` and
pushes it *before* the window opens — the runtime's font metrics are read
lazily on the first render (`fontReady`), so the shell comes up already at
the user's scale — then reverts with a bare `sessionfont` after the
window closes, so the next login (a different user, or the greeter) starts
from the system default. The push shares the GUI runtime's own fontsvc
request buffer; a small refactor split the buffer-attach
(`ensureFontBuf`) out of `fontReady` so either the push or the first
render can bring it up.

The drill (profile `guishell`, extended) now watches the scale ride the
session: `fontsvc: up (ui 16px, scale 1.00)`, then on login `init: seeded
home config conf/font.msh` and `fontsvc: reconfigured (ui 24px, scale
1.50)` *before* the shell's own `gui: ready`, then on logout `fontsvc:
reconfigured (ui 16px, scale 1.00)`. The per-user accessibility scale,
read from the user's home, applied to the whole session's type, and
unwound with the session — the honest end of the font arc's per-user work.

**Stage 7c — the settings UI (as built, 2026-09-09).** The post-login
shell, until now a single "log out" button, becomes a small settings
desktop: the user adjusts the accessibility text scale and it takes
effect. It is still a pure mshl GUI, and the pure-`update` rule (no caps
in `update`) shapes the interaction exactly as `login` did — the panel's
`update` only changes state (smaller/larger step the scale ±0.25, clamped
to [1.0, 3.0]; apply and log out set a done flag with an action), and the
side effects are pipeline steps *after* the GUI returns. On "apply" the
script does two ordinary commands — `save "conf/font.msh" { scale }` into
the user's own home (a data record rendered to msh, the same layer format
fontsvc reads) and `sessionfont (cat "conf/font.msh")?` to push it live —
then *recurses* (`def panel [scale]` calling itself with the new scale),
reopening the panel at the new size, so the change is visible immediately
and the session stays up. "log out" reverts the layer (a bare
`sessionfont`) and falls out of the recursion, ending the shell. So the
whole loop — read the saved scale (`from-data (cat …) | get "scale"`),
adjust, persist, apply live, repeat — is a dozen lines of mshl over the
`gui`, `save`, `cat` and `sessionfont` primitives that already existed;
no new machinery. Persist and apply are the same file: `save` writes it,
`cat` reads it back for the push, so a session's setting outlives the
session (the next login's auto-scale reads it), and the live push resizes
the running session's type at once.

The `guishell` drill now drives the round trip end to end: sign in as
alice, watch the shell auto-apply her saved scale on login (`fontsvc:
reconfigured (ui 24px, scale 1.50)`), press *smaller* then *apply* and
watch the new scale persist and push (`(ui 20px, scale 1.25)`) with the
panel reopening at it, then log out and watch it revert (`(ui 16px, scale
1.00)`). A settings UI written in mshl, editing the user's own home,
applied through the one shared font service.

**Rendering pass (as built, 2026-09-08).** The first look was honest but
crude — a 400×240 window marooned on a 640×480 scanout, 1-bit 8×16 glyphs
blitted 1:1 and then nearest-neighbour-upscaled by the viewer into hard
blocks. Three changes, no new font asset. (1) The compositor's scanout
went to **1024×768** (`fb_w`/`fb_h`), so there are more real pixels and the
viewer scales less; the framebuffer is now 768 DMA pages, and a
full-scanout *surface* (the terminal's, gpucli's) is 768 pages too — which
overran the kernel's `shm_max_pages` (384), so that cap rose to 768 (a
full scanout is the largest single shared buffer the system hands out).
(2) The GUI font is drawn at **2× crisp** (`drawGlyph`): each source pixel
becomes a solid 2×2 block — a bigger 16×32 cell, sharp, reusing the one
bitmap font. Two smoothing passes were tried and rejected first: EPX/
Scale2x (a sprite scaler that rounds *every* corner, including a letter's
intended square ones — blobby) and bilinear grayscale AA (soft edges, but
at this size it just reads blurry). A 1-bit bitmap has no detail to
smooth *into*; the honest choices are crisp-blocky or a real larger/vector
font (a later arc), and crisp is what a pixel font should be. (3) A
real **layout**: a centred 680×460 window, a title with a rule under it,
consistent padding and line spacing, and widget chrome — buttons are
padded outlined boxes (filled and brightly outlined when focused, a quiet
fill otherwise), fields a label over a full-width outlined value box with
a cursor. The terminal, which sizes itself to the scanout, and every
graphical drill's pixel checks were updated to the new geometry. Real
grayscale-antialiased type is still a later arc; this is the bounded pass
that makes the GUI look intentional.

**Theming and accessibility (as built, 2026-09-09).** The rendering pass
made the GUI look intentional but hardcoded its colours; this makes the
look a *theme* — a set of semantic tokens, not scattered literals — and
turns colour into an accessibility surface. The mshl GUI runtime
(`user/guicmds.zig`) now draws from a `Palette` of roles (bg, surface,
raised-surface, text, muted text, title, border, focus, primary +
primary-ink, danger + danger-ink, field, and the border/focus
thicknesses), resolved from three *composable* appearance axes: theme
(dark default / light), contrast (normal / high) and colours (default /
colourblind-safe). They combine — dark + high-contrast + colourblind-safe
is a real, distinct palette. High contrast pushes the ground and ink to
the extremes and bolds the outlines and the focus ring; colourblind-safe
swaps the accent and danger hues to the Okabe-Ito set (blue vs vermillion,
distinguishable across the common CVDs — no red/green cue), and meaning is
never carried by colour alone: a control's raised shape and its label say
what it is too. Widgets got depth without gradients — a button is a filled
box with a one-shade-lighter top edge and a one-shade-darker bottom edge
(`shade` scales the fill's channels), a border, and, when focused, a
bright ring; a `variant` field gives it semantic colour (primary = the
accent, danger = destructive, else the neutral surface), so the login
form's "sign in" and the settings "apply" read as the primary action and
"log out" as the destructive one. The renderer also grew a small layout
engine — `column` stacks, `row` flows left-to-right, buttons auto-size to
their label — over the old single-column walk.

Where the palette comes from is the honest part: fontsvc, already the
appearance authority (it owns the accessibility *scale* and merges the
system + per-user settings layers), now also parses the appearance axes
from that same `conf/font.msh` layer and serves them (`FontReq.appearance`
→ the packed flags). guicmds queries it as each window opens and resolves
its palette, so a user's theme and their high-contrast / colourblind-safe
switches are *system-wide* (every GUI, the greeter included) and ride the
same per-user push the font scale does — set them in your `conf/font.msh`
and the next login (or a live `sessionfont` push) recolours the whole
session.

The settings desktop drives all of it. The post-login shell's panel grew
an *appearance* section — theme, contrast and colours, each a button that
cycles its axis — beside the text-scale controls, laid out in `row`
groups. "apply" writes the whole appearance (`to-data { scale, theme,
contrast, colours }`, so the hyphenated `cb-safe` is quoted and
round-trips) to the user's home and pushes it live, and the panel reopens
recoloured; the accessibility switches persist for the next login. One
bug surfaced the layered-settings contract: `lib/settings.merge` keeps the
*system* layer's keys and lets a user override them, so a key the user
sets but the system layer never declared is dropped — the theme toggled
in the panel but reverted on apply until `theme`/`contrast`/`colors` were
added to the system `conf/font.msh` too. The `guishell` drill now drives
the appearance round trip: sign in, turn contrast high and colours
cb-safe, apply, and a screendump confirms the reopened window's ground is
pure black (the Okabe-Ito accent lighting the "apply" button) before
logging out.

**Fixes from driving it by hand (2026-09-09).** Three things the drills
missed but a person found in `run-gui`. (1) The settings panel overflowed
the fixed 460-px window (the "apply"/"log out" row fell off the bottom);
the window now *sizes to its content* — a measuring pass lays the tree out
with the pixel-writing primitives suppressed (`measuring`), and the
surface is created at that height, clamped to the scanout and re-centred,
before it opens. (2) Repeatedly applying settings crashed the VM to a
clean exit: each apply reopens the panel (the `def panel` recursion), and
`closeSurface` destroyed the compositor surface but never *unmapped its
pixel buffer or dropped its cap*, so a ~1.25-MB mapping leaked per reopen
until the shell's shm quota was spent, `openSurface` failed, and the
essential shell exited — taking the interactive session down with it. Now
close unmaps and drops; the `guishell` drill cycles apply several times so
a regression trips it. (3) There was no cursor: `run-gui` handed the guest
only a keyboard, and the guishell profile used the keyboard-only
compositor. The post-login shell now runs on the pointer-capable
compositor (`compositor-ptr`), and a virtio tablet rides along in both
`run-gui` and the drill — so clicks route to widgets, keyboard-driven
tests still pass, and an idle cursor stays hidden (no screendump noise).

**The settings shell's memory (2026-09-09).** The surface-buffer leak
above was real but not the whole story: freeing it, the shell still fell
over after ~7 applies with `mshrun: out of memory` — the interpreter's,
not the compositor's. Two causes, both from a GUI that *reopens*
repeatedly. First, the shell looped by **recursion** (`def panel … panel
…`), and a never-returning tail call keeps every prior frame's scope
alive, so the call chain and its bindings grew without bound; it is now a
`while` loop that reads the saved appearance each pass, so a pass's state
is dead once it ends. Second — the deeper one — the GUI runtime's own
event loop never **reclaimed** the per-render view trees: each render
calls `view` and builds a fresh widget tree, and mshl retains escaping
values in reference-counted boxes that are only swept at statement
boundaries — but a `gui` call is one long statement, so the dead trees
piled up across every render of every panel until the box heap was spent.
The runtime now calls `it.reclaim()` at the top of each render, draining
the previous frame's garbage; that bounds *any* long-running GUI (a
counter clicked a thousand times, a shell reopened all afternoon), not
just this one. A drill that cycles apply a dozen times guards it.

**Rounded widgets and a live clock (as built, 2026-09-09).** Two things a
person asked for after living with the flat look: softer shapes and a
login that shows the time. The renderer grew anti-aliased rounded
rectangles — `fillRoundRect` fills the straight bands solid and feathers
each corner's quarter-disc with `blendPx` (coverage = `r + 0.5 − dist`, a
~1px edge), and `panel` draws a rounded fill inside a rounded border of a
given thickness, its inner corners AA against the border, the outer
against the ground. Buttons and fields are `panel`s now (radius 10 / 8);
focus is one mechanism with the border — a bright, thicker ring plus a
one-shade lift of the fill (still a double cue, never colour alone) — and
a hair of top highlight stands in for the old hard depth bars. Spacing
opened up a little. The window itself stays square (its surface is opaque,
so rounding it would only paint the ground colour into the corners); the
rounding is on the controls, where it reads.

The clock needed the display loop to wake without input, which it never
did — `next_input` parks forever in the compositor. So the protocol grew
`next_input_tick { ms }`: the reader also asks for a periodic tick, and if
no real input arrives the compositor answers with a `kind` 2 event so the
client re-renders. The compositor rides its existing input doorbell — a
kernel timer (`timer_arm`) signals `key_bell` with a distinct bit (2), the
serve loop reads the latched bits from `notify_wait` and, on the tick bit,
hands a tick to every ticking reader with a parked token; the timer is
armed only while some reader wants ticks (the shortest period any asks)
and disarmed when none do, so an idle compositor never wakes. The mshl
`gui` spec gained `tick: <ms>` (or `true` → 1s); on a tick the runtime
recomputes the *view* from the unchanged state (no `update`), so a `view`
that reads `(date)` refreshes on its own — a live GUI with no busy-wait.
Local apps only (a remote view would need a round trip per tick). The
front door (`gui-session.msh`) now shows a big `HH:MM:SS` over a `Sep 9,
2026` date above the fields; the time comes from `(date)` (the RTC read at
boot, no cap needed), month names from a small `match` in the script
because the `date` record carries only numeric parts and a bare ISO
string — a locale-agnostic source (CLDR) is stashed for later. The
`gsession`/`gisession`/`guishell` drills still drive the login green with
the clock ticking under them; the widget hit-boxes do not move because the
clock is a label and the column lays out by height, not width.

**The fabric GUI (as built, 2026-09-09).** The payoff of the GUI-as-a-
service model: a GUI can run on another node. Because an mshl GUI is a
pure `update`/`view` over a declarative tree, the whole app is data — the
view tree that comes out, the event id that goes in — so it ships across
the fabric with nothing lost. `gui { …, node: N }` makes the runtime a
pure *viewer*: it reconstructs the app (update + view) as one worker
script that reads `$in = { state, ev, apply }` and returns `{ state, tree
}` — the same trick the crash-isolation path already used for `update`
alone, now covering `view` too — and runs it on node N over the fabric
(`fabcmds.runRemote`, the very code the `remote` command uses) once per
event. The viewer holds no app logic: it renders the tree that comes
back, routes input, threads the returned state, and on a dropped round
trip keeps the last good frame (let-it-crash across the wire). The window
sizes and the initial view still work locally because the app closures
*are* present locally — the definition lives in the script and is shipped
to execute elsewhere, exactly as a `remote` block is.

The drill (`fabgui`) is the repo's first display on a fabric node: node 1
is the proven `flogin` fabric host (it accepts remote stages), node 2
boots the new `fabgui` profile — a fabric client with the graphical
devices — and runs a counter whose `node: 1` puts its state, update and
view on node 1. The app script waits for the mesh (a `remote 1` probe
retried like the fabric drill's) before opening the window, so the window
appearing already proves the join and the first remote view. The runner
presses increment twice and quit over QMP; each event round-trips to node
1 and the final `fabgui: done count=2` — the count computed on node 1 —
comes back to node 2. A GUI you cannot tell is remote.

The stage is *persistent*: opened once when the window opens and reused
for every event, so node 1's log shows a single `remote spawn request
served … remote stage up` for the whole session rather than one per
event. `mshrun`'s remote-stage loop no longer exits after its one answer
(a one-shot `remote` caller still ends it by tearing the session down —
`peer_dead`); it resets its arena per run, so runs do not accumulate.
`fabcmds.Stage` (open / call / close) spawns the stage once, re-sends the
(small, unchanging) app script with each event's input on the kept
session, and the fabric proxies that session across calls the same way a
remote home's does. If the node is unreachable when the window opens, the
runtime falls back to running the app in-process — its closures are
present locally — a graceful degradation. The domain spawn on the host is
paid once, not per keystroke.

**Cross-node notifications: a signal primitive (as built, 2026-09-09).**
The fabric could move state and calls; it could not, until now, let one
node *wake* another. The primitive is a `signal`: `(signal)` creates one
(a mshl handle over a kernel notification cap the runtime holds), `wait`
blocks on it and returns the bits that woke it, and `notify NODE NAME
BITS` rings it from anywhere in the mesh. A signal is named on the fabric
by the same `publish` the concurrency arc already had — `publish` is
overloaded on its argument's shape (a worker handle publishes a channel,
a signal handle publishes a notification), so a waiter does `let s =
(signal); publish "evt" $s; wait $s` and any node fires `notify 1 "evt"
5`. The wake is a single one-way wire frame — `fw_notify` (frame type 22,
wire version bumped 6→7), `[a][b][bits]` three little-endian words, no
reply and no ack. `fabsvc` on the naming node holds the published
signal's notification cap in its `Export` (a new `notif` field); when
`fw_notify` lands it does `findPublished(name)` and signals a copy of
that cap, so the sender's `wait` returns with the bits. Fire-and-forget
by design: like a doorbell, a lost ring is simply not heard — there is no
shared clock to assume and nothing to retransmit. Local `notify` (same
node) skips the wire and signals the export directly, so the primitive
reads the same whether the waiter is here or across the mesh.

The drill (`fabsignal`) is a two-node exchange with no display and no
console: node 1 (profile `fabsig`, the fabric seed) publishes `"evt"` and
blocks in `wait`; node 2 (profile `fabsigtx`) joins over the socket and
fires `notify 1 "evt" 5` forty times over ~20s, so the first frame to
land wakes node 1 — its log shows `fabsig: woke bits=5` four milliseconds
after node 2 reports the join, then a clean essential-unit shutdown. The
`notify NODE NAME BITS` argument packing reuses a single `FabReq` word
(`packNodeBits`: 16-bit node, 48-bit bits), so the request stays within
the three-word payload the fabric control channel already carried.

**The system font service (as built, 2026-09-08).** The bitmap font was
the ceiling on how the GUI could look; real type meant a vector-font
stack, and the shape it took is a *service every text program goes
through* — so type is consistent and, crucially, scaled in one place
(accessibility, the thing Linux fumbles because every toolkit scales on
its own). Three pieces. (1) `lib/font.zig` — a from-scratch rasterizer,
pure and host-tested: it parses the SFNT tables (`head`/`maxp`/`hhea`/
`hmtx`/`cmap`/`loca`/`glyf`, or `CFF `), decodes both outline flavours —
TrueType (`glyf`, simple + composite, quadratic Béziers) and
OpenType/PostScript (`CFF ` Type2 charstrings, cubic Béziers) — and fills
either with one 4× supersampled non-zero-winding scanline rasterizer into
an 8-bit coverage bitmap. Every format converges here — WOFF (zlib) and
WOFF2 (Brotli + a glyf/loca transform, lib/woff2.zig over lib/brotli.zig)
are additive container front-ends that normalize to the SFNT it reads. (2)
`user/fontsvc.zig` — the service: it scans the boot archive's assets/fonts
tier and registers every `.ttf` it finds by its family name (from the
`name` table) into a **font registry** — the bundled IBM Plex Sans, Mono
and Serif (OFL), and any font dropped there; no filesystem needed, so it
runs in any profile. It owns the effective font settings (a family name
and a base size per role, plus a scale factor), and rasterizes glyphs on
demand into a **shared coverage atlas** — a client attaches a request/response buffer, maps the atlas
once, and `layout`s each string; fontsvc shapes it, caches each glyph in
the atlas, and writes the glyph run (pen positions + atlas rects +
metrics) back into the buffer. **Per-client buffers (2026-09-10):** the
buffer was a single global, so a second client's `attach_buf` unmapped and
repointed it and the first client's next `layout` read a stale, foreign
buffer and faulted — the race behind the `desktop` drill's flake (its two
windows are the only two GUI processes sharing one fontsvc, and under load
their requests interleaved). fontsvc now keys each buffer by the badge the
client invokes with: a GUI client `register`s (like the compositor) for a
fresh badge (2..) so its buffer is its own; an unregistered client keeps
badge 0, one shared slot — the single-client legacy (the terminal, a
drill), unchanged. It never draws: rendering stays
client-side, so the trusted path is untouched and a glyph bitmap is all
that crosses. (3) The mshl GUI runtime is the first client — it lays out
proportionally (measured widths size the buttons and fields), blits each
glyph's coverage from the atlas over its own background with its own
colour, and falls back to the bitmap font when no `font` cap is present.
The login form and the counter now render in real IBM Plex Sans, crisp
and anti-aliased. The terminal is the second client: a monospace grid, so
it does not want proportional layout — it takes the mono role's advance
and line height as the cell size, fetches each byte's glyph from fontsvc
once (caching it locally by codepoint, so a warmed console does no IPC per
character), and blits coverage at fixed cells. So the shell console — the
post-login seat — is real IBM Plex Mono too, at the same scale as
everything else, with the same bitmap fallback.

The effective sizes and the accessibility scale are data, not constants:
fontsvc reads `conf/font.msh` (the system settings layer) at startup —
parsed with mshl and run through `lib/settings.merge`, the same substrate
every other program's settings use — for the per-role base sizes and a
single `scale`. Every size is multiplied by `scale`, and because all text
goes through fontsvc and the GUI lays out from the *scaled* metrics, one
`scale: 1.5` resizes the whole UI at once and the layout reflows to match
(bigger buttons, wider fields, taller rows) — the system-wide
accessibility knob, the thing Linux never manages because each toolkit
scales on its own. The same file names a font family per role
(`ui_family`, `title_family`, `mono_family`); since fontsvc registers
whatever `.ttf` is under assets/fonts by family name, installing a font is
dropping the file there and naming it here — the system's typographic
personality is data, not code (a serif title, say, next to a sans body).
On a real system with a disk that directory is on the filesystem, not just
the archive: `fontsvc` in filesystem mode (`arg 1` + a fonts-dir view)
lists it and reads each `.ttf` off mossfs, so a font a user drops there
persists and loads with no OS rebuild (the diskless default reads the
bundled families from the archive instead), and a `rescan` request picks
up a font added since start-up with no restart at all — install is live.
The `gboom` drill renders through a filesystem-mode fontsvc (families log
tagged `(fs)`); the `fontrescan` drill installs a font at runtime — a
client copies a `.ttf` into the fonts directory and calls `rescan`, and
the new family registers on the spot. A paid-for lesson from that drill:
init parses each unit file into an arena it resets before the next, and
the mshl parser *copies* quoted strings into it — so a quoted give path
like `fs: "assets/fonts"` dangled once enough units pushed the reuse past
it (bare words slice the persistent archive and were fine); init now
copies every kept give string into a pool that outlives the parse. The per-user layer plugs into the same `merge` call (a
user's `home/<user>/conf/font.msh` over the system one), and a session now
pushes it. **The per-user scale push (as built, 2026-09-09).** fontsvc is a
singleton — one atlas, one effective scale — so a per-user scale is the
logged-in user's scale applied to the shared service for the life of their
session. fontsvc keeps the system layer's text and gains a `reconfigure`
request: a client stages the user's `font.msh` in the request buffer and
fontsvc merges it over the system layer (the same `lib/settings.merge`,
locked keys and all) and re-applies scale, sizes and families; an empty
push reverts to the system layer alone (logout). New sizes just produce new
atlas entries on a client's next layout, so the change is picked up with no
invalidation. Because a user overriding only `scale` keeps the system's
sizes, `scale: 1.5` over a system `ui: 16` yields an effective 24 px — and
every client that lays out through fontsvc renders larger, which is the
accessibility knob made personal. Drilled (`fontscale`): a session-stand-in
(`fontpush`, the same idiom as the `fontrescan` client) reads a user's font
layer, pushes it, reads back the ui role's size (24 px), then reverts on
logout (back to 16 px) — fontsvc logs each reconfigure. Wiring this into the
automatic login flow — usersvc or the session pushing on sign-in — waits on
a post-login GUI that renders through fontsvc to show it (today post-login
is the bitmap-fallback terminal); the mechanism is proven and ready for it.

Paid-for lessons: a service reached by a `unit:` give
must still run init's boot handshake (answer `go`) even if it takes no
caps, or init deems it unwired; and the rasterizer's `top` is the bitmap's
signed device-y offset from the baseline (negative above), so the client
*adds* it — subtracting scattered every glyph off the line.

**Font formats (WOFF as built, 2026-09-08).** The formats are additive
front-ends that converge on the SFNT the parser already reads: a `toSfnt`
step normalises the input before `Font.parse`. WOFF is the first — a
zlib-per-table wrapper: `toSfnt` reads the WOFF directory and decompresses
each table (via `std.compress.flate`, which compiles freestanding) into a
reassembled SFNT; an SFNT input is returned untouched, so only a
compressed font costs anything. fontsvc keeps a decompress heap for the
result (a `Font` borrows its bytes).

**OTF/CFF (as built, 2026-09-08).** OpenType/PostScript fonts carry their
outlines not as `glyf`/`loca` but as a `CFF ` table: a compact structure of
INDEXes (Name, Top DICT, String, Global Subrs, CharStrings) and DICTs
(operator-follows-operands key/value blocks) whose glyphs are Type2
charstrings — a little stack machine of moveto/lineto/curveto ops with
**cubic** Béziers, hint operators, and subroutine calls (`callsubr`/
`callgsubr`, biased indices into a shared subr INDEX). `Font.parse` now
accepts a `CFF ` table (no `glyf`): `parseCff` walks the INDEXes and the
Top/Private DICTs down to the three INDEXes the interpreter needs
(CharStrings, global subrs, local subrs), and `rasterize` dispatches to a
Type2 interpreter (`execCharstring`) that emits an all-on-curve outline —
cubics flattened by `flattenCubic`, everything else identical to the glyf
path, so **one** scanline fill serves both. Non-CID only (a single Top +
Private DICT); CID-keyed fonts (FDArray/FDSelect) return `Unsupported`, a
later refinement. Width operands (which the first stack-clearing op may
carry) are detected and dropped — advances come from `hmtx`. `toSfnt`
already passed `OTTO` through untouched, so an OTF drops straight in. The
`fontrescan` drill now installs *two* real fonts live — IBM Plex Serif
(WOFF/zlib) and Source Code Pro (OTF/CFF) — covering both container
front-ends end to end; a host test also parses+rasterizes a hand-built
minimal CFF (a Type2 square) as a fast regression. WOFF2 (Brotli + table
transforms) is the remaining front-end.

**Brotli decoder (WOFF2 stage 1, as built, 2026-09-08).** WOFF2's tables
are a raw Brotli stream, so WOFF2 needs a Brotli decompressor — a large one,
with no equivalent in std. `lib/brotli.zig` is a from-scratch RFC 7932
decoder: an LSB-first bit reader, canonical prefix codes decoded through a
bit-reversed lookup table (Brotli packs codes LSB-first, unlike Deflate — a
puff.c-style MSB walk silently mis-decodes same-length symbols, the bug that
cost the most here), the full meta-block machinery (block-type/count
switching, literal/distance context maps with RLE + inverse-MTF, the
insert-and-copy command split via the cell-position table, the distance
ring buffer and its roll compensation), and the 122 KB static dictionary +
121 word transforms for dictionary references. It is a straight-through
decoder: the decompressed size is known (WOFF2 states it), so the output
buffer is the window and there is no ring-buffer wrap or resumable state.
The fixed tables (dictionary, context lookup, transforms) are RFC-defined
data lifted verbatim from the reference (MIT, `lib/brotli/LICENSE`); the
logic is independent. Validated by fuzzing 70 corpora (empty, tiny, binary,
random, text, CSS, font bytes, a real WOFF2) across every quality level
against the reference `brotli`, plus committed vectors (dictionary, copy,
store paths). Freestanding-safe (arena over a caller heap), so fontsvc can
use it directly.

**WOFF2 (as built, 2026-09-08).** `lib/woff2.zig` sits on the Brotli decoder
and completes the container: parse the WOFF2 header + table directory (with
its UIntBase128 and 255UInt16 compact integers and the 63-entry known-tag
table), Brotli-decompress the concatenated table data, and reverse the
`glyf`/`loca` transform. That transform is the substance: the outlines are
split across seven sub-streams (contour counts, per-contour point counts,
point flags, the coordinate triplet stream, composite data, an explicit-bbox
bitmap + values, and instructions), and reconstruction walks them per glyph —
decoding the triplet-packed coordinates, re-encoding standard `glyf` flags +
delta runs, computing the bbox where the font omitted it (simple glyphs),
sizing composites from their component flags — then rebuilds `loca` from the
resulting glyph offsets. Untransformed tables are copied; the rare `hmtx`
transform is refused. The reassembled SFNT flows into the same `Font.parse`.
`toSfnt` gained an allocator (used only here); fontsvc passes a reset-per-font
scratch heap, and `.woff2` is a recognised font extension, so a WOFF2 dropped
in the fonts dir installs like any other. Validated hard: every glyph of two
real fonts — Source Code Pro (296 glyphs) against a fontTools reference, and
IBM Plex Sans (1025 glyphs, 485 of them composites) against the original TTF —
rasterizes byte-identically; the reconstructed `glyf` even matches the
declared `origLength`. The `fontrescan` drill now installs all three
front-ends live (WOFF, OTF/CFF, WOFF2), each registering its family.

What's left for the arc: richer layout, subpixel, and the fabric-remote
GUI the data-only design already allows. (Pointer input, the per-user
scale push, and TrueType hinting have landed.)

**TrueType hinting, stage 1 — the interpreter (as built, 2026-09-09).**
A glyph's outline, scaled to a small pixel size and filled, blurs its
stems across pixel boundaries; the crispness real type has at UI sizes
comes from *hinting* — a bytecode program, shipped in the font, that
grid-fits the outline so stems land on whole pixels. moss reads real
fonts (IBM Plex Mono/Sans both carry hint programs), so the honest thing
is to run them: `lib/tthint.zig` is a from-scratch TrueType instruction
interpreter. It is a stack machine over 26.6 fixed-point pixel
coordinates with the full graphics state (projection/freedom/dual
vectors, three reference points, three zone pointers, a super-round
state, loop counter, minimum distance, cut-ins, delta base/shift), a
storage area, a scaled control-value table (CVT), user-defined functions,
and two point zones (the glyph and the twilight scratch zone). Stage 1 is
the VM and the two size-independent/per-size programs it runs: `fpgm`
(once, to define functions) and `prep` (per size, to set the graphics
state and scale the CVT). Essentially the whole instruction set is
implemented — pushes, the stack ops, arithmetic and logic in 26.6,
rounding in every mode, control flow (IF/ELSE/JMPR/JROT/JROF),
FDEF/CALL/LOOPCALL, storage and CVT reads/writes, the graphics-state
setters, measurement (GC/MD/MPPEM), the point-movement family
(MDAP/MIAP/MDRP/MIRP/IP/SHP/IUP/…) and deltas — because a called function
uses any of it. Two decisions shape the design. First, **hinting is
best-effort**: any malformed program, unimplemented corner, or bound
overrun returns `error.Hint`, and the caller (stage 2) simply keeps the
unhinted outline — so rendering never breaks and the opcode set can grow
under real fonts. Second, **`maxp` is not trusted**: real fonts routinely
under-report (IBM Plex Mono declares maxFunctionDefs=0 while its fpgm
defines functions, and maxSizeOfInstructions=3 while glyphs carry 58+
instruction bytes), so the stack, storage, function table and twilight
zone are provisioned from generous minimums, not the font's claims. The
paid-for bug was in MINDEX: it must move the k-th stack element to the
top (net −1, for the popped index), but an extra decrement made it net
−2, and IBM Plex Mono's prep — which threads values through deep
MINDEX/ROLL/IF chains to pick a CVT value for the current ppem —
desynced the stack and tripped a SWAP underflow a hundred instructions
later. Verified two ways: a synthetic fpgm+prep unit test (push,
arithmetic, RCVT/WCVTP, storage, IF, FDEF/CALL, rounding) with asserted
results, and a real-program smoke test running IBM Plex Mono's own
`fpgm`+`prep` (extracted as small vectors) clean across every UI ppem
(8–48).

**TrueType hinting, stage 2 — glyph fitting, wired (as built,
2026-09-09).** The visible half: run each glyph's own program and
rasterize the *fitted* outline. `rasterizeHinted` loads a simple glyph's
points in font units (composites fall back — they are the accented
letters, not the stems that matter), scales them to 26.6, appends the
four phantom points (the horizontal pair carrying the side bearing and
advance from `hmtx`, the vertical pair the bbox top/bottom), builds the
glyph zone and hands it to the interpreter's `hintGlyph`, which restarts
from the graphics state prep left and runs the glyph's instructions —
moving points onto the grid, the glyph program calling IUP itself to drag
the untouched points along. The fitted 26.6 points come back, convert to
pixel coordinates, and flow into the *same* scanline fill the unhinted
path uses — a small refactor split `fillOutline` out of `rasterize` so
both feed it, the hinted path passing points already in pixels (scale 1).
The advance stays the linear one, so grid-fitting changes the glyph's
shape, never the layout. Every failure path — a composite, an
unimplemented opcode, a bound overrun — returns `error.Hint` and the
caller keeps the plain fill, so a font moss cannot fully hint still
renders.

fontsvc drives it: a small cache holds one prepared hinter per (family,
device ppem) — dear to build (it runs fpgm+prep), cheap to reuse across
every glyph at that size — each in its own backing heap, evicting the
oldest when full. A glyph is hinted when its family carries a program,
else filled plain. Verified end to end both ways: a host test rasterizes
IBM Plex Mono's `H` hinted and unhinted at 16px and asserts the hinted
bitmap has strictly fewer mid-grey (anti-aliased-edge) pixels — the
measurable signature of stems snapped to whole pixels — and the running
system proves it live, the `term` drill asserting `fontsvc: hinting 'IBM
Plex Mono' at 15px` while both bundled hinted families (Mono and Sans)
grid-fit clean across every UI size (15/16/22/24px) with no drill
regressing. Real type, from the font's own instructions, at moss's sizes.

**Smoother proportional text (as built, 2026-09-10).** Once the scanout
went to 1280×1024 and the window is shown on a Retina 2× display, the
grid-fit look — crisp but a touch digital — was worth trading for shape
fidelity on the *proportional* UI text (the macOS approach: minimal
hinting, heavy AA). Two changes. The rasterizer's supersampling went 4→8
per axis (16→64 samples/pixel), so curve edges carry a finer coverage
gradient; glyphs are cached in the atlas, so it is a one-time cost per
glyph and size. And fontsvc now hints only the **mono** role — the
terminal, where snapped stems and even spacing matter (and the `term`
drill's hinting assertion lives) — while the `ui` and `title` roles render
*unhinted*, their outlines following the true curve for the AA to smooth.
The hinting interpreter and stage-2 fitting stay exactly as built; only
which roles ask for them changed. Open for the arc: subpixel, the
fabric-remote GUI.

**A scrollable list and a two-pane split (as built, 2026-09-10).** The
widget set (label/button/field/row/column) had no way to show more items
than fit, which a file explorer needs, so two widgets landed. A **`list`**
is a viewport of a fixed pixel height (`h`) over its `rows` (each `{id,
cells}`), with optional `cols` (`{title, w}`) for a header and column
layout: it clips its rows to the viewport, draws a proportional scrollbar
when the rows overflow, highlights the selected row, and truncates a cell
that overruns its column with an ellipsis. A **`split`** places a
fixed-width `left` node beside a `right` node that fills the rest, divided
by a hairline — the sidebar layout. Two pieces of machinery made the list
work against the immediate-mode renderer. First, a **clip rectangle** the
drawing primitives honour (`putPx`/`fillRect`/`blendPx`), reset to the
whole window each render and narrowed to the viewport while rows are drawn,
so a partial bottom row is cut cleanly rather than spilling. Second, the
list's **interaction state — scroll offset and selection — is owned by the
runtime and keyed by the widget's id** (like a text field's edit buffer,
in `ListState`), with a `key` that resets scroll/selection when the
content changes (a new directory), so the mshl app stays declarative: it
emits the rows, the runtime remembers where the user is in them. A list is
one focusable (its rows never eat the 16-focusable budget); a click hit-
tests to a row (a reclick opens it), the scrollbar pages, and — once arrow
keys were added to the keymap (evdev up/down → private control bytes) — the
selection moves by key with the view scrolling to keep it visible, Enter
opening it. Selection follows the selection *only when it moves* (a click
or arrow), never on a plain render, so a free scroll (the scrollbar) is not
clamped back. A list fires `{id, row, activated}` — `activated` true for
Enter or a reclick (open), false for a plain selection — and the app maps
`row` to its data. The `listdemo` drill drives it end to end: arrow the
selection down past the viewport (proving it auto-scrolls) and Enter to
open the row it lands on. **Lesson (paid for here):** a value a `view`
builds with `map` lives in the interpreter's *call scopes*, which `reclaim`
collects between renders — so a list whose rows are `map`-generated and
held across renders has its backing overwritten (a corrupt tree, a
vanishing widget). Rows from a literal or from a command like `ls` (which
dupes into the bump arena) are stable; the file explorer builds its rows
from `ls`, so it is unaffected, but a `map`-in-`view` that is retained is a
trap until the interpreter promotes such results out of the call scope.

**The file explorer, local (as built, 2026-09-10).** A two-pane explorer
written in mshl (`boot/scripts/explorer.msh`): a **Places** sidebar (Home)
and a file list of the current directory — name, kind, size, directories
first — in a `split`, with an "Up" button, a breadcrumb, and a footer
showing the volume's capability facts. Navigation is state: the app keeps a
`path` string, "Up" is `fs-parent`, opening a folder appends the child; a
row's activation only navigates if the target lists as a directory (it
tries `fs-rows` on it and stays put on an error), so a file open is a
no-op rather than a broken path. The rows come from a new Zig command,
**`fs-rows [path]`** (`user/fscmds.zig`): it does the `ls` listing, sorts
directories first then by name, and returns `{id, cells}` rows with display
strings (a folder's name carries a trailing `/`, a human size like `2.1
KB`) — built with arena strings so the list widget can hold them across
renders, the point the stage-1 lesson made. The footer reads `df`, which
gained a **`read_only`** field (the bit was already on the `statfs` wire,
just never surfaced to a script) beside `encrypted` — so the explorer
states, from the filesystem itself, whether the volume is encrypted and
whether this view is read-only, the capability facts a browser should show.
An `fs-parent PATH` command (a pure string op) backs "Up". The standalone
`explorer` drill boots it over a read-write view of the disk root, clicks
the first folder, opens it, and closes — the app reporting a non-empty
path proves the click, activation, and descent. The desktop dock gained a
**Files** pill (a lazy session unit, `conf/sessiongui/explorer.msh`, over
the session's own home view), so it launches like Settings and Demo.

**Capability-scoped views in the explorer (as built, 2026-09-10).** The
filesystem's standout feature — a view is a capability you can narrow and
hand off — is now something you *do* in the explorer. "Open read-only"
derives a narrower, read-only sub-view rooted at the current folder and
makes it the explorer's active view: you are now browsing inside that
capability, the crumb reads `[scoped]`, the footer flips to read-only, and
"Up" cannot climb above the sub-view's root — you cannot escape what you
were handed. "Leave view" revokes it and restores the parent. The mechanism
is a **view stack in mshrun**: `view_chan`/`view_buf` always point at the
active view, and three commands (added to `fscmds` as optional host hooks,
so the one place that lists fs commands still owns them) drive it —
`fs-derive PATH [ro]` mints the sub-view (`fsDeriveBadged`), attaches its
buffer, pushes the parent, and switches to it; `fs-leave` revokes
(`fsRevoke` against the parent, with the derived badge), frees the derived
buffer and cap, and pops; `fs-derived` reports the depth. The read-only
flag is monotone in the service (a read-only view cannot derive a
read-write child), so this is a real capability boundary, not a UI toggle.
The `explorer` drill opens a folder, mints a read-only sub-view of it, and
confirms at close that it is inside a derived view (`depth=1`) whose volume
reports read-only (`ro=yes`) even though the base disk view is read-write —
the narrowing is genuine, not faked. Still local — browsing a remote node's
files (the chosen end goal) is the arc's next, larger stage.

**Remote file listing over the fabric (as built, 2026-09-10).** Browsing
another node's disk needs no new kernel or fabric machinery — it is a named
service over the existing dial/call transport. A per-node **browse service**
(`boot/scripts/browse.msh`, unit `browse`) is given a *read-only* view of its
disk (`{tag: view, ro: true}`) plus `{fabric, unit: fabsvc}`, and publishes
itself under the name `"browse"`; its whole body is `match (fs-rows ($in |
get "path")) { ok $r => $r; _ => [] }` — it answers a call carrying a `path`
with that folder's arena-stable `{id, cells}` rows, the same shape the local
explorer's list already renders. A client on another node (`browse-cli.msh`)
`dial`s the node by number and `call`s the service; the rows come back inline
over the fabric session buffer (a directory page fits well under the 32 KB
bulk limit). The 2-node **`browse`** drill proves the round trip: node 1
reports "node 2 root has 8 entries" — a real remote directory read, gated by
a read-only capability at the source. Two lessons paid for here: (1) any
profile whose units certify a fabric identity **must include `rngd`** —
`getrandom` is fail-closed until the virtio-rng pool is seeded, so a profile
missing it makes `certifySecret` spin its 50×100ms retry and time out at 5s,
and the fabric unit silently never wires; (2) the 24-byte unit script-path
field truncates without complaint (`scripts/browse-client.msh` → `…client.ms`
→ "not in the boot archive"), so unit script names must stay short.

**Remote browse in the explorer GUI (as built, 2026-09-11).** The explorer
became fabric-aware without a second script. Its Places sidebar gained a
**Network** section listing the live peers, and selecting one browses that
node's files in the right pane — the same two-pane UI whether the rows are
local or a node away. Two new commands back it, both in `workcmds` (the
module that already holds the fabric channel): **`net-rows`** asks
`FabReq.members` for the membership and returns one `{id, cells}` row per
live peer other than this node (id = the node number, cells = its label and
free space); **`browse-rows NODE PATH`** dials that node's `browse` service
and calls it with the path, returning the folder's rows. Both build their
rows in the interpreter arena — the same contract `fs-rows` keeps — so the
view can hold them across the per-render reclaim; a `map`-built list could
not. The members buffer is attached to `fabsvc` once and reused (the view
calls `net-rows` every render, and `fabsvc` does not unmap a prior
`attach_buf`, so re-attaching each frame would leak a mapping there — the
explorer is the sole members client, since `dnsd` uses the race-free
`member_state` query instead), and the dialed browse service is cached by
node, so switching nodes dials once and re-listing on navigation costs a
single call. The `netbrowse` drill is the end-to-end proof: two nodes, node
1 (`browsehost`) serving its files and node 2 (`netbrowse`) running the
explorer with a fabric cap and the graphical devices; the runner clicks the
one peer in the Network sidebar and reads back "node=1 rows=8" — node 2's
GUI listed node 1's disk over a certified fabric link. One design change
fell out of it: `workcmds` is now **always wired** (each command already
self-guards on the capability it needs, so `spawn` without a spawner or
`browse-rows` without a fabric fails with a clear message, not an "unknown
command"), which lets the *same* explorer script run local-only — where
`net-rows` simply returns no peers — or networked, rather than forking into
two scripts.

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

**As built (Phase 11 fabric v0 + dynamic membership, wire v2):** each
node's fabric service serves one channel; peers speak a versioned wire
protocol over TCP (frames [len][type][ver]; a version-mismatched peer is
dropped loudly). A *remote channel* is a badged cap on the local fabric
service: badged calls forward verbatim as call_req frames and return the
peer's reply words — the same four typed message words that cross local
channels, so remote services are indistinguishable to callers (the
remote-echo server literally runs unmodified CalcRequest-serving code).
Remote spawn ships {image, arg} to the peer, which spawns under a local
manifest and proxies the child's channel back.

**Membership is dynamic**: a node joins by dialing any seed
(connect_peer); the hello_ack carries the acker's member view — gossip at
join — and member_up/down broadcasts keep everyone current. The mesh
converges without coordination via one rule: **the lower node id dials a
learned member** (the joiner's dial to its seed is the bootstrap
exception); a fresh hello from a node already tracked replaces the stale
peer entry, which is exactly the rejoin path. **Liveness never assumes a
shared clock**: each node heartbeats on its own poll tick, and a peer
that goes silent — or whose socket errors, or to whom a frame cannot be
sent — becomes a membership down event immediately and is broadcast.
Heartbeats carry free-memory adverts; remote_spawn{node=0} places on the
least-loaded live member and reports where the spawn landed. Sessions
are keyed by node id (never peer slot), so a slot recycled by rejoin can
never misroute a stale remote channel — calls to a rebooted peer fail
cleanly instead (its rsessions died with it).

Lessons paid for: a failed *send* must update membership on the spot —
the first cut only marked the peer struct dead, so a vanished node was
never gossiped down and the death stage hung; and a best-effort ping must
treat would_block as "skip" (a healthy peer mid-stop-and-wait exchange is
not dead) while hard errors fail the peer. Test-harness note: mcast
socket netdevs do not deliver between QEMU processes on this macOS host,
so the 3-node check's L2 segment is a hub inside node 1's QEMU (hubport
netdevs bridging its NIC to two socket listeners) — and the runner
relaunches node 2 after its drill poweroff, so the check proves join,
gossip (node 3's own full-mesh view), placement, death detection with no
call in flight, rejoin, and respawn on the rejoined node.

**Fabric security (as built, wire v4: per-node identities).** Before
any of this, port 7100 was the one ambient-authority hole in the system:
anyone on the segment could join, lie in gossip, read everything, and —
worst — send fw_spawn_req, which the receiver executed with its spawner
capability: code execution by packet. v3 closed it with a shared cluster
key (mutual HMAC challenge-response, sealed transport); v4 replaces the
shared key with identities, keeping the transport.

*Trust artifacts* (`lib/fabcert.zig`, pure and host-tested): the cluster
has one **root of trust**, an Ed25519 keypair whose public half — the
cluster key — every node is configured with (public material, not a
secret). Each node has its own Ed25519 **identity**, and a
**certificate** the root signed over {node id, identity key,
authorization flags, image mask, serial}. A **revocation** is a
root-signed {node, minimum serial}. Signatures are domain-separated by
label so no artifact can be replayed as another.

*Custody*: the root key lives in **fabroot** (fabric role 3), a separate
domain — the code-sharing decision's "a capability service holds the
secret" made literal. It certifies identity *public* keys handed to it
and signs revocations; it never sees a node's identity seed. fabsvc
generates its keypair from a seed (set_identity, zeroized after the
copy), exports the public key, and installs the certificate the root
returns (set_cert — verified under the cluster key and checked to name
this node and this key, so a mis-issued certificate fails at boot, not
at the first handshake). The boot driver is the out-of-band channel
between the two services; neither sees the other's secret, and the
fabric is **fail-closed** until both steps are done.

*Handshake*: signed ephemeral Diffie-Hellman. hello carries the node id,
a nonce, a fresh X25519 ephemeral key, and the certificate; hello_ack
answers with the acceptor's, plus an identity-key signature over the
transcript {wire version, both ids, both nonces, both ephemeral keys,
both certificates}; auth is the dialer's signature over the same bytes
under a different label. Each side verifies the peer's certificate
under the cluster key (the id must match the claim; the serial must
clear every revocation it holds) and the signature under the certified
key. Session keys come from HKDF(X25519 shared secret, both nonces) —
identity keys only ever sign, so a stolen identity key cannot decrypt
past sessions — and every later frame travels fw_sealed as before. The
certificate is checked before anything else changes on the acceptor, so
a stranger claiming a live peer's id cannot evict it.

*Authorization is the certificate*: membership gossip (member_up/down
and the join-time member view) is believed only from a peer whose
certificate carries the gossip flag (its own liveness and load are
always taken — it speaks for itself); a spawn request needs the spawn
flag and that image's bit, and a refusal is a typed `denied`, not a
timeout. *Revocation* is applied where it lands (live peers below the
bar are dropped, membership updated), gossiped once to every peer (a
record already held is not re-broadcast, which bounds the flood), and
enforced at every later handshake. A compromised node is thus a
revocable identity; it returns only with a fresh key and a fresh
certificate at a serial that clears the bar. No cluster rekey exists,
because no cluster secret exists.

The check's fabric drill proves each claim from the nodes' own logs: an
imposter whose certificate comes from a different root is refused; node
3's certificate has no spawn authority and its spawn is refused on
certificate grounds; node 1 revokes node 3 mid-life, node 2 receives the
revocation by gossip and cuts its own link, and node 3's rejoin attempts
are refused at the handshake.

Threat-model honesty:
- Identity seeds are handed in by the boot driver each boot from fixed
  test material; persisting a node's seed in `state/fabric/` on the
  encrypted volume is the evolution, and nothing in the protocol cares
  where the seed comes from. The root seed in the check is likewise a
  fixed constant every node's boot driver knows — a test artifact; the
  architecture (root key only in fabroot, fabsvc never sees it) is what
  the drill exercises.
- Certificates carry no expiry: no protocol may assume a shared clock,
  so revocation serials are the only clock. Live nodes learn a
  revocation by gossip; a node that was down while one circulated learns
  it at its next join (both handshake sides hand the newcomer every
  record they hold). Records live in memory, so a whole-cluster restart
  forgets them until the root re-issues — persisting them beside the
  identity seed is part of the same `state/fabric/` evolution.
- Handshake nonces and ephemeral keys are 16/32 bytes from getrandom
  (the kernel pool seeded by the virtio-rng driver — see Entropy under
  Drivers). attach_net probes the pool and refuses the network with
  no_entropy while it is unseeded, the same fail-closed gate as a
  missing certificate; a refusal after that exits the service rather
  than handshaking with weak material.
- The plaintext-vs-sealed gate drops any peer that sends plaintext
  outside the handshake; a burned counter on a would_block ping is
  rolled back so the streams never desync.

**The promise kept (as built):** a channel across the network is a
slower channel, in both directions. An *export* is a local channel a
node has made reachable by peers under a small id — a remotely spawned
child's channel, or any channel cap a caller attached to a call or a
server attached to a reply; the other node binds a badged *session* to
(node, export) and hands out the badge as an ordinary channel cap. A
cap that crossed the wire calls back through the reverse proxy, which
the drill proves by handing a local service to a remote child. Many
exchanges are in flight per link: a forwarded call parks its caller
under the kernel's reply token, responses are matched by sequence
number, and a peer's death or a timeout fails every exchange on that
link with the error sentinel. Nobody pumps the fabric: it arms a timer
notification for its clock and a netsvc doorbell (`watch`) on every
socket, on one bound notification that interrupts its recv. Inbound
calls run on a worker pool; the serve thread alone touches peers and
the wire — workers own only their job record and ring the serve thread
when the result is in.

Lesson paid for: the first cut served inbound calls inline, and the
moment a capability crossed the wire the remote callee called back
through the fabric that was blocked calling it — a deadlock that the
timeout turned into a dropped peer. A proxy that makes blocking calls
on behalf of others needs more than one thread; that is why user
domains can create threads now.

**Identity across boots (as built):** under the system boot, init
looks for `state/fabric/identity.seed` through the root-of-trust view;
absent, the seed is born from the kernel pool and written there, the
public key is certified by fabroot and the certificate kept beside it;
present, seed and certificate are restored and fabroot is not needed
at all. fabsvc keeps the revocations it accepts in the same state (a
file of records, rewritten whole) and reloads them at boot. Re-enrolling
a node is deleting its state; the shell check boots one volume twice to
prove both paths. The archive holds only the root of trust's seed (test
material) — no node secret is handed in any more.

v0 honesty notes that remain: node id → 10.77.0.N addressing is static
(dynamic addressing is a separate concern), shm caps do not cross nodes
(by design: no cross-machine shared memory) and notifications do not
yet; the multi-node drill's nodes have no disk and take kernel-composed
test seeds.

A teardown lesson from wiring the fabric into the shell boot: an shm
cap delivered to a service is unref'd by *that service's* teardown, so
one buffer handed to two services against a single ref underflows the
refcount at the second teardown. Every service gets its own staging
buffer; and finishTeardown's bare assert became a named panic (domain,
kobj and user balances) so the next leak says who.

**Published services (as built, 2026-09-03):** `publish{service}` with
a channel cap attached makes that channel an export remembered under a
`ServiceId` (only a local holder of the fabric channel may publish; a
request from the wire arrives badged and is forwarded, never
interpreted); `lookup{node, service}` asks that node for the export
behind the id (`lookup_req`/`lookup_ack`, wire version 5) and binds a
session badge to it, handing back an ordinary channel cap — a lookup
of one's own node answers with a copy of the export. Any certified
member may look a service up: the service is the authority boundary,
by badge. The fabric drill has node 1 publish its calc service and
node 3, with no spawn authority, reach it; the session manager uses
the same path for fabric logins. A system boot is node-parameterized
now — `node: boot` in a unit takes the boot's node id (root passes it
to init in its argument's high bits) into the program's argument and
its certification, and `certify.seeds` has init dial the seeds once
certified — so the cluster units serve any node, not node 1 alone.

## Users and sessions

**As built (stage 1, 2026-09-03):** a user is not a kernel concept. The
kernel has domains, budgets and capabilities; users, sessions, settings
and logins are userspace composition of those, and every piece is a unit
with a manifest and a drill (`users` test) like everything else.

- **A user is a key.** A user record — `conf/users/<name>.msh`, an
  mshl data literal like a unit file, admin-written — holds an Ed25519
  identity's public key, a scrypt salt and cost, the identity's 32-byte
  seed **sealed** under a passphrase-derived key (AEGIS-256), and the
  session's budgets. No uid, no group, no mode bits, no password hash to
  compare: logging in is unsealing the seed and checking that the key it
  regenerates is the one on record (`lib/usercred.zig`, pure and
  host-tested). The KDF cost lives in the record, so a deployment picks
  its own; the drill uses ln 11 (2 MiB) so the custodian's domain stays
  small, and the custodian refuses a record whose cost it cannot pay.
- **A session is a domain tree.** `usersvc` (`user/users.zig` role 1)
  is the session manager and key custodian: it holds a view of the
  records (ro), the `home/` tier (rw), the system settings layer (ro)
  and spawn authority. `SessReq.login` (name and passphrase through the
  client's attached buffer, wiped after use) authenticates and spawns a
  session under the record's budgets — kobj, user memory, CPU share —
  handed exactly two capabilities: a rw view of `home/<name>` and the
  settings view. The unlocked identity stays in the manager for the
  session's lifetime (custody: the session never sees its seed) and is
  wiped on `wait`/`logout`, which destroy the domain — total, transitive
  teardown is the whole logout. Every refusal (unknown user, wrong
  passphrase, unparsable record) is one answer after a pause.
- **Storage is isolated by view, and by key.** `home/` is a hierarchy
  tier (fssvc creates it on format and upgrades older volumes), and
  each user's home is **its own encrypted mossfs volume** kept in one
  file there, `home/<name>/vol`. The volume's key is derived from the
  unlocked identity (HKDF over the seed, `usercred.homeKey`), so the
  same identity always opens the same volume and nothing else can. At
  login the manager spawns a **home filesystem service** for the
  session — `user/fs.zig` role 4, the same service over a file-backed
  block device (one view read or write per sector run; past the file's
  end reads as zeros, so a fresh file is a blank disk) — stages the key
  to it as a secret, and hands the session a view of that service's
  root. The system volume only ever holds ciphertext; the plaintext
  exists in one domain, spawned for the session and destroyed with it.
  A home volume has the lifecycle tiers at the user's radius (`conf/`
  is the user settings layer, `img/` the user's own program store), and
  its root is the user's to shape. A session's filesystem *is* that view:
  the other homes, the credential store and the system settings are
  unnameable from inside it, not forbidden (`..` is `bad_path`,
  `conf/users/...` is `not_found`). Logout is a durability barrier —
  the manager syncs the volume before destroying its service — and
  sharing between users, when it arrives, is a derived view handed
  over: delegation, not ACLs.
- **Settings are data in layers.** The system layer is
  `conf/<svc>.msh` (here `conf/app/editor.msh`), the user layer
  `home/<user>/conf/<svc>.msh`; a program merges the two for its own
  keys with `lib/settings.zig`, and its schema says which keys are
  **locked** — a locked key keeps the system value whatever the user
  layer says, so a setting a user may not change is not overridable
  rather than merely discouraged. Both layers are mshl read by the same
  strict parser as unit files and user records: one syntax for config,
  shell and (later) automation. No settings daemon.
- **No root.** Administrative authority is holding the caps: the
  records view and the home tier are `usersvc`'s; `apply` writes
  records through a rw view of `conf/`. There is no setuid, no sudo,
  and no ambient home directory.

**The desired state (as built, 2026-09-03):** `conf/system.msh` — the
archive's copy as the default, the volume's taking precedence — lists
the users (name, a bootstrap passphrase, budgets, the seal's kdf cost)
and the system settings layer; `apply` (users role 2) makes the volume
match it idempotently: a user with a record is kept as is (the
passphrase is used only to create a record that does not exist), a
settings file is rewritten only when it differs, and every action is a
row of the table it returns. It is the first step of the users and
login profiles and a program the shell runs (`run apply`): a unit file
saying `run: true` becomes a manifest in the store under the unit's
name, and `run` honors a manifest's `arg` and a `bootfs` grant. A
fresh disk boots to a multi-user system with no manual step.

The drill (`profile=users`): `apply` creates alice's and bob's records
from the archive's desired state (seeds and salts from the kernel
pool) and the system settings file; the driver then has the wrong passphrase and an unknown user
refused, opens both sessions at once, waits for each to exit clean, and
through its own read-only view of `home/` finds each home to be one
file — the volume — in which the session's plaintext appears nowhere.
Each session proved from inside that nothing above its home is nameable
and computed its effective settings: theme from the user layer, tab
width from the system, telemetry locked. Alice logs in again and her
session finds its earlier work: the volume reopened with the key her
login derived. A further session is logged out early. The leak bar
holds after all of it.

Lessons paid for (home volumes): fssvc refuses to create top-level
entries because a volume root's children are the hierarchy — and every
home session died at its first `mkdir` until that rule was scoped to
the system volume. And a file written through msh and left unsynced was
gone on the next login: the manager had destroyed the home service
before its last transaction group committed. Crash-only holds — nothing
was damaged — but a logout is not a crash, so it syncs first.

Lessons paid for: the drill first died at exit 210 — `createShm` had
no free slot. The kernel's shared-buffer pool was 16 objects, and a
filesystem view's buffer stays pinned by fssvc's mapping after its
client domain dies, so two users' worth of views drained it (pool now
64; since then a view's death is reported to the service — see
"Client identities" under IPC — and it unmaps the buffer, so sessions
may come and go without bound). And a
program's static KDF work area is BSS mapped at spawn, so it sizes
every role's domain — budgets in unit files and records must include
it.

**Console login (as built, 2026-09-03):** the `login` boot profile
puts a login prompt on every console. A seat is a virtio-console
device — two `virtio-serial-pci` devices are two seats; the boot setup
files several devices of one kind in arrival order and a unit picks one
with `index:` (`cons1` is the console driver on device 1), and a program
can be handed several caps of one tag the same way (`{ tag: console,
unit: cons1, index: 1 }`). `usersvc` runs one thread per console:
prompt, passphrase (never echoed), then the same `authenticate` the
protocol uses, under one lock — the KDF work area and the session table
are shared. A session opened at a console is **an init instance** (mode
3): the manager spawns `init` under the record's budgets with spawn
authority and the archive, and hands it the console, the home view and
the settings view over the boot channel. That init loads its units from
`conf/units/` in the home — the user's own topology — or, when there
are none, the archive's `conf/session/` template (msh on the session's
console with the home as its whole filesystem and the session's own
init for service control); views it gives derive from the home, and
`{ tag: X, session: true }` hands a unit one of the session's own caps.
Node init, session init and fabric placement are one orchestrator at
three radii, as the orchestration decision says. The user's `exit` ends
msh, the essential unit, so init shuts the session down; the manager
sees the domain die, wipes the key, rebinds its console buffer and
prompts again — the seat is free. msh's fabric is optional now (a
session has none). **Programs in a session (2026-09-03):** msh consults
two stores — its own, `img/` in the filesystem it holds (the home's,
empty until the user fills it), then the system's, a read-only view of
the system `img/` the manager hands every session as the `store` cap —
and `install NAME` copies a program from the system store into the
user's own, image verified against its digest, after which `run` finds
the user's copy first. Manifests travel with images (`img/<name>.msh`),
so `run` no longer needs `boot/` in its view. The `login` drill drives both consoles over
TCP: a refused passphrase, alice and bob in at once, each home the
whole filesystem (`..` is an error, the other's files unnameable), both
shells visible from either, alice out and back in to find her file,
then both out; the manager's drill flag ends the boot when every seat
has had a session and none is open.

Lessons paid for: `after:` steps started regardless of profile — the
users drill's driver came up under the login profile the moment the
admin step finished, and its exit shut the system down. A step now
starts only under a profile it lists, which every drill unit states
explicitly. The console device keeps DMAing into its posted receive
buffers after its driver's domain is revoked at shutdown; the SMMU
refuses each write (`C_BAD_STE`) and the log shows the refusals — the
design working, not a fault to chase.

**Sharing (as built, 2026-09-03):** a session derives a view of a path
in its home — `derive` now answers with the view's badge as well as the
cap — and offers it under a name to one user over its own badged
channel to the manager (minted at spawn with the session's slot as the
badge: requests name their caller by badge, and a session's badge may
only share while the unbadged channel the drills hold may open and end
sessions). The manager keeps the cap in an offer table until the
target's session accepts, when the cap crosses to it and the manager
drops its copy; msh mounts it as `@name` and routes any `@`-prefixed
path to that view. `unshare` revokes the view at the source through
the owner's root view (`FsReq.revoke`, allowed from the root or the
view that derived the badge): the service marks the slot revoked, so
every call fails whoever holds a copy, and reuses it only once
client_dead says the last cap is gone — a stale cap can never alias
the next view minted there. Offers live while the owner's session
does. Lesson paid for: the manager used to hand each session a *copy*
of its own settings-layer and store views — the same badge, hence the
same one attached buffer on the service, so a second session's attach
replaced the first's and a dead session's buffer lingered until the
manager died. A view handed to a session is derived for that session.

**Fabric logins (as built, 2026-09-03):** a record is safe to copy —
a public key and a seed sealed under the passphrase — so the same
identity can log in on any node. A session manager holding a fabric
channel publishes a badged copy of its channel to the pool under
`ServiceId.usersvc` (the badge admits exactly one request, `record`);
a login for a user with no local record asks every live member in
turn — `members`, then `lookup` for its session manager — and pulls
the record 24 bytes a chunk through the proxied channel, caches it in
`conf/users/`, and unseals it locally. The home is born on the node of
the session, keyed from the same identity; a remote home would need a
bulk transport across the wire, which the view protocol (data through
an attached buffer) does not have. The `flogin` drill: two system
boots on one segment, both with disks, node 1 applying the users and
publishing, node 2 joining through its seed and logging alice in on
its console.

What this does not do, deliberately: standing shares that survive a
logout (offers are per session, in memory), fabric logins (stage 3,
with the desired-state `apply` tool and the installer), any source of
programs but the system store (a user's own
store is filled by `install` alone), a capacity a home volume
actually enforces (it reports 8 MB; the file grows on demand within the
system volume), and MULTIPORT virtio-console (more seats on one
device) — the seat model is the same either way.

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
zero legacy. The HAL boundary was a promise until 2026-09-04, when it
became a directory; the x86_64 (UEFI-era only) port is what tests it.

### The HAL (as built, 2026-09-04)

`kernel/arch.zig` is the whole of what the generic kernel knows about
the machine: one `switch (builtin.cpu.arch)` selecting a port directory
(`kernel/arch/aarch64/`), and a list of names every port provides —
`cpu` (interrupt masking, the per-core pointer, the cycle counter,
halt), `trap` (vectors, the frame and its argument/result slots),
`thread` (the saved-register context, vector state, the switch, the
trampoline, the drop to user mode), `mmu` (kernel and user page tables,
`switchUser`, `publishTables`), `uaccess`, `intc` (line interrupts:
enable, disable, acknowledge, end, kick a core), `msi` (message
interrupts and their doorbell), `timer` (the tick source), `power`,
`smp`, `iommu`, `vm`, `platform` (what firmware says: memory, the
PCIe host, the boot arguments; `initInterrupts`, `initIommu`, the INTx
line of a slot and pin) and `console`. Only the selected port is
analyzed, so nothing of another architecture reaches a binary: the
selection is Zig's lazy analysis, not a build flag. `-Darch` picks the
target and the linker script (`kernel/arch/<arch>/linker.ld`).

The rules of the boundary: generic code imports `arch.zig` and never a
file under `arch/`; a port may call up into the generic kernel, but
only through the C-ABI entry points its assembly names
(`kmain`, `trapHandler`'s callees, `schedThreadStart`/`schedThreadRun`,
`secondaryEntry`) and the public API of the generic modules (the trap
path dispatches `syscall.dispatch`, `irq.deliver`, `timer.handleIrq`,
`sched.preemptIfNeeded`; a secondary core calls `sched.registerCpu`).
Names on the generic side are neutral — a thread carries `user_root`
and an `asid`, a domain `user_root_pa`, a lock saves an
`arch.cpu.IrqState` — and the port's names stay in the port (TTBR0,
DAIF, the GIC's SPIs and the ITS's LPIs are `arch.intc` lines and
`arch.msi` messages outside it). The devicetree parser stays a
library (`kernel/dt.zig`, host-tested); `arch/aarch64/platform.zig` is
what reads it.

What the extraction found: the boundary had been honest in spirit —
no generic module had grown a dependency the port could not answer —
but it lived in eleven files' inline assembly and three modules'
private copies of `mrs daif` / `msr daif`. The scheduler alone held
the context-switch and FP stubs, the per-core register with its EL2
special case, the user-space switch and the cycle counter; the domain
loader held the `eret`; the syscall dispatcher named x0..x8 by index in
120 places (they are frame *slots* now — the port maps a slot to a
register). Nothing changed behaviour: the gate is the proof, every
drill byte-identical in what it logs.

What a port must bring, learned from writing the interface down:
a boot entry that lands in `kmain` with the MMU on and the kernel
in its high half; a trap frame with seven argument slots and eight
result slots (the IPC syscalls return five words plus a cap, a badge
and a token); an interrupt id space with a contiguous range of line
interrupts and one of message interrupts (the generic `irq.zig` keeps
one binding table per range); a per-core tick; a cycle counter with a
constant frequency (CPU budgets are in cycles); a way for user code to
read that counter without a syscall (userspace benchmarks and timeouts
rely on it); and an IOMMU whose translation is the domain's own page
tables (the DMA-grant design assumes device address == the driver's
virtual address). The hypervisor is the one optional piece: a port
without one answers `NotHost` from `vm.create` and the drills that
need it are not built for it.

### The x86_64 port, stage 1 (as built, 2026-09-04)

`kernel/arch/x86_64/` boots the generic kernel to "boot complete" on
the boot core under KVM: Limine (base revision 5) on OVMF, the memory
map, the port's own page tables, the allocator, the scheduler's
per-core registration, thread contexts, and ACPI power-off. No
interrupts, no user mode, one core — those are the port's next stages,
and `zig build -Darch=x86_64 run` says so in its log.

Boot: the kernel is an ELF linked in the top 2 GB (`0xffffffff80000000`,
the "kernel" code model, red zone off), loaded by Limine from a FAT
volume QEMU synthesizes from a build directory (`fat:ro:` on virtio-blk
— no image tooling), with OVMF's x86_64 code flash read-only and a
scratch copy of its variable store. The requests live in
`.limine_requests` between the start and end markers the linker script
keeps in order inside `.data`; the loader fills the responses in and
lands in `_start` in long mode, paging on, interrupts off, on a stack
of its own. `_start` builds this port's coarse direct map — 1 GB pages
for the first 64 GB at `kvirt_offset` (`0xffff800000000000`, PML4 slot
256) beside the loader's kernel mapping (slot 511, copied) — moves onto
the image's stack and calls `kmain`; from then on every
`mem.physToPtr` works, as on aarch64 after its boot L1. `platform.discover`
copies what the port keeps out of the loader's memory (the map, the
command line, the RSDP, the TSC frequency, the CPU list) through the
loader's own direct map (every response pointer carries its HHDM
offset); `mmu.init` rebuilds the tables — the direct map as 2 MB pages
RW/NX, the ACPI regions 4K, the image 4K W^X from the linker symbols
and the loader's physical base — and `activate` loads CR3. The image is
not inside the direct map here, which is why the kernel's own
reservation moved from kmain into each port's `platform.reserved`.

The CPU module: RFLAGS.IF for masking, `rdgsbase`/`wrgsbase` for the
per-core pointer (CR4.FSGSBASE, with the MSR as the fallback the
hardware this port targets never takes), the TSC for cycles with the
frequency the loader measured (CPUID.15H as the fallback, a panic
without either: budgets are in cycles), HLT to idle. x2APIC is on (the
MP request asks; the loader enables it). The trap frame is the 256-stub
IDT's: registers, vector, error code, the CPU's five words; syscall
slots are fixed now — rdi, rsi, rdx, r10, r8, r9, r12, r13, the number
in rax — so the userspace stubs and the port agree before either
exists. The GDT is the port's (kernel code/data, user data/code in the
order `sysret` wants, a TSS slot per core for later). Thread contexts
are the SysV callee-saved set plus rsp with a trampoline return address
on a fresh stack; vector state is the FXSAVE area (XSAVE when userspace
gains AVX). Power-off is ACPI S5: the FADT's PM1a_CNT and the sleep type
read straight out of the DSDT's `_S5_` package (the one AML shape
firmware emits for it), no interpreter — QEMU's q35 exits on it.

Lessons paid for: a `pub const` array holding the Limine end marker was
materialized in `.rodata` *before* the real start marker in `.data`,
and the loader takes the last start and the first end marker, so the
window was empty and the base revision tag went unhonoured — the
values are spelled out at their one placement now. Zig's self-hosted
x86_64 backend assumes SSE and cannot build a soft-float, no-vector
kernel (it failed selecting `fpext` and encoding `movups`); the kernel
executable asks for LLVM. The 256 IDT stubs are one comptime string and
need a raised branch quota. `-drive=…` is not a QEMU spelling; the
file argument is a separate word.

### The x86_64 port, stage 2: interrupts and every core (as built, 2026-09-04)

The local APIC in x2APIC mode (`lapic.zig`: every register an MSR, the
loader having enabled x2APIC on every core at the MP request's asking):
the spurious vector at 0xff, the LVT lines masked, the timer in
TSC-deadline mode — one MSR write per period, the TSC the loader
measured as the clock, so the tick is `rdtsc + interval` into
IA32_TSC_DEADLINE and nothing is calibrated (on a CPU without that
mode — QEMU's TCG — the same timer in one-shot mode, its clock
calibrated against the TSC once at boot; see "under TCG" below).
End-of-interrupt is one
MSR write; an IPI is one (`intc.kick`: the resched vector 0xf1 to the
core's APIC id). Interrupt ids are vectors, so delivery needs no
translation: lines are 32 + the GSI (I/O APIC redirection entries,
programmed at `enableLine` with the MADT overrides' polarity and
trigger for ISA lines and level/low for PCI's, all to the boot core),
messages are vectors 128..223 handed out by `msi.route` (the data word
a device writes is the vector; the doorbell is the LAPIC's page with
the boot core's id in the address), the tick 0xf0. The trap handler's
one branch — vector ≥ 32 — is the interrupt path: the tick, the kick
(only there for the preempt), a bound line or message, EOI before any
context switch, `sched.preemptIfNeeded`, exactly as on aarch64.

The other cores are the loader's (`smp.zig`): Limine parks them and
releases one at a `goto_address` store. The port brings them up one at
a time — allocate a stack, publish it and the index in globals, store
the address, wait for the online count — and the trampoline loads the
kernel's CR3 and the new stack in one asm block (the loader's stack is
unmapped under our tables, and any spill between the two would fault),
then `secondaryEntry` does what the boot core did: its GDT/IDT/CR4,
`sched.registerCpu`, the local APIC, the timer, interrupts on, HLT.
The parked cores' memory is the loader's reclaimable region, which the
port keeps reserved. The scheduler drill runs on all four cores under
KVM: pins pinned, migrants migrating, the mortal reaped, in 12 seconds
of a 17-second gate.

The gate now runs the port's drills: `zig build -Darch=x86_64 check`
builds panic, fault and sched for the target and the runner (`--arch
x86_64`) composes a boot directory per drill — Limine's `BOOTX64.EFI`,
the ELF, a `limine.conf` carrying the drill's boot arguments — and
launches OVMF on it; a drill's markers differ only where the port's
fault dump does (`pass_x86`). Host tests run as always.

Lessons paid for: the IDT assumed stub `v` at `base + 16·v`, but the
label before the first stub was not itself aligned, so every gate
pointed a few bytes into the wrong stub, the frame lost a push, and
the first interrupt on every core panicked on a vector that did not
fit in 32 bits — the fix is `.balign 16` before the label, and the
lesson that a table of fixed-pitch stubs needs its base aligned as
strictly as its entries. Finding it needed a backtrace: the panic
handler now walks the frame-pointer chain and prints the return
addresses on both ports (`llvm-addr2line -f -e moss-kernel.elf` reads
them), because one address into a Debug build's cold panic blocks
names the wrong function.

### The x86_64 port, stage 3: user mode (as built, 2026-09-04)

Every core keeps a block at its GS base (`trap.CpuLocal`): the
scheduler's per-core pointer at offset 0 — `thisCpu` is `mov %gs:0`,
one instruction, no FSGSBASE needed after all — the current thread's
kernel stack top, a scratch word for the syscall entry, its TSS (rsp0
= that same kernel stack, for interrupts from ring 3) and its GDT
(kernel code and data, user data and code in the order `sysret`
derives them, the TSS). The GS base is the block in the kernel and 0
in user mode; `swapgs` at every crossing, both ways — the trap common
path tests the frame's CS for ring 3 on entry and exit, the syscall
entry and exit do it unconditionally.

`syscall` lands in `__syscall_entry` with IF, TF, DF and AC masked
(SFMASK): swap GS, stash the user rsp, take the kernel stack from the
block, and push a frame in the trap frame's shape (ss, rsp, rflags
from r11, cs, rip from rcx, a zero error code, vector 0x80, the
registers) so `syscall.dispatch` sees one shape from both ports; the
handler marks the thread in a syscall, dispatches, clears the mark and
takes the preempt-or-die safe point, exactly the aarch64 SVC path;
`sysretq` leaves. The scheduler tells the port the kernel stack of
every user thread it switches to (`arch.thread.setKernelStack`, a
no-op on aarch64 where SP_EL1 is that stack already). Entering user
mode is an `iretq` to ring 3 with IF set, the five entry arguments in
rdi, rsi, rdx, rcx, r8 so `umain` is a plain C function, and the
stack aligned as the ABI wants at a function's first instruction (16
bytes minus 8: the missing return address). A fault in ring 3 goes to
the domain's supervisor as a message — the vector and error code, the
address (CR2 for a page fault), the pc — else the domain dies, the
same two outcomes as aarch64's. SMAP is the door to user memory:
`stac`/`clac` around the copies, AC masked at every entry, and a
kernel touch outside the window is a page fault the dump names ("refused
(SMAP)"). CR4 also gains OSFXSR/OSXMMEXCPT (SSE in user mode), SMEP,
PGE (kernel pages survive CR3 loads); CR0.EM off, MP on.

TLB shootdown is by IPI: every CR3 load flushes the non-global entries
(no PCIDs yet), so a core can only hold a user tree it is running at
that moment — `switchUser` records it — and `unmapUserPages` sends the
flush vector to exactly those cores and waits for their acks before
the caller frees a frame; senders serialize on a lock so the acks are
theirs. Tearing a tree down needs none: by then no core runs it.

Userspace's seam is `user/usys.zig`: the syscall instruction and its
slots by port (`syscall` with rax the number, rcx and r11 the
instruction's own; the results come back in the argument slots, slot 0
the errno on both), the cycle counter (`rdtsc`; its rate from a new
ungated syscall, `cycle_hz`, cached — the TSC's rate is the loader's
measurement, not a register), the barrier drivers use around virtio
rings (`mfence`), and the image header stanza every program now takes
from `usys.imageHeader("name")` instead of carrying its own copy. The
IPC drill's vector-state probe has an x86 body (the sixteen xmm
registers) and passes: FXSAVE at the switch keeps them.

Lessons paid for: `.word` is 4 bytes on ARM and 2 on x86, so the
shared header stanza put every field off by two — every image was
BadImage until the field became `.4byte`. The syscall dispatcher read
its number as "slot 8", which is x8 on aarch64 and nothing on x86;
the frame has a `syscallNumber` now. And the one that took the frame
dump: user threads came back from their first sleep to a #GP with
error code 0x18 at the kernel's own `iretq` — the return frame's SS
was 0x18 with ring 0 bits, where the thread had left through
`sysretq`. Intel's SYSRET ORs the RPL into the SS selector it derives
from STAR; AMD's does not; the base in STAR carries RPL 3 already
(0x13, as Linux does), so CS is 0x23 and SS 0x1b on either. The fault
report prints the words at the faulting stack pointer now, because
a refused return names itself there.

### The x86_64 port, stage 4: PCIe (as built, 2026-09-04)

The PCIe host comes from ACPI: the ECAM base and bus range from the
MCFG, the window BARs may be placed in from the host bridge's
resources in the DSDT — the largest 32-bit DWordMemory descriptor above
the first megabyte, read as bytes (type 0x87, length, resource type,
min, max, length), no interpreter, as the S5 package is — and INTx
lines by the conventional slot swizzle onto GSIs 16..23, which nothing
uses: the enumerator programs MSI-X. The one addition the enumerator
needed is the data word: an ITS takes an event id (0) where the local
APIC takes the vector, so `device_register` answers a fourth word,
`arch.msi.data(intid)`, and pcisvc writes it into the MSI-X entry
beside the doorbell address. Nothing else changed: the kernel's device
table, the window capabilities, `dma_alloc` (device address = physical
address without an IOMMU, as the aarch64 port without its SMMU), the
virtio drivers, the filesystem, the network stack, the fabric — every
drill that needs a device passed the first time it ran: rng, blk, fs
and net, then shell, users, login, the three-node fabric and the
fabric login. The x86_64 gate is nineteen drills, everything but the
aarch64 hypervisor's three and the SMMU's, in three minutes under KVM.

The runner routes every drill's boot arguments through the port-aware
base builder (the loader's config carries them on x86_64, `-append` on
aarch64) and labels each node of a multi-node drill, since each gets
its own boot directory and variable store.

### The x86_64 port, stage 5: the IOMMU (as built, 2026-09-04)

VT-d in scalable mode with first-stage translation (`vtd.zig`): the
IOMMU walks the page tables of the domain that holds a device's
capability — the very PML4 the CPU uses — so device address == the
driver's virtual address, as the SMMU gives the aarch64 port. First-
stage walks require the user bit, so the kernel half is out of a
device's reach by construction, and a page the driver was not given
is "not present" to the device as to the driver. The structures: a
root table whose bus-0 entry names one scalable-mode context table,
one PASID directory and one PASID table shared by every device —
device table index `i` takes PASID `i + 1` as its RID_PASID, so the
PASID entry *is* the binding (first-stage, DID = the domain's ASID,
FLPTPTR = the domain's root) and an unbound slot resolves to a
non-present entry. Attach fills the PASID entry then the context entry
and invalidates (context cache by device, PASID cache and PASID-IOTLB
by PASID) through the invalidation queue — scalable mode allows no
register-based invalidation — with a wait descriptor whose status word
the kernel polls; detach clears both and invalidates the same way;
`invalidateAsid` is a domain-selective IOTLB invalidation. Faults land
in the one recording register and raise an MSI whose vector the port
allocates like a device's; the handler reads the record (the page
address, the source id, the reason), releases it and counts, the
same statistics the smmu drill reads on either port. Devices' MSI
writes never meet the translation: QEMU (as the architecture) routes
the interrupt address range to the interrupt path, so no doorbell
mapping matters here. The IOMMU comes from the DMAR's first DRHD;
QEMU is asked for `intel-iommu,x-scalable-mode=on,x-flts=on`, placed
before the devices it fronts. Every drill runs through it — the
whole gate, twenty now, with the smmu drill's rogue refused on its
write to a kernel page and every honest DMA translated.

Lessons paid for: the drill handed the rogue a "kernel physical
address" computed as `mem.virtToPhys` of an image variable, which on
this port (the image outside the direct map) produced a user-half
address that VT-d refused as non-canonical — the right answer for the
wrong reason. `mem.virtToPhys` is image-aware now, through a new HAL
name, `arch.imagePhys`, and the rogue targets the canary's real page.
And a reason code with no name in the table is worth a second look:
0x80 was the clue.

### The x86_64 port, stage 6a: the hypervisor's core (as built, 2026-09-04)

AMD-V (`svm.zig`), the counterpart of the EL2 host: a VMCB per vCPU,
nested paging (the NPT is an x86 table with the user bit — what nested
walks are, and what VT-d's first stage can walk too, so a passed-through
device's DMA will reach guest memory by the same tables), and every
way out of the guest intercepted: host interrupts, CPUID, HLT, port
I/O, MSRs, the hypercall (`vmmcall`), the SVM instructions themselves,
shutdown; a nested-paging fault on memory the VM was not given is the
VMM's MMIO exit. The core's own state is what the architecture saves
for the host (`VM_HSAVE_PA`) plus a `vmsave` of its segment state at
`trap.init`, reloaded after every exit; the entry stub keeps the host's
callee-saved registers in the vCPU and moves the fourteen guest
registers the VMCB does not carry. Around a run: the VMM thread's
vector state saved and the guest's restored (FXSAVE, as at a switch),
`clgi`/`stgi`, and the host interrupt that ended a run taken on the
spot (`sti; nop; cli`) so a tick preempts the VMM's thread as it would
anyone's. The guest's local APIC is emulated here through its x2APIC
MSRs — the vGIC's role: ID, SVR, TPR, EOI, the LVTs, the ICR (an IPI
pends the vector on the target vCPU) and IA32_TSC_DEADLINE; a
deadline is watched at the host's tick and the timer's vector pended
when it passes, so the guest's tick is coarse — a hundred
milliseconds, the host's period — which is what the aarch64 port's
descheduled vCPU gets too. Delivery is the VMCB's virtual-interrupt
request (V_IRQ with the vector, V_IGN_TPR): the CPU takes it when the
guest's IF allows and clears the request, and the next pending vector
goes in at the next entry. CPUID is the host's with the vCPU's id,
x2APIC and TSC-deadline present, MONITOR and SVM absent.

What the guest sees at entry is the loader's state a moss kernel
expects: long mode, paging on, flat 64-bit segments (CS 0x28, data
0x30), PAE and SSE enabled in CR4, EFER with SVME forced (VMRUN
requires it; a read of EFER hides it). `vm_set` grew two words for
this port — the guest's page tables and its stack, since a 64-bit
guest cannot take its first instruction without either — and the VMM
builds the bare guest's identity map (2 MB pages at the top of its
RAM) before entering it. Port I/O is a new pair of exit kinds
(`pio_read`/`pio_write`); the VMM answers the serial port's data
register as the console, its line-status register as always ready,
and the ACPI PM1a control register with SLP_EN as the power-off. The
bare-metal guest for this port (`guest/hello_x86.zig`) is the aarch64
one's twin: its own GDT and one IDT gate, x2APIC on through the MSRs,
a TSC-deadline tick, three ticks over the serial port, `vmmcall` with
the PSCI power-off id the VMM already answers. The vm drill passes
under nested KVM.

Lessons paid for: the VMCB's 64-bit intercept word sits at offset 12,
unaligned — an `extern struct` field padded it to 16 and the comptime
offset asserts caught it before hardware did. And VINTR is not an
intercept to hold: it fires the moment the guest can take the virtual
interrupt, before delivery, so a handler that merely re-enters spins
forever (ten million entries, one tick) — the request delivers by
itself, and V_IRQ clearing is how the hypervisor learns it did.

### The x86_64 port, stage 6b: the moss kernel as a guest, passthrough (as built, 2026-09-04)

The VMM is the guest's loader, as on aarch64 — but there the guest
kernel is an Image with a devicetree, and here it is the Limine
protocol (`user/vmm.zig`, `loadMossGuestX86`). The VMM copies the
ELF's segments into guest RAM at their link address, builds the guest's
first page tables (the image, and the higher-half direct map at the
same offset the real loader uses), scans the image for the protocol's
request markers, and answers each request the kernel makes: the memory
map (usable RAM, and the image, tables, ACPI and stacks as loader
reservations), the HHDM offset, the executable's addresses, the command
line (the drill's boot arguments, as on aarch64), the RSDP, the TSC
frequency (the host's, since the TSC is not scaled), the bootloader's
name, and the MP response. ACPI is synthesized, the same tables the
port reads on hardware: an RSDP and XSDT, a FADT with the PM1a control
port the VMM already answers as power-off and a DSDT carrying `_S5_`
and the host bridge's memory window, a MADT with the vCPUs' local
APICs and no I/O APIC, and an MCFG placing the emulated ECAM. The MP
response parks the secondary vCPUs the way the loader parks cores:
one VMM thread per AP polls its `goto_address`, and when the kernel
writes it the thread sets the vCPU's entry, page tables and stack
(`vm_set`) and brings it online (`vm_cpu_on`) — the same PSCI
mechanics the aarch64 VMM answers by hypercall, driven by memory here.
The guest kernel boots as it does on hardware, four cores up, and the
entry it hands its stack is a higher-half address: the first attempt
passed the guest-physical one and triple-faulted at its first push.

Nested-paging faults are instructions to finish. The decoder in
`svm.zig` takes the instruction's bytes from the exit when the CPU
provides them and otherwise fetches them through the guest's own page
tables (nested KVM offers no decode assist), and knows what a driver
compiles to: moves in both directions and from an immediate, the zero-
and sign-extending loads, `test` and `cmp` against memory, and the
ALU read-modify-writes (`or`, `and`, `add`, `sub`, `xor` on a memory
operand). The address is the fault's, so only the width and the other
operand are decoded. A read completes at the next `vm_run` with the
VMM's value: into the register, or through the ALU into RFLAGS — and a
read-modify-write yields its write as the very next exit, before the
guest runs again, so the two halves are one instruction to the guest.
The first form the drill demanded was not a move: LLVM folded
`pcisvc`'s volatile load of the header-type byte into `testb
$0x7f,(%rax)`, and a decoder that stopped at `mov` reported it as
undecodable. The undecodable ones are logged with their bytes — the
way the decoder learns the next form.

Passthrough is the stage-5 machinery pointed at the guest: the NPT is
the device's first-stage table in VT-d (`attachStage2`, domain id
`0x800 | vm`), so a device the VMM hands over addresses guest-physical
memory directly, and the device's interrupt — its MSI-X vector on the
host, programmed by the host's enumerator — is bound to the VM and
delivered as the vector the guest expects for the slot's INTx line,
48 plus the platform's swizzle. The guest has no I/O APIC: the MADT
does not name one, its line enables and masks are no-ops, and the
injected vector is the line. Masking is the host's business, and the
host's line is a message, so there is nothing to re-enable; interrupt
remapping is not needed for this. The guest's enumerator sees the
device's real configuration space with virtual BARs (sized from the
real one, placed by the guest) and no BAR for the MSI-X table, so it
falls back to INTx — which exposed a mismatch that had been harmless
on the host: `pci.register` routed a message interrupt for every
device on x86_64, because the local APIC routes them for any device
where aarch64 needs an ITS, and the kernel's idea of the device's
interrupt (vector 128) parted from the enumerator's (INTx). The
guest's rngd waited on 128 while the host injected 49. The fix is a
word from the enumerator: `device_register` carries an `msix` bit,
and a message interrupt is routed only when the enumerator can reach
the MSI-X table; a device without one keeps its INTx line, on both
architectures. The second bug was VT-d's: the PASID entry's address
width describes the second-stage table, which first-stage translation
never walks, so it was left zero — and QEMU derives its "is this DMA
address canonical" limit from that field for first-stage too. Zero
means 30 bits; every DMA above 1 GB, which is where guest RAM begins,
was refused as non-canonical (fault 0x80) while the smmu drill, whose
buffers sit lower, passed. The port sets it to 48 bits.

Two more lessons from the run loop. A `vmrun` with the host's
interrupts disabled never sees the INTR intercept fire, since the
core does not take the interrupt that would cause the exit: the BSP,
spinning for its APs, ran on forever with the VMM's poller threads
never scheduled. The entry stub now runs the guest under `clgi; sti`
and returns through `cli; stgi`, so a host interrupt ends the run and
is taken as soon as GIF is set again. And an instruction the decoder
finished must advance `rip` by the bytes it decoded, not the bytes it
fetched — the fetch takes fifteen.

The guest drill (the moss kernel with four vCPUs, its own PCIe and
ACPI, powering itself off through the PM1a port) and the vmnode drill
(a NIC and an entropy device passed through, the guest joining the
fabric as node 2 and serving a remote spawn) pass under nested KVM;
the port's gate is all twenty-three drills — and, since the day
after, the six `+rs` rows as well: the ReleaseSafe kernel passed them
on the port unchanged, so both gates are the same twenty-nine rows.
Still owed: AMD-Vi for the machines that have it, PCIDs, and an I/O
APIC and MSI-X for guests when a guest needs more than a line per
device.

### The framebuffer console (as built, 2026-09-04)

A real machine has a screen where QEMU has a serial port, so the log
is drawn as well as sent: `kernel/fbcon.zig`, generic, fed by the
port's console `write` after the serial bytes go out. The port's
platform reports the framebuffer firmware left (`Info.framebuffer`:
Limine's response on x86_64 — the GOP mode, 1280x800x32 under OVMF
with QEMU's standard VGA; aarch64's devicetree boot brings none and
the field stays null), and the port's mmu maps it: write-combining on
x86_64, which is PAT entry 1 — `trap.init` reprograms IA32_PAT on
every core so that PWT alone means WC, the other seven entries at
their reset values — so stores stream and a screenful costs a memcpy,
where an uncached mapping would make each scroll a visible pause. The
console attaches right after the kernel's tables are live; the lines
before that reach the serial port only.

Character cells are the unit. The font is an 8x16 bitmap of printable
ASCII rasterized from Departure Mono, a pixel font that lands on that
grid at its native 12 px without anti-aliasing to lose (SIL Open Font
License 1.1; the notice and license sit beside it in `kernel/font/`,
`tools/mkfont.py` regenerates it); three candidates were rendered and
looked at before choosing. A shadow of the text (rows by columns of
bytes) is what a scroll redraws the whole screen from — no reads of
the framebuffer, which through a WC mapping are uncached and slow, and
no second pixel buffer to size to the mode. The log is UTF-8 and the
font is ASCII, so a multibyte sequence is gathered and drawn as one
stand-in — a hyphen for the dashes, an angle bracket for an arrow,
`?` for the rest — after the first screenshot showed the em dash in
the PCIe line as three question marks. Writes take a spinlock with
IRQs masked and a bounded spin: a core that panics while another holds
the lock drops its line on the screen rather than hanging, since the
serial port already has it.

Verification was by looking: QEMU's monitor `screendump` of the panic
drill (the boot log and the panic, legible) and of the sched drill
mid-run (a scrolled screenful, every row where it should be). The
gate cannot look, so the panic drill asserts the console's attach line
on x86_64 and the rest is the eye's, as it should be for a console.

The gate found what the eye could not. With the console on, the users,
login and fabric drills stalled for a minute at a time while the
kernel-only drills kept their times, and counters in the console put
the minute inside its own writes: a scroll that cost 2.6 ms at attach
cost five seconds later — five microseconds a store, the price of a
store that leaves the VM. The framebuffer had moved. `pcisvc`, the
user-space enumerator, assigned every BAR from the window's base as it
does on the devicetree machine where firmware assigns none; on UEFI
firmware had assigned them all, the display's among them, and the
kernel went on drawing at the address the loader gave it while QEMU
had re-homed the memory behind the BAR. Every store went to nothing,
slowly. The kernel-only drills never start `pcisvc`, which is why the
screenshots were fine. `pcisvc` now keeps a firmware placement that
lies inside the window and allocates only for BARs firmware left empty
— the right rule on both machines, and the console's attach line now
prints the address so the next move shows. Under TCG the console is
the gate's single largest cost: a scroll is a million emulated stores,
and the x86_64 gate there went from about four minutes to under six;
under KVM it is unchanged.

### The x86_64 port: the loader's requests lead the image (2026-09-05)

A merge that added two programs and five configuration files to the
boot archive stopped every x86_64 drill at the first line of the
kernel: "the loader does not speak Limine base revision 5". Nothing
in the merge touched the boot. What had moved was the archive's
layout. Limine finds the protocol's markers by scanning the loaded
image from its base in 8-byte steps, resetting at a start marker and
stopping at the first end marker it meets — and the host kernel's
archive carries the guest kernel, an ELF with markers of its own,
inside `.rodata`, ahead of the real requests in `.data`. Those copies
had been skipped only because the archive happened to leave them at
addresses no 8-byte step lands on; the new files shifted the archive
by a few bytes, a copy came into step, and the loader answered the
guest kernel's requests inside the blob and left the host's untouched.
The requests now come first: their own section and load segment at
the image base, mapped read-only once the kernel's tables are up (the
loader wrote its answers before the kernel ran; the kernel only reads
them), so the scan ends at the real end marker before it reaches
anything that resembles one. The lesson generalizes: an image that
embeds another image of the same kind must not let the embedded copy
be found first by a scanner that stops at the first match.

### The x86_64 port under TCG (as built, 2026-09-04)

The port grew up under KVM, and the first boot under QEMU's own
emulation (`-Dtcg`, the runner's `--tcg`: no `-accel kvm`) panicked at
the timer — TCG's `max` CPU has no TSC-deadline mode, nor PCIDs, nor
next-RIP save in its SVM, three things every real x86 of the last
decade has. TCG matters because it is the only way the x86_64 gate
runs on the Apple-silicon machine the project grew up on, and because
`-cpu max` there is the CPU model with the most features QEMU can
offer at all. So the port does without those three where it must. The
tick falls back to the local APIC timer in one-shot mode: the APIC's
clock is calibrated against the TSC over 20 ms once, on the boot core
(`lapic.calibrateTimer`; QEMU's runs at 1 GHz), and every tick is one
write of the initial-count register instead of the deadline MSR — the
same vector, the same handler, `lapic.tsc_deadline` deciding at
`initCore`. The hypervisor no longer requires next-RIP save: the exits
whose instruction has a fixed length (CPUID and RDMSR/WRMSR two bytes,
HLT one, VMMCALL three — compilers prefix none of them) are stepped by
hand when the VMCB does not say (`nextRip`), and port I/O carries its
own next RIP in EXITINFO2 either way. Nested paging and VGIF TCG has,
and with those the three hypervisor drills pass under emulation — the
moss guest and its passed-through devices included. All twenty-nine
rows pass under TCG on the Framework; the KVM gate is the fast one, and
what the box runs by default. PCIDs are the third absence, and the
reason they are still owed: this host's Linux hides PCID from KVM
guests as well (INVPCID shows, PCID does not), so no machine to hand
can exercise a tagged TLB, and an unverified TLB-tagging scheme is not
one to ship. The design is written down in ROADMAP for the day a host
can test it.

Boot contract (Phase 0): the bootable artifact is a raw arm64 Image (Linux
boot protocol) objcopy'd from the kernel ELF, which is kept for symbols and
debugging. The 64-byte Image header in `kernel/arch/aarch64/boot.zig` requests loading at
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

**EL2 host (as built, 2026-09-02).** Entered at EL2 (`virtualization=on`),
the boot assembly first makes the core a VHE host — `HCR_EL2.E2H|TGE|RW`,
`ICC_SRE_EL2` — and nothing else changes: under E2H every EL1-named
system register the kernel writes (SCTLR, TCR, TTBRx, MAIR, VBAR, ELR,
SPSR, ESR, FAR, CPACR, CNTKCTL, CNTP_*) names its EL2 counterpart, the
`*E1` TLB invalidations apply to the EL2&0 regime, EL0 traps straight
to EL2 under TGE, and `eret` to EL0 works as before. Two things are
decided at run time: the PSCI conduit (HVC at EL1, SMC as the host — an
HVC would trap to ourselves; the SMC is spelled as an encoding because
the assembler wants an EL3 target) and the tick's line (CNTP at EL1 is
PPI 30; the same CNTP names reach the hypervisor physical timer at EL2,
PPI 26). Secondaries arrive at EL2 too and take the same path. Entered
at EL1 the kernel runs there unchanged; the whole check runs as the EL2
host under TCG (`-cpu cortex-a76`, which has VHE — the A72 does not).

HVF cannot host it: Apple's nested virtualization exposes an EL2
without VHE (ID_AA64MMFR1.VH = 0; the E2H bit reads back clear), and a
high-half kernel has no TTBR1 at a non-VHE EL2. `run-hvf` therefore
boots at EL1 as before; guests are a TCG-only affair until real
hardware. The move to a v8.2 CPU model also brought PAN; it is on (see
"Kernel model" and `kernel/arch/aarch64/uaccess.zig`).

## Virtual machines

**As built (2026-09-02, first cut).** `kernel/arch/aarch64/vm.zig` runs an EL1 guest
in its own stage-2 world; a userspace VMM owns it through the
**hypervisor capability**. `vm_create(hyp, pages)` allocates contiguous
frames (charged to the VMM's user account), builds a stage-2 table
(39-bit IPA, three levels, 4K pages, charged to its kernel-object
account) mapping them at IPA 0x40000000, and maps the same frames into
the VMM (unowned) so it can load the guest; `vm_set` names the entry
point; `vm_run` runs until an exit and reports it in x1..x5. A `vm` cap
is the object; dropping the last one (or teardown) waits for a run in
flight, invalidates the VMID's TLB entries, and returns tables and RAM.

Entering a guest is what VHE makes cheap: the guest's EL1 state goes in
through the `_EL12`/`_EL02` names (registers the host never uses for
itself), VTTBR_EL2 points at the VM's tables, the vGIC list registers
carry whatever is pending, HCR_EL2 drops TGE and raises VM (plus
IMO/FMO/AMO, DC so stage-1-off memory is still cacheable, TWI, TSC), and
an `eret` to EL1h lands in the guest. The host's callee-saved registers
are parked in the vCPU first. Every exception the guest raises arrives
at the host's ordinary vector table as "from a lower EL": the trap
handler sees the core's `vcpu` pointer set and hands the frame to
`vm.guestExit`, which restores the host's HCR before anything else,
saves the guest (GPRs from the frame, EL1 registers, ICH state), decides
the exit — a stage-2 data abort becomes `mmio_read`/`mmio_write` with
the decoded size, register and IPA (HPFAR + FAR); WFI, HVC, a trapped
SMC (the little PSCI we speak: VERSION answered in place, SYSTEM_OFF an
exit); a host interrupt is handled right there (`trap.handleIrq`,
scheduler and all, on the VMM thread's kernel stack) and reported as
`interrupted` — and then **rewrites the frame** so the trap's own `eret`
returns into `__guest_resume` at EL2h, which restores the parked host
context and returns from `__guest_enter`. A pending MMIO read completes
on the next `vm_run`, whose argument is the value.

The guest's clock is the virtual timer: CNTVOFF 0, CNTV_* live in the
EL1 registers, and its interrupt (PPI 27) fires physically at the host,
which masks the timer (IMASK) so the line drops and marks the vCPU;
the next entry puts a pending virtual PPI 27 into a free ICH_LR, and
the guest's ICC accesses — virtual under IMO — take it from there. No
distributor is emulated: list-register injection needs none, and a
guest that only uses the CPU interface (ours) never touches GICD/GICR.
The vector unit is saved around a run; the host's per-core pointer moved
to TPIDR_EL2 because TPIDR_EL1 is the one register VHE does not redirect
and a guest owns it — found the first time a guest exited with the
host's pointer nulled.

The drill: `user/vmm.zig` takes the hypervisor cap and the boot archive,
builds an 8M VM, copies `img/guest-hello` (`guest/hello.zig`: a
bare-metal EL1 program with its own vectors, linked at the RAM base,
raw binary) into it and runs the loop: UART stores (IPA 0x09000000)
become `guest>` log lines, WFI sleeps a tick, PSCI power-off ends it.
The guest says hello, counts three ticks, powers off; the VMM exits 0
only then.

**A moss kernel as a guest (as built, 2026-09-02).** The VMM's second
mode loads `img/moss-guest` — the same kernel, built to boot the
`guest` profile from its own archive (which lacks only the guest kernel
itself), packed into the host's archive — by the Linux Image protocol at
RAM+0x80000, writes it a flattened devicetree (memory, `chosen`
bootargs, PSCI with `method = "hvc"`, and for a pool node the PCIe host
below), and emulates what a kernel boot touches: a PL011 whose data
register becomes `guest|` log lines, and the GICv3 distributor and one
redistributor as a plain register file (writes remembered, reads given
back, WAKER reporting the core awake) — enough for a guest that takes
its interrupts through the (virtual) CPU interface, which needs no
distributor semantics for list-register injection. PSCI over HVC is
answered in the hypervisor like the trapped SMC: VERSION, SYSTEM_OFF an
exit, CPU_ON refused with INVALID_PARAMETERS so the guest's SMP
bring-up stops at one core without complaint. The EL1 kernel ticks on
the virtual timer (PPI 27) precisely so that a hypervisor can hand it
the real one; a vCPU idling in WFI sleeps in the kernel on a per-VM
notification that timer fires and device interrupts signal (`vm.run`
loops; the VMM never sees the idle).

**Device passthrough and the pool node (as built, 2026-09-02).** The
VMM's third mode is handed devices over its boot channel and presents
them to the guest on an emulated PCIe bus (ECAM at IPA 0x3f000000, a
32-bit MMIO window, INTx base SPI 3 in the guest's devicetree): config
space reads come from the real device's config page (the cap's), the
command register is read-only, only the virtio BAR exists and it is
virtual — sized from the real one, placed by the guest — and when the
guest writes its address the VMM calls `vm_attach_device`. That maps
the BAR's pages into the guest's stage 2 (device attributes), binds
the device's SMMU stream to **stage 2** (`smmu.attachStage2`: STE
config 0b110, VTTB = the VM's tables, VMID = the VM's, S2R recording
faults), and routes the device's LPI into the guest (`irq.bindGuest`
→ `vm.injectSpi`: a pending bit, the VM's notification, an SGI to the
core running the vCPU; the next entry puts the virtual SPI in a free
list register, no duplicate while the guest holds one — a virtio driver
drains its device anyway). The guest sees wired INTx (its devicetree's
INTx rotation, the same formula its kernel uses) while the real device
keeps the host's MSI-X: the guest's transport sees the capability
enabled and points config and queues at vector 0, whose message the
host routed to an LPI. The MSI write is DMA too, so the ITS doorbell
page is in every VM's stage 2 at itself. The guest kernel's DMA
addresses are IPAs (it finds no SMMU in its devicetree), which is
exactly what stage 2 translates: a passed-through device reaches the
guest's memory and nothing else. The `vmnode` test: node 1 comes up on
the machine's first NIC and entropy device; the VMM gets the second of
each; the guest, told `node=2`, runs the same joiner path a physical
node does, joins node 1, and a remote spawn placed on it answers an
RPC. One box, two pool nodes.

Lessons, each bought by a symptom: (1) VMPIDR_EL2 must be set — a
kernel guest parks every core but affinity 0, and it read the physical
core the VMM thread landed on. (2) HCR_EL2.DC forces the guest's stage
1 off; the high-half kernel entry became an address-size fault on a
"physical" address of 0xffffff80.... (3) Masking a fired virtual timer
with IMASK needs the host to lift the mask once the guest has moved its
compare value — a kernel rearms the countdown and never rewrites the
control register — and to do it at *exit*, on the core the timer lives
on: the first cut unmasked at entry only, and the vCPU's idle wait
blocked with the timer masked, four ticks in sixty seconds. (4) SP_EL0
must be restored on entry: a guest interrupted in user code otherwise
resumes on the VMM's user stack — two services died at PC 0 at once,
and a struct copied by value lost a field. (5) The guest's vector
registers are per-vCPU state; the VMM's own NEON between runs clobbered
them mid-memcpy. (6) QEMU's virtio completes a request synchronously
with the kick, so a passthrough can *seem* to work with no interrupt
path at all; the LPI-to-SPI injection was proven only by a driver that
waited.

**Several vCPUs (as built, 2026-09-02).** A VM has up to four vCPUs,
each a `Vcpu` with its own registers, EL1 state, vGIC state (VMCR,
AP1R0, list registers), pending timer/SGI/SPI bits, notification for
its idle wait, and vector registers; `vm_run` names the vCPU. vCPU 0
runs first. PSCI CPU_ON from the guest resets the target vCPU with the
requested entry and context in x0, marks it online, answers SUCCESS to
the caller and hands the caller a `cpu_on` exit — the VMM starts a
thread that runs `vm_run` for the new vCPU (the guest's own SMP
bring-up then sees it check in, exactly as a physical secondary does:
same `_secondary_start`, same devicetree-less loop until CPU_ON says
INVALID_PARAMETERS). Each vCPU reads its index as MPIDR Aff0
(VMPIDR_EL2). SGIs: the virtual CPU interface has no SGI generation,
so a guest write to ICC_SGI1R_EL1 traps (EC 0x18); the hypervisor
decodes the target list (bit i = Aff0 i, IRM = all but self), pends the
SGI on each targeted vCPU, wakes an idle one and kicks a running one
with a host SGI, and the next entry fills a list register. Device SPIs
go to vCPU 0, as a moss guest routes them. The redistributor shadow in
the VMM is per vCPU. One thing the second core exposed: a vCPU's
virtual timer lives in whichever core's CNTV registers it was last
loaded into, and another vCPU may take that core, so the timekeeper's
tick watches every descheduled vCPU's deadline and pends its timer
when it passes. Another: CNTHCTL_EL2 as written for the host's own
EL0 (E2H layout bits 0,1) does not let a *guest's* EL1/EL0 read the
physical counter; EL1PCTEN (bit 10) does, and a user program's
`cycles()` inside the guest was the first to trap. Both VM drills
boot the moss guest on four cores; the pool node got faster for it.
Guests run under TCG only: HVF's nested EL2 has no VHE.

**PSCI is the VMM's (as built, 2026-09-02).** A guest's firmware
interface — on this architecture PSCI: VERSION, CPU_ON, SYSTEM_OFF —
is not answered by the kernel any more. An HVC, and a trapped SMC,
reach the VMM as `hvc`/`smc` exits carrying x0..x3, and the next
`vm_run`'s resume value becomes the guest's x0, the same completion
path an MMIO load uses. The kernel keeps one mechanism, `vm_cpu_on`:
reset a vCPU at an entry with a context in x0 and mark it online. The
VMM decides what CPU_ON means (a vCPU quota, a thread of its own),
what power-off means (the VM ends), and what to say to everything else
(NOT_SUPPORTED). This restores the interposition ideal at the VM
boundary — the monitor is the authority — and it is what portability
wants: PSCI over HVC is ARM's spelling of "start this processor at
this address"; x86 spells it INIT/SIPI through a local APIC the VMM
emulates, RISC-V spells it SBI over `ecall`. A port changes the exit
decoder's few lines, not policy in the kernel, and a foreign guest's
further requests (suspend, affinity, reset) land in a program that can
be changed without touching the kernel.

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
- An `asm` expression without `volatile` is a pure function of its inputs
  to the optimizer: it may be moved past other code, merged with an
  identical read, or hoisted. That is right for constants (CNTFRQ,
  CurrentEL, ID registers) and wrong for anything the machine changes
  under you — DAIF, the per-core pointer in TPIDR, ESR/FAR, TCR — which
  must be `asm volatile`. Lesson paid for (2026-09-03), found the day a
  ReleaseSafe kernel first ran the suite: `lockIrqSave`'s `mrs daif` was
  moved *after* its `msr daifset`, so every unlock restored interrupts
  masked; core 0 took not a single interrupt after boot while the
  secondaries (whose idle path unmasked explicitly) ticked on, and the
  Debug kernel — which never reorders — had hidden it for the project's
  whole life. The gate now runs the kernel-heavy drills under a
  ReleaseSafe kernel as well (`+rs` in the check output).
