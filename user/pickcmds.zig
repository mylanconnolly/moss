//! `save-as NAME DATA`: the Save dialog, from a script. The chooser
//! (the session's file picker) asks the user where, and the bytes go
//! there through the document endpoint it grants — the script writes
//! nothing to the home on its own. What a download is: the page domain
//! reports a resource it will not show, the app fetches it through its
//! own view of the network, and the user says where it goes.
const std = @import("std");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const Value = mshl.Value;
const usys = @import("usys.zig");
const Document = @import("document.zig").Client;

pub const command_names = [_][]const u8{"save-as"};

var picker: u64 = 0;
var log_h: u64 = 0;

pub fn setup(picker_cap: u64, log: u64) void {
    picker = picker_cap;
    log_h = log;
}

const saved_shape = blk: {
    const fields = [_]mshl.Shape.Field{ .{ .key = "bytes", .shape = .int }, .{ .key = "name", .shape = .string } };
    break :blk mshl.Shape{ .record_of = &fields };
};

const saved_result = mshl.resultShape(saved_shape, .string);

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "save-as")) return .{ .params = &.{ .{ .name = "name", .shape = .string }, .{ .name = "data" } }, .ret = saved_result };
    return null;
}

pub fn call(it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    _ = input;
    if (!std.mem.eql(u8, name, "save-as")) return null;
    if (args.len < 2 or args[0] != .str) return it.fail("save-as: a name and the data are needed", .{});
    const bytes: []const u8 = switch (args[1]) {
        .str => |s| s,
        .bytes => |b| b,
        else => return it.fail("save-as: the data must be a string or bytes", .{}),
    };
    if (picker == 0) return try it.mkResult(false, .{ .str = "save-as: this session has no file picker" });
    var doc = Document.init(picker) catch return try it.mkResult(false, .{ .str = "save-as: the picker did not answer" });
    defer doc.deinit();
    doc.name_len = @min(args[0].str.len, doc.name.len);
    @memcpy(doc.name[0..doc.name_len], args[0].str[0..doc.name_len]);
    const ok = doc.save(bytes, true) catch |e| return try it.mkResult(false, .{ .str = switch (e) {
        error.FileTooLarge => "save-as: too large for the picker (256 KiB)",
        error.NotText => "save-as: the picker saves UTF-8 text only",
        error.ReadOnly => "save-as: that place is read-only",
        error.DiskFull => "save-as: no room on the volume",
        error.SaveUncertain => "save-as: the save may not have completed",
        else => "save-as: the save was refused",
    } });
    if (!ok) return try it.mkResult(false, .{ .str = "cancelled" });
    // The name is the picker's: what the user chose in the dialog.
    const keys = try it.arena.dupe([]const u8, &.{ "bytes", "name" });
    const vals = try it.arena.dupe(Value, &.{ .{ .int = @intCast(bytes.len) }, .{ .str = try it.arena.dupe(u8, doc.title()) } });
    return try it.mkResult(true, .{ .record = .{ .keys = keys, .vals = vals } });
}
