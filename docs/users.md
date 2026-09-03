# Users and sessions

## In one breath

In moss a user is not a number the kernel knows about. A user is a
**key**: a cryptographic identity whose secret half is locked in a small
record under a passphrase. Logging in means unlocking that secret; there
is no password to compare and no list of who is allowed what. A login
starts a **session**, which is an ordinary sandboxed program tree running
under that user's resource limits, handed exactly the things it may
touch: the user's own home (a separate encrypted disk of its own — see
[Filesystems and views](filesystem.md)), the system's settings, the
system's program store, and the console it logged in from. Logging out
destroys that program tree, and the unlocked secret with it. There is no
root account, because administrative power is just holding the right
capabilities.

## How it works

### What replaces the usual machinery

| The usual thing | In moss |
|---|---|
| a uid | an Ed25519 identity; the public key is the user |
| `/etc/passwd`, `/etc/shadow` | one record per user, `conf/users/<name>.msh`, readable only by the session manager |
| a password hash | the identity's seed, sealed under a key derived from the passphrase; login unseals it and checks the key it regenerates |
| groups, mode bits, ACLs | views: a program can name only what it was handed |
| root, sudo, setuid | nobody: the records view and the home tier belong to the session manager, the admin step writes records through its own view |
| a login process | a thread of the session manager per console |
| a session | a domain tree spawned under the record's budgets |
| logout | destroying that domain tree |

### A user is a key

A user record is an mshl data literal, written by an admin step (or,
later, an installer) into `conf/users/<name>.msh`:

```
{ key: "…64 hex…", salt: "…32 hex…", sealed: "…96 hex…",
  kdf: { ln: 11, r: 8, p: 1 },
  budget: { kobj: 2mb, user: 12mb, cpu: 500 } }
```

`key` is the Ed25519 public key; `salt` and `kdf` are the scrypt
parameters; `sealed` is the identity's 32-byte seed encrypted with
AEGIS-256 under a key derived from the passphrase and the salt, plus a
16-byte tag. Nothing in the record can be compared against a typed
passphrase: the only way to know the passphrase is right is to derive
the key, unseal the seed, regenerate the key pair, and find that its
public key is the one on record. That is what `lib/usercred.zig` does,
on the host in tests and in the session manager in the system.

The same unlocked identity derives the key of the user's home volume
(HKDF over the seed), so the volume opens for that identity and no
other; and it is the key that will sign challenges when logins cross
the fabric (not built yet — see limits).

### Login is unsealing

```mermaid
sequenceDiagram
  participant C as console
  participant M as usersvc (session manager)
  participant F as fssvc (system volume)
  participant H as homefs (the user's volume)
  participant I as session init
  participant S as msh
  C->>M: name, then passphrase (not echoed)
  M->>M: read conf/users/name.msh, scrypt, unseal the seed, check the public key
  Note over M: wrong name, wrong passphrase, unparsable record: one answer, "login refused", after a 2 s pause
  M->>F: mkdir home/name, derive a view of it
  M->>H: spawn the home filesystem service, hand it that view and the home key (a secret)
  H->>F: open home/name/vol, mount the encrypted volume
  M->>H: derive the volume's root view
  M->>I: spawn init under the record's budgets, hand it: home root view, conf/app view, img/ store view, the console, the user's name
  I->>S: start the session's units (the home's conf/units, else the template): msh with the console, the home, the store
  S-->>C: moss shell
```

The passphrase lives in the manager's memory only for the duration of
the KDF and is zeroed afterwards. What the manager keeps for the
session's lifetime is the unlocked key pair, in the session's slot —
custody: the session never sees its own seed. Every refusal is the same
answer after the same pause, so the reply never says whether the name
or the passphrase was wrong.

### A session is a domain tree

The session manager spawns the session with the kernel's `spawn` under
the budgets the record names — kernel-object memory, user memory, and a
CPU share in permille of one core — so a session's cost is bounded
before it runs a single instruction. What it is handed, and nothing
else:

```mermaid
graph LR
  M["usersvc holds:\nconf/users view (ro)\nhome/ tier (rw)\nconf/app view (ro)\nimg/ store view (ro)\nspawn authority\nthe console channels"]
  M -- "spawn under the record's budgets" --> I["session init (mode 3)"]
  M -- "home root view (rw)" --> I
  M -- "conf/app view (ro)" --> I
  M -- "img/ store view (ro)" --> I
  M -- "the console" --> I
  I -- "unit gives: views derived from the home,\nthe session's own caps by tag" --> S["msh"]
  I -- "the same, for any unit the user's conf/units/ names" --> U["…"]
```

