# Hacking on moss

The practical companion to [ROADMAP.md](ROADMAP.md) (what was decided) and
[DESIGN.md](DESIGN.md) (how it works). This file is about getting things
done without rediscovering the sharp edges.

## Build & run

- Zig is **pinned** (0.16.0, `mise.toml` + `build.zig.zon`). Version bumps
  are deliberate, standalone commits — kernel code touches the parts of the
  language that churn.
- `zig build` produces `zig-out/bin/moss-kernel.bin` (a raw arm64 Image;
  the `.elf` sits beside it for symbols) plus every user program. User
  programs build ReleaseSafe by default (`-Duser-optimize` overrides);
  the kernel follows `-Doptimize` (Debug default — ReleaseFast kernel is
  untested territory). Benchmark numbers are meaningless from a Debug
  userspace; that mistake cost a 5x mystery once.
- `zig build check` is the gate: 14 OS tests under QEMU plus host unit
  tests, ~55s. Run it before committing. Logs land in `zig-out/check/`.
- Interactive boots: `run` (TCG), `run-hvf` (Apple Silicon acceleration),
  `run-blk` (adds a scratch virtio disk), `run-net` (slirp + a guestfwd
  echo at 10.0.2.100:9000), `run-cluster` (two nodes on a socket segment),
  and `run-shell` — your terminal becomes msh, no flags needed (type
  `help`; kernel log lands in zig-out/shell-kernel.log; the `exit`
  command powers the machine off — Ctrl-C goes to the guest, not QEMU).

## Adding things

**A syscall**: number + doc in `shared/lib.zig` (`Syscall` enum) → dispatch
arm + implementation in `kernel/syscall.zig` (args in `frame.regs[0..6]`,
results written back to the frame) → wrapper in `user/usys.zig`. Anything
that names a kernel object goes through a capability lookup — no syscall
takes a raw object id. A syscall that reads a user buffer checks
`userRangeOk`; one that WRITES a user buffer checks `userRangeWritable`
(text and the granted blob are read-only to EL1 too — a kernel store there
is a panic the caller provoked).

**A user program**: new file in `user/` with the MOSS header stanza (copy
the `comptime { asm(...) }` block and the `uPanic` handler from any
existing one, and put the program's own name in the `.ascii` field — it
is the child's domain name and must match the catalog; entry args are
x0=log handle, x1=channel handle, x2=arg, x3/x4=boot archive va/len) →
add to `user_progs` in `build.zig` and to the `shared.ImageId` catalog,
both by name (nothing is order-coupled: the image becomes `img/<name>`
in the boot archive). To spawn it from userspace, stage it with
`loader.Stage.load(...)` from the granted archive and pass the stage's
shm handle to `usys.spawn`; kernel boot drivers use `img(.name)`.

