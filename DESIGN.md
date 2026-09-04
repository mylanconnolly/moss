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
door, `kernel/uaccess.zig`: every syscall range-checks the pointer
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
Interrupts are MSI-X through the **ITS** (`kernel/its.zig`, as built
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

An SMMUv3 (`kernel/smmu.zig`) sits in front of the PCIe bus; every boot
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
"Kernel model" and `kernel/uaccess.zig`).

## Virtual machines

**As built (2026-09-02, first cut).** `kernel/vm.zig` runs an EL1 guest
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
