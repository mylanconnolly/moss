//! The fabric for mshl hosts that hold a fabric channel: `remote NODE
//! FN` runs a function's body on another node as a pipeline stage. The
//! fabric spawns `mshrun` there (its remote-stage role), the host
//! attaches a buffer to the channel it gets back — which the fabric
//! proxies as a session buffer, so bytes cross the wire — writes the
//! function's source and the pipeline input as a data literal, and
//! reads the value back the same way. The remote stage sees `$in` and
//! nothing else of the caller: no captures, no files, no network, no
//! caps beyond a log; it is pure computation placed elsewhere. Every
//! outcome the fabric decides is a result.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const Value = mshl.Value;

pub const Fab = struct {
    chan: u64,
};

fn errResult(it: *mshl.Interp, msg: []const u8) mshl.Error!Value {
    const r = try it.arena.create(mshl.Result);
    r.* = .{ .ok = false, .val = .{ .str = msg } };
    return .{ .result = r };
}

fn okResult(it: *mshl.Interp, v: Value) mshl.Error!Value {
    const r = try it.arena.create(mshl.Result);
    r.* = .{ .ok = true, .val = v };
    return .{ .result = r };
}

fn fabErrName(code: u64) []const u8 {
    return switch (code) {
        @intFromEnum(shared.FabErr.no_peer) => "no such member",
        @intFromEnum(shared.FabErr.timeout) => "timed out",
        @intFromEnum(shared.FabErr.disconnected) => "disconnected",
        @intFromEnum(shared.FabErr.refused) => "refused",
        @intFromEnum(shared.FabErr.no_space) => "the fabric's tables are full",
        @intFromEnum(shared.FabErr.no_identity) => "this node has no identity",
        @intFromEnum(shared.FabErr.no_entropy) => "no entropy yet",
        @intFromEnum(shared.FabErr.denied) => "denied: this node's certificate does not allow it",
        else => "fabric error",
    };
}

/// null = not a fabric command.
pub fn call(f: *Fab, it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    if (!std.mem.eql(u8, name, "remote")) return null;
    if (args.len != 2 or args[0] != .int or args[0].int < 0) return it.fail("remote: NODE FUNCTION expected", .{});
    const node: u64 = @intCast(args[0].int);
    const script: []const u8 = switch (args[1]) {
        .func => |cl| cl.src,
        .str => |t| t,
        else => return it.fail("remote: a function or script text expected, got a {s}", .{args[1].typeName()}),
    };
    const in_val = input orelse .nothing;
    if (!in_val.isData()) return it.fail("remote: the input is a {s}, which cannot cross the wire (only data can)", .{in_val.typeName()});
    var in_text: std.ArrayList(u8) = .empty;
    if (in_val != .nothing) try mshl.writeData(in_val, it.arena, &in_text);
    const room = shared.fab_bulk_pages * 4096;
    if (script.len + in_text.items.len > room) return it.fail("remote: script and input exceed the {d}-byte buffer", .{room});

    // A stage on that node: mshrun in its remote role, behind a channel.
    const sess = switch (usys.callTypedCap(shared.FabReq, shared.FabResp, f.chan, .{ .remote_spawn = .{ .node = node, .image = @intFromEnum(shared.ImageId.mshrun), .arg = 1 } }, 0)) {
        .ok => |r| switch (r.rep) {
            .spawned => r.cap,
            .fab_err => |e| return try errResult(it, fabErrName(e.code)),
            else => return it.fail("remote: unexpected reply from the fabric", .{}),
        },
        .err => return it.fail("remote: the fabric did not answer", .{}),
    };
    defer _ = usys.capDrop(sess); // the stage's channel dies with this
    if (sess == 0) return try errResult(it, "the fabric handed back no channel");

    // The buffer: ours here, a twin there, kept alike by the fabric.
    const sh = usys.shmCreate(shared.fab_bulk_pages);
    if (sh.err != .ok) return it.fail("remote: out of shared memory", .{});
    defer _ = usys.capDrop(sh.data[0]);
    const m = usys.shmMap(sh.data[0]);
    if (m.err != .ok) return it.fail("remote: cannot map the buffer", .{});
    defer _ = usys.shmUnmap(m.data[0]);
    const buf: [*]u8 = @ptrFromInt(m.data[0]);
    switch (usys.callTyped(shared.RunReq, shared.RunResp, sess, .attach_buf, sh.data[0])) {
        .ok => |rep| if (rep != .ok) return try errResult(it, "the remote stage refused the buffer"),
        .err => return try errResult(it, "the remote stage did not take the buffer"),
    }
    @memcpy(buf[0..script.len], script);
    @memcpy(buf[script.len .. script.len + in_text.items.len], in_text.items);
    switch (usys.callTyped(shared.RunReq, shared.RunResp, sess, .{ .run = .{ .script_len = script.len, .input_len = in_text.items.len } }, 0)) {
        .ok => |rep| switch (rep) {
            .value => |v| {
                if (v.len == 0) return try okResult(it, .nothing);
                if (v.len > room) return try errResult(it, "the remote value overran the buffer");
                const text = try it.arena.dupe(u8, buf[0..v.len]);
                return try okResult(it, try mshl.tableize(it.arena, try it.parseData(text)));
            },
            .failed => |e| return try errResult(it, try it.arena.dupe(u8, buf[0..@min(e.len, room)])),
            .refused => return try errResult(it, "the remote stage refused"),
            .ok => return try okResult(it, .nothing),
        },
        .err => return try errResult(it, "the remote stage vanished (the call failed)"),
    }
}

pub const command_names = [_][]const u8{"remote"};
