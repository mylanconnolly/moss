//! Virtual machines on AMD-V: a guest in its own nested-paging world,
//! run by a userspace VMM through the hypervisor capability. The kernel
//! runs `vmrun` on a VMCB per vCPU with every interrupt, CPUID, HLT,
//! port I/O, MSR and hypercall intercepted; a guest fault in nested
//! paging (memory the VM was not given) is an MMIO exit for the VMM to
//! answer. The local APIC the guest sees is emulated here through its
//! x2APIC MSRs — the counterpart of the vGIC on the aarch64 port: its
//! timer is a TSC deadline the host watches, its IPIs pend vectors on
//! the target vCPU, and every interrupt reaches the guest through the
//! VMCB's virtual-interrupt request, delivered when the guest's IF
//! allows it. Host interrupts leave the guest (INTR intercept) and are
//! taken here before the next entry.
//!
//! What the guest sees: RAM at GPA 0x40000000 (its VMM's choice of
//! size), the TSC, x2APIC with a TSC-deadline timer, port I/O and
//! nested-paging faults that the VMM answers, and nothing else. A
//! guest's RAM is plain frames owned by the VM object and charged to
//! the VMM; the nested page tables are x86 tables with the user bit,
//! which is what VT-d's first stage can walk too, so a passed-through
//! device's DMA reaches guest memory by the same tables.

const std = @import("std");
const boot = @import("boot.zig");
const cpu = @import("cpu.zig");
const intc = @import("intc.zig");
const ipc = @import("../../ipc.zig");
const irq = @import("../../irq.zig");
const kalloc = @import("../../kalloc.zig");
const lock = @import("../../lock.zig");
const log = @import("../../log.zig");
const mem = @import("../../mem.zig");
const pci = @import("../../pci.zig");
const pmem = @import("../../pmem.zig");
const sched = @import("../../sched.zig");
const shared = @import("shared");
const smp = @import("smp.zig");
const thread = @import("thread.zig");
const vtd = @import("vtd.zig");

pub const max_vms = 4;
pub const ram_ipa: u64 = shared.vm_ram_ipa;
pub const max_ram_pages = 32768; // 128M
pub const max_vm_devices = 4;
pub const max_vcpus = 4;

pub var stat_entries: u64 = 0;
pub var stat_timer_fires: u64 = 0;
pub var stat_timer_injected: u64 = 0;
pub var stat_spi_injected: u64 = 0;
pub var stat_waits: u64 = 0;
pub var stat_wfi: u64 = 0;
pub var stat_unmasks: u64 = 0;
pub var stat_spi_delivered: u64 = 0;

pub const Exit = struct { kind: shared.VmExit = .none, a: u64 = 0, b: u64 = 0, c: u64 = 0, d: u64 = 0 };

// ------------------------------------------------------------- the VMCB

const Vmcb = extern struct {
    // Control area.
    intercept_cr: u32,
    intercept_dr: u32,
    intercept_exc: u32,
    intercept_v3: u32, // at 0xc: the 64-bit intercept word is unaligned
    intercept_v4: u32,
    intercept_v5: u32,
    _r1: [40]u8,
    iopm_pa: u64,
    msrpm_pa: u64,
    tsc_offset: u64,
    asid: u32,
    tlb_ctl: u8,
    _r2: [3]u8,
    int_ctl: u32,
    int_vector: u32,
    int_state: u32,
    _r3: [4]u8,
    exit_code: u64,
    exit_info1: u64,
    exit_info2: u64,
    exit_int_info: u32,
    exit_int_info_err: u32,
    np_enable: u64,
    avic_apic_bar: u64,
    ghcb_pa: u64,
    event_inj: u32,
    event_inj_err: u32,
    n_cr3: u64,
    lbr_ctl: u64,
    clean: u32,
    _r4: u32,
    nrip: u64,
    insn_len: u8,
    insn_bytes: [15]u8,
    _r5: [800]u8,
    // State save area at 0x400.
    es: Seg,
    cs: Seg,
    ss: Seg,
    ds: Seg,
    fs: Seg,
    gs: Seg,
    gdtr: Seg,
    ldtr: Seg,
    idtr: Seg,
    tr: Seg,
    _r6: [43]u8,
    cpl: u8,
    _r7: [4]u8,
    efer: u64,
    _r8: [112]u8,
    cr4: u64,
    cr3: u64,
    cr0: u64,
    dr7: u64,
    dr6: u64,
    rflags: u64,
    rip: u64,
    _r9: [88]u8,
    rsp: u64,
    _r10: [24]u8,
    rax: u64,
    star: u64,
    lstar: u64,
    cstar: u64,
    sfmask: u64,
    kernel_gs_base: u64,
    sysenter_cs: u64,
    sysenter_esp: u64,
    sysenter_eip: u64,
    cr2: u64,
    _r11: [32]u8,
    g_pat: u64,
    _r12: [2448]u8,
};

const Seg = extern struct { selector: u16, attrib: u16, limit: u32, base: u64 };

comptime {
    std.debug.assert(@offsetOf(Vmcb, "iopm_pa") == 0x40);
    std.debug.assert(@offsetOf(Vmcb, "exit_code") == 0x70);
    std.debug.assert(@offsetOf(Vmcb, "event_inj") == 0xa8);
    std.debug.assert(@offsetOf(Vmcb, "n_cr3") == 0xb0);
    std.debug.assert(@offsetOf(Vmcb, "nrip") == 0xc8);
    std.debug.assert(@offsetOf(Vmcb, "es") == 0x400);
    std.debug.assert(@offsetOf(Vmcb, "cpl") == 0x4cb);
    std.debug.assert(@offsetOf(Vmcb, "efer") == 0x4d0);
    std.debug.assert(@offsetOf(Vmcb, "cr4") == 0x548);
    std.debug.assert(@offsetOf(Vmcb, "rip") == 0x578);
    std.debug.assert(@offsetOf(Vmcb, "rsp") == 0x5d8);
    std.debug.assert(@offsetOf(Vmcb, "rax") == 0x5f8);
    std.debug.assert(@offsetOf(Vmcb, "g_pat") == 0x668);
    std.debug.assert(@sizeOf(Vmcb) == 4096);
}

// Intercept bits (vector 3 in the low word, vector 4 in the high).
const icpt_intr: u64 = 1 << 0;
const icpt_nmi: u64 = 1 << 1;
const icpt_smi: u64 = 1 << 2;
const icpt_init: u64 = 1 << 3;
const icpt_vintr: u64 = 1 << 4;
const icpt_cpuid: u64 = 1 << 18;
const icpt_hlt: u64 = 1 << 24;
const icpt_ioio: u64 = 1 << 27;
const icpt_msr: u64 = 1 << 28;
const icpt_shutdown: u64 = 1 << 31;
const icpt_vmrun: u64 = 1 << 32;
const icpt_vmmcall: u64 = 1 << 33;
const icpt_vmload: u64 = 1 << 34;
const icpt_vmsave: u64 = 1 << 35;
const icpt_stgi: u64 = 1 << 36;
const icpt_clgi: u64 = 1 << 37;
const icpt_skinit: u64 = 1 << 38;
const icpt_wbinvd: u64 = 1 << 41;
const icpt_monitor: u64 = 1 << 42;
const icpt_mwait: u64 = 1 << 43;
const icpt_mwait_cond: u64 = 1 << 44;
const icpt_xsetbv: u64 = 1 << 45;

