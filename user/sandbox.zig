//! Phase 6 sandbox demo, personality by x2:
//!   1 "parent"    — builds the sandbox: a real log service, a
//!                   filter+audit proxy in front of it, and a child that
//!                   only ever sees the proxy. Also nests: the child gets a
//!                   spawner and a budget slice.
//!   2 "steadylog" — the real service (LogMsg, never crashes).
//!   3 "proxy"     — interposition: audits every request, redacts any text
//!                   containing "secret", forwards upstream. The child
//!                   holds an ordinary channel cap; nothing distinguishes
//!                   the proxy from the real thing.
//!   4 "child"     — sandboxed: one channel cap, a spawner, a budget slice,
//!                   no debug log. Logs innocently (including a secret),
//!                   spawns a grandchild from its slice, then idles until
//!                   revoked.
//!   5 "sleeper"   — the grandchild: proof that revoking the parent
//!                   reclaims even the deepest leaf. Holds nothing, sleeps
//!                   forever.

const shared = @import("shared");
const usys = @import("usys.zig");
const loader = @import("loader.zig");

comptime {
    asm (usys.imageHeader("sandbox"));
}

pub const panic = @import("std").debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

// With no debug_log grant, the channel lands at slot 0 and the spawner at
// slot 1; with debug_log, log=0/channel=1/spawner=2. Insert order is fixed
// in domain.spawn.
const spawner_with_log: u64 = @bitCast(shared.Handle{ .slot = 1, .generation = 1 });
const spawner_no_log: u64 = @bitCast(shared.Handle{ .slot = 1, .generation = 1 });

// Roles that spawn hold the boot archive (x3/x4) and stage images from it.
var boot_va: u64 = 0;
var boot_len: u64 = 0;
var stage: loader.Stage = undefined;

fn stageImage() u64 {
    if (!stage.load(boot_va, boot_len, .sandbox)) usys.exit(170);
    return stage.handle;
}

export fn umain(log_h: u64, chan_h: u64, role: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    boot_va = blob_va;
    boot_len = blob_len;
    if (role == 1 or role == 4) {
        stage = loader.Stage.init(loader.Stage.default_pages) orelse usys.exit(171);
    }
    switch (role) {
        1 => parent(log_h),
        2 => steadylog(log_h, chan_h),
        3 => proxy(log_h, chan_h),
        4 => child(chan_h),
        5 => sleeper(),
        else => usys.exit(250),
    }
}

fn parent(log_h: u64) noreturn {
    _ = usys.log(log_h, "parent: assembling the sandbox");

    // The real service.
    const chan_l = usys.chanCreate();
    if (chan_l.err != .ok) usys.exit(140);
    if (usys.spawn(spawner_with_log, stageImage(), 2, chan_l.data[0], shared.SpawnFlags.grant_log |
        shared.SpawnFlags.chan_side_a, usys.kbLimits(512, 2 << 10)).err != .ok) usys.exit(141);
    _ = usys.capDrop(chan_l.data[0]); // service owns its serving side alone

    // The proxy, configured with the upstream cap over its own channel.
    const chan_p = usys.chanCreate();
    if (chan_p.err != .ok) usys.exit(142);
    if (usys.spawn(spawner_with_log, stageImage(), 3, chan_p.data[0], shared.SpawnFlags.grant_log |
        shared.SpawnFlags.chan_side_a, usys.kbLimits(512, 2 << 10)).err != .ok) usys.exit(143);
    _ = usys.capDrop(chan_p.data[0]);
    switch (usys.callTyped(shared.ProxyCfg, shared.ProxyCfgReply, chan_p.data[1], .upstream, chan_l.data[1])) {
        .ok => {},
        .err => usys.exit(144),
    }

    // The child sees exactly one thing: the proxy's channel. It could not
    // name the real service if it tried — there is no name to use.
    // The child gets the archive too: its nested spawn stages from it.
    if (usys.spawn(spawner_with_log, stageImage(), 4, chan_p.data[1], shared.SpawnFlags.grant_spawner |
        shared.SpawnFlags.grant_bootfs, usys.kbLimits(512, 3 << 10)).err != .ok) usys.exit(145);
    _ = usys.log(log_h, "parent: sandbox live (real svc + proxy + child); awaiting revocation");

    while (true) usys.sleep(100);
}

fn steadylog(log_h: u64, chan_h: u64) noreturn {
    var buf: [24]u8 = undefined;
    var line: [64]u8 = undefined;
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err != .ok) usys.exit(0);
        const msg = shared.decodeMsg(shared.LogMsg, r.data) orelse continue;
        switch (msg) {
            .text => |t| {
                const text = shared.wordsToStr(&buf, .{ t.a, t.b, t.c });
                _ = usys.log(log_h, cat(&line, "steadylog: ", text));
                _ = usys.replyTyped(shared.LogReply, chan_h, .ok, 0);
            },
        }
    }
}

fn proxy(log_h: u64, chan_h: u64) noreturn {
    // First message is configuration: the upstream channel cap.
    var upstream: u64 = 0;
    {
        const r = usys.recvMsg(chan_h);
        if (r.err != .ok or r.cap == 0) usys.exit(150);
        upstream = r.cap;
        _ = usys.replyTyped(shared.ProxyCfgReply, chan_h, .ok, 0);
    }

    var buf: [24]u8 = undefined;
    var line: [64]u8 = undefined;
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err != .ok) usys.exit(0);
        const msg = shared.decodeMsg(shared.LogMsg, r.data) orelse continue;
        switch (msg) {
            .text => |t| {
                const text = shared.wordsToStr(&buf, .{ t.a, t.b, t.c });
                // Audit: everything the child does is on the record.
                _ = usys.log(log_h, cat(&line, "proxy audit: ", text));
                // Filter: redact before it ever reaches the real service.
                const w = if (contains(text, "secret"))
                    shared.strToWords("[redacted]")
                else
                    [3]u64{ t.a, t.b, t.c };
                _ = usys.callTyped(shared.LogMsg, shared.LogReply, upstream, .{
                    .text = .{ .a = w[0], .b = w[1], .c = w[2] },
                }, 0);
                _ = usys.replyTyped(shared.LogReply, chan_h, .ok, 0);
            },
        }
    }
}

fn child(log_chan: u64) noreturn {
    // Nested sandbox: a grandchild from our own budget slice, granted
    // nothing at all.
    if (usys.spawn(spawner_no_log, stageImage(), 5, 0, 0, usys.kbLimits(256, 1 << 10)).err != .ok) {
        usys.exit(160);
    }

    // Log through what we believe is the log service. (Texts fit the
    // 24-byte message payload.)
    sendText(log_chan, "child: hello sandbox");
    sendText(log_chan, "the secret code is 1234");
    sendText(log_chan, "child: all went fine");

    while (true) usys.sleep(100); // live here until the parent is revoked
}

fn sendText(chan: u64, text: []const u8) void {
    const w = shared.strToWords(text);
    switch (usys.callTyped(shared.LogMsg, shared.LogReply, chan, .{
        .text = .{ .a = w[0], .b = w[1], .c = w[2] },
    }, 0)) {
        .ok => {},
        .err => usys.exit(161),
    }
}

fn sleeper() noreturn {
    while (true) usys.sleep(100);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |c, j| {
            if (haystack[i + j] != c) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn cat(buf: []u8, prefix: []const u8, s: []const u8) []const u8 {
    var i: usize = 0;
    for (prefix) |c| {
        buf[i] = c;
        i += 1;
    }
    for (s) |c| {
        if (i == buf.len) break;
        buf[i] = c;
        i += 1;
    }
    return buf[0..i];
}