On a console, the session's root is an instance of **init** — the same
program that orchestrates the whole system, in its session mode — with
spawn authority and the boot archive. It reads the session's units from
`conf/units/` in the home, the user's own topology, and when there are
none, the archive's session template: msh on the session's console,
holding the home as its whole filesystem, the system store, and the
session's own init for service control. A unit in the home can ask for
any of the session's capabilities by tag (`{ tag: console, session:
true }`) and for views, which derive from the home and nothing above it.
Node init, session init and fabric placement are the same orchestrator
at three radii.

Without a console (the `users` drill, or any client speaking the
session protocol), the session is the session program itself, role 3 of
`user/users.zig`, handed the home view and the settings view.

### Consoles and seats

A seat is a virtio-console device. The `login` profile hands the session
manager every console driver's channel — `cons` on device 0, `cons1` on
device 1 — and the manager runs one thread per console, forever:

```mermaid
stateDiagram-v2
  [*] --> Prompt
  Prompt: bind our buffer, print "moss login: "
  Prompt --> Passphrase: a name
  Passphrase: print "passphrase: ", read unechoed
  Passphrase --> Authenticating: a line
  Authenticating --> Refused: unseal fails (2 s pause)
  Refused --> Prompt: "login refused"
  Authenticating --> Open: session spawned
  Open: the console is the session's shell's;\nthe thread only watches the domain
  Open --> Closing: the session domain is dead
  Closing: sync the home, destroy its service, wipe the key
  Closing --> Prompt
