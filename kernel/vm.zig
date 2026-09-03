//! Virtual machines: an EL1 guest in its own stage-2 world, run by a
//! userspace VMM through the hypervisor capability. The kernel is a VHE
//! host (EL2, E2H); a guest is entered by loading its EL1 state through
//! the _EL12/_EL02 register names (which under VHE reach the EL1
//! registers the host itself never uses), pointing VTTBR_EL2 at the
//! VM's stage-2 tables, giving the vGIC its list registers, dropping
//! TGE and raising VM in HCR_EL2, and `eret`ing to EL1. Everything the
//! guest does that it may not do arrives at the host's own vector table
//! as an exception from a lower EL: a stage-2 fault (MMIO the VMM
//! emulates), WFI, HVC, a trapped SMC (PSCI), or a host interrupt. The
//! trap handler notices the core is in a guest, saves the guest's state,
//! restores the host's translation regime, decides the exit, and
//! returns into the VMM's syscall — by rewriting the exception frame so
//! that its `eret` lands in the host resume stub instead of the guest.
//!
//! What the guest sees: RAM at IPA 0x40000000 (its VMM's choice of size),
//! the virtual counter and timer (its timer interrupt, PPI 27, fires
//! physically at the host, which masks the timer and injects a virtual
//! PPI 27 through ICH_LR0), the GICv3 system-register CPU interface
//! (virtual, via HCR.IMO/FMO), and nothing else: every other address is
//! a stage-2 fault the VMM answers.
//!
//! Host state a guest could disturb — the vector unit — is saved around
//! the run; the host's per-core pointer lives in TPIDR_EL2, so TPIDR_EL1
//! (which VHE does not redirect) is the guest's. No DMA reaches a guest yet
//! (that is the SMMU's stage 2, a later step), so a guest's RAM is
//! plain frames owned by the VM object and charged to the VMM.

const std = @import("std");
const gic = @import("gic.zig");
const kalloc = @import("kalloc.zig");
const lock = @import("lock.zig");
const log = @import("log.zig");
const mem = @import("mem.zig");
const pmem = @import("pmem.zig");
const ipc = @import("ipc.zig");
const irq = @import("irq.zig");
const its = @import("its.zig");
const pci = @import("pci.zig");
const sched = @import("sched.zig");
const shared = @import("shared");
const smmu = @import("smmu.zig");
const trap = @import("trap.zig");

pub const max_vms = 4;
pub const ram_ipa: u64 = 0x4000_0000;
pub const max_ram_pages = 32768; // 128M
pub const max_vm_devices = 4;

/// Counters for the drills' post-mortems.
pub var stat_entries: u64 = 0;
pub var stat_timer_fires: u64 = 0;
pub var stat_timer_injected: u64 = 0;
pub var stat_spi_injected: u64 = 0;
pub var stat_waits: u64 = 0;
pub var stat_wfi: u64 = 0;
pub var stat_unmasks: u64 = 0;
pub var stat_spi_delivered: u64 = 0;
const vtimer_ppi: u32 = 27;

pub const Exit = struct {
    kind: shared.VmExit = .none,
    a: u64 = 0,
    b: u64 = 0,
    c: u64 = 0,
    d: u64 = 0,
};

/// The host's callee-saved context across a guest run (x19..x30, sp).
const HostCtx = extern struct {
    regs: [12]u64 = @splat(0),
    sp: u64 = 0,
};