const exit_intr: u64 = 0x60;
const exit_vintr: u64 = 0x64;
const exit_cpuid: u64 = 0x72;
const exit_hlt: u64 = 0x78;
const exit_ioio: u64 = 0x7b;
const exit_msr: u64 = 0x7c;
const exit_shutdown: u64 = 0x7f;
const exit_vmmcall: u64 = 0x81;
const exit_npf: u64 = 0x400;

const int_ctl_v_irq: u32 = 1 << 8;
const int_ctl_v_ign_tpr: u32 = 1 << 20;
const int_ctl_v_intr_masking: u32 = 1 << 24;

// ------------------------------------------------------------- per core

const hsave_pages = 2; // VM_HSAVE_PA, then the host's own VMCB for vmsave
var host_pages: [sched.max_cpus][hsave_pages][4096]u8 align(4096) = undefined;
/// The I/O permission map (every port intercepted) and the MSR
/// permission map (every MSR intercepted but the ones the segment
/// state carries), shared by every VM.
var iopm: [3][4096]u8 align(4096) = @splat(@splat(0xff));
var msrpm: [2][4096]u8 align(4096) = @splat(@splat(0xff));

var svm_ready = false;
var msrpm_ready = false;

const msr_efer: u32 = 0xc000_0080;
const msr_vm_cr: u32 = 0xc001_0114;
const msr_vm_hsave_pa: u32 = 0xc001_0117;

/// Per core, at trap.init: is AMD-V here and allowed? Then EFER.SVME and
/// the host save area, and the host's own segment state saved once
/// (`vmsave`) for every exit to reload.
pub fn initCore() void {
    const ext = cpu.cpuid(0x8000_0001, 0);
    if (ext.ecx & (1 << 2) == 0) return; // no SVM
    if (cpu.rdmsr(msr_vm_cr) & (1 << 4) != 0) return; // SVMDIS: firmware locked it
    const feat = cpu.cpuid(0x8000_000a, 0);
    if (feat.edx & 1 == 0) return; // nested paging is the design
    // Next-RIP save spares the decode of the instruction that exited;
    // without it (QEMU's TCG) the fixed-length ones are stepped by hand.
    nrips = feat.edx & (1 << 3) != 0;
    const idx = smp.currentIndex();
    cpu.wrmsr(msr_efer, cpu.rdmsr(msr_efer) | (1 << 12));
    cpu.wrmsr(msr_vm_hsave_pa, boot.imagePhys(@intFromPtr(&host_pages[idx][0])));
    asm volatile ("vmsave %[pa]"
        :
        : [pa] "{rax}" (boot.imagePhys(@intFromPtr(&host_pages[idx][1]))),
        : .{ .memory = true });
    if (!msrpm_ready) {
        // Pass-through: FS/GS/KERNEL_GS bases and STAR/LSTAR/CSTAR/SFMASK
        // — the VMCB carries them, VMLOAD/VMSAVE move them.
        for ([_]u32{ 0xc000_0081, 0xc000_0082, 0xc000_0083, 0xc000_0084, 0xc000_0100, 0xc000_0101, 0xc000_0102 }) |m| msrpmAllow(m);
        msrpm_ready = true;
    }
    svm_ready = true;
    if (idx == 0) log.info("svm: AMD-V with nested paging{s}; this kernel is a hypervisor", .{if (nrips) "" else " (no next-RIP save)"});
}

var nrips: bool = false;

/// The instruction after the one that exited: the saved next RIP, or
/// the fixed length of the instruction the exit code names — CPUID and
/// RDMSR/WRMSR are two bytes, HLT one, VMMCALL three; compilers put no
/// prefix on any of them. (Port I/O carries its own in EXITINFO2.)
fn nextRip(c: *volatile Vmcb) u64 {
    if (nrips) return c.nrip;
    return c.rip + @as(u64, switch (c.exit_code) {
        exit_hlt => 1,
        exit_cpuid, exit_msr => 2,
        exit_vmmcall => 3,
        else => 0,
    });
}

/// Clear the two permission bits of an MSR in the map: bit offset
/// 2 * index within its range's 2K-byte region.
fn msrpmAllow(m: u32) void {
    const region: usize = if (m < 0x2000) 0 else if (m >= 0xc000_0000 and m < 0xc000_2000) 1 else if (m >= 0xc001_0000 and m < 0xc001_2000) 2 else return;
    const index: usize = (m & 0x1fff) * 2;
    const bit = region * 2048 * 8 + index;
    const bytes: [*]u8 = @ptrCast(&msrpm);
    bytes[bit / 8] &= ~(@as(u8, 3) << @intCast(bit % 8));
}

pub fn isHost() bool {
    return svm_ready;
}

// --------------------------------------------------------------- vCPUs

/// The guest's general registers the VMCB does not carry (rax and rsp
/// live in the VMCB): rbx rcx rdx rsi rdi rbp r8..r15, in this order,
/// which the entry stub indexes.
const nregs = 14;

pub const Vcpu = extern struct {
    vm: u64 = 0,
    idx: u64 = 0,
    online: bool = false,
    running: u32 = 0,
    run_core: u32 = 0,
    /// Signaled whenever something becomes injectable (an
    /// *ipc.Notification as an address): what a vCPU idling in HLT waits for.
    notif: u64 = 0,
    regs: [nregs]u64 = @splat(0),
    /// Host callee-saved state across a run: rbx rbp r12 r13 r14 r15 rsp.
    host: [7]u64 = @splat(0),
    /// This core's saved segment state (vmload after the exit).
    host_vmcb: u64 = 0,
    vmcb_pa: u64 = 0,
    /// Vectors waiting for delivery, 256 bits.
    pending: [4]u64 = @splat(0),
    // The emulated local APIC.
    apic_base: u64 = 0xfee0_0d00, // enabled, x2APIC on (as the loader leaves a core), BSP for vCPU 0
    svr: u64 = 0xff,
    tpr: u64 = 0,
    lvt_timer: u64 = 1 << 16,
    lvt_lint0: u64 = 1 << 16,
    lvt_lint1: u64 = 1 << 16,
    lvt_error: u64 = 1 << 16,
    icr: u64 = 0,
    esr: u64 = 0,
    tsc_deadline: u64 = 0,
    timer_pending: bool = false,
    pat: u64 = 0x0007_0406_0007_0406,
    first_run: bool = true,
    /// A read the VMM answers at the next vm_run, and what to do with
    /// the value: `pend_kind` (see Pend), the register encoding, the size,
    /// the other operand and the address for a read-modify-write.
    pending_read: bool = false,
    pend_kind: u8 = 0,
    pend_reg: u8 = 0,
    pend_size: u8 = 0,
    pend_extend: u8 = 0, // 0 keep upper bytes, 1 zero-extend, 2 sign-extend
    pend_alu: u8 = 0, // the ALU op of a test/cmp/rmw (Alu)
    pend_operand: u64 = 0,
    pend_gpa: u64 = 0,
    exit_kind: u64 = 0,
    exit_a: u64 = 0,
    exit_b: u64 = 0,
    exit_c: u64 = 0,
    exit_d: u64 = 0,
    fp: thread.FpState = .{},
};

