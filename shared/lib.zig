//! Cross-boundary ABI and protocol types shared by the kernel, userspace,
//! host-side tests, and (eventually) MCU leaf nodes. This module is the IDL:
//! everything here must compile identically for every target, so it may not
//! import kernel or userspace code and may not allocate.

const std = @import("std");

pub const version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 };

/// Generational handle: the only form in which kernel object identity crosses
/// the ABI. Slot indexes a domain's cap table; the generation is bumped on
/// slot reuse so a stale handle can never resurrect authority. 40 bits of
/// generation means a slot reused once per microsecond takes ~35 years to
/// wrap.
pub const Handle = packed struct(u64) {
    slot: u24,
    generation: u40,

    pub const invalid: Handle = .{ .slot = 0, .generation = 0 };

    pub fn eql(a: Handle, b: Handle) bool {
        return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
    }
};

/// Syscall numbers, passed in x8; arguments in x0..x5, result in x0.
/// IPC calls additionally return message words in x1..x4 and a received cap
/// handle (or 0) in x5.
pub const Syscall = enum(u64) {
    log = 1,
    yield = 2,
    sleep = 3,
    exit = 4,
    /// call(channel, w0..w3, cap) -> reply w0..w3, cap
    call = 5,
    /// recv(channel) -> msg w0..w3, cap
    recv = 6,
    /// reply(channel, w0..w3, cap)
    reply = 7,
    notify_create = 8,
    notify_signal = 9,
    /// notify_wait(notification) -> x1 = accumulated bits (cleared)
    notify_wait = 10,
    /// shm_create(pages) -> x1 = handle
    shm_create = 11,
    /// shm_map(handle) -> x1 = va
    shm_map = 12,
    /// spawn(spawner, image, arg, chan, flags) -> x1 = domain_ctl handle
    spawn = 13,
    /// chan_create() -> x1 = side A handle, x2 = side B handle
    chan_create = 14,
    /// domain_stat(ctl) -> x1 = DomainState, x2 = exit code
    domain_stat = 15,
    /// domain_destroy(ctl) — the one revocation
    domain_destroy = 16,
    /// watch_deaths(notification): deaths of domains this domain spawns are
    /// signaled here; also binds the calling thread so a signal interrupts
    /// its blocked recv (Errno.interrupted)
    watch_deaths = 17,
    /// cap_drop(handle): release one capability
    cap_drop = 18,
    _,
};

pub const SpawnFlags = struct {
    pub const grant_log: u64 = 1 << 0;
    pub const grant_spawner: u64 = 1 << 1;
    /// Grant the A (serving) side of the channel in x3 instead of B.
    pub const chan_side_a: u64 = 1 << 2;
};

/// Domain lifecycle as reported by domain_stat.
pub const DomainState = enum(u64) {
    alive = 0,
    dying = 1,
    dead = 2,
};

/// Syscall results: 0 is success, anything else is one of these.
pub const Errno = enum(u64) {
    ok = 0,
    bad_handle = 1,
    denied = 2,
    fault = 3,
    bad_arg = 4,
    nosys = 5,
    /// The other end of the channel is gone. In-flight operations complete
    /// with this — a blocked call returns it the moment the peer dies.
    peer_dead = 6,
    busy = 7,
    bad_state = 8,
    no_space = 9,
    /// A bound notification fired while this thread was blocked in recv;
    /// drain it with notify_wait, then resume receiving.
    interrupted = 10,
    _,
};

/// Images the kernel can spawn, indexed into its embedded blob table until
/// a filesystem exists (Phase 9). Order must match the kernel's table.
pub const ImageId = enum(u64) {
    hello = 0,
    pingpong = 1,
    root = 2,
    init = 3,
    services = 4,
    sandbox = 5,
};

/// Services init knows how to activate. Discovery is by protocol id over
/// init's channel — never by global name.
pub const ServiceId = enum(u64) {
    logsvc = 0,
    greeter = 1,
};

/// Encode a message union into the four IPC data words: word 0 is the tag,
/// words 1..3 the payload fields (u64s, at most three). This is the seed of
/// the comptime IDL: protocol types written once here compile identically
/// into both sides' stubs.
pub fn encodeMsg(comptime T: type, val: T) [4]u64 {
    var out: [4]u64 = @splat(0);
    out[0] = @intFromEnum(val);
    switch (val) {
        inline else => |payload| {
            const P = @TypeOf(payload);
            if (P != void) {
                const fields = @typeInfo(P).@"struct".fields;
                comptime std.debug.assert(fields.len <= 3);
                comptime var i = 1;
                inline for (fields) |f| {
                    comptime std.debug.assert(f.type == u64);
                    out[i] = @field(payload, f.name);
                    i += 1;
                }
            }
        },
    }
    return out;
}

