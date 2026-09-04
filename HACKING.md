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
- `zig build check` is the gate: 23 OS tests under QEMU plus host unit
  tests, then the kernel-heavy drills once more under a **ReleaseSafe
  kernel** (the `+rs` rows) — about two minutes. Run it before
  committing. Logs land in `zig-out/check/` (`<name>-1.log`,
  `<name>+rs-1.log`). `-Donly=fs,ipc+rs` runs just those; `-Dsoak=10`
  runs each test ten times and stops at the first failure, leaving its
  log (also copied to `<label>-failed.log`, which a rerun does not
  overwrite) — the way to chase an intermittent one. `-Doptimize=ReleaseSafe`
  runs the whole suite optimized.
- `-Darch=x86_64` builds the x86_64 port (VT-d as the IOMMU, AMD-V as
  the hypervisor — bare-metal guests so far) — the kernel ELF and every
  program. `zig build
  -Darch=x86_64 run` boots it on OVMF + Limine (KVM when the host has
  it, else TCG) from a directory QEMU exposes as a FAT volume; it wants
  Limine's `BOOTX64.EFI` (`-Dlimine=DIR`, default the host's share dir)
  and the x86_64 OVMF images beside QEMU (`-Dovmf`, `-Dovmf-vars`).
  `zig build -Darch=x86_64 check` runs the port's drills (twenty-one:
  everything but guest and vmnode, which wait for the moss guest on
  the port) the same way, plus the host tests; the
  runner's `--arch x86_64` composes a boot directory per drill under
  `zig-out/check/esp-<name>/`. Syscall ABI on x86_64: rax = number,
  rdi rsi rdx r10 r8 r9 r12 r13 the argument and result slots (rcx and
  r11 are the instruction's); the kernel's `frame.arg(i)`/`set(i)` and
  `syscallNumber()` are the same on both ports.
- Interactive boots: `run` (TCG), `run-hvf` (Apple Silicon acceleration),
  `run-blk` (adds a scratch virtio disk), `run-net` (slirp + a guestfwd
  echo at 10.0.2.100:9000), `run-cluster` (two nodes on a socket segment),
  and `run-shell` — your terminal becomes msh, no flags needed (type
  `help`; kernel log lands in zig-out/shell-kernel.log; the `exit`
  command powers the machine off — Ctrl-C goes to the guest, not QEMU).

## Adding things

**A syscall**: number + doc in `shared/lib.zig` (`Syscall` enum) → dispatch
arm + implementation in `kernel/syscall.zig` (args are `frame.arg(0..6)`,
results `frame.set(i, v)` — slots the port maps to registers) → wrapper in `user/usys.zig`. Anything
that names a kernel object goes through a capability lookup — no syscall
takes a raw object id. A syscall that reads a user buffer checks
`userRangeOk`; one that WRITES a user buffer checks `userRangeWritable`
(text and the granted blob are read-only to EL1 too — a kernel store there
is a panic the caller provoked).

**A user program**: new file in `user/` opening with
`comptime { asm (usys.imageHeader("name")); }` (the MOSS header and
the entry, generated per port; the name is the child's domain name and
must match the catalog) and the `uPanic` handler copied from any
existing one; `umain(log handle, channel handle, arg, boot archive va,
boot archive len)` is a C function — the kernel places the arguments
per the port's ABI (x0..x4 / rdi..r8). Nothing else in a program is
port-specific: `usys.cycles()`/`cycleHz()` for the clock,
`usys.barrier()` between a virtio ring write and the doorbell →
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
receiver's second of that tag), and `profiles: [system, ...]` (the
profiles under which the unit starts at boot — there is no `start:`
key; a unit with no `profiles` starts only when something `give`s its
channel or an `after:` step names it) / `essential: true`
/ `certify` (with `seeds: [..]`, members the fabric dials once
certified) / `node: boot` (the boot's `node=N` becomes the program's
node: arg = role | node << 8, and the certification names it) /
`install` / `run: true` (the unit is also a program the shell can `run`
under its name: init writes a manifest for it into the store) as
needed — added to the boot-file list in
`build.zig`. A step that starts `after:` another must list the
`profiles` it belongs to, or it never starts. The program takes
it all with `boot.take`. A run tool's unit file becomes its manifest in
the store (`img/<name>.msh`: digest, `grant`, `give`; `fs: arg` = the
run argument) when init installs the images. Services reachable by
`connect` are units named after `shared.ServiceId`.

**A service**: serve one channel; scope per-client state by **badge**
(mint scoped caps with `chanMint`, hand them out in replies, drop your
own copy). When the last cap carrying a badge dies, `recv` returns
`client_dead` with the badge: unmap that client's buffer (`shmUnmap`),
free its slot, and only then may the badge be minted again. Blocking is
polled (`would_block`) so one loop serves everyone; a bound notification
(`notifyBind`) can interrupt your blocked `recv` — drain it with
`notifyWait` after every `interrupted` or the latched bits will spin you.