pub const Vm = struct {
    active: bool = false,
    owner: ?*anyopaque = null,
    ram_pa: u64 = 0,
    ram_pages: u64 = 0,
    npt_root: u64 = 0,
    asid: u32 = 0,
    kobj: ?*kalloc.Account = null,
    user_mem: ?*kalloc.Account = null,
    devices: [max_vm_devices]VmDevice = @splat(.{}),
    ndevices: usize = 0,
    nvcpus: u64 = 1,
    /// vCPU 0's initial page tables and stack, which later vCPUs share.
    cr3: u64 = 0,
    vcpus: [max_vcpus]Vcpu = @splat(.{}),
};

pub const VmDevice = struct { idx: u64 = 0, bar_ipa: u64 = 0, vintid: u32 = 0, intid: u32 = 0 };

var vms: [max_vms]Vm = @splat(.{});
var vms_lock: lock.SpinLock = .{};

pub const Error = error{ NoVms, OutOfFrames, NotHost };

fn vmcbOf(v: *Vcpu) *volatile Vmcb {
    return mem.physToPtr(*volatile Vmcb, v.vmcb_pa);
}

fn vmOf(v: *Vcpu) *Vm {
    return @ptrFromInt(v.vm);
}

fn vcpuNotif(v: *Vcpu) ?*ipc.Notification {
    return if (v.notif == 0) null else @ptrFromInt(v.notif);
}

/// Create a VM with `pages` of RAM at GPA 0x40000000, owned by `owner`
/// (RAM charged to its user account, tables and VMCBs to its
/// kernel-object one).
pub fn create(owner: *anyopaque, kobj: *kalloc.Account, user_mem: *kalloc.Account, pages: u64, nvcpus: u64) Error!*Vm {
    if (!svm_ready) return Error.NotHost;
    const irqs = vms_lock.lockIrqSave();
    var slot: ?*Vm = null;
    for (&vms, 0..) |*v, i| {
        if (!v.active) {
            v.* = .{ .active = true, .owner = owner, .asid = @intCast(i + 1), .kobj = kobj, .user_mem = user_mem, .nvcpus = @max(1, @min(nvcpus, max_vcpus)) };
            slot = v;
            break;
        }
    }
    vms_lock.unlockRestore(irqs);
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
    vm.npt_root = mem.virtToPhys(@intFromPtr(root));
    errdefer freeTables(vm);
    for (0..pages) |i| {
        nptMap(vm, ram_ipa + i * mem.page_size, pa + i * mem.page_size, npt_ram) catch return Error.OutOfFrames;
    }
    for (vm.vcpus[0..vm.nvcpus], 0..) |*v, i| {
        const page = kalloc.allocPage(kobj) catch return Error.OutOfFrames;
        v.* = .{ .vm = @intFromPtr(vm), .idx = i, .vmcb_pa = mem.virtToPhys(@intFromPtr(page)) };
        v.notif = @intFromPtr(ipc.createNotification() catch return Error.OutOfFrames);
        initVmcb(vm, v);
    }
    vm.vcpus[0].online = true;
    return vm;
}

/// A vCPU's VMCB at reset: long mode, paging on, flat 64-bit segments
/// (the loader's state a moss kernel expects, and what a bare guest
/// linked for 64-bit wants), the intercepts, nested paging.
fn initVmcb(vm: *Vm, v: *Vcpu) void {
    const c = vmcbOf(v);
    @memset(@as([*]volatile u8, @ptrCast(c))[0..4096], 0);
    // VINTR is not intercepted: the virtual-interrupt request delivers by
    // itself when the guest's IF allows, and V_IRQ clears once it has.
    const icpt: u64 = icpt_intr | icpt_nmi | icpt_smi | icpt_init | icpt_cpuid | icpt_hlt | icpt_ioio | icpt_msr | icpt_shutdown |
        icpt_vmrun | icpt_vmmcall | icpt_vmload | icpt_vmsave | icpt_stgi | icpt_clgi | icpt_skinit | icpt_wbinvd | icpt_monitor | icpt_mwait | icpt_mwait_cond | icpt_xsetbv;
    c.intercept_v3 = @truncate(icpt);
    c.intercept_v4 = @truncate(icpt >> 32);
    // A double fault in the guest is a fault exit that names its rip and
    // CR2, where a shutdown would say nothing.
    c.intercept_exc = 1 << 8;
    c.iopm_pa = boot.imagePhys(@intFromPtr(&iopm));
    c.msrpm_pa = boot.imagePhys(@intFromPtr(&msrpm));
    c.asid = vm.asid;
    c.tlb_ctl = 1; // flush this ASID at the first entry
    c.int_ctl = int_ctl_v_intr_masking | int_ctl_v_ign_tpr;
    c.np_enable = 1;
    c.n_cr3 = vm.npt_root;
    c.cs = .{ .selector = 0x28, .attrib = 0xa9b, .limit = 0xffff_ffff, .base = 0 }; // 64-bit code
    const data = Seg{ .selector = 0x30, .attrib = 0xc93, .limit = 0xffff_ffff, .base = 0 };
    c.ds = data;
    c.es = data;
    c.ss = data;
    c.fs = data;
    c.gs = data;
    c.gdtr = .{ .selector = 0, .attrib = 0, .limit = 0, .base = 0 };
    c.idtr = .{ .selector = 0, .attrib = 0, .limit = 0, .base = 0 };
    c.ldtr = .{ .selector = 0, .attrib = 0x82, .limit = 0, .base = 0 };
    c.tr = .{ .selector = 0, .attrib = 0x8b, .limit = 0xffff, .base = 0 };
    c.cpl = 0;
    c.efer = (1 << 8) | (1 << 10) | (1 << 11) | (1 << 12); // LME | LMA | NXE | SVME (required)
    c.cr0 = 0x8001_0011; // PG | WP | ET | PE
    c.cr4 = (1 << 5) | (1 << 9) | (1 << 10); // PAE, OSFXSR, OSXMMEXCPT (SSE code from the first instruction)
    c.cr3 = vm.cr3;
    c.rflags = 0x2;
    c.g_pat = v.pat;
    c.dr6 = 0xffff_0ff0;
    c.dr7 = 0x400;
}