pub const Vcpu = extern struct {
    regs: [31]u64 = @splat(0),
    pc: u64 = 0,
    pstate: u64 = 0x3c5, // EL1h, DAIF masked
    host: HostCtx = .{},
    sp_el0: u64 = 0,
    sp_el1: u64 = 0,
    sctlr: u64 = 0x30d0_0800, // RES1 bits, MMU/caches off
    tcr: u64 = 0,
    ttbr0: u64 = 0,
    ttbr1: u64 = 0,
    mair: u64 = 0,
    amair: u64 = 0,
    vbar: u64 = 0,
    elr: u64 = 0,
    spsr: u64 = 0,
    esr: u64 = 0,
    far: u64 = 0,
    afsr0: u64 = 0,
    afsr1: u64 = 0,
    contextidr: u64 = 0,
    cpacr: u64 = 3 << 20,
    cntkctl: u64 = 0,
    cntv_ctl: u64 = 0,
    cntv_cval: u64 = 0,
    tpidr_el1: u64 = 0,
    tpidr_el0: u64 = 0,
    tpidrro_el0: u64 = 0,
    vmcr: u64 = 0,
    ap1r0: u64 = 0,
    lr: [4]u64 = @splat(0),
    timer_pending: bool = false,
    /// Virtual SPIs 32..95 waiting for a list register (bit = vintid-32).
    spi_pending: u64 = 0,
    /// The host masked the guest's virtual timer (IMASK) when it fired;
    /// the mask lifts at the next entry once the guest has moved the
    /// compare value (its handler rearmed it) — a kernel guest never
    /// rewrites CNTV_CTL, so nobody else would clear it.
    host_masked: bool = false,
    masked_cval: u64 = 0,
    pending_read: bool = false,
    pending_read_reg: u8 = 0,
    pending_read_size: u8 = 0,
    exit_kind: u64 = 0,
    exit_a: u64 = 0,
    exit_b: u64 = 0,
    exit_c: u64 = 0,
    exit_d: u64 = 0,
    /// The guest's vector registers: live while it runs, kept here across
    /// exits — the VMM's own code between runs uses NEON too.
    fp: sched.FpState = .{},
};

pub const Vm = struct {
    active: bool = false,
    owner: ?*anyopaque = null,
    ram_pa: u64 = 0,
    ram_pages: u64 = 0,
    s2_root: u64 = 0,
    vmid: u16 = 0,
    first_run: bool = true,
    running: std.atomic.Value(bool) = .init(false),
    kobj: ?*kalloc.Account = null,
    user_mem: ?*kalloc.Account = null,
    /// Signaled whenever something becomes injectable (timer, device):
    /// what a vCPU idling in WFI waits for.
    notif: ?*ipc.Notification = null,
    /// The core a run is on, to kick it when a device interrupt arrives.
    run_core: u32 = 0,
    devices: [max_vm_devices]VmDevice = @splat(.{}),
    ndevices: usize = 0,
    vcpu: Vcpu = .{},
};

pub const VmDevice = struct { idx: u64 = 0, bar_ipa: u64 = 0, vintid: u32 = 0, intid: u32 = 0 };

var vms: [max_vms]Vm = @splat(.{});
var vms_lock: lock.SpinLock = .{};

pub const Error = error{ NoVms, OutOfFrames, NotHost };

fn atEl2() bool {
    return (asm ("mrs %[el], CurrentEL"
        : [el] "=r" (-> u64),
    ) >> 2) == 2;
}

/// Create a VM with `pages` of RAM at IPA 0x40000000, owned by `owner`
/// (RAM charged to its user account, tables to its kernel-object one).
pub fn create(owner: *anyopaque, kobj: *kalloc.Account, user_mem: *kalloc.Account, pages: u64) Error!*Vm {
    if (!atEl2()) return Error.NotHost;
    const daif = vms_lock.lockIrqSave();
    var slot: ?*Vm = null;
    for (&vms, 0..) |*v, i| {
        if (!v.active) {
            v.* = .{ .active = true, .owner = owner, .vmid = @intCast(i + 1), .kobj = kobj, .user_mem = user_mem };
            slot = v;
            break;
        }
    }
    vms_lock.unlockRestore(daif);
    const vm = slot orelse return Error.NoVms;
    errdefer vm.* = .{};

    const pa = pmem.allocContiguous(@intCast(pages)) orelse return Error.OutOfFrames;
    errdefer pmem.freeContiguous(pa, @intCast(pages));
    user_mem.charge(pages * mem.page_size) catch return Error.OutOfFrames;
    errdefer user_mem.credit(pages * mem.page_size);
    @memset(mem.physToPtr([*]u8, pa)[0 .. pages * mem.page_size], 0);
    vm.ram_pa = pa;
    vm.ram_pages = pages;

    const root = kalloc.allocPage(kobj) catch return Error.OutOfFrames;
    vm.s2_root = mem.virtToPhys(@intFromPtr(root));
    errdefer freeTables(vm);
    for (0..pages) |i| {
        s2Map(vm, ram_ipa + i * mem.page_size, pa + i * mem.page_size, s2_page) catch return Error.OutOfFrames;
    }
    // A passed-through device signals by writing the ITS doorbell — DMA
    // through the guest's stage 2, so the doorbell is there, at itself.
    if (its.active) s2Map(vm, its.doorbellPage(), its.doorbellPage(), s2_device) catch return Error.OutOfFrames;
    vm.notif = ipc.createNotification() catch return Error.OutOfFrames;
    asm volatile ("dsb ish");
    return vm;
}

