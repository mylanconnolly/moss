//! virtio over PCI, modern transport only (VIRTIO_F_VERSION_1; no legacy
//! I/O ports, no transitional ids). The driver is handed a device cap;
//! mapping it yields the BAR that holds the virtio structures and the
//! function's PCI config page, from which the capability list says where
//! in that BAR the common configuration, the notification area, the ISR
//! byte and the device-specific configuration live. Everything a driver
//! needs from the transport is here; the virtqueues themselves stay in
//! the drivers (their layouts differ).

const shared = @import("shared");
const usys = @import("usys.zig");

const cap_msix = 0x11;
const cap_common = 1;
const cap_notify = 2;
const cap_isr = 3;
const cap_device = 4;

// Common configuration structure offsets (virtio 1.x §4.1.4.3).
const c_device_feature_select = 0;
const c_device_feature = 4;
const c_driver_feature_select = 8;
const c_driver_feature = 12;
const c_msix_config = 16;
const c_num_queues = 18;
const c_queue_msix_vector = 26;
const c_device_status = 20;
const c_queue_select = 22;
const c_queue_size = 24;
const c_queue_enable = 28;
const c_queue_notify_off = 30;
const c_queue_desc = 32;
const c_queue_driver = 40;
const c_queue_device = 48;

pub const status_ack = 1;
pub const status_driver = 2;
pub const status_driver_ok = 4;
pub const status_features_ok = 8;
pub const status_failed = 128;

/// VIRTIO_F_VERSION_1 and VIRTIO_F_ACCESS_PLATFORM in the high feature
/// word: the second is offered when the device sits behind an IOMMU and
/// must be accepted for the device to start — and it is exactly what a
/// driver wants: its DMA addresses are its own.
pub const f_version_1: u32 = 1 << 0;
pub const f_access_platform: u32 = 1 << 1;

pub const max_queues = 4;

