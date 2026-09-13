//! Text-file IO through an explicitly granted directory view. No ambient paths.
//! Saves stage a sibling with O_EXCL, flush its contents, then use the service's
//! atomic rename-replace and durability barrier. The destination is never opened
//! for writing or truncated. An unsuccessful final barrier is explicitly uncertain.
const std = @import("std");
const shared = @import("shared");
const fs = @import("fsclient.zig");
const usys = @import("usys.zig");

pub const max_bytes = 256 * 1024;
pub const max_path = 256;
pub const Error = error{
    BadPath,
    NotFound,
    ReadOnly,
    NoSpace,
    NotText,
    TooLarge,
    NotFile,
    Unavailable,
    TemporaryFileBusy,
    CommitUncertain,
};

pub fn message(err: Error) []const u8 {
    return switch (err) {
        error.BadPath => "Use a relative path within this folder.",
        error.NotFound => "The file or its folder was not found.",
        error.ReadOnly => "This folder is read-only.",
        error.NoSpace => "There is not enough space to save this file.",
        error.NotText => "This file is not valid UTF-8 text.",
        error.TooLarge => "The editor supports files up to 256 KB.",
        error.NotFile => "Choose a regular file, not a folder or symbolic link.",
        error.Unavailable => "The filesystem is unavailable. Your edits are still here.",
        error.TemporaryFileBusy => "Unable to reserve a temporary file. Try saving again.",
        error.CommitUncertain => "The file was replaced, but its disk flush failed. Keep your edits and retry.",
    };
}

fn convert(err: shared.FsErr) Error {
    return switch (err) {
        .denied => error.ReadOnly,
        .not_found => error.NotFound,
        .no_space => error.NoSpace,
        .bad_path => error.BadPath,
        .exists => error.TemporaryFileBusy,
        else => error.Unavailable,
    };
}

/// Reject empty/absolute paths, traversal, control bytes and oversized names.
/// The view service independently resolves intermediate symlinks within its root.
pub fn validatePath(path: []const u8) Error!void {
    if (path.len == 0 or path.len > max_path or !std.unicode.utf8ValidateSlice(path)) return error.BadPath;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return error.BadPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 56 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.BadPath;
    }
}

pub fn validateText(data: []const u8) Error!void {
    if (data.len > max_bytes) return error.TooLarge;
    if (std.mem.indexOfScalar(u8, data, 0) != null or !std.unicode.utf8ValidateSlice(data)) return error.NotText;
}

/// `dst` is scratch storage: failure can alter it, so only replace the document
/// after success. `buf` is this view's attached fs_buf_pages shared buffer.
pub fn load(chan: u64, buf: [*]u8, path: []const u8, dst: []u8) Error![]const u8 {
    try validatePath(path);
    if (chan == 0) return error.Unavailable;
    const st = switch (fs.fsStatR(chan, buf, path)) {
        .ok => |value| value,
        .err => |err| return convert(err),
    };
    if (st.typ != @intFromEnum(shared.FsType.file)) return error.NotFile;
    if (st.size > @min(dst.len, max_bytes)) return error.TooLarge;
    const fd = switch (fs.fsOpen(chan, buf, path, 0)) {
        .fd => |value| value,
        .err => |err| return convert(err),
    };
    defer fs.fsClose(chan, fd);
    const capacity = @min(dst.len, max_bytes);
    var off: usize = 0;
    while (true) {
        // Probe one byte beyond capacity to catch growth after stat as well.
        const want = @min(shared.fs_max_io, capacity - off + 1);
        const n = fs.fsReadAt(chan, fd, off, want) orelse return error.Unavailable;
        if (n > want) return error.Unavailable;
        if (n == 0) break;
        if (n > capacity - off) return error.TooLarge;
        @memcpy(dst[off .. off + n], buf[0..n]);
        off += n;
    }
    try validateText(dst[0..off]);
    return dst[0..off];
}

/// On success the replacement is durable. On any failure keep the document
/// dirty. CommitUncertain means replacement succeeded but durability is unknown.
/// A crashed process may leave a .medit-* staging file; we never adopt or delete
/// another process's staging file. Save As overwrite confirmation belongs to UI.
pub fn save(chan: u64, buf: [*]u8, path: []const u8, data: []const u8) Error!void {
    try validatePath(path);
    try validateText(data);
    if (chan == 0) return error.Unavailable;
    const volume = fs.fsStatfs(chan) orelse return error.Unavailable;
    if (volume.read_only) return error.ReadOnly;
    switch (fs.fsStatR(chan, buf, path)) {
        .ok => |st| if (st.typ != @intFromEnum(shared.FsType.file)) return error.NotFile,
        .err => |err| if (err != .not_found) return convert(err),
    }
    const parent_len = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| slash + 1 else 0;
    var temporary: [max_path]u8 = undefined;
    @memcpy(temporary[0..parent_len], path[0..parent_len]);
    const token = usys.cycles();
    var fd: u64 = 0;
    var temp: []const u8 = undefined;
    for (0..16) |attempt| {
        const suffix = std.fmt.bufPrint(temporary[parent_len..], ".medit-{x}-{x}", .{ token, attempt }) catch return error.BadPath;
        temp = temporary[0 .. parent_len + suffix.len];
        switch (fs.fsOpen(chan, buf, temp, 3)) {
            .fd => |value| {
                fd = value;
                break;
            },
            .err => |err| if (err != .exists) return convert(err),
        }
    } else return error.TemporaryFileBusy;
    defer fs.fsClose(chan, fd);
    var replaced = false;
    defer if (!replaced) {
        _ = fs.fsDelete(chan, buf, temp);
    };
    var off: usize = 0;
    while (off < data.len) {
        const end = @min(data.len, off + shared.fs_max_io);
        @memcpy(buf[0 .. end - off], data[off..end]);
        switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{ .write = .{ .fd = fd, .off = off, .len = end - off } }, 0)) {
            .ok => |rep| switch (rep) {
                .num => |written| if (written.n != end - off) return error.Unavailable,
                .fs_err => |err| return convert(std.enums.fromInt(shared.FsErr, err.code) orelse .io),
                else => return error.Unavailable,
            },
            .err => return error.Unavailable,
        }
        off = end;
    }
    switch (fs.fsSyncR(chan)) {
        .ok => {},
        .err => |err| return convert(err),
    }
    switch (fs.fsRenameR(chan, buf, temp, path)) {
        .ok => replaced = true,
        .err => |err| return convert(err),
    }
    switch (fs.fsSyncR(chan)) {
        .ok => {},
        .err => return error.CommitUncertain,
    }
}

test "editor file paths stay relative and text stays valid" {
    try validatePath("notes/hello world.txt");
    try validatePath("日記.txt");
    try std.testing.expectError(error.BadPath, validatePath(&([_]u8{'a'} ** 57)));
    for ([_][]const u8{ "", "/home/note", "../note", "notes/../note", "notes/./note", "notes//note", "notes/", "a\x00b", "a\nb", "\xff" }) |path| {
        try std.testing.expectError(error.BadPath, validatePath(path));
    }
    try validateText("Hello, 世界\n");
    try validateText("");
    try std.testing.expectError(error.NotText, validateText("a\x00b"));
    try std.testing.expectError(error.NotText, validateText("\xc0\x80"));
    try std.testing.expectError(error.NotText, validateText("\xf0\x9f"));
    try std.testing.expectError(error.TooLarge, validateText(&([_]u8{'a'} ** (max_bytes + 1))));
}