/// Pass device `idx` through: its BAR at `bar_ipa` in the guest's stage
/// 2, its DMA through the guest's stage 2, its interrupt as virtual SPI
/// `vintid`.
pub fn attachDevice(vm: *Vm, idx: u64, bar_ipa: u64, vintid: u32) Error!void {
    if (vm.ndevices == max_vm_devices or idx >= pci.count) return Error.OutOfFrames;
    const dev = &pci.devices[idx];
    const pages = (dev.bar_len + mem.page_size - 1) / mem.page_size;
    for (0..pages) |i| {
        s2Map(vm, bar_ipa + i * mem.page_size, dev.bar_pa + i * mem.page_size, s2_device) catch return Error.OutOfFrames;
    }
    asm volatile ("dsb ish");
    smmu.attachStage2(idx, vm.s2_root, vm.vmid, @ptrCast(vm));
    irq.bindGuest(dev.intid, @ptrCast(vm), vintid) catch return Error.OutOfFrames;
    vm.devices[vm.ndevices] = .{ .idx = idx, .bar_ipa = bar_ipa, .vintid = vintid, .intid = dev.intid };
    vm.ndevices += 1;
}

/// A passed-through device's interrupt (from irq.deliver, IRQs masked):
/// pend the virtual SPI, wake an idling vCPU, kick a running one.
pub fn injectSpi(token: *anyopaque, vintid: u32) void {
    const vm: *Vm = @ptrCast(@alignCast(token));
    if (vintid < 32 or vintid >= 96) return;
    if (stat_spi_delivered < 3) log.info("vm: device interrupt -> guest spi {d}", .{vintid});
    stat_spi_delivered += 1;
    _ = @atomicRmw(u64, &vm.vcpu.spi_pending, .Or, @as(u64, 1) << @intCast(vintid - 32), .acq_rel);
    if (vm.notif) |n| ipc.signal(n, 1);
    if (vm.running.load(.acquire) and vm.run_core != sched.thisCpu().id) gic.sendSgi(vm.run_core);
}

// Stage-2 descriptors: normal WB (MemAttr 0b1111), RW (S2AP 0b11), inner
// shareable, accessed; executable (XN = 0). Device pages: Device-nGnRnE
// (MemAttr 0), execute-never.
const s2_page: u64 = 3 | (0b1111 << 2) | (0b11 << 6) | (0b11 << 8) | (1 << 10);
const s2_device: u64 = 3 | (0b11 << 6) | (1 << 10) | (@as(u64, 1) << 54);

fn s2Entry(table_pa: u64, idx: u64) *volatile u64 {
    return &mem.physToPtr([*]volatile u64, table_pa)[idx];
}

fn s2Walk(vm: *Vm, table_pa: u64, idx: u64) !u64 {
    const e = s2Entry(table_pa, idx);
    if (e.* & 1 != 0) return e.* & 0x0000_ffff_ffff_f000;
    const page = try kalloc.allocPage(vm.kobj.?);
    const pa = mem.virtToPhys(@intFromPtr(page));
    e.* = pa | 3;
    return pa;
}

/// 39-bit IPA space (VTCR.T0SZ = 25), three levels from level 1.
fn s2Map(vm: *Vm, ipa: u64, pa: u64, desc: u64) !void {
    const l2 = try s2Walk(vm, vm.s2_root, (ipa >> 30) & 0x1ff);
    const l3 = try s2Walk(vm, l2, (ipa >> 21) & 0x1ff);
    s2Entry(l3, (ipa >> 12) & 0x1ff).* = pa | desc;
}

fn freeTables(vm: *Vm) void {
    const kobj = vm.kobj.?;
    for (0..512) |i| {
        const l1e = s2Entry(vm.s2_root, i).*;
        if (l1e & 1 == 0) continue;
        const l2 = l1e & 0x0000_ffff_ffff_f000;
        for (0..512) |j| {
            const l2e = s2Entry(l2, j).*;
            if (l2e & 1 == 0) continue;
            kalloc.freePage(kobj, mem.physToPtr([*]u8, l2e & 0x0000_ffff_ffff_f000));
        }
        kalloc.freePage(kobj, mem.physToPtr([*]u8, l2));
    }
    kalloc.freePage(kobj, mem.physToPtr([*]u8, vm.s2_root));
    vm.s2_root = 0;
}