```

While a session is open the console belongs to its shell: msh binds its
own byte buffer to the driver, and the manager's thread only polls the
session domain's state. When the user types `exit`, msh — the session's
essential unit — exits; the session's init shuts everything under it
down and exits; the manager's thread sees the domain dead, closes the
session, rebinds its own buffer, and prompts again. The seat is free.

### Logout is teardown

Closing a session is one operation, in this order: destroy the session
domain (the whole tree, transitively — every capability it held is
released, every view it had dies and its filesystem service reclaims
it); sync the home volume through the manager's own view of it, because
a logout is not a crash and what the user was told is written must
reach the disk; destroy the home filesystem service (the only holder of
the volume key in plaintext); and zero the unlocked key pair in the
manager. Nothing of the session survives but the ciphertext of its
volume.

### Sharing between users

A user shares a part of their home by handing out a view of it — a
capability, not a permission bit — and takes it back by revoking that
view at the source. The session manager brokers the exchange; it never
sees the files.

```mermaid
sequenceDiagram
  participant A as alice's msh
  participant HA as alice's home service
  participant M as usersvc
  participant B as bob's msh
  A->>HA: derive a view of notes (read-only)
  HA-->>A: the view cap, and its badge
  A->>M: share "shared" for bob (the view cap attached, the badge named)
  M->>M: keep the cap under {from alice, to bob, name, badge}
  B->>M: shares
  M-->>B: [ { name: shared, from: alice, to: bob, accepted: false } ]
  B->>M: accept shared
  M-->>B: the view cap (the manager drops its copy)
  B->>HA: cat @shared/a.txt  (calls through the view)
  A->>M: unshare shared
  M->>HA: revoke that badge (through alice's root view)
  B->>HA: cat @shared/a.txt
  HA-->>B: bad_fd — the view is withdrawn, whoever holds it
```

Every session holds its own **badged** channel to the manager (minted
at spawn with the session's slot as the badge), so a sharing request
names its caller by badge and never by a word in the message; the
unbadged channel the drills hold can open and end sessions, a session's
badge can only share. Offers live in the manager's table (8 at a time)
while the owner's session does: at logout the home service dies and
every view of it with it, and the manager forgets the owner's offers
and whatever that user had accepted.

The shell mounts an accepted view as `@name`: `ls @shared`, `cat
@shared/a.txt`, `write @shared/x.txt "…"` (refused when the share is
read-only — and the owner may share read-write with a fourth word,
`rw`). A revoked or dead share simply fails its calls; `accept` of the
same name again replaces the mount. Sharing is per session pair and
lives in memory: nothing about an offer is written to disk.

### Settings in layers

A program's settings are two mshl records merged by `lib/settings.zig`:
the system layer, `conf/app/<program>.msh`, which a session sees
read-only through its `conf` view; and the user layer,
`conf/<program>.msh` in the home. The program's own schema lists the
keys that are **locked**: a locked key keeps the system value whatever
the user layer says, so a setting a user may not change is not
overridable rather than merely discouraged. Keys the system layer does
not define are ignored — a schema, not a dumping ground. There is no
settings daemon and no third syntax.

```mermaid
flowchart LR
  S["system layer\nconf/app/editor.msh\n{ theme: dark, tab_width: 4, telemetry: false }"] --> M{"merge, per key"}
  U["user layer\nhome conf/editor.msh\n{ theme: light, telemetry: true }"] --> M
  L["locked keys (the program's schema)\n[telemetry]"] --> M
  M --> E["effective\ntheme: light (user)\ntab_width: 4 (system)\ntelemetry: false (locked)"]
```

### What the drills prove

The `users` drill boots the system profile `users`: the admin step
writes alice's and bob's records (seeds and salts from the kernel's
entropy pool) and the system settings file; the driver then has a wrong
passphrase and an unknown user refused with the same answer, opens both
sessions at once, and waits for each to exit clean. Each session, from
inside, writes into its home, finds that `..` is an error and that
`conf/users/alice.msh` does not exist rather than being forbidden, and
computes its effective settings: theme from the user layer, tab width
from the system, telemetry locked. The driver, through its own read-only
view of `home/`, then finds each home to be exactly one file, `vol`, in
which neither session's plaintext occurs. Alice logs in again and her
session finds its earlier work. A further session is logged out early.
The kernel's leak bar holds after all of it: every page and every
kernel object is back.

The `login` drill drives two consoles over TCP: alice's wrong passphrase
refused, alice and bob in at once, each home the whole filesystem (`ls`
shows only one's own files, `cat ../b.txt` is an error), both shells
visible in `ps` from either seat, alice out and back in to find her
file, `run ps` from the system store inside her session, `install ps`
and the home's own store listing it, then both out. The manager exits
when every console has had a session and none is open.

## In detail

- **Records.** `conf/users/<name>.msh`. Names are 1–16 characters of
  `a-z`, `0-9`, `-`, `_` (a name is a directory name and a domain
  argument). Fields: `key` (32 bytes hex), `salt` (16 bytes hex),
  `sealed` (48 bytes hex: 32-byte seed + 16-byte AEGIS-256 tag), `kdf`
  (`ln`, `r`, `p`; defaults 12, 8, 1 — scrypt memory is 128 · 2^ln · r
  bytes), `budget` (`kobj`, `user` in bytes with size suffixes, `cpu`
  in permille of a core). The seal uses a fixed nonce and the label
  `moss-user-seed-v1`; the key it protects is derived from a per-user
  random salt and used once per seal, so the nonce is unique by
  construction.
- **KDF cost.** The manager's work area is static (2 MiB + 64 KiB, in
  its BSS), so a record whose cost exceeds it is refused as unreadable.
  The drills use `ln 11` (2 MiB); the library's default is `ln 12`
  (4 MiB), which a deployment must budget for.
- **Budgets.** Default when a record names none: 1 MiB kernel objects,
  4 MiB user memory, no CPU cap. The drill's records ask for 2 MiB,
  12 MiB and 500 permille (half a core).
- **The manager.** `usersvc` (`user/users.zig` role 1) holds: the
  records view (`conf/users`, ro), the home tier (`home/`, rw), the
  system settings layer (`conf/app`, ro), the system store (`img/`,
  ro), spawn authority, the boot archive, and in the login profile one
  console channel per seat (up to 4). It serves `SessReq` on one
  channel: `attach_buf` (a client's buffer for names and passphrases;
  the manager wipes the passphrase there after copying it), `login`
  (name and passphrase as offset/length words into that buffer, each at
  most 256 bytes; reply `session { sid }` or `denied`), `wait { sid }`
  (block until the session's domain is dead, close it, reply the exit
  code), `logout { sid }` (close it now). At most 4 sessions at once
  (`sess_err 3` beyond that). A refusal sleeps 20 ticks (2 s) before
  answering `denied`.
- **Custody.** The unlocked Ed25519 key pair lives in the session's slot
  in the manager for the session's lifetime and is zeroed at close. The
  home key is derived from it at login (`usercred.homeKey`: HKDF-SHA256,
  extract with salt `moss-home-volume-v1`, expand with info `home`),
  staged to the home filesystem service through a shared buffer as a
  boot-protocol secret, and zeroed in the manager immediately after.
- **Spawning.** A console session spawns `init` with `arg` 3 (session
  mode), flags log + spawner + bootfs; a protocol session spawns the
  `users` image with `arg` 3 (role 3), flags log only. Both take side A
  of a fresh channel and receive over it, in order: the home root view
  (`view`), the settings view (`conf`), the store view (`store`, when
  the manager has one), the console (`console`, on a console), the
  user's name as the argument, then `go`.
- **Session init.** Loads `conf/units/*.msh` from the home; with none,
  the archive's `conf/session/*.msh` (one unit: `msh` with `{ tag:
  console, session: true }`, `{ tag: view, fs: "", ro: false }`, `{
  tag: store, session: true }`, `{ tag: init, self: true }`, budget 8 MB
  user memory, essential). Views a unit asks for derive from the home
  root; `session: true` hands over one of the session's own caps by
  tag and index.
- **Console threads.** One per console, a 32 KiB stack each, a 1-page
  buffer bound to the driver at every prompt. Lines are read 64 bytes
  at a time with backspace handling; the name is echoed, the passphrase
  is not. Name buffer 64 bytes, passphrase buffer 256. While a session
  is open the thread polls the session domain every 5 ticks. All
  authentication runs under one lock: the KDF work area and the session
  table are shared by every console thread and the protocol loop.
- **Settings.** `settings.merge(system, user, locked)` returns the
  system record's keys with the user's values substituted for unlocked
  keys; a missing user layer yields the system layer. Both layers are
  parsed by the strict data parser (`parseData`) unit files use.
- **Exit codes.** The programs exit with distinct codes on every check
  they make (the drill role 140–159, the session role 160–179, the
  manager 180–185, the admin step 190–195), so a failing drill names its
  step.

## Known limits and bugs

- Shares are not persistent: an offer lives in the manager's memory
  while the owner's session does; there is no standing grant that
  survives a logout, and no sharing to a user who is not logged in when
  the offer is withdrawn is remembered. At most 8 offers at once, 8
  mounts per shell.
- No fabric logins: the identity is built to sign challenges across
  nodes, but nothing asks it to yet (stage 3).
- No installer and no desired-state `apply` tool: records are written
  by the drill's admin step, and a deployment would write the same
  files by hand (stage 3).
- A home volume's 8 MB capacity is reported, not enforced (see
  [Filesystems and views](filesystem.md)).
- One seat per virtio-console device; a device's MULTIPORT feature
  (several seats on one device) is not used.
- At most 4 sessions open at once and 4 consoles; names are at most 16
  characters; passphrases at most 256 bytes.
- The KDF cost a record may ask for is bounded by the manager's static
  work area (2 MiB + 64 KiB); raising it is a code change, not a
  configuration.
- The record format carries no version and no expiry; changing the seal
  or KDF means rewriting records.
- A session's CPU budget is a cap on its share, not a guarantee.

## Dig deeper

- DESIGN.md — "Users and sessions" (as built, console login, home
  volumes, lessons paid for), "Domains" (budgets, teardown), "Init and
  supervision" (unit files, session mode).
- ROADMAP.md — "Users and sessions, stage 1" and its residuals.
- HACKING.md — adding a unit file; `give` lines including `session:
  true` and `index:`.
- Source — `user/users.zig` (manager, console threads, admin step,
  session program, drill), `lib/usercred.zig` (records, unlock, home
  key; host-tested), `lib/settings.zig` (merge; host-tested),
  `shared/lib.zig` (`SessReq`, `SessResp`, `CapTag`), `user/init.zig`
  (session mode, `loadSessionUnits`), `boot/conf/units/usersvc.msh`,
  `usersvc-login.msh`, `useradmin.msh`, `users-drill.msh`,
  `boot/conf/session/msh.msh`, `tools/runner.zig` (the login script).
