//! No hypervisor on this port yet: every VM operation answers `NotHost`,
//! which the syscalls report as bad_state. SVM is the port's last stage.

const kalloc = @import("../../kalloc.zig");
const shared = @import("shared");

pub const max_vms = 4;
pub const ram_ipa: u64 = 0x4000_0000;
pub const max_ram_pages = 32768;
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
/// The shapes the VM syscalls touch; no VM ever exists here.
pub const Vcpu = struct { pc: u64 = 0, regs: [1]u64 = .{0} };
pub const Vm = struct { owner: *anyopaque, ram_pa: u64 = 0, nvcpus: u64 = 0, vcpus: [max_vcpus]Vcpu = @splat(.{}) };
pub const Error = error{ NoVms, OutOfFrames, NotHost };
pub const CpuOnError = error{ NoSuchVcpu, AlreadyOn };

pub fn isHost() bool {
    return false;
}

pub fn create(owner: *anyopaque, kobj: *kalloc.Account, user_mem: *kalloc.Account, pages: u64, nvcpus: u64) Error!*Vm {
    _ = .{ owner, kobj, user_mem, pages, nvcpus };
    return Error.NotHost;
}

pub fn attachDevice(vm: *Vm, idx: u64, bar_ipa: u64, vintid: u32) Error!void {
    _ = .{ vm, idx, bar_ipa, vintid };
    return Error.NotHost;
}

pub fn injectSpi(token: *anyopaque, vintid: u32) void {
    _ = .{ token, vintid };
}

pub fn tick() void {}

pub fn destroy(vm: *Vm) void {
    _ = vm;
}

pub fn byIndex(idx: u64) ?*Vm {
    _ = idx;
    return null;
}

pub fn indexOf(vm: *Vm) u64 {
    _ = vm;
    return 0;
}

pub fn run(vm: *Vm, vcpu: u64, resume_value: u64) Exit {
    _ = .{ vm, vcpu, resume_value };
    return .{};
}

pub fn vcpuOn(vm: *Vm, idx: u64, entry: u64, ctx: u64) CpuOnError!void {
    _ = .{ vm, idx, entry, ctx };
    return CpuOnError.NoSuchVcpu;
}