/// Tear a VM down: waits for a run in flight on another core to exit
/// (its thread is being killed and leaves at its next interrupt), then
/// returns tables and RAM to the owner's accounts.
pub fn destroy(vm: *Vm) void {
    if (!vm.active) return;
    while (vm.running.load(.acquire)) std.atomic.spinLoopHint();
    for (vm.devices[0..vm.ndevices]) |d| {
        irq.unbindGuest(d.intid, @ptrCast(vm));
        smmu.detachStage2(d.idx, vm.vmid, @ptrCast(vm));
    }
    if (vm.notif) |n| {
        vm.notif = null;
        ipc.unrefNotification(n);
    }
    // Stage-2 TLB entries for this VMID: gone before the frames are.
    asm volatile (
        \\dsb ish
        \\tlbi vmalls12e1is
        \\dsb ish
        \\isb
    );
    freeTables(vm);
    pmem.freeContiguous(vm.ram_pa, @intCast(vm.ram_pages));
    vm.user_mem.?.credit(vm.ram_pages * mem.page_size);
    vm.* = .{};
}

pub fn byIndex(idx: u64) ?*Vm {
    if (idx >= max_vms or !vms[idx].active) return null;
    return &vms[idx];
}

pub fn indexOf(vm: *Vm) u64 {
    return (@intFromPtr(vm) - @intFromPtr(&vms[0])) / @sizeOf(Vm);
}

// ------------------------------------------------------------ registers

const hcr_host: u64 = (1 << 34) | (1 << 31) | (1 << 27); // E2H | RW | TGE
// VM | SWIO | FMO | IMO | AMO | TWI | TSC | RW | E2H: stage 2 on,
// interrupts to the host and virtual to the guest, WFI and SMC trapped.
// Not DC: it would force the guest's stage 1 off, and a kernel guest
// links in the high half (the first fetch after its MMU came on was an
// address-size fault on a "physical" address of 0xffffff80...).
const hcr_guest: u64 = 1 | (1 << 1) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 13) | (1 << 19) | (1 << 31) | (1 << 34);
// T0SZ 25, start level 1, WB RA/WA, inner shareable, 4K, 40-bit PA.
const vtcr: u64 = 25 | (1 << 6) | (1 << 8) | (1 << 10) | (3 << 12) | (2 << 16);

// The EL1 registers reached from the VHE host carry `_EL12`/`_EL02`
// names; they are spelled by encoding (S3_5_Cn_Cm_op2 = the EL1 register's
// encoding with op1 = 5) because the assembler gates the names behind a
// v8.1 target and the kernel's code generation stays v8.0.
inline fn mrs(comptime name: []const u8) u64 {
    return asm volatile ("mrs %[v], " ++ name
        : [v] "=r" (-> u64),
    );
}

inline fn msr(comptime name: []const u8, v: u64) void {
    asm volatile ("msr " ++ name ++ ", %[v]"
        :
        : [v] "r" (v),
    );
}

fn loadGuestSysregs(v: *Vcpu) void {
    msr("S3_5_C1_C0_0", v.sctlr);
    msr("S3_5_C2_C0_2", v.tcr);
    msr("S3_5_C2_C0_0", v.ttbr0);
    msr("S3_5_C2_C0_1", v.ttbr1);
    msr("S3_5_C10_C2_0", v.mair);
    msr("S3_5_C10_C3_0", v.amair);
    msr("S3_5_C12_C0_0", v.vbar);
    msr("S3_5_C4_C0_1", v.elr);
    msr("S3_5_C4_C0_0", v.spsr);
    msr("S3_5_C5_C2_0", v.esr);
    msr("S3_5_C6_C0_0", v.far);
    msr("S3_5_C5_C1_0", v.afsr0);
    msr("S3_5_C5_C1_1", v.afsr1);
    msr("S3_5_C13_C0_1", v.contextidr);
    msr("S3_5_C1_C0_2", v.cpacr);
    msr("S3_5_C14_C1_0", v.cntkctl);
    msr("S3_5_C14_C3_2", v.cntv_cval);
    msr("S3_5_C14_C3_1", v.cntv_ctl);
    msr("tpidr_el1", v.tpidr_el1);
    msr("tpidr_el0", v.tpidr_el0);
    msr("tpidrro_el0", v.tpidrro_el0);
    msr("sp_el1", v.sp_el1);
}

