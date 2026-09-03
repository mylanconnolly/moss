# moss documentation

These pages explain how moss works: what the system does, why it is
built the way it is, what it does today, and what it does not do yet.
They sit beside the three working documents at the repository root —
[ROADMAP.md](../ROADMAP.md) (decisions and milestones),
[DESIGN.md](../DESIGN.md) (the architecture narrative, "as built"), and
[HACKING.md](../HACKING.md) (building, debugging, extending) — and point
into them for the deepest detail.

## How to read these pages

Every page has the same shape:

1. **In one breath.** A plain-language explanation for someone who has
   never touched a kernel. If you read only this, you know what the thing
   is for.
2. **How it works.** The mechanism, with diagrams where a picture says it
   better than prose: what is on disk, who can see what, what happens in
   which order.
3. **In detail.** The exact behavior as built — names, sizes, limits,
   protocol shapes — for someone changing the code.
4. **Known limits and bugs.** What is deliberately not done, what is
   known to be wrong, and where that is tracked.
5. **Dig deeper.** Pointers into DESIGN.md, HACKING.md, and the source.

Two rules govern every page. **Grounded in truth:** a page describes the
system as it is in the same commit, checked against the code and the
tests, never as it is planned to be — plans live in ROADMAP.md, and a
page says "not yet" where that is the truth. **Layered, not diluted:**
the plain version at the top is simpler, never less true, than the
detail below it.

## Pages

| Page | What it covers |
|---|---|
| [The kernel](kernel.md) | What the kernel provides and refuses to; domains, capabilities, budgets, threads and scheduling, teardown, memory, the EL2 host, the security posture. |
| [IPC and services](ipc.md) | Channels, notifications, shared buffers, capability transfer, badges and client identities, peer death, rings, threads, typed protocols, the boot protocol. |
| [Boot and init](boot.md) | The boot sequence, the boot archive, root and init, unit files and `give` lines, profiles and drills, supervision, shutdown. |
| [Devices and drivers](drivers.md) | Drivers as sandboxed programs: PCI enumeration, virtio, MSI-X through the ITS, DMA through the SMMU, the console, entropy, the block driver's transports. |
| [Filesystems and views](filesystem.md) | The tiers of the system volume, what a view is, what a program and a user session can see, home volumes, program stores and manifests, and where `run` finds a program. |
| [Storage](storage.md) | The block driver, fssvc's data path, and mossfs: copy-on-write, checksums, transaction groups, compression, encryption, hashed directories, the host test suite, baselines. |
| [Networking](networking.md) | netsvc over virtio-net, the IPv6-native dual stack, network views and allowlists, sockets and doorbells, what the drills prove. |
| [Users and sessions](users.md) | Identities as keys, user records, login as unsealing, the session manager, sessions as domains, console login, logout, layered settings. |
| [The fabric](fabric.md) | Pooling machines: node identities and the root of trust, the join handshake and sealed transport, membership and placement, proxied channels and cap transfer. |
| [The hypervisor](hypervisor.md) | moss as an EL2 host: the VM syscalls, the userspace VMM, guest timers and vCPUs, device passthrough, a moss guest as a fabric node. |
| [The shell](shell.md) | msh and the mshl language: pipelines of values, verbs, functions, data files, the line editor, `run` and `install`. |
| [Testing and debugging](testing.md) | The gate, its drills, the ReleaseSafe rows, soak and filter, the hang watchdog and trace ring, the debugging recipes that have paid off. |

## Diagrams

Diagrams are [Mermaid](https://mermaid.js.org/), which GitHub renders
inline. They show the real mechanism — a real tree, a real sequence of
messages — not decoration; when a diagram and the prose disagree, that
is a bug in the page.