pub fn decodeMsg(comptime T: type, words: [4]u64) ?T {
    const Tag = @typeInfo(T).@"union".tag_type.?;
    const tag = std.enums.fromInt(Tag, words[0]) orelse return null;
    switch (tag) {
        inline else => |t| {
            const P = @FieldType(T, @tagName(t));
            if (P == void) return @unionInit(T, @tagName(t), {});
            var p: P = undefined;
            comptime var i = 1;
            inline for (@typeInfo(P).@"struct".fields) |f| {
                @field(p, f.name) = words[i];
                i += 1;
            }
            return @unionInit(T, @tagName(t), p);
        },
    }
}

/// The first typed protocol: a trivial calculator, used by the Phase 4
/// demo. A request may carry a shared-memory cap with a greeting.
pub const CalcRequest = union(enum(u64)) {
    add: struct { a: u64, b: u64 },
    greet: void,
};

pub const CalcReply = union(enum(u64)) {
    sum: struct { value: u64 },
    hi: void,
};

/// Fault messages delivered to a supervisor channel (fault-as-message).
pub const FaultMsg = union(enum(u64)) {
    fault: struct { esr: u64, far: u64, elr: u64 },
};

/// Init's front-channel protocol: ask to be connected to a service; the
/// reply attaches a fresh channel-B cap for it.
pub const InitRequest = union(enum(u64)) {
    connect: struct { service: u64 },
};

pub const InitReply = union(enum(u64)) {
    connected: void,
    failed: struct { err: u64 },
};

/// The logging service protocol: 24 bytes of text packed into the words.
pub const LogMsg = union(enum(u64)) {
    text: struct { a: u64, b: u64, c: u64 },
};

/// One-time configuration a spawner sends a proxy before it starts serving:
/// the upstream channel cap rides as the attachment.
pub const ProxyCfg = union(enum(u64)) {
    upstream: void,
};

pub const ProxyCfgReply = union(enum(u64)) {
    ok: void,
};

pub const LogReply = union(enum(u64)) {
    ok: void,
};

/// Pack a short string into three message words (nul-padded, max 24 bytes).
pub fn strToWords(s: []const u8) [3]u64 {
    var bytes: [24]u8 = @splat(0);
    const n = @min(s.len, 24);
    @memcpy(bytes[0..n], s[0..n]);
    return .{
        std.mem.readInt(u64, bytes[0..8], .little),
        std.mem.readInt(u64, bytes[8..16], .little),
        std.mem.readInt(u64, bytes[16..24], .little),
    };
}

/// Unpack; returns the slice up to the first nul within `buf`.
pub fn wordsToStr(buf: *[24]u8, w: [3]u64) []const u8 {
    std.mem.writeInt(u64, buf[0..8], w[0], .little);
    std.mem.writeInt(u64, buf[8..16], w[1], .little);
    std.mem.writeInt(u64, buf[16..24], w[2], .little);
    var n: usize = 0;
    while (n < 24 and buf[n] != 0) n += 1;
    return buf[0..n];
}

/// Header at the start of a flat user image ("MOSS" magic). Written by the
/// user program's entry assembly from linker-script symbols; read by the
/// kernel loader. All sizes are from the image base, 4K-aligned.
pub const UserImageHeader = extern struct {
    magic: u32,
    version: u32,
    text_size: u64,
    load_size: u64,
    mem_size: u64,

    pub const expected_magic: u32 = 0x53534f4d; // "MOSS" little-endian
};

/// Entry convention for user programs: x0 holds the debug-log capability
/// handle (as bits), or 0 when the manifest granted none.
pub const user_image_base: u64 = 0x40_0000;

test "typed messages round-trip through the four data words" {
    const req: CalcRequest = .{ .add = .{ .a = 17, .b = 25 } };
    const words = encodeMsg(CalcRequest, req);
    const back = decodeMsg(CalcRequest, words) orelse return error.DecodeFailed;
    try std.testing.expectEqual(req, back);

    const greet = encodeMsg(CalcRequest, .greet);
    try std.testing.expectEqual(CalcRequest.greet, decodeMsg(CalcRequest, greet).?);

    // A junk tag decodes to null, never to a wrong message.
    try std.testing.expectEqual(@as(?CalcRequest, null), decodeMsg(CalcRequest, .{ 99, 0, 0, 0 }));
}

test "strings round-trip through message words" {
    const w = strToWords("worker msg 7");
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("worker msg 7", wordsToStr(&buf, w));
    const empty = strToWords("");
    try std.testing.expectEqualStrings("", wordsToStr(&buf, empty));
}

test "handle round-trips through its integer representation" {
    const h: Handle = .{ .slot = 7, .generation = 42 };
    const bits: u64 = @bitCast(h);
    const back: Handle = @bitCast(bits);
    try std.testing.expect(h.eql(back));
    try std.testing.expect(!h.eql(Handle.invalid));
}