fn saveGuestSysregs(v: *Vcpu) void {
    v.sctlr = mrs("S3_5_C1_C0_0");
    v.tcr = mrs("S3_5_C2_C0_2");
    v.ttbr0 = mrs("S3_5_C2_C0_0");
    v.ttbr1 = mrs("S3_5_C2_C0_1");
    v.mair = mrs("S3_5_C10_C2_0");
    v.amair = mrs("S3_5_C10_C3_0");
    v.vbar = mrs("S3_5_C12_C0_0");
    v.elr = mrs("S3_5_C4_C0_1");
    v.spsr = mrs("S3_5_C4_C0_0");
    v.esr = mrs("S3_5_C5_C2_0");
    v.far = mrs("S3_5_C6_C0_0");
    v.afsr0 = mrs("S3_5_C5_C1_0");
    v.afsr1 = mrs("S3_5_C5_C1_1");
    v.contextidr = mrs("S3_5_C13_C0_1");
    v.cpacr = mrs("S3_5_C1_C0_2");
    v.cntkctl = mrs("S3_5_C14_C1_0");
    v.cntv_cval = mrs("S3_5_C14_C3_2");
    v.cntv_ctl = mrs("S3_5_C14_C3_1");
    v.tpidr_el1 = mrs("tpidr_el1");
    v.tpidr_el0 = mrs("tpidr_el0");
    v.tpidrro_el0 = mrs("tpidrro_el0");
    v.sp_el1 = mrs("sp_el1");
}

fn loadVgic(v: *Vcpu) void {
    // A pending virtual timer goes into a free list register (unless
    // the guest still has one in flight).
    if (v.timer_pending) {
        var present = false;
        for (v.lr) |lr| {
            if (lr & 0xffff_ffff == vtimer_ppi and (lr >> 62) != 0) present = true;
        }
        if (!present) {
            for (&v.lr) |*lr| {
                if ((lr.* >> 62) == 0) {
                    lr.* = (@as(u64, 1) << 62) | (@as(u64, 1) << 60) | @as(u64, vtimer_ppi); // pending, group 1
                    stat_timer_injected += 1;
                    break;
                }
            }
        }
        v.timer_pending = false;
    }
    // Device interrupts: one list register each, no duplicates while the
    // guest still has that one in hand (it drains its device anyway).
    while (@atomicLoad(u64, &v.spi_pending, .acquire) != 0) {
        const bit: u6 = @intCast(@ctz(@atomicLoad(u64, &v.spi_pending, .acquire)));
        const vintid: u64 = 32 + @as(u64, bit);
        var present = false;
        var free: ?*u64 = null;
        for (&v.lr) |*lr| {
            if (lr.* & 0xffff_ffff == vintid and (lr.* >> 62) != 0) present = true;
            if ((lr.* >> 62) == 0 and free == null) free = lr;
        }
        if (!present) {
            const lr = free orelse break; // no room: stays pending
            lr.* = (@as(u64, 1) << 62) | (@as(u64, 1) << 60) | vintid;
            stat_spi_injected += 1;
        }
        _ = @atomicRmw(u64, &v.spi_pending, .And, ~(@as(u64, 1) << bit), .acq_rel);
    }
    msr("ich_vmcr_el2", v.vmcr);
    msr("ich_ap1r0_el2", v.ap1r0);
    msr("ich_lr0_el2", v.lr[0]);
    msr("ich_lr1_el2", v.lr[1]);
    msr("ich_lr2_el2", v.lr[2]);
    msr("ich_lr3_el2", v.lr[3]);
    msr("ich_hcr_el2", 1); // En
}

fn saveVgic(v: *Vcpu) void {
    v.vmcr = mrs("ich_vmcr_el2");
    v.ap1r0 = mrs("ich_ap1r0_el2");
    v.lr[0] = mrs("ich_lr0_el2");
    v.lr[1] = mrs("ich_lr1_el2");
    v.lr[2] = mrs("ich_lr2_el2");
    v.lr[3] = mrs("ich_lr3_el2");
    msr("ich_hcr_el2", 0);
}