**A shell command**: add an arm to `hostCall` in `user/shell.zig` (or
to `user/fscmds.zig` if it is a file command every mshl host — msh and
mshrun — should have) that turns typed IPC into a `mshl.Value` (a table, record, string, or
nothing — never text parsed out of another service; rendering is the
interpreter's job), add the name to `command_names` (tab completion),
and extend `shell_script` in `tools/runner.zig` so the scripted console
session covers it (`.raw = true` sends bytes without a newline; an empty
`expect` waits for the prompt only). A LANGUAGE feature (a verb over
values, syntax, an operator) belongs in `lib/mshl.zig` with a host test
beside it — `zig test lib/mshl.zig` runs in a second, every test under
the leak-detecting allocator, so a value that escapes without being
counted fails the test; the QEMU check is for integration. A change to
the *syntax* also changes `tools/tree-sitter-mshl/grammar.js`, with a
corpus entry for it (`tree-sitter generate && tree-sitter test`; record
a new tree with `tree-sitter test -u` and read it before trusting it),
and then `zig build fmt-test lint-test ls-test` — the tools compile
the generated parser in (`tools/mshtree.zig`), so a grammar change is a
formatter, lint and language-server change, and every `.msh` under
`boot/` must still come out unchanged and clean (a new spacing rule means running
`zig-out/bin/mshfmt` over the tree and reading the diff; a new kind of
token needs its `Leaf.Kind` and a `needSpace` rule, and a test in
`tools/mshfmt.zig`; a new binding form or scope needs `collect`/`check`
in `tools/mshlint.zig`, and the server's hover/definition/completion
follow from its `Analysis` — a new binding kind needs a line in
`describe`). Two lists in the lint mirror the OS: the
implicit names a block gets (`it`, `in`, `acc`, `req` — a host that
calls a block with new names adds them) and the unit keys
`user/init.zig`'s `parseUnit` reads (a new key is added there and in
`unit_keys`, or every unit using it lints as a typo). New `.msh` files
are formatted and lint clean before they are committed; the two test
steps name any that are not. The memory
rules for host code: a host command builds its value in `it.arena` and
never keeps a pointer to one past the call; anything that must outlive
the line goes through `setVar` (a box); flags read out of data files
are `Value.asBool()` — `true` and nothing else — because the language
coerces nothing, and a host command that wants a number takes an int,
not text it parses.

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
`lib/usercred.zig` makes and unlocks them; `apply` (users role 2, the
`apply` unit, `run apply` from the shell) writes one from the passphrase
in `conf/system.msh` when no record exists — the desired-state file
(users, budgets, kdf cost, the settings layer; the archive's copy is
the default, the volume's wins). The session manager is the `usersvc` unit; a client
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

**A big record cannot be reset by a struct literal.** `s.* = .{}` on
a record with a 64 KB buffer inside builds the whole record on the
stack first and overflows the thread; keep buffers in arrays beside
the table (`snd_bufs`, `rx_bufs`, `peer_rx`) and the records small.
And a 16-bit protocol field takes a checked cast: `@intCast(65536)`
in ReleaseSafe is a panic, and a panicking service exits without a
word — the drill saw only `peer_dead`.

**A channel with deferred replies must reply by token.** `reply` with
token 0 answers the oldest parked caller on the channel — on a server
that parks callers (the fabric's forwarded calls), a control reply
without its token lands on some other client. Keep the token from
`recv` and answer with `replyRawTo`.

**A peer dropped**: every `fabsvc: peer lost (…)` line names the
reason (silent, send failed, sealed frame failed authentication, call
timed out, …); a `spawn by X refused: <cause>` line on the kernel log
says why a spawn answered `no_space` (usually `QuotaExceeded`: memory
accounts nest, and a parent pays for its children).

**Looking at the wire**: the `net` check keeps its packets in
`zig-out/check/net.pcap` and the `flogin` check keeps each node's per
boot (`zig-out/check/flogin-node2-1.pcap` …); read them with `tcpdump
-nr FILE`. The manual boots take the same `-object filter-dump` (see the
runner).

**An OS test**: prefer a unit-file drill — a profile in
`shared.BootProfile`, drill units under `boot/conf/units/` (`profiles:
[x]`, `oneshot: true`, `after:` for steps, `essential: true` on the last),
a kernel worker that is just `systemDrill("x")`, and a `Spec` in
`tools/runner.zig` with `.append = "profile=x"`; a non-zero step exit
fails the boot with that code. A step can be a script: `{ image:
mshrun, script: scripts/x.msh, oneshot: true, give: [ { tag: view, fs:
boot, ro: true } ] }` runs it from the archive and its error is the
step's failure. Write a kernel-side driver only when the
test must assert kernel state (log a unique `"<name>-test: PASS ..."`
line, then `psci.systemOff()`; panics are failures). Either way, add
the option to `build.zig` (the `-D` flag and the `variants`/
`all_test_opts` lists).

**An architecture**: a directory `kernel/arch/<name>/` whose `arch.zig`
provides every name `kernel/arch.zig` lists (read that file first: it
is the interface, with the shape of each piece in its doc comment), a
`linker.ld` beside it, and a case in `kernel/arch.zig`'s switch plus
the target query in `build.zig` (`-Darch=<name>`). Start from
`arch/aarch64/`: `cpu.zig`, `thread.zig`, `trap.zig`, `mmu.zig` and
`platform.zig` are the shape; `gic`/`its`/`smmu`/`psci`/`vm` are the
devices behind `intc`/`msi`/`iommu`/`power`/`vm`. The generic kernel
never imports a file under `arch/`, and the port calls up only through
the C-ABI entry points its assembly names and the generic modules'
public API — a port that needs something new from the generic side adds
it to the interface in `kernel/arch.zig`, with a doc comment, not by
reaching around it. Userspace has the same seam to make when a second
architecture arrives: `user/usys.zig` (the `svc` stubs and the counter
reads), the `.text.uhdr` stanza every program carries, the `dmb`
barriers in the virtio drivers, and `user/vmm.zig`.

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
- **A panic prints its backtrace**: the frame-pointer chain as return
  addresses (`!! stack: 0x… 0x…`); feed them to `llvm-addr2line -f -e
  zig-out/bin/moss-kernel.elf` (or the check variant's `.elf` under
  `.zig-cache`). The first address alone is not enough — it lands in
  the cold panic block of a Debug build and addr2line names whatever
  symbol precedes it.
- **A hang dumps itself.** Every system drill (`systemDrill` in
  kernel/main.zig) panics after 60s without shutdown, first printing
  every thread (state, the channel or notification it blocks on, its
  request word and badge), every domain (state, live threads, ctl refs,
  parent) and every bound IRQ line — `sched.debugDump()`,
  `domain.debugDump()`, `irq.debugDump()`. Read the dump before anything
  else: a caller parked on `chan#N` with the server of `chan#N` in recv
  is a dropped reply; a domain `dying` with threads_alive>0 and no
  thread of that name is a lost reap; a manager polling a domain that is
  not in the list was the slot-reuse bug. Wire the same three calls
  into any new driver that waits.
- **The trace ring** (`kernel/trace.zig`): lifecycle events (spawn,
  destroy, reaper signal, domain_stat, every notification signal and
  the path it took) recorded lock-free, printed by the hang watchdog
  after the dumps. When a dump shows the end state but not how it got
  there, add a `trace.record` at the suspect step — it costs nothing in
  the race's window, where a log line would move the race.
- `QEMU -d int -D file` lists every exception with its CPU ("Taking
  exception 5 [IRQ] on CPU 2"): the quickest way to see that one core
  takes no interrupts at all, which is how the non-volatile `mrs daif`
  was found.
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
- Architecture-specific code lives under `kernel/arch/<arch>/` and is
  reached only through `kernel/arch.zig` (the HAL). No inline assembly,
  system register, interrupt-controller or page-table-format knowledge
  outside that directory; generic names for generic things (`user_root`,
  `IrqState`, `intc.line_base`), the port's names inside the port.
- `asm volatile` for every read of CPU state that can change (DAIF,
  TPIDR, ESR/FAR, TCR, the counters); plain `asm` only for constants
  (CNTFRQ, CurrentEL, ID registers). A non-volatile read is pure to the
  optimizer and moves: a ReleaseSafe kernel once saved DAIF *after*
  masking it and never took an interrupt on core 0 again. The check runs
  the kernel-heavy drills ReleaseSafe (`+rs`) to keep this honest.
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
- A thread killed from another core dies at a **safe point** (syscall
  exit, an interrupt from EL0, block, sleep), never mid-syscall: a
  syscall may hold an object between allocating and publishing it.
  Still, prefer publishing under the lock that teardown takes (the
  window table's `Mapping.state` is the pattern).
- After `finishTeardown` a ctl-governed domain's slot may belong to
  someone else the next instant: read what you need first (the reaper
  learned this by stealing a fresh domain's death watch). A domain is
  `drained` only when its threads are gone AND nobody is inside
  `destroy()` — never reclaim on the thread count alone.
- Sentinels must not collide with valid values (sockets and slots start at
  0; use `0xffff...` or an optional).
- Handle-slot conventions for spawn grants are fixed by insert order in
  `domain.spawn`: log→chan→spawner→entropy→introspect→windows→hypervisor; user
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

The complete, current list of residuals is ROADMAP.md's **Open** section
(under "Phase 12 and beyond"); these are the ones that change how you
debug.

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
- User memory is touched ONLY through `kernel/arch/aarch64/uaccess.zig`
  (`copyFromUser`/`copyToUser`/`withUserBuffer`), after the syscall's
  range check: PAN is armed everywhere else and a stray dereference of
  a user pointer is a kernel fault ("privileged access to user memory
  refused"). No PAN toggling anywhere else, and never hold a window
  across a log call or a block; no cap transfer across nodes beyond
  spawn-time grants. All recorded in DESIGN.md "as built" sections.
