//! What the port does not have yet, named honestly: each answers
//! "nothing here" where the generic kernel can carry on, and panics
//! where it cannot.

const log = @import("../../log.zig");

pub const intc = struct {
    pub const line_base: u32 = 32;
    pub const line_count: u32 = 224;
    pub const spurious: u32 = 0xff;
    pub fn initCore(cpu: u32) void {
        _ = cpu;
    }
    pub fn enableLine(intid: u32) void {
        _ = intid;
        @panic("x86_64: interrupt lines are a later stage");
    }
    pub fn disableLine(intid: u32) void {
        _ = intid;
    }
    pub fn configureEdge(intid: u32) void {
        _ = intid;
    }
    pub fn kick(cpu: u32) void {
        _ = cpu;
    }
    pub fn acknowledge() u32 {
        return spurious;
    }
    pub fn endOfInterrupt(intid: u32) void {
        _ = intid;
    }
    pub const LineState = struct { enabled: bool, pending: bool, active: bool };
    pub fn lineState(intid: u32) LineState {
        _ = intid;
        return .{ .enabled = false, .pending = false, .active = false };
    }
};

pub const msi = struct {
    pub const base: u32 = 256;
    pub const count: u32 = 64;
    pub inline fn isActive() bool {
        return false;
    }
    pub fn route(device_id: u32) ?u32 {
        _ = device_id;
        return null;
    }
    pub fn doorbellPage() u64 {
        return 0;
    }
    pub fn translater() u64 {
        return 0;
    }
};

pub const timer = struct {
    pub var intid: u32 = 0xf0;
    pub fn initCore(cpu: u32) void {
        if (cpu == 0) log.warn("x86_64: no tick yet (stage 1); nothing preempts", .{});
    }
    pub fn rearm() void {}
};

pub const iommu = struct {
    pub var active = false;
    pub var fault_count: u64 = 0;
    pub var last_fault_type: u32 = 0;
    pub var last_fault_sid: u32 = 0;
    pub var last_fault_addr: u64 = 0;
    pub var first_fault_addr: u64 = 0;
    pub fn attach(idx: u64, root: u64, asid: u16, who: *anyopaque) void {
        _ = .{ idx, root, asid, who };
    }
    pub fn attachStage2(idx: u64, s2_root: u64, vmid: u16, who: *anyopaque) void {
        _ = .{ idx, s2_root, vmid, who };
    }
    pub fn detachStage2(idx: u64, vmid: u16, who: *anyopaque) void {
        _ = .{ idx, vmid, who };
    }
    pub fn detachIfHolder(idx: u64, who: *anyopaque, asid: u16) void {
        _ = .{ idx, who, asid };
    }
    pub fn invalidateAsid(asid: u16) void {
        _ = asid;
    }
    pub fn handleIrq(intid: u32) bool {
        _ = intid;
        return false;
    }
};