// ------------------------------------------------------------- running

extern fn __guest_enter(v: *Vcpu) void;
extern const __guest_resume: anyopaque;

/// Run the guest until it exits. `resume_value` completes a pending MMIO
/// read from the previous exit. Called in the VMM's syscall context.
pub fn run(vm: *Vm, resume_value: u64) Exit {
    const v = &vm.vcpu;
    if (v.pending_read) {
        v.pending_read = false;
        if (v.pending_read_reg < 31) {
            v.regs[v.pending_read_reg] = switch (v.pending_read_size) {
                1 => resume_value & 0xff,
                2 => resume_value & 0xffff,
                4 => resume_value & 0xffff_ffff,
                else => resume_value,
            };
        }
        v.pc += 4;
    }
    while (true) {
        v.exit_kind = 0;
        enterOnce(vm);
        if (v.exit_kind == @intFromEnum(shared.VmExit.wfi)) {
            stat_wfi += 1;
            // Idle: sleep until something is injectable, then go again.
            // The bits latch, so a signal between the check and the wait
            // is not lost.
            if (!v.timer_pending and @atomicLoad(u64, &v.spi_pending, .acquire) == 0) {
                if (vm.notif) |n| _ = ipc.wait(n);
                stat_waits += 1;
            }
            continue;
        }
        if (v.exit_kind != 0) break; // .none means "handled in the kernel, go again"
    }
    return .{ .kind = @enumFromInt(v.exit_kind), .a = v.exit_a, .b = v.exit_b, .c = v.exit_c, .d = v.exit_d };
}

fn enterOnce(vm: *Vm) void {
    const v = &vm.vcpu;
    const daif = maskIrqs();
    const cpu = sched.thisCpu();
    gic.enableLocalInterrupt(cpu.id, vtimer_ppi);
    stat_entries += 1;

    sched.fpSaveCurrent();
    sched.fpRestore(&v.fp);
    msr("vtcr_el2", vtcr);
    msr("vttbr_el2", vm.s2_root | (@as(u64, vm.vmid) << 48));
    // What the guest reads as MIDR/MPIDR: the real part, vCPU 0 — not
    // whichever physical core the VMM thread landed on (a kernel parks
    // every core but affinity 0 at boot).
    msr("vpidr_el2", mrs("midr_el1"));
    msr("vmpidr_el2", 0x8000_0000);
    msr("cntvoff_el2", 0);
    if (vm.first_run) {
        vm.first_run = false;
        asm volatile (
            \\dsb ish
            \\tlbi vmalls12e1is
            \\dsb ish
        );
    }
    if (v.host_masked and v.cntv_cval != v.masked_cval) {
        v.cntv_ctl &= ~@as(u64, 1 << 1);
        v.host_masked = false;
        stat_unmasks += 1;
    }
    loadGuestSysregs(v);
    loadVgic(v);
    cpu.vcpu = @ptrCast(v);
    cpu.last_vcpu = @ptrCast(v);
    vm.run_core = cpu.id;
    vm.running.store(true, .release);
    msr("hcr_el2", hcr_guest);
    asm volatile ("isb");
    __guest_enter(v);
    // Back from the resume stub: the guest's state is in `v`, the host's
    // translation regime is restored, IRQs are masked.
    sched.fpRestoreCurrent();
    restoreIrqs(daif);
}