/// The VMM's entry: pc, the first argument (rdi), the guest's page
/// tables (0 = the VM's shared ones) and stack.
pub fn setEntry(vm: *Vm, vcpu: u64, pc: u64, arg: u64, extra: [2]u64) void {
    if (vcpu >= vm.nvcpus) return;
    const v = &vm.vcpus[vcpu];
    if (extra[0] != 0) {
        if (vcpu == 0) vm.cr3 = extra[0];
        vmcbOf(v).cr3 = extra[0];
    } else vmcbOf(v).cr3 = vm.cr3;
    vmcbOf(v).rip = pc;
    vmcbOf(v).rsp = extra[1];
    v.regs[4] = arg; // rdi
}

pub const CpuOnError = error{ NoSuchVcpu, AlreadyOn };

/// A second vCPU comes online at `entry` with `ctx` in rdi, on the
/// VM's shared page tables; the VMM then runs it.
pub fn vcpuOn(vm: *Vm, idx: u64, entry: u64, ctx: u64) CpuOnError!void {
    if (idx >= vm.nvcpus) return CpuOnError.NoSuchVcpu;
    const v = &vm.vcpus[idx];
    if (v.online) return CpuOnError.AlreadyOn;
    const notif = v.notif;
    const vmcb_pa = v.vmcb_pa;
    v.* = .{ .vm = @intFromPtr(vm), .idx = idx, .notif = notif, .vmcb_pa = vmcb_pa };
    initVmcb(vm, v);
    vmcbOf(v).rip = entry;
    v.regs[4] = ctx;
    v.apic_base = 0xfee0_0c00; // not the BSP
    v.online = true;
    log.info("vm: vcpu {d} online at 0x{x}", .{ idx, entry });
}

// ------------------------------------------------------ nested paging

// Guest RAM: present, writable, user (nested walks are user accesses),
// executable; a device BAR: the same, uncached, never executable.
const npt_ram: u64 = 1 | 2 | 4;
const npt_device: u64 = 1 | 2 | 4 | (1 << 3) | (1 << 4) | (1 << 63);

fn nptEntry(table_pa: u64, i: u64) *volatile u64 {
    return &mem.physToPtr([*]volatile u64, table_pa)[i];
}

fn nptWalk(vm: *Vm, table_pa: u64, i: u64) !u64 {
    const e = nptEntry(table_pa, i);
    if (e.* & 1 != 0) return e.* & 0x000f_ffff_ffff_f000;
    const page = try kalloc.allocPage(vm.kobj.?);
    const pa = mem.virtToPhys(@intFromPtr(page));
    e.* = pa | 1 | 2 | 4;
    return pa;
}

fn nptMap(vm: *Vm, gpa: u64, pa: u64, bits: u64) !void {
    const pdpt = try nptWalk(vm, vm.npt_root, (gpa >> 39) & 0x1ff);
    const pd = try nptWalk(vm, pdpt, (gpa >> 30) & 0x1ff);
    const pt = try nptWalk(vm, pd, (gpa >> 21) & 0x1ff);
    nptEntry(pt, (gpa >> 12) & 0x1ff).* = pa | bits;
}

fn freeTables(vm: *Vm) void {
    const kobj = vm.kobj.?;
    const mask: u64 = 0x000f_ffff_ffff_f000;
    for (0..512) |i| {
        const e4 = nptEntry(vm.npt_root, i).*;
        if (e4 & 1 == 0) continue;
        for (0..512) |j| {
            const e3 = nptEntry(e4 & mask, j).*;
            if (e3 & 1 == 0) continue;
            for (0..512) |k| {
                const e2 = nptEntry(e3 & mask, k).*;
                if (e2 & 1 == 0) continue;
                kalloc.freePage(kobj, mem.physToPtr([*]u8, e2 & mask));
            }
            kalloc.freePage(kobj, mem.physToPtr([*]u8, e3 & mask));
        }
        kalloc.freePage(kobj, mem.physToPtr([*]u8, e4 & mask));
    }
    kalloc.freePage(kobj, mem.physToPtr([*]u8, vm.npt_root));
    vm.npt_root = 0;
}

/// Pass device `idx` through: its BAR at `bar_ipa` in the guest's nested
/// tables, its DMA through those tables (VT-d walks them as a
/// first stage — they carry the user bit), its interrupt as vector
/// `vintid` in the guest.
pub fn attachDevice(vm: *Vm, idx: u64, bar_ipa: u64, vintid: u32) Error!void {
    if (vm.ndevices == max_vm_devices or idx >= pci.count) return Error.OutOfFrames;
    const dev = &pci.devices[idx];
    const pages = (dev.bar_len + mem.page_size - 1) / mem.page_size;
    for (0..pages) |i| {
        nptMap(vm, bar_ipa + i * mem.page_size, dev.bar_pa + i * mem.page_size, npt_device) catch return Error.OutOfFrames;
    }
    vtd.attachStage2(idx, vm.npt_root, @intCast(vm.asid), @ptrCast(vm));
    irq.bindGuest(dev.intid, @ptrCast(vm), vintid) catch return Error.OutOfFrames;
    vm.devices[vm.ndevices] = .{ .idx = idx, .bar_ipa = bar_ipa, .vintid = vintid, .intid = dev.intid };
    vm.ndevices += 1;
}

/// A passed-through device's interrupt (from irq.deliver, IRQs masked):
/// pend the vector on vCPU 0, wake it if idle, kick it if running.
pub fn injectSpi(token: *anyopaque, vintid: u32) void {
    const vm: *Vm = @ptrCast(@alignCast(token));
    if (vintid < 32 or vintid > 255) return;
    if (stat_spi_delivered < 3) log.info("vm: device interrupt -> guest vector {d}", .{vintid});
    stat_spi_delivered += 1;
    pend(&vm.vcpus[0], @intCast(vintid));
}

fn pend(v: *Vcpu, vector: u8) void {
    _ = @atomicRmw(u64, &v.pending[vector / 64], .Or, @as(u64, 1) << @intCast(vector % 64), .acq_rel);
    wake(v);
}

fn hasPending(v: *Vcpu) bool {
    for (&v.pending) |*w| if (@atomicLoad(u64, w, .acquire) != 0) return true;
    return false;
}

/// The highest pending vector, taken.
fn takePending(v: *Vcpu) ?u8 {
    var i: usize = 4;
    while (i > 0) {
        i -= 1;
        const w = @atomicLoad(u64, &v.pending[i], .acquire);
        if (w == 0) continue;
        const bit: u6 = @intCast(63 - @clz(w));
        _ = @atomicRmw(u64, &v.pending[i], .And, ~(@as(u64, 1) << bit), .acq_rel);
        return @intCast(i * 64 + bit);
    }
    return null;
}

fn wake(v: *Vcpu) void {
    if (vcpuNotif(v)) |n| ipc.signal(n, 1);
    if (@atomicLoad(u32, &v.running, .acquire) != 0 and v.run_core != sched.thisCpu().id) intc.kick(v.run_core);
}