pub const Dev = struct {
    cfg: u64, // the PCI config page
    bar: u64,
    bar_len: u64,
    bar_index: u64,
    common: u64 = 0,
    notify_base: u64 = 0,
    notify_mult: u32 = 0,
    isr: u64 = 0,
    devcfg: u64 = 0,
    notify_off: [max_queues]u16 = @splat(0),
    /// The kernel enabled MSI-X (vector 0 -> the device's LPI); the
    /// driver points the config and every queue at that vector.
    has_msix: bool = false,

    /// Map the device and locate its virtio structures; null when the
    /// cap is not a device or the device is not a modern virtio function
    /// of the expected kind.
    pub fn open(dev_h: u64, kind: shared.DeviceKind) ?Dev {
        const mm = usys.mmioMap(dev_h);
        if (mm.err != .ok) return null;
        var d: Dev = .{ .bar = mm.data[0], .bar_len = mm.data[1], .cfg = mm.data[2], .bar_index = mm.data[3] };
        if (d.cfgRead16(0) != 0x1af4) return null;
        if (d.cfgRead16(2) != 0x1040 + @intFromEnum(kind)) return null;
        var ptr: u64 = d.cfgRead8(0x34) & 0xfc;
        var guard: u32 = 0;
        while (ptr != 0 and guard < 48) : (guard += 1) {
            const id = d.cfgRead8(ptr);
            if (id == cap_msix and d.cfgRead16(ptr + 2) & 0x8000 != 0) d.has_msix = true;
            if (id == 0x09) {
                const ctype = d.cfgRead8(ptr + 3);
                const bar = d.cfgRead8(ptr + 4);
                const off = d.cfgRead32(ptr + 8);
                const len = d.cfgRead32(ptr + 12);
                if (bar == d.bar_index and off + len <= d.bar_len) {
                    switch (ctype) {
                        cap_common => d.common = d.bar + off,
                        cap_notify => {
                            d.notify_base = d.bar + off;
                            d.notify_mult = d.cfgRead32(ptr + 16);
                        },
                        cap_isr => d.isr = d.bar + off,
                        cap_device => d.devcfg = d.bar + off,
                        else => {},
                    }
                }
            }
            ptr = d.cfgRead8(ptr + 1) & 0xfc;
        }
        if (d.common == 0 or d.notify_base == 0 or d.isr == 0) return null;
        return d;
    }

    // ---- PCI configuration space
    pub fn cfgRead8(d: *const Dev, off: u64) u8 {
        return @as(*volatile u8, @ptrFromInt(d.cfg + off)).*;
    }
    pub fn cfgRead16(d: *const Dev, off: u64) u16 {
        return @as(*volatile u16, @ptrFromInt(d.cfg + off)).*;
    }
    pub fn cfgRead32(d: *const Dev, off: u64) u32 {
        return @as(*volatile u32, @ptrFromInt(d.cfg + off)).*;
    }

    // ---- common configuration
    fn c8(d: *const Dev, off: u64) *volatile u8 {
        return @ptrFromInt(d.common + off);
    }
    fn c16(d: *const Dev, off: u64) *volatile u16 {
        return @ptrFromInt(d.common + off);
    }
    fn c32(d: *const Dev, off: u64) *volatile u32 {
        return @ptrFromInt(d.common + off);
    }

    pub fn status(d: *const Dev) u8 {
        return d.c8(c_device_status).*;
    }

    pub fn setStatus(d: *const Dev, v: u8) void {
        d.c8(c_device_status).* = v;
    }

    pub fn deviceFeatures(d: *const Dev, sel: u32) u32 {
        d.c32(c_device_feature_select).* = sel;
        return d.c32(c_device_feature).*;
    }

    /// Reset, acknowledge, and negotiate: the driver accepts whatever the
    /// device offers within `lo_mask` (feature bits 0..31) and `hi_mask`
    /// (32..63); VERSION_1 is always taken, and ACCESS_PLATFORM whenever
    /// offered. Returns the accepted features, or null when the device
    /// refuses the set.
    pub fn negotiate(d: *const Dev, lo_mask: u32, hi_mask: u32) ?struct { lo: u32, hi: u32 } {
        d.setStatus(0);
        while (d.status() != 0) {}
        d.setStatus(status_ack);
        d.setStatus(status_ack | status_driver);
        const lo = d.deviceFeatures(0) & lo_mask;
        const offered_hi = d.deviceFeatures(1);
        var hi = (offered_hi & hi_mask) | f_version_1;
        if (offered_hi & f_access_platform != 0) hi |= f_access_platform;
        d.c32(c_driver_feature_select).* = 0;
        d.c32(c_driver_feature).* = lo;
        d.c32(c_driver_feature_select).* = 1;
        d.c32(c_driver_feature).* = hi;
        d.setStatus(status_ack | status_driver | status_features_ok);
        if (d.status() & status_features_ok == 0) return null;
        if (d.has_msix) d.c16(c_msix_config).* = 0;
        return .{ .lo = lo, .hi = hi };
    }

    pub fn driverOk(d: *const Dev) void {
        d.setStatus(status_ack | status_driver | status_features_ok | status_driver_ok);
    }

    /// Program one virtqueue (split ring at the given device addresses)
    /// and enable it. False when the device's queue is too small.
    pub fn queueSetup(d: *Dev, idx: u16, size: u16, desc: u64, driver: u64, device: u64) bool {
        if (idx >= max_queues) return false;
        d.c16(c_queue_select).* = idx;
        if (d.c16(c_queue_size).* < size) return false;
        d.c16(c_queue_size).* = size;
        d.c32(c_queue_desc).* = @truncate(desc);
        d.c32(c_queue_desc + 4).* = @truncate(desc >> 32);
        d.c32(c_queue_driver).* = @truncate(driver);
        d.c32(c_queue_driver + 4).* = @truncate(driver >> 32);
        d.c32(c_queue_device).* = @truncate(device);
        d.c32(c_queue_device + 4).* = @truncate(device >> 32);
        d.notify_off[idx] = d.c16(c_queue_notify_off).*;
        if (d.has_msix) d.c16(c_queue_msix_vector).* = 0;
        d.c16(c_queue_enable).* = 1;
        return true;
    }

    /// Ring the device's doorbell for queue `idx`.
    pub fn notify(d: *const Dev, idx: u16) void {
        const addr = d.notify_base + @as(u64, d.notify_off[idx]) * d.notify_mult;
        @as(*volatile u16, @ptrFromInt(addr)).* = idx;
    }

    /// Read-and-clear the ISR status byte; reading it also deasserts INTx.
    pub fn isrRead(d: *const Dev) u8 {
        return @as(*volatile u8, @ptrFromInt(d.isr)).*;
    }

    // ---- device-specific configuration
    pub fn devRead32(d: *const Dev, off: u64) u32 {
        return @as(*volatile u32, @ptrFromInt(d.devcfg + off)).*;
    }
    pub fn devRead8(d: *const Dev, off: u64) u8 {
        return @as(*volatile u8, @ptrFromInt(d.devcfg + off)).*;
    }
};
