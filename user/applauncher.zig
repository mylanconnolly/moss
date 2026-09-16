//! Session application search. A transient surface owned by the resident bar;
//! neither discovery nor presentation creates additional launch authority.
const std = @import("std");
const shared = @import("shared");
const tk = @import("mosslib").ui;
const wf = @import("windowframe.zig");
const ui = @import("widgets.zig");
const usys = @import("usys.zig");
const apps = @import("appsclient.zig");
const search = tk.search;
var catalog: apps.Catalog = .{};
var matches: [128]usize = undefined;
var scores: [128]usize = undefined;
var count: usize = 0;
var query: tk.text.Editor = .{};
var selected: usize = 0;
var first: usize = 0;
var message: []const u8 = "";
fn filter() void {
    count = 0;
    for (catalog.records[0..catalog.len], 0..) |*app, index| {
        const rank = search.score(std.mem.sliceTo(&app.name, 0), std.mem.sliceTo(&app.description, 0), query.buf[0..query.len]) orelse continue;
        var at = count;
        while (at > 0 and scores[at - 1] > rank) : (at -= 1) {
            matches[at] = matches[at - 1];
            scores[at] = scores[at - 1];
        }
        matches[at] = index;
        scores[at] = rank;
        count += 1;
    }
    selected = 0;
    first = 0;
}
fn rowHeight() usize {
    return wf.lineOf(wf.R_UI) * 2 + 20;
}
fn rowsY() usize {
    return 28 + ui.height() + wf.lineOf(wf.R_UI);
}
fn visibleRows() usize {
    return @max(1, (wf.win_h -| rowsY() -| (wf.lineOf(wf.R_UI) + 20)) / rowHeight());
}
fn render() void {
    const p = wf.pal;
    wf.clipReset();
    wf.fillAll(p.surface);
    wf.panel(0, 0, wf.win_w, wf.win_h, 12, p.surface, p.border, p.border_w);
    ui.input(.{ .x = 16, .y = 16, .w = wf.win_w -| 32, .h = ui.height() }, &query, true);
    if (query.len == 0) wf.drawStrTrunc(28, 16 + (ui.height() -| wf.lineOf(wf.R_UI)) / 2, wf.R_UI, "Search applications", wf.win_w -| 72, p.text_muted, p.field_bg);
    wf.drawStrTrunc(20, 24 + ui.height(), wf.R_UI, "Applications", wf.win_w -| 40, p.text_muted, p.surface);
    const vis = visibleRows();
    if (selected < first) first = selected;
    if (selected >= first + vis) first = selected + 1 - vis;
    var y = rowsY();
    if (count == 0) wf.drawStrTrunc(24, y + 12, wf.R_UI, if (message.len > 0) message else "No matching applications", wf.win_w -| 48, p.text_muted, p.surface);
    for (first..@min(count, first + vis)) |i| {
        const a = &catalog.records[matches[i]];
        const bg = if (i == selected) p.primary else p.surface;
        const ink = if (i == selected) p.primary_ink else p.text;
        wf.fillRoundRect(12, y, wf.win_w -| 24, rowHeight() - 4, 6, bg);
        const icon = wf.iconSize();
        wf.drawIcon(24, y + (rowHeight() -| icon) / 2, icon, std.mem.sliceTo(&a.icon, 0), ink);
        const x = 36 + icon;
        wf.drawStrTrunc(x, y + 6, wf.R_UI, std.mem.sliceTo(&a.name, 0), wf.win_w -| x -| 40, ink, bg);
        wf.drawStrTrunc(x, y + 8 + wf.lineOf(wf.R_UI), wf.R_UI, std.mem.sliceTo(&a.description, 0), wf.win_w -| x -| 40, if (i == selected) ink else p.text_muted, bg);
        if (a.flags & shared.apps.running != 0) wf.fillDot(wf.win_w - 26, y + 14, 3, ink);
        y += rowHeight();
    }
    wf.drawStrTrunc(20, wf.win_h -| wf.lineOf(wf.R_UI) -| 10, wf.R_UI, if (message.len > 0 and count > 0) message else "Enter to open · Esc to dismiss", wf.win_w -| 40, p.text_muted, p.surface);
    _ = wf.commitSurface();
}
pub fn run(control: u64, log: u64) bool {
    const focus = wf.activeMenu().token;
    query = .{};
    message = if (catalog.refresh()) "" else "Applications are unavailable.";
    filter();
    const work = wf.workArea();
    const width = @min(@as(usize, 800), work.w -| 32);
    const height = @min(ui.height() + wf.lineOf(wf.R_UI) * 2 + rowHeight() * @min(@max(catalog.len, 1), 6) + 60, work.h -| 24);
    const x = work.x + (work.w -| width) / 2;
    const y = work.y + @min(@as(usize, 70), (work.h -| height) / 3);
    const created = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, wf.chan, .{ .create_surface = .{ .xy = shared.packPair(@intCast(x), @intCast(y)), .wh = shared.packPair(@intCast(width), @intCast(height)), .flags = shared.gpu_pointer_tracking } }, 0)) {
        .ok => |r| r,
        .err => return false,
    };
    if (created.rep != .created or created.cap == 0) return false;
    const surface = created.rep.created.surface;
    defer _ = usys.capDrop(created.cap);
    const map = usys.shmMap(created.cap);
    if (map.err != .ok) {
        _ = usys.callTyped(shared.GpuReq, shared.GpuResp, wf.chan, .{ .destroy_surface = .{ .surface = surface } }, 0);
        return false;
    }
    defer _ = usys.shmUnmap(map.data[0]);
    const old = .{ wf.px, wf.surf, wf.win_x, wf.win_y, wf.win_w, wf.win_h };
    wf.px = @ptrFromInt(map.data[0]);
    wf.surf = surface;
    wf.win_x = x;
    wf.win_y = y;
    wf.win_w = width;
    wf.win_h = height;
    var restore = true;
    defer {
        // Destroy before restoring focus: an obsolete overlay must not become
        // the compositor's fallback target after its app has been raised.
        _ = usys.callTyped(shared.GpuReq, shared.GpuResp, wf.chan, .{ .destroy_surface = .{ .surface = surface } }, 0);
        wf.px = old[0];
        wf.surf = old[1];
        wf.win_x = old[2];
        wf.win_y = old[3];
        wf.win_w = old[4];
        wf.win_h = old[5];
        wf.clipReset();
        wf.ptr_down = false;
        if (restore and focus != 0) _ = wf.restoreMenuFocus(control, focus);
        _ = usys.log(log, "launcher: dismissed");
    }
    render();
    var lb: [100]u8 = undefined;
    _ = usys.log(log, std.fmt.bufPrint(&lb, "launcher: ready count={d} x={d} y={d} w={d} h={d}", .{ catalog.len, x, y, width, height }) catch "launcher: ready");
    var down_before = false;
    while (wf.nextInput()) |ev| {
        var open = false;
        if (ev.kind == 7) return false;
        if (ev.kind == 4 and ev.surface == surface and ev.ch == 0) {
            restore = false;
            return false;
        }
        if (ev.kind == 1) {
            const down = ev.btn & 1 != 0;
            const press = down and !down_before;
            down_before = down;
            if (ev.surface != surface) {
                if (press) {
                    restore = false;
                    return false;
                } else continue;
            }
            const wheel = shared.ptrWheel(ev.btn);
            if (wheel != 0 and count > 0) selected = if (wheel > 0) selected -| 1 else @min(selected + 1, count - 1);
            if (wheel == 0 and ev.y >= rowsY() and ev.y < wf.win_h -| (wf.lineOf(wf.R_UI) + 20)) {
                const at = first + (ev.y - rowsY()) / rowHeight();
                if (at < count) {
                    selected = at;
                    open = press;
                }
            }
        } else if (ev.kind == 0) {
            switch (ev.ch) {
                27, shared.keyboard.launcher => return false,
                shared.keyboard.menu_focus => {
                    restore = false;
                    return true;
                },
                shared.keyboard.down, '\t', 14 => if (count > 0) {
                    selected = (selected + 1) % count;
                },
                shared.keyboard.up, shared.keyboard.back_tab, 16 => if (count > 0) {
                    selected = (selected + count - 1) % count;
                },
                '\n', '\r' => open = true,
                else => if (ui.fieldKey(&query, ev.ch)) {
                    filter();
                    message = "";
                },
            }
        } else continue;
        if (open and count > 0) {
            const app = &catalog.records[matches[selected]];
            if (apps.activate(app, wf.display)) {
                _ = usys.log(log, std.fmt.bufPrint(&lb, "launcher: activate {s}", .{std.mem.sliceTo(&app.unit, 0)}) catch "launcher: activate");
                restore = false;
                return false;
            }
            message = "Could not start this application. Try again.";
        }
        render();
    }
    return false;
}
