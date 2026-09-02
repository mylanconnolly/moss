//! Boot-archive packer (build-time host tool): `mkmarc OUT ENTRY...` where
//! each ENTRY is `<archive path>=<host file>`. Emits a MARC archive:
//! "MARC" then { path_len u32 LE, data_len u32 LE, path, data } per entry.
//! The kernel embeds exactly this one blob; every program image is an
//! `img/<name>` entry in it.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.arena.allocator();
    var args: std.ArrayList([]const u8) = .empty;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |a| try args.append(gpa, try gpa.dupe(u8, a));
    if (args.items.len < 2) {
        std.debug.print("usage: mkmarc OUT path=file...\n", .{});
        return 2;
    }
    const cwd = std.Io.Dir.cwd();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, "MARC");
    for (args.items[2..]) |spec| {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse {
            std.debug.print("mkmarc: bad entry '{s}'\n", .{spec});
            return 2;
        };
        const path = spec[0..eq];
        const data = try cwd.readFileAlloc(io, spec[eq + 1 ..], gpa, .limited(1 << 24));
        var hdr: [8]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], @intCast(path.len), .little);
        std.mem.writeInt(u32, hdr[4..8], @intCast(data.len), .little);
        try out.appendSlice(gpa, &hdr);
        try out.appendSlice(gpa, path);
        try out.appendSlice(gpa, data);
    }
    try cwd.writeFile(io, .{ .sub_path = args.items[1], .data = out.items });
    return 0;
}