/// The timekeeper's tick: a vCPU's TSC deadline is watched here, its
/// timer vector pended and the vCPU woken when it passes.
pub fn tick() void {
    const now = cpu.cycles();
    for (&vms) |*vm| {
        if (!vm.active) continue;
        for (vm.vcpus[0..vm.nvcpus]) |*v| {
            if (!v.online) continue;
            if (v.tsc_deadline != 0 and now >= v.tsc_deadline and v.lvt_timer & (1 << 16) == 0) {
                v.tsc_deadline = 0;
                stat_timer_fires += 1;
                stat_timer_injected += 1;
                pend(v, @intCast(v.lvt_timer & 0xff));
            }
        }
    }
}

/// Tear a VM down: waits for a run in flight on another core to exit,
/// then returns tables, VMCBs and RAM to the owner's accounts.
pub fn destroy(vm: *Vm) void {
    if (!vm.active) return;
    for (vm.vcpus[0..vm.nvcpus]) |*v| {
        while (@atomicLoad(u32, &v.running, .acquire) != 0) std.atomic.spinLoopHint();
    }
    for (vm.devices[0..vm.ndevices]) |d| {
        irq.unbindGuest(d.intid, @ptrCast(vm));
        vtd.detachStage2(d.idx, @intCast(vm.asid), @ptrCast(vm));
    }
    for (vm.vcpus[0..vm.nvcpus]) |*v| {
        if (vcpuNotif(v)) |n| ipc.unrefNotification(n);
        v.notif = 0;
        if (v.vmcb_pa != 0) kalloc.freePage(vm.kobj.?, mem.physToPtr([*]u8, v.vmcb_pa));
        v.vmcb_pa = 0;
    }
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

// ------------------------------------------------------------- running

extern fn __svm_run(v: *Vcpu, vmcb_pa: u64) void;

/// Run the guest until it exits. `resume_value` completes a pending
/// port/MMIO read from the previous exit. Called in the VMM's syscall.
pub fn run(vm: *Vm, vcpu: u64, resume_value: u64) Exit {
    const v = &vm.vcpus[vcpu];
    if (!v.online) return .{ .kind = .fault };
    if (v.pending_read) {
        v.pending_read = false;
        if (completeRead(v, resume_value & sizeMask(v.pend_size))) |exit| return exit;
    }
    while (true) {
        v.exit_kind = 0;
        enterOnce(vm, v);
        if (v.exit_kind == @intFromEnum(shared.VmExit.wfi)) {
            stat_wfi += 1;
            if (!hasPending(v)) {
                stat_waits += 1;
                if (vcpuNotif(v)) |n| _ = ipc.wait(n);
                stat_waits += 1;
            }
            continue;
        }
        if (v.exit_kind != 0) break;
    }
    return .{ .kind = @enumFromInt(v.exit_kind), .a = v.exit_a, .b = v.exit_b, .c = v.exit_c, .d = v.exit_d };
}

fn sizeMask(size: u8) u64 {
    return switch (size) {
        1 => 0xff,
        2 => 0xffff,
        4 => 0xffff_ffff,
        else => ~@as(u64, 0),
    };
}

fn enterOnce(vm: *Vm, v: *Vcpu) void {
    const c = vmcbOf(v);
    // An interrupt to deliver, if the last one was taken: the virtual
    // interrupt request, honoured when the guest's IF allows.
    if (c.int_ctl & int_ctl_v_irq == 0) {
        if (takePending(v)) |vec| {
            c.int_vector = vec;
            c.int_ctl |= int_ctl_v_irq | (0xf << 16);
        }
    }
    const irqs = cpu.irqSave();
    const core = sched.thisCpu();
    stat_entries += 1;
    sched.fpSaveCurrent();
    thread.fpRestore(&v.fp);
    v.run_core = core.id;
    v.host_vmcb = boot.imagePhys(@intFromPtr(&host_pages[core.id][1]));
    @atomicStore(u32, &v.running, 1, .release);
    if (v.first_run) {
        v.first_run = false;
        c.tlb_ctl = 1;
    }
    __svm_run(v, v.vmcb_pa);
    c.tlb_ctl = 0;
    @atomicStore(u32, &v.running, 0, .release);
    thread.fpSave(&v.fp);
    sched.fpRestoreCurrent();
    // A host interrupt that ended the run is still pending: take it now.
    asm volatile ("sti; nop; cli" ::: .{ .memory = true });
    cpu.irqRestore(irqs);
    _ = vm;
    decode(v);
}

fn setExit(v: *Vcpu, kind: shared.VmExit, a: u64, b: u64, c: u64, d: u64) void {
    v.exit_kind = @intFromEnum(kind);
    v.exit_a = a;
    v.exit_b = b;
    v.exit_c = c;
    v.exit_d = d;
}

fn decode(v: *Vcpu) void {
    const c = vmcbOf(v);
    const code = c.exit_code;
    switch (code) {
        exit_intr => setExit(v, .interrupted, 0, 0, 0, 0),
        exit_hlt => {
            c.rip = nextRip(c);
            setExit(v, .wfi, 0, 0, 0, 0);
        },
        exit_cpuid => {
            emulateCpuid(v);
            c.rip = nextRip(c);
        },
        exit_msr => {
            if (c.exit_info1 == 0) emulateRdmsr(v) else emulateWrmsr(v);
            c.rip = nextRip(c);
        },
        exit_ioio => {
            const info = c.exit_info1;
            const port: u64 = (info >> 16) & 0xffff;
            const size: u8 = @intCast((info >> 4) & 7);
            if (info & (1 << 2) != 0 or info & (1 << 3) != 0) {
                setExit(v, .fault, code, c.rip, info, 0); // string or repeated I/O
                return;
            }
            c.rip = c.exit_info2;
            if (info & 1 != 0) {
                v.pending_read = true;
                v.pend_kind = @intFromEnum(Pend.rax);
                v.pend_size = size;
                setExit(v, .pio_read, port, size, 0, 0);
            } else {
                setExit(v, .pio_write, port, size, c.rax & sizeMask(size), 0);
            }
        },
        exit_vmmcall => {
            c.rip = nextRip(c);
            v.pending_read = true;
            v.pend_kind = @intFromEnum(Pend.rax);
            v.pend_size = 8;
            setExit(v, .hvc, c.rax, v.regs[4], v.regs[3], v.regs[2]); // rax, rdi, rsi, rdx
        },
        exit_npf => decodeMmio(v, c.exit_info2, c.exit_info1),
        exit_shutdown => setExit(v, .fault, code, c.rip, c.cr2, 0),
        0x48 => setExit(v, .fault, code, c.rip, c.cr2, c.exit_info1), // #DF: rip, cr2, error
        else => setExit(v, .fault, code, c.rip, c.exit_info1, c.exit_info2),
    }
}

// ------------------------------------------------------------- MMIO

/// What a completed read does with its value.
const Pend = enum(u8) {
    /// Into rax, the size's low bytes (port I/O, a hypercall's answer).
    rax = 1,
    /// Into the register `pend_reg` names, extended per `pend_extend`.
    reg = 2,
    /// Flags only: `test`/`cmp` against `pend_operand`.
    flags = 3,
    /// Flags, then the ALU result written back: a read-modify-write.
    rmw = 4,
};

const Alu = enum(u8) { add = 0, @"or" = 1, adc = 2, sbb = 3, @"and" = 4, sub = 5, xor = 6, cmp = 7, @"test" = 8 };

var undecodable_logged: u32 = 0;

/// The bytes of an instruction the decoder refused, logged for the
/// first few — how the decoder learns a new form.
fn undecodable(v: *Vcpu, b: []const u8, gpa: u64, info: u64) void {
    const c = vmcbOf(v);
    if (undecodable_logged < 4) {
        undecodable_logged += 1;
        log.warn("vm: MMIO instruction not decoded at rip 0x{x} (gpa 0x{x}): {x}", .{ c.rip, gpa, b });
    }
    setExit(v, .fault, exit_npf, c.rip, gpa, info);
}

/// A nested-paging fault on memory the VM was not given: an MMIO exit,
/// if the instruction is one a device driver produces — a move (also
/// zero/sign-extending, or from an immediate), `test`/`cmp` against
/// memory, or an ALU read-modify-write on it. The bytes come with the
/// exit (decode assist) or are fetched through the guest's tables; the
/// address is the fault's, so only the register operand and the width
/// are decoded. Reads complete at the next vm_run (`completeRead`).
fn decodeMmio(v: *Vcpu, gpa: u64, info: u64) void {
    const c = vmcbOf(v);
    var b: [15]u8 = undefined;
    var n: usize = c.insn_len;
    if (n > 15) n = 0;
    for (0..n) |k| b[k] = c.insn_bytes[k];
    if (n == 0) {
        n = fetchGuestBytes(v, c.rip, &b);
        if (n == 0) return setExit(v, .fault, exit_npf, c.rip, gpa, info);
    }
    var i: usize = 0;
    var opsize: u8 = 4;
    var rex: u8 = 0;
    while (i < n) : (i += 1) {
        if (b[i] == 0x66) {
            opsize = 2;
        } else if (b[i] & 0xf0 == 0x40) {
            rex = b[i];
        } else break;
    }
    if (rex & 8 != 0) opsize = 8;
    if (i >= n) return undecodable(v, b[0..n], gpa, info);
    var op = b[i];
    i += 1;
    var two = false;
    if (op == 0x0f) {
        if (i >= n) return undecodable(v, b[0..n], gpa, info);
        op = b[i];
        i += 1;
        two = true;
    }
    if (i >= n) return undecodable(v, b[0..n], gpa, info);
    const modrm = b[i];
    i += 1;
    const reg: u8 = ((modrm >> 3) & 7) | (if (rex & 4 != 0) @as(u8, 8) else 0);
    const ext: u8 = (modrm >> 3) & 7; // the opcode extension of a group
    const mod = modrm >> 6;
    const rm = modrm & 7;
    if (mod != 3 and rm == 4) i += 1; // SIB
    if (mod == 1) i += 1 else if (mod == 2 or (mod == 0 and rm == 5)) i += 4;
    if (i > n) return undecodable(v, b[0..n], gpa, info);

    var size: u8 = opsize;
    var kind: Pend = .reg;
    var alu: Alu = .add;
    var write_value: ?u64 = null; // a plain store
    var operand: u64 = 0;
    var extend: u8 = 1;
    var imm_len: usize = 0;
    const Imm = struct {
        fn read(bytes: []const u8, at: usize, len: usize, to_size: u8) ?u64 {
            if (at + len > bytes.len) return null;
            const raw: u64 = switch (len) {
                1 => bytes[at],
                2 => std.mem.readInt(u16, bytes[at..][0..2], .little),
                4 => std.mem.readInt(u32, bytes[at..][0..4], .little),
                else => return null,
            };
            // Immediates sign-extend to the operand size.
            const shift: u6 = @intCast(64 - len * 8);
            const sx: u64 = @bitCast(@as(i64, @bitCast(raw << shift)) >> shift);
            return sx & sizeMask(to_size);
        }
    };
    if (!two) switch (op) {
        0x88 => {
            size = 1;
            write_value = regRead(v, reg, 1);
        },
        0x89 => write_value = regRead(v, reg, size),
        0x8a => {
            size = 1;
            extend = 0;
        },
        0x8b => extend = if (size == 4) 1 else 0,
        0xc6, 0xc7 => {
            if (ext != 0) return undecodable(v, b[0..n], gpa, info);
            if (op == 0xc6) size = 1;
            imm_len = if (op == 0xc6) 1 else if (size == 2) 2 else 4;
            write_value = Imm.read(b[0..n], i, imm_len, size) orelse return undecodable(v, b[0..n], gpa, info);
        },
        0x84, 0x85 => { // test m, r
            if (op == 0x84) size = 1;
            kind = .flags;
            alu = .@"test";
            operand = regRead(v, reg, size);
        },
        0xf6, 0xf7 => { // test m, imm
            if (ext != 0) return undecodable(v, b[0..n], gpa, info);
            if (op == 0xf6) size = 1;
            imm_len = if (op == 0xf6) 1 else if (size == 2) 2 else 4;
            kind = .flags;
            alu = .@"test";
            operand = Imm.read(b[0..n], i, imm_len, size) orelse return undecodable(v, b[0..n], gpa, info);
        },
        0x38, 0x39 => { // cmp m, r
            if (op == 0x38) size = 1;
            kind = .flags;
            alu = .cmp;
            operand = regRead(v, reg, size);
        },
        0x3a, 0x3b => { // cmp r, m: the operands reversed
            if (op == 0x3a) size = 1;
            kind = .flags;
            alu = .cmp;
            operand = regRead(v, reg, size) | (1 << 63); // marked: r - m
            if (size == 8) return undecodable(v, b[0..n], gpa, info);
        },
        0x80, 0x81, 0x83 => { // group 1: ALU m, imm
            if (op == 0x80) size = 1;
            imm_len = if (op == 0x81) (if (size == 2) 2 else 4) else 1;
            operand = Imm.read(b[0..n], i, imm_len, size) orelse return undecodable(v, b[0..n], gpa, info);
            alu = @enumFromInt(ext);
            kind = if (alu == .cmp) .flags else .rmw;
        },
        0x00, 0x01, 0x08, 0x09, 0x20, 0x21, 0x28, 0x29, 0x30, 0x31 => { // ALU m, r
            if (op & 1 == 0) size = 1;
            alu = @enumFromInt(op >> 3);
            operand = regRead(v, reg, size);
            kind = .rmw;
        },
        else => return undecodable(v, b[0..n], gpa, info),
    } else switch (op) {
        0xb6 => size = 1, // movzx
        0xb7 => size = 2,
        0xbe => {
            size = 1;
            extend = 2;
        },
        0xbf => {
            size = 2;
            extend = 2;
        },
        else => return undecodable(v, b[0..n], gpa, info),
    }
    c.rip += i + imm_len;
    if (write_value) |w| return setExit(v, .mmio_write, gpa, size, w & sizeMask(size), 0);
    v.pending_read = true;
    v.pend_kind = @intFromEnum(kind);
    v.pend_reg = reg;
    v.pend_size = size;
    v.pend_extend = extend;
    v.pend_alu = @intFromEnum(alu);
    v.pend_operand = operand;
    v.pend_gpa = gpa;
    setExit(v, .mmio_read, gpa, size, reg, 0);
}

/// The VMM answered a read: finish the instruction. A read-modify-write
/// produces the write as the next exit, before the guest runs again.
fn completeRead(v: *Vcpu, val: u64) ?Exit {
    const c = vmcbOf(v);
    const size = v.pend_size;
    switch (@as(Pend, @enumFromInt(v.pend_kind))) {
        .rax => c.rax = if (size == 4) val else (c.rax & ~sizeMask(size)) | val,
        .reg => {
            const wide: u64 = if (v.pend_extend == 2) signExtend(val, size) else val;
            const zero = v.pend_extend != 0;
            regWrite(v, v.pend_reg, if (v.pend_extend == 2) 8 else size, wide, zero);
        },
        .flags => {
            const alu: Alu = @enumFromInt(v.pend_alu);
            if (v.pend_operand & (1 << 63) != 0 and alu == .cmp) {
                _ = aluOp(v, .cmp, v.pend_operand & sizeMask(size), val, size);
            } else {
                _ = aluOp(v, alu, val, v.pend_operand, size);
            }
        },
        .rmw => {
            const result = aluOp(v, @enumFromInt(v.pend_alu), val, v.pend_operand, size);
            return .{ .kind = .mmio_write, .a = v.pend_gpa, .b = size, .c = result & sizeMask(size), .d = 0 };
        },
    }
    return null;
}

fn signExtend(val: u64, size: u8) u64 {
    const shift: u6 = @intCast(64 - @as(u32, size) * 8);
    return @bitCast(@as(i64, @bitCast(val << shift)) >> shift);
}

/// An ALU operation on `a` and `b` of `size` bytes: the result, and the
/// guest's CF/PF/ZF/SF/OF as the instruction would leave them.
fn aluOp(v: *Vcpu, op: Alu, a: u64, b: u64, size: u8) u64 {
    const mask = sizeMask(size);
    const bits: u6 = @intCast(@as(u32, size) * 8 - 1);
    const sign: u64 = @as(u64, 1) << bits;
    var result: u64 = 0;
    var cf = false;
    var of = false;
    switch (op) {
        .add, .adc => {
            const wide = (a & mask) + (b & mask);
            result = wide & mask;
            cf = wide > mask;
            of = ((a ^ result) & (b ^ result) & sign) != 0;
        },
        .sub, .sbb, .cmp => {
            result = (a -% b) & mask;
            cf = (a & mask) < (b & mask);
            of = ((a ^ b) & (a ^ result) & sign) != 0;
        },
        .@"and", .@"test" => result = a & b & mask,
        .@"or" => result = (a | b) & mask,
        .xor => result = (a ^ b) & mask,
    }
    const zf = result == 0;
    const sf = result & sign != 0;
    const low: u8 = @truncate(result);
    const pf = @popCount(low) % 2 == 0;
    const c = vmcbOf(v);
    var f = c.rflags & ~@as(u64, 0x8d5);
    if (cf) f |= 1;
    if (pf) f |= 1 << 2;
    if (zf) f |= 1 << 6;
    if (sf) f |= 1 << 7;
    if (of) f |= 1 << 11;
    c.rflags = f;
    return result;
}

/// Guest-physical to host-physical, for guest RAM only.
fn gpaToPa(vm: *Vm, g: u64) ?u64 {
    if (g < ram_ipa or g >= ram_ipa + vm.ram_pages * mem.page_size) return null;
    return vm.ram_pa + (g - ram_ipa);
}

/// Walk the guest's page tables (CR3 in the VMCB) for `va`; 4-level,
/// 4K/2M/1G pages; null when unmapped.
fn guestVaToPa(v: *Vcpu, va: u64) ?u64 {
    const vm = vmOf(v);
    var table = vmcbOf(v).cr3 & 0x000f_ffff_ffff_f000;
    const shifts = [_]u6{ 39, 30, 21, 12 };
    for (shifts, 0..) |shift, level| {
        const tpa = gpaToPa(vm, table) orelse return null;
        const e = mem.physToPtr([*]const u64, tpa)[(va >> shift) & 0x1ff];
        if (e & 1 == 0) return null;
        if (level == 3) return (e & 0x000f_ffff_ffff_f000) | (va & 0xfff);
        if (level > 0 and e & (1 << 7) != 0) { // a large page
            const page_mask: u64 = (@as(u64, 1) << shift) - 1;
            return (e & 0x000f_ffff_ffff_f000 & ~page_mask) | (va & page_mask);
        }
        table = e & 0x000f_ffff_ffff_f000;
    }
    return null;
}

/// Up to 15 instruction bytes at the guest's rip (within its page).
fn fetchGuestBytes(v: *Vcpu, rip: u64, out: *[15]u8) usize {
    const vm = vmOf(v);
    const g = guestVaToPa(v, rip) orelse return 0;
    const pa = gpaToPa(vm, g) orelse return 0;
    const room = mem.page_size - (pa & 0xfff);
    const n: usize = @intCast(@min(15, room));
    const src = mem.physToPtr([*]const u8, pa);
    for (0..n) |i| out[i] = src[i];
    return n;
}

/// General registers by encoding: 0 rax .. 7 rdi, 8..15 r8..r15; rax and
/// rsp live in the VMCB, the rest in `regs` (rbx rcx rdx rsi rdi rbp r8..).
fn regIndex(enc: u8) ?usize {
    return switch (enc) {
        1 => 1, // rcx
        2 => 2, // rdx
        3 => 0, // rbx
        5 => 5, // rbp
        6 => 3, // rsi
        7 => 4, // rdi
        8...15 => 6 + @as(usize, enc - 8),
        else => null, // rax, rsp: the VMCB's
    };
}

fn regRead(v: *Vcpu, enc: u8, size: u8) u64 {
    const c = vmcbOf(v);
    const full: u64 = if (enc == 0) c.rax else if (enc == 4) c.rsp else v.regs[regIndex(enc).?];
    return full & sizeMask(size);
}

fn regWrite(v: *Vcpu, enc: u8, size: u8, val: u64, zero_extend: bool) void {
    const c = vmcbOf(v);
    const old: u64 = if (enc == 0) c.rax else if (enc == 4) c.rsp else v.regs[regIndex(enc).?];
    const new: u64 = if (zero_extend or size >= 4) (val & sizeMask(size)) else (old & ~sizeMask(size)) | (val & sizeMask(size));
    if (enc == 0) c.rax = new else if (enc == 4) c.rsp = new else v.regs[regIndex(enc).?] = new;
}

// ------------------------------------------------------ the guest's CPU

fn emulateCpuid(v: *Vcpu) void {
    const c = vmcbOf(v);
    const leaf: u32 = @truncate(c.rax);
    const sub: u32 = @truncate(v.regs[1]); // rcx
    var r = cpu.cpuid(leaf, sub);
    switch (leaf) {
        1 => {
            r.ebx = (r.ebx & 0x00ff_ffff) | (@as(u32, @intCast(v.idx)) << 24);
            r.ecx |= (1 << 21) | (1 << 24) | (1 << 31); // x2APIC, TSC deadline, hypervisor
            r.ecx &= ~@as(u32, (1 << 3) | (1 << 5)); // no MONITOR/MWAIT, no VMX
        },
        7 => if (sub == 0) {
            r.ebx &= ~@as(u32, 1 << 0); // no FSGSBASE for a guest (CR4 bit not virtualized here)
        },
        0xb, 0x1f => {
            r.edx = @intCast(v.idx); // x2APIC id
        },
        0x8000_0001 => {
            r.ecx &= ~@as(u32, 1 << 2); // no SVM inside
        },
        0x8000_000a => {
            r = .{ .eax = 0, .ebx = 0, .ecx = 0, .edx = 0 };
        },
        else => {},
    }
    c.rax = r.eax;
    v.regs[0] = r.ebx;
    v.regs[1] = r.ecx;
    v.regs[2] = r.edx;
}

fn emulateRdmsr(v: *Vcpu) void {
    const c = vmcbOf(v);
    const m: u32 = @truncate(v.regs[1]);
    const val: u64 = switch (m) {
        0x1b => v.apic_base,
        0x277 => v.pat,
        0x6e0 => v.tsc_deadline,
        0xc000_0080 => c.efer & ~@as(u64, 1 << 12),
        0x802 => v.idx, // x2APIC id
        0x803 => 0x0105_0014, // version: 5 LVT entries, x2APIC
        0x808 => v.tpr,
        0x80f => v.svr,
        0x828 => v.esr,
        0x830 => v.icr,
        0x832 => v.lvt_timer,
        0x835 => v.lvt_lint0,
        0x836 => v.lvt_lint1,
        0x837 => v.lvt_error,
        0x10 => cpu.cycles(),
        else => 0,
    };
    c.rax = val & 0xffff_ffff;
    v.regs[2] = val >> 32;
}

fn emulateWrmsr(v: *Vcpu) void {
    const c = vmcbOf(v);
    const m: u32 = @truncate(v.regs[1]);
    const val: u64 = (v.regs[2] << 32) | (c.rax & 0xffff_ffff);
    switch (m) {
        0x1b => v.apic_base = val,
        0x277 => {
            v.pat = val;
            c.g_pat = val;
        },
        0x6e0 => v.tsc_deadline = val,
        0xc000_0080 => c.efer = val | (1 << 12),
        0x808 => v.tpr = val,
        0x80b => {}, // EOI: the next pending vector goes in at the next entry
        0x80f => v.svr = val,
        0x828 => v.esr = 0,
        0x830 => {
            v.icr = val;
            ipi(v, val);
        },
        0x832 => v.lvt_timer = val,
        0x835 => v.lvt_lint0 = val,
        0x836 => v.lvt_lint1 = val,
        0x837 => v.lvt_error = val,
        0x83f => {}, // self IPI
        else => {},
    }
}

/// A guest IPI (x2APIC ICR): fixed delivery to one vCPU by APIC id, or
/// to all/all-but-self by shorthand.
fn ipi(sender: *Vcpu, icr: u64) void {
    const vm = vmOf(sender);
    const vector: u8 = @truncate(icr);
    const shorthand = (icr >> 18) & 3;
    const dest: u32 = @truncate(icr >> 32);
    for (vm.vcpus[0..vm.nvcpus]) |*t| {
        if (!t.online) continue;
        const hit = switch (shorthand) {
            1 => t == sender,
            2 => true,
            3 => t != sender,
            else => t.idx == dest,
        };
        if (hit) pend(t, vector);
    }
}

comptime {
    asm (svmRunAsm());
}

/// The entry stub, generated: rdi = the vCPU, rsi = the VMCB's physical
/// address. Host callee-saved state into `host`, the guest's registers
/// from `regs`, clgi/vmload/vmrun, the guest's registers back, vmsave,
/// the host's segment state back (vmload), stgi, the host's registers.
fn svmRunAsm() []const u8 {
    @setEvalBranchQuota(20_000);
    const o_regs = @offsetOf(Vcpu, "regs");
    const o_host = @offsetOf(Vcpu, "host");
    const o_host_vmcb = @offsetOf(Vcpu, "host_vmcb");
    const host_regs = [_][]const u8{ "rbx", "rbp", "r12", "r13", "r14", "r15", "rsp" };
    // regs[]: rbx rcx rdx rsi rdi rbp r8..r15 — rdi last in, first out.
    const guest_regs = [_][]const u8{ "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };
    var out: []const u8 =
        \\.section .text, "ax"
        \\.global __svm_run
        \\__svm_run:
        \\
    ;
    for (host_regs, 0..) |r, i| out = out ++ std.fmt.comptimePrint("        mov %{s}, {d}(%rdi)\n", .{ r, o_host + i * 8 });
    // GIF off, then the host's IF on: nothing is delivered until the
    // guest runs, and a physical interrupt during the guest is then an
    // INTR exit (with IF clear at vmrun it would be blocked instead).
    out = out ++
        \\        push %rdi
        \\        mov %rsi, %rax
        \\        clgi
        \\        sti
        \\        vmload %rax
        \\
    ;
    for (guest_regs, 0..) |r, i| {
        if (i == 4) continue; // rdi: last, it is the base register
        out = out ++ std.fmt.comptimePrint("        mov {d}(%rdi), %{s}\n", .{ o_regs + i * 8, r });
    }
    out = out ++ std.fmt.comptimePrint("        mov {d}(%rdi), %rdi\n", .{o_regs + 4 * 8});
    out = out ++
        \\        vmrun %rax
        \\        push %rdi
        \\        mov 8(%rsp), %rdi
        \\
    ;
    for (guest_regs, 0..) |r, i| {
        if (i == 4) continue;
        out = out ++ std.fmt.comptimePrint("        mov %{s}, {d}(%rdi)\n", .{ r, o_regs + i * 8 });
    }
    out = out ++ std.fmt.comptimePrint("        pop %rsi\n        mov %rsi, {d}(%rdi)\n", .{o_regs + 4 * 8});
    out = out ++ std.fmt.comptimePrint("        vmsave %rax\n        mov {d}(%rdi), %rax\n        vmload %rax\n        cli\n        stgi\n        pop %rdi\n", .{o_host_vmcb});
    for (host_regs, 0..) |r, i| out = out ++ std.fmt.comptimePrint("        mov {d}(%rdi), %{s}\n", .{ o_host + i * 8, r });
    out = out ++ "        ret\n";
    return out;
}