**A unit** (anything init starts): a file `boot/conf/units/<name>.msh` —
an mshl record with `image`, optional `arg`/`budget` (`kobj`, `user`,
`cpu` in permille of a core or `"25%"`)/`cores` (a partition)/`grant`/`restart`,
`give` lines (`{ tag: device, device: blk }`, `{ tag: disk, unit: blk }`,
`{ tag: buf, shm: 1 }`, `{ secret: conf/x.key }`, `{ tag: view, fs: p,
ro: true }`, `{ tag: net, netview: net }`, `{ tag: init, self: true }`,
`{ tag: console, session: true }` for one of a session's own caps; add
`index: 1` to pick the second device of a kind or to file a cap as the
receiver's second of that tag), and `start: eager` / `essential: true`
/ `certify` / `install` as needed — added to the boot-file list in
`build.zig`. A step that starts `after:` another must list the
`profiles` it belongs to, or it never starts. The program takes
it all with `boot.take`. A run tool's unit is what `run` reads for its
grants and views (`fs: arg` = the run argument). Services reachable by
`connect` are units named after `shared.ServiceId`.

**A service**: serve one channel; scope per-client state by **badge**
(mint scoped caps with `chanMint`, hand them out in replies, drop your
own copy). When the last cap carrying a badge dies, `recv` returns
`client_dead` with the badge: unmap that client's buffer (`shmUnmap`),
free its slot, and only then may the badge be minted again. Blocking is
polled (`would_block`) so one loop serves everyone; a bound notification
(`notifyBind`) can interrupt your blocked `recv` — drain it with
`notifyWait` after every `interrupted` or the latched bits will spin you.

**A shell command**: add an arm to `hostCall` in `user/shell.zig` that
turns typed IPC into a `mshl.Value` (a table, record, string, or
nothing — never text parsed out of another service; rendering is the
interpreter's job), add the name to `command_names` (tab completion),
and extend `shell_script` in `tools/runner.zig` so the scripted console
session covers it (`.raw = true` sends bytes without a newline; an empty
`expect` waits for the prompt only). A LANGUAGE feature (a verb over
values, syntax, an operator) belongs in `lib/mshl.zig` with a host test
beside it — `zig test lib/mshl.zig` runs in a second; the QEMU check is
for integration.

**A run tool's result**: build a `mshl.Value` in a `result.Result` arena
and `deliver` it — it lands in msh's `out` buffer as a data literal and
becomes the command's value (a table is a list of records). Render text
only when `deliver` returns false (no `out`: a human is watching).

**A program that needs more than log + one channel** (a driver, a
service, a run tool): call `boot.take(chan_h)` first thing — it serves
the boot channel until `go`, collecting caps by tag (`setup.cap(.mmio)`,
`.view`, `.disk`, ...), secret bytes, and argument text; `tty.attach`
wires the console from it. The spawner gives caps with `boot.giveCap`
(userspace) or `giveCap` (kernel boot drivers); authority caps (log,
spawner, mmio, irq, entropy, introspect) travel in messages like any
other cap. Run tools that need a kernel cap or a view are named in
`run_kinds` in msh until unit files land. The shell check drives a tool
with a `run NAME` step; a driver's device grant is exercised by its own
test (rngd in the rng test).

**A user**: a record `conf/users/<name>.msh` — `key` (Ed25519 public
key, hex), `salt` and `sealed` (the seed under the passphrase, hex),
`kdf: { ln, r, p }` (scrypt cost; the custodian's work area must cover
`128 * 2^ln * r` bytes) and `budget` (kobj/user/cpu, as in a unit).
`lib/usercred.zig` makes and unlocks them; `useradmin` (users role 2)
shows how an admin step writes one from a passphrase, and an installer
will do the same. The session manager is the `usersvc` unit; a client
attaches a buffer, sends `SessReq.login` with the name and passphrase in
it, and gets a session id to `wait` on or `logout`. A session is handed
its home view (tag `view`) and the settings layer (tag `conf`); a
program that reads settings merges `conf/<svc>.msh` with
`conf/<svc>.msh` in the home through `lib/settings.zig`, naming its
locked keys. A session's home is an encrypted mossfs volume in
`home/<name>/vol` on the system volume, served by `fs` role 4 (a
file-backed block device: `fileRead`/`fileWrite`/`fileFlush` in
`user/fs.zig`) that the manager spawns per session with the key from
`usercred.homeKey` and syncs before destroying at logout; the check
disk is 16 MB so two homes fit beside the program store. A session
opened at a console is `init` in mode 3: its
units come from `conf/units/` in the home, else `boot/conf/session/`;
`zig build run-login` boots the multi-user system with seat 0 on your
terminal and seat 1 on `nc 127.0.0.1 31905`.

**An OS test**: prefer a unit-file drill — a profile in
`shared.BootProfile`, drill units under `boot/conf/units/` (`profiles:
[x]`, `oneshot: true`, `after:` for steps, `essential: true` on the last),
a kernel worker that is just `systemDrill("x")`, and a `Spec` in
`tools/runner.zig` with `.append = "profile=x"`; a non-zero step exit
fails the boot with that code. Write a kernel-side driver only when the
test must assert kernel state (log a unique `"<name>-test: PASS ..."`
line, then `psci.systemOff()`; panics are failures). Either way, add
the option to `build.zig` (the `-D` flag and the `variants`/
`all_test_opts` lists).

## Debugging techniques that have paid off

- One OS test by hand, without the whole gate: `zig build -D<name>-test`
  then `zig-out/bin/moss-check <name> zig-out/bin/moss-kernel.bin`
  (the runner is installed alongside the kernel). Logs land in
  `zig-out/check/`.
- A kernel fault dump prints the top 0x120 bytes of the current thread's
  stack after the registers. An SPSR-looking word (`0x60000345`) there,
  or a stack pointer below the thread's stack, is a stack overflow — a
  Debug kernel spends over a kilobyte per formatted log line, and
  iterating an array by value (`for (arr)`) copies it onto the stack;
  iterate by pointer (`for (&arr) |*b|`). Kernel stacks are 32K.
- QEMU's SMMU/virtio device models explain themselves: add
  `-d guest_errors,unimp -D <file>` (the SMMU's "not allowed yet"
  messages live there) or `-trace 'smmuv3_*' -trace 'smmu_*'` to see
  every translation, event and command.
- A leak bar that fails by exactly one shm page, sometimes: the kernel
  dumps every still-active shared buffer with its page count, refs and
  creating domain (`ipc.dumpShms`) before the panic. A buffer whose
  creator is dead with refs left is a ref that skipped its release —
  look at what that domain was doing when it died (a call with a cap
  attached that nobody received, once).

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
- The kernel is FP-free by build flags; the scheduler's __fp_save/__fp_restore
  stubs are the only EL1 vector instructions (`.arch_extension` admits
  them). Userspace has NEON + hardware AES; the vector unit is per-thread
  state saved eagerly at context switch. If you write a userspace FP
  probe, make it `inline` — clobbering callee-saved v8-v15 in an outlined
  function makes the compiler's epilogue restore stale values right after
  your asm.
- Scheduler and IPC locks are fine-grained (DESIGN "Locking"): order is
  notification → channel → thread → run queue → sleepers, IRQs masked
  under all of them, and **never log while holding any** (the logger has
  its own lock). Park a thread only through `sched.block(list, slot,
  &obj.lock)` with the object lock held — it releases that lock itself —
  and wake only what you have already unlinked under that same lock.
  Anything a waker checks before giving up (a thread's blocked state, a
  latched bit) must be published under the lock the waker holds before
  the sleeper releases it — recv holds its bound notification's lock
  from the bits peek through the park for exactly this reason.
  Never take a notification or timers/IRQ lock while holding a channel or
  thread lock.
- Enqueueing a thread kicks the target core (SGI); do long-running work
  from a spawned thread, not from kmain's idle context — idle, once
  displaced by non-yielding threads, does not come back.
- Sentinels must not collide with valid values (sockets and slots start at
  0; use `0xffff...` or an optional).
- Handle-slot conventions for spawn grants are fixed by insert order in
  `domain.spawn`: log→chan→spawner→mmio→irq→entropy→introspect; user
  programs hardcode the slots they expect (documented per program).
- The kernel embeds exactly one blob, the boot archive; `spawn` takes an
  shm cap holding a staged image, never an index. An shm mapping refs
  the object until `shm_unmap` or teardown; a service maps a client's
  buffer once per client and unmaps it when the client's badge dies
  (`client_dead`) or a new buffer is attached — and drops the cap handle
  once mapped, since the mapping keeps its own ref. Keep one buffer per
  purpose rather than mapping per operation.
- `shared/` may not import kernel or user code and may not allocate; it is
  the ABI and compiles for every target.
- Kernel W^X, no ambient authority, no kernel channel bypasses — see the
  invariants section of ROADMAP.md before "optimizing" anything.

## Known scoping notes (deliberate, tracked)

- Kernel object pools are static: 64 channels, 64 notifications, 64
  shared buffers, 256 client badges (`kernel/ipc.zig`); a domain's
  window holds 64 mappings. If a program exits 210 (attachBuf's
  shmCreate refused), some service is keeping dead clients' buffers:
  it must handle `client_dead` (unmap, free the slot) — every server
  that mints badges gets that recv result, and one that treats every
  non-ok recv as fatal will exit on the first client to leave.
- A service that needs a clock arms a timer notification (`timerArm`);
  one that waits on sockets asks netsvc to `watch` them with its
  notification; bind the notification and the recv is interrupted on
  either. Nothing ticks the fabric any more (`FabReq.poll` is a no-op
  pump kept for compatibility). A server that must call out on a
  caller's behalf holds the caller open by its recv token
  (`replyRawTo`) or runs the blocking call on a worker thread
  (`threadCreate`) — never inline in its serve loop: a callee that
  calls back deadlocks it.
- netsvc listeners keep a 4-deep accept backlog; a SYN past it is
  dropped and the client's SYN retransmit retries. A five-second fabric
  timeout with nothing logged on either side was once an orphaned
  connection from the old one-slot design — if that shape ever returns,
  look at accept before anything else.
- The fabric check is a 3-node dynamic-membership drill: node 1's QEMU
  hosts the L2 hub (hubport netdevs bridging two socket listeners —
  mcast netdevs don't deliver cross-process on macOS), node 2 boots with
  drill=1 and powers off, and the RUNNER relaunches it when node 1 logs
  the death — the rejoin path is exercised on every check. Debug with
  the per-node logs in zig-out/check/fabric-node*.log plus pcap filters
  per netdev. A fourth node (node 9, badkey=1) is the imposter: its
  certificate comes from a different root of trust and its join must be
  refused by the v4 handshake. Node 3's certificate has no spawn
  authority (its spawn must be `denied`), and node 1 revokes node 3 at
  the end (node 2 must learn it by gossip; node 3's rejoins must be
  refused). Certificate/revocation encoding is `lib/fabcert.zig` — test
  it on the host with `zig test lib/lib.zig`.
- The shell boot is root → init → units (`zig build run-shell` and the
  shell check alike); read `boot/conf/units/` before the kernel when a
  service is missing, and `zig-out/shell-kernel.log` for init's "give
  failed"/"could not wire" lines. The other OS tests keep their kernel
  boot drivers and orchestrate their own topologies.
- Under the system boot a node's fabric identity lives in
  `state/fabric/` (seed + certificate; revocations beside them). A stale
  identity is fixed by deleting that directory; the next boot enrolls a
  fresh one with the root of trust. `zig build run-shell` keeps its
  volume, so it enrolls once.
- The fabric is fail-closed: fabsvc takes its buffer, identity material
  (seed + cluster key, a boot `secret`), and net view over its boot
  channel, then `identity_key` hands its public key back, fabroot
  `issue`s a certificate over it, and `set_cert` installs it — only
  then does it open the network. The kernel helpers `spawnFabroot` /
  `certifyFabric` / `fabRevoke` are the whole flow; `spawnDevice` and
  `spawnFs` are the driver and filesystem equivalents. Wire frames after the handshake are AEGIS-sealed — pcaps
  show ciphertext; to read a session, log on the fabsvc side of the
  seal. Give every service its OWN shm staging buffer: an shm cap handed
  to two services against one ref underflows at the second teardown.
- mossfs v3 (CoW, checksums, txg commits, LZ4 compression, XTS
  encryption) is the disk backend; its core (`user/mossfs.zig`) is a pure
  library over `lib/` static modules, so debug it on the host:
  `zig test --dep mosslib -Mroot=user/mossfs.zig -Mmosslib=lib/lib.zig`
  runs the whole suite including both crash-injection sweeps (RamDev
  records every sector run; each cut point and torn final request must
  remount to a valid pre- or post-txg tree). When a commit-path bug hides
  behind the overlay cache, compare a fresh mount (`t_fs2.mount(dev)`)
  against the live instance — disk right + live wrong means cache
  aliasing, both wrong means the commit wrote it.
- `lib/` modules (lz4, xts) are pure and freestanding-safe: no
  allocators, no OS imports, test vectors generated from reference
  implementations checked in as hex. Test them alone with
  `zig test lib/lib.zig`. New shared code goes here as a static module —
  there is no dynamic loader (locked decision in ROADMAP.md).
- Baselines: `zig build bench` / `zig build bench-soft` print primitive
  and core throughput (numbers recorded in DESIGN.md); alice logs
  whole-stack `bench` lines during every fs check run — watch them for
  regressions.
- The fs check runs on an encrypted+compressed volume: the kernel driver
  stages a fixed key via set_key before attach_disk. Wrong key, missing
  key, or a non-blank non-mossfs disk all degrade fssvc to bootfs-only
  serving with a loud log line — auto-format touches only all-zero disks.
- QEMU disks must keep the default writeback cache; `cache=unsafe` drops
  the FLUSH barriers mossfs's crash consistency depends on.
- `run-shell` keeps `zig-out/shell-disk.img` across runs (the check uses
  a fresh disk). Top-level directories are the hierarchy and cannot be
  made through the protocol; fssvc adds a missing standard tier at mount
  (`fssvc: hierarchy upgraded`), so a new tier needs a `std_hierarchy`
  entry in `user/fs.zig`, nothing else. The boot driver's image-store
  setup warns and continues on any refusal — if `run` says there is no
  index, read `zig-out/shell-kernel.log` first.
- Every QEMU config carries `-device virtio-rng-device` (and
  `force-legacy=false`, now in the common args): rngd is part of the
  base system. getrandom is fail-closed — a service that needs random
  bytes must start after rngd has seeded (boot drivers use `spawnRngd`,
  which blocks on `rng.isSeeded()`), and fabsvc refuses attach_net with
  no_entropy otherwise. `-Drng-test` is the drill; `rand` in msh is the
  quickest manual poke.
- EL2 host rules: the per-core pointer is TPIDR_EL2 at EL2 (TPIDR_EL1 is
  the one register VHE does not redirect, and a guest owns it); guest
  EL1 registers are reached by encoding (`S3_5_Cn_Cm_op2`, the EL1
  register's encoding with op1=5) because the assembler gates the
  `_EL12` names behind a v8.1 target; stage-2 registers need the
  `el2vmsa` assembler feature (set on the kernel target). Anything that
  runs while a core is in a guest must first restore HCR_EL2 (vm.guestExit
  does, before anything else).
- User memory is touched ONLY through `kernel/uaccess.zig`
  (`copyFromUser`/`copyToUser`/`withUserBuffer`), after the syscall's
  range check: PAN is armed everywhere else and a stray dereference of
  a user pointer is a kernel fault ("privileged access to user memory
  refused"). No PAN toggling anywhere else, and never hold a window
  across a log call or a block; no cap transfer across nodes beyond
  spawn-time grants. All recorded in DESIGN.md "as built" sections.