/// From the trap handler, on any exception taken while this core was in
/// a guest. Saves the guest, restores the host, decides the exit, and
/// rewrites the frame so the trap's `eret` resumes the VMM's syscall.
pub fn guestExit(frame: *trap.TrapFrame, kind_raw: u64) void {
    const cpu = sched.thisCpu();
    const v: *Vcpu = @ptrCast(@alignCast(cpu.vcpu.?));
    cpu.vcpu = null;
    msr("hcr_el2", hcr_host);
    asm volatile ("isb");
    const vm: *Vm = @fieldParentPtr("vcpu", v);
    // The guest's vector registers go to the vCPU and the host thread's
    // come back before anything here could run other code (a context
    // switch in the interrupt path would otherwise file the guest's
    // registers as the VMM's).
    sched.fpSave(&v.fp);
    sched.fpRestoreCurrent();

    v.regs = frame.regs;
    v.pc = frame.elr;
    v.pstate = frame.spsr;
    v.sp_el0 = frame.sp_el0;
    saveGuestSysregs(v);
    saveVgic(v);
    // The guest rearmed its timer since the host masked it: unmask now,
    // in the hardware on this core, where the timer lives — the host may
    // block waiting for the next fire before any further entry.
    if (v.host_masked and v.cntv_cval != v.masked_cval) {
        v.cntv_ctl &= ~@as(u64, 1 << 1);
        msr("S3_5_C14_C3_1", v.cntv_ctl);
        v.host_masked = false;
        stat_unmasks += 1;
    }
    vm.running.store(false, .release);

    switch (kind_raw) {
        9 => { // lower64_irq: a host interrupt; handle it as usual
            setExit(v, .interrupted, 0, 0, 0, 0);
            trap.handleIrq();
        },
        8 => decodeSync(v), // lower64_sync
        else => setExit(v, .fault, kind_raw, 0, 0, 0),
    }

    frame.elr = @intFromPtr(&__guest_resume);
    frame.spsr = 0x3c9; // EL2h, DAIF masked
    frame.regs[0] = @intFromPtr(v);
}

/// The little PSCI a guest kernel needs: VERSION, SYSTEM_OFF/RESET as an
/// exit, and CPU_ON refused (one vCPU, for now) — answered in place.
/// False when x0 is not a PSCI function id.
fn psci(v: *Vcpu) bool {
    const fid = v.regs[0];
    const base = fid & 0xffff_ffe0;
    if (base != 0x8400_0000 and base != 0xc400_0000) return false;
    switch (fid) {
        0x8400_0008, 0x8400_0009 => setExit(v, .poweroff, fid, 0, 0, 0),
        0x8400_0000 => v.regs[0] = 0x0001_0002, // PSCI 1.2
        0x8400_0003, 0xc400_0003 => v.regs[0] = @bitCast(@as(i64, -2)), // CPU_ON: INVALID_PARAMETERS (no such core)
        else => v.regs[0] = @bitCast(@as(i64, -1)), // NOT_SUPPORTED
    }
    return true;
}

fn setExit(v: *Vcpu, kind: shared.VmExit, a: u64, b: u64, c: u64, d: u64) void {
    v.exit_kind = @intFromEnum(kind);
    v.exit_a = a;
    v.exit_b = b;
    v.exit_c = c;
    v.exit_d = d;
}

fn decodeSync(v: *Vcpu) void {
    const esr = mrs("esr_el2");
    const ec: u8 = @truncate(esr >> 26);
    switch (ec) {
        0x24 => { // data abort from the guest: MMIO, when the syndrome is decodable
            const far = mrs("far_el2");
            const hpfar = mrs("hpfar_el2");
            const ipa = ((hpfar >> 4) << 12) | (far & 0xfff);
            if (esr & (1 << 24) == 0) {
                setExit(v, .fault, esr, ipa, 0, 0);
                return;
            }
            const size: u64 = @as(u64, 1) << @intCast((esr >> 22) & 3);
            const srt: u8 = @intCast((esr >> 16) & 0x1f);
            if (esr & (1 << 6) != 0) {
                const value = if (srt == 31) 0 else v.regs[srt] & (if (size == 8) ~@as(u64, 0) else (@as(u64, 1) << @intCast(size * 8)) - 1);
                v.pc += 4;
                setExit(v, .mmio_write, ipa, size, value, 0);
            } else {
                v.pending_read = true;
                v.pending_read_reg = srt;
                v.pending_read_size = @intCast(size);
                setExit(v, .mmio_read, ipa, size, srt, 0);
            }
        },
        0x01 => { // WFI/WFE: run() decides whether there is anything to wait for
            v.pc += 4;
            setExit(v, .wfi, esr & 1, 0, 0, 0);
        },
        0x16 => { // HVC: PSCI when it looks like PSCI, else the VMM's
            if (!psci(v)) setExit(v, .hvc, v.regs[0], v.regs[1], v.regs[2], v.regs[3]);
        },
        0x17 => { // SMC (trapped): PSCI or nothing
            v.pc += 4;
            if (!psci(v)) v.regs[0] = @bitCast(@as(i64, -1)); // NOT_SUPPORTED
        },
        // Anything else: report it with the guest's own ELR_EL1/ESR_EL1 too,
        // which say where the guest was and what it was handling.
        else => setExit(v, .fault, esr, v.elr, v.esr, mrs("far_el2")),
    }
}

