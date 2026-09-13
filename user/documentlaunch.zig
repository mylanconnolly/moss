//! Files-to-Editor handoff. The selected parent view goes only to the broker;
//! the Editor receives a selected-document endpoint, never directory access.
const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const fs = @import("fsclient.zig");
const Document = @import("document.zig").Client;
var picker: u64 = 0;
var supervisor: u64 = 0;
var display: u64 = 0;
pub fn setup(p: u64, init: u64, screen: u64) void {
    picker = p;
    supervisor = init;
    display = screen;
}
fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.NotText => "This file is not UTF-8 text.",
        error.FileTooLarge => "This file is too large for Editor (256 KiB maximum).",
        error.FileNotFound => "This file is no longer available.",
        error.NotFile => "Choose a regular text file.",
        error.OutOfMemory, error.DocumentBusy => "Not enough resources to open another document. Close a tab and try again.",
        else => "The document could not be opened. Your files have not changed.",
    };
}
pub fn open(chan: u64, buf: [*]u8, path: []const u8) ?[]const u8 {
    if (picker == 0 or supervisor == 0) return "Opening in Editor is unavailable in this session.";
    if (path.len == 0 or path.len > 256) return "Choose a file within this view.";
    const cut = std.mem.lastIndexOfScalar(u8, path, '/');
    const parent = if (cut) |i| path[0..i] else "";
    const name = if (cut) |i| path[i + 1 ..] else path;
    if (name.len == 0) return "Choose a regular text file.";
    // Derivation preserves inherited read-only and revocation restrictions.
    // Its independent buffer also prevents interference with Files' listing.
    const selected_view = fs.fsDerive(chan, buf, parent, false) orelse return "This folder is no longer available.";
    defer _ = usys.capDrop(selected_view);
    var sender = Document.init(picker) catch |e| return message(e);
    defer sender.deinit();
    const ticket = sender.offer(selected_view, name) catch |e| return message(e);
    var committed = false;
    defer if (!committed) sender.cancelOffer(ticket);
    const name_words = shared.strToWords("medit");
    const launched = switch (usys.callTypedCap(shared.InitRequest, shared.InitReply, supervisor, .{ .connect_named = .{ .a = name_words[0], .b = name_words[1] } }, 0)) {
        .ok => |r| blk: {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            break :blk r.rep == .connected;
        },
        .err => false,
    };
    if (!launched) return "Editor could not start. Close an application and try again.";
    sender.enqueue(ticket) catch |e| return message(e);
    committed = true;
    if (display != 0) {
        const title = shared.strToWords("Editor");
        _ = usys.callTyped(shared.GpuReq, shared.GpuResp, display, .{ .restore_titled = .{ .a = title[0], .b = title[1] } }, 0);
    }
    return null;
}