/// The guest's virtual timer fired (physically, at the host): mask it so
/// the line drops, and inject a virtual PPI 27 at the next entry.
pub fn onVirtualTimer() void {
    stat_timer_fires += 1;
    const ctl = mrs("S3_5_C14_C3_1") | (1 << 1); // IMASK
    msr("S3_5_C14_C3_1", ctl);
    const cpu = sched.thisCpu();
    if (cpu.last_vcpu) |p| {
        const v: *Vcpu = @ptrCast(@alignCast(p));
        v.cntv_ctl = ctl;
        v.host_masked = true;
        v.masked_cval = mrs("S3_5_C14_C3_2");
        v.timer_pending = true;
        const vm: *Vm = @fieldParentPtr("vcpu", v);
        if (vm.notif) |n| ipc.signal(n, 1);
    }
}

fn maskIrqs() u64 {
    const daif = asm ("mrs %[v], daif"
        : [v] "=r" (-> u64),
    );
    asm volatile ("msr daifset, #2");
    return daif;
}

fn restoreIrqs(daif: u64) void {
    asm volatile ("msr daif, %[v]"
        :
        : [v] "r" (daif),
    );
}

comptime {
    // Offsets into Vcpu for the assembly below.
    const o_regs = @offsetOf(Vcpu, "regs");
    const o_pc = @offsetOf(Vcpu, "pc");
    const o_pstate = @offsetOf(Vcpu, "pstate");
    const o_host = @offsetOf(Vcpu, "host");
    const o_sp_el0 = @offsetOf(Vcpu, "sp_el0");
    asm (std.fmt.comptimePrint(
            \\.section .text, "ax"
            \\.global __guest_enter
            \\__guest_enter:
            \\        // Host callee-saved state, for the resume stub.
            \\        add     x1, x0, #{d}
            \\        stp     x19, x20, [x1, #0]
            \\        stp     x21, x22, [x1, #16]
            \\        stp     x23, x24, [x1, #32]
            \\        stp     x25, x26, [x1, #48]
            \\        stp     x27, x28, [x1, #64]
            \\        stp     x29, x30, [x1, #80]
            \\        mov     x2, sp
            \\        str     x2, [x1, #96]
            \\        ldr     x1, [x0, #{d}]
            \\        msr     elr_el2, x1
            \\        ldr     x1, [x0, #{d}]
            \\        msr     spsr_el2, x1
            \\        ldr     x1, [x0, #{d}]
            \\        msr     sp_el0, x1              // the guest EL0 stack, when it was there
            \\        add     x1, x0, #{d}
            \\        ldp     x2, x3, [x1, #16]
            \\        ldp     x4, x5, [x1, #32]
            \\        ldp     x6, x7, [x1, #48]
            \\        ldp     x8, x9, [x1, #64]
            \\        ldp     x10, x11, [x1, #80]
            \\        ldp     x12, x13, [x1, #96]
            \\        ldp     x14, x15, [x1, #112]
            \\        ldp     x16, x17, [x1, #128]
            \\        ldp     x18, x19, [x1, #144]
            \\        ldp     x20, x21, [x1, #160]
            \\        ldp     x22, x23, [x1, #176]
            \\        ldp     x24, x25, [x1, #192]
            \\        ldp     x26, x27, [x1, #208]
            \\        ldp     x28, x29, [x1, #224]
            \\        ldr     x30, [x1, #240]
            \\        ldp     x0, x1, [x1, #0]
            \\        eret
            \\
            \\// Entered by the trap handler's eret with x0 = the vcpu: put the host
            \\// back where __guest_enter left it and return into vm.enterOnce.
            \\.global __guest_resume
            \\__guest_resume:
            \\        add     x1, x0, #{d}
            \\        ldp     x19, x20, [x1, #0]
            \\        ldp     x21, x22, [x1, #16]
            \\        ldp     x23, x24, [x1, #32]
            \\        ldp     x25, x26, [x1, #48]
            \\        ldp     x27, x28, [x1, #64]
            \\        ldp     x29, x30, [x1, #80]
            \\        ldr     x2, [x1, #96]
            \\        mov     sp, x2
            \\        ret
        , .{ o_host, o_pc, o_pstate, o_sp_el0, o_regs, o_host }));
}
