//! Moss-native medit. The editing model is pure Zig; the picker alone holds a filesystem view.
const std = @import("std");
const shared = @import("shared");
const ml = @import("mosslib");
const core = ml.editor;
const usys = @import("usys.zig");
const wf = @import("windowframe.zig");
const ui = @import("widgets.zig");
const boot = @import("boot.zig");
const clip = @import("clipboard.zig");
const Document = @import("document.zig").Client;
const k = shared.keyboard;
const mono: u64 = @intFromEnum(shared.FontRole.mono);
comptime {
    asm (usys.imageHeader("medit"));
}
pub const panic = std.debug.FullPanic(uPanic);
fn uPanic(msg: []const u8, _: ?usize) noreturn {
    _ = usys.log(log_h, msg);
    usys.exit(255);
}
var log_h: u64 = 0;
var authority: u64 = 0;
var test_mode = false;
var pool: ml.pool.Pool(64, 131072) = .{};
var ed: core.Editor = undefined;
var doc: ?Document = null;
var running = true;
var hidden = false;
var needs_reveal = false;
var top: usize = 0;
var left: usize = 0;
var cell: usize = 10;
var line_h: usize = 24;
var area: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var gutter: usize = 50;
var buttons: [5]ui.Rect = undefined;
var find_rect: ui.Rect = undefined;
var finding = false;
var query: shared.TextEdit = .{};
var message: [180]u8 = undefined;
var message_len: usize = 0;
const Pending = enum { none, close, new, open };
var pending: Pending = .none;
var confirm_focus: usize = 2;
var confirm_buttons: [3]ui.Rect = undefined;
var drag_select = false;
var pressed: ?usize = null;
var toolbar_focus: ?usize = null;
var last_click: u64 = 0;
var click_pos: core.Pos = .{ .line = 0, .col = 0 };
fn log(comptime fmt: []const u8, args: anytype) void {
    var b: [400]u8 = undefined;
    _ = usys.log(log_h, std.fmt.bufPrint(&b, fmt, args) catch return);
}
fn status(text: []const u8) void {
    message_len = @min(text.len, message.len);
    @memcpy(message[0..message_len], text[0..message_len]);
}
fn failed(err: anyerror) void {
    status(switch (err) {
        error.OutOfMemory => "Not enough memory. Your document is unchanged.",
        error.FileNotFound => "The selected file was not found. Your document is unchanged.",
        error.InvalidPath => "Choose a valid file name within the selected folder.",
        error.NotFile => "Choose a regular text file.",
        error.DocumentBusy => "The document picker is busy. Please try again.",
        error.ReadOnly => "This document is read-only. Use Save As to make a copy.",
        error.FileTooLarge, error.TooManyLines => "Document limit: 256 KiB or 8192 lines.",
        error.InvalidUtf8, error.BinaryFile, error.NotText => "This file is not supported UTF-8 text.",
        error.DiskFull => "The disk is full. Your edits are still here.",
        error.SaveUncertain => "Save could not be confirmed. Your edits remain unsaved.",
        else => "The document service is unavailable. Your edits are still here.",
    });
    log("editor: error {s}", .{@errorName(err)});
}
fn rows() usize {
    return @max(1, area.h / line_h);
}
fn cols() usize {
    return @max(1, (area.w -| gutter -| 12) / cell);
}
fn nextByte(s: []const u8, i: usize) usize {
    return @min(s.len, i + (std.unicode.utf8ByteSequenceLength(s[i]) catch 1));
}
fn advanceCell(s: []const u8, i: usize, col: usize) usize {
    if (s[i] == '\t') return col + 4 - col % 4;
    if (s[i] == '\r') return col;
    const cp = std.unicode.utf8Decode(s[i..nextByte(s, i)]) catch 0xfffd;
    return col + core.uwidth.cellWidth(cp);
}
fn visualCol(s: []const u8, end: usize) usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < @min(end, s.len)) : (i = nextByte(s, i)) col = advanceCell(s, i, col);
    return col;
}
fn byteCol(s: []const u8, target: usize) usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const next = advanceCell(s, i, col);
        if (next > target) break;
        col = next;
        i = nextByte(s, i);
    }
    return i;
}
fn reveal() void {
    const r = rows();
    if (ed.cursor.line < top) top = ed.cursor.line;
    if (ed.cursor.line >= top + r) top = ed.cursor.line - r + 1;
    const c = visualCol(ed.buffer.lineSlice(ed.cursor.line), ed.cursor.col);
    if (c < left) left = c;
    if (c >= left + cols()) left = c - cols() + 1;
}
fn drawRun(x: usize, y: usize, text: []const u8, selected: bool, width: usize) void {
    const bg = if (selected) wf.pal.primary else wf.pal.bg;
    if (selected) wf.fillRect(x, y, width, line_h, bg);
    wf.drawStr(x, y, mono, text, if (selected) wf.pal.primary_ink else wf.pal.text, bg);
}
fn drawLine(index: usize, y: usize) void {
    const s = ed.buffer.lineSlice(index);
    var b: [4096]u8 = undefined;
    var n: usize = 0;
    var run_start: usize = 0;
    var col: usize = 0;
    var selected = false;
    var started = false;
    const selection = ed.selection();
    var i: usize = 0;
    while (i < s.len) {
        const end = nextByte(s, i);
        const nc = advanceCell(s, i, col);
        if (col >= left + cols()) break;
        if (col >= left and nc <= left + cols() and s[i] != '\r') {
            const yes = if (selection) |r| !core.Pos.lessThan(.{ .line = index, .col = i }, r.start) and core.Pos.lessThan(.{ .line = index, .col = i }, r.end) else false;
            if (started and yes != selected) {
                drawRun(area.x + gutter + (run_start - left) * cell, y, b[0..n], selected, (col - run_start) * cell);
                n = 0;
                started = false;
            }
            if (!started) {
                run_start = col;
                selected = yes;
                started = true;
            }
            if (s[i] == '\t') {
                const spaces = nc - col;
                if (n + spaces > b.len) break;
                @memset(b[n..][0..spaces], ' ');
                n += spaces;
            } else {
                if (n + end - i > b.len) break;
                @memcpy(b[n..][0 .. end - i], s[i..end]);
                n += end - i;
            }
        }
        col = nc;
        i = end;
    }
    if (started) drawRun(area.x + gutter + (run_start - left) * cell, y, b[0..n], selected, (col - run_start) * cell);
    if (selection) |r| if (index >= r.start.line and index < r.end.line and col >= left and col < left + cols()) {
        wf.fillRect(area.x + gutter + (col - left) * cell, y, cell, line_h, wf.pal.primary);
    };
}
fn render() void {
    wf.clipReset();
    wf.fillAll(wf.pal.bg);
    wf.drawChrome("Editor");
    cell = @max(1, wf.strW(mono, "M"));
    line_h = wf.lineOf(mono);
    const pad: usize = 16;
    const h = ui.height();
    const labels = [_][]const u8{ "New", "Open", "Save", "Save As", "Find" };
    const icons = [_][]const u8{ "file-text", "folder", "", "", "" };
    var widths: [5]usize = undefined;
    var total: usize = 0;
    for (labels, icons, 0..) |label, icon, i| {
        widths[i] = wf.strW(wf.R_UI, label) + 24 + (if (icon.len > 0) wf.iconSize() + @as(usize, 8) else 0);
        total += widths[i];
    }
    const available = @min(total, wf.win_w -| pad * 2 -| 32);
    var x = pad;
    var before: usize = 0;
    for (0..5) |i| {
        const w = shared.gui.trackWidth(available, total, before, widths[i]);
        before += widths[i];
        buttons[i] = .{ .x = x, .y = wf.title_h + 12, .w = w, .h = h };
        ui.Button.draw(buttons[i], labels[i], icons[i], toolbar_focus == i, false, false);
        x += w + 8;
    }
    var y = wf.title_h + h + 36;
    const title = if (doc) |*d| d.title() else "Untitled";
    wf.drawStrTrunc(pad, y, wf.R_UI, title, wf.win_w -| pad * 2 -| 120, wf.pal.text, wf.pal.bg);
    const state = if (ed.dirty()) "Edited" else if (doc) |d| (if (d.read_only) "Read-only" else "Saved") else "New document";
    const sw = wf.strW(wf.R_UI, state);
    wf.drawStr(wf.win_w -| pad -| sw, y, wf.R_UI, state, wf.pal.text_muted, wf.pal.bg);
    y += wf.lineOf(wf.R_UI) + 12;
    if (finding) {
        find_rect = .{ .x = pad, .y = y, .w = wf.win_w -| pad * 2, .h = h };
        ui.input(find_rect, &query, true);
        if (query.len == 0) wf.drawStrTrunc(find_rect.x + 10, find_rect.y + (find_rect.h -| wf.lineOf(wf.R_UI)) / 2, wf.R_UI, "Find in document · Enter next · Esc close", find_rect.w -| 20, wf.pal.text_muted, wf.pal.field_bg);
        y += h + 10;
    }
    const status_h = wf.lineOf(wf.R_UI) + 20;
    area = .{ .x = pad, .y = y, .w = wf.win_w -| pad * 2, .h = wf.win_h -| status_h -| y -| 12 };
    var number: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&number, "{d}", .{ed.buffer.lineCount()}) catch "1";
    gutter = wf.strW(mono, digits) + 24;
    if (needs_reveal) {
        reveal();
        needs_reveal = false;
    }
    top = @min(top, ed.buffer.lineCount() - 1);
    wf.fillRect(area.x, area.y, gutter - 8, area.h, wf.pal.surface);
    wf.clip_x0 = area.x;
    wf.clip_y0 = area.y;
    wf.clip_x1 = area.x + area.w - 8;
    wf.clip_y1 = area.y + area.h;
    for (0..@min(rows(), ed.buffer.lineCount() - top)) |r| {
        const idx = top + r;
        const yy = area.y + r * line_h;
        const ns = std.fmt.bufPrint(&number, "{d}", .{idx + 1}) catch "";
        wf.drawStr(area.x + gutter - 16 - wf.strW(mono, ns), yy, mono, ns, wf.pal.text_muted, wf.pal.surface);
        drawLine(idx, yy);
    }
    if (wf.win_focused and !finding and pending == .none and toolbar_focus == null and ed.cursor.line >= top and ed.cursor.line < top + rows()) {
        const col = visualCol(ed.buffer.lineSlice(ed.cursor.line), ed.cursor.col);
        if (col >= left and col < left + cols()) wf.fillRect(area.x + gutter + (col - left) * cell, area.y + (ed.cursor.line - top) * line_h, 2, line_h, wf.pal.focus);
    }
    wf.clipReset();
    if (ed.buffer.lineCount() > rows() and area.h > 0) {
        const thumb = @max(16, area.h * rows() / ed.buffer.lineCount());
        const off = (area.h -| thumb) * top / @max(1, ed.buffer.lineCount() - 1);
        wf.fillRoundRect(area.x + area.w - 5, area.y + off, 4, thumb, 2, wf.pal.text_muted);
    }
    wf.fillRect(0, wf.win_h - status_h, wf.win_w, 1, wf.pal.border);
    var foot: [200]u8 = undefined;
    const text = if (message_len > 0) message[0..message_len] else std.fmt.bufPrint(&foot, "Ln {d}, Col {d}   ·   UTF-8   ·   {d} lines", .{ ed.cursor.line + 1, visualCol(ed.buffer.lineSlice(ed.cursor.line), ed.cursor.col) + 1, ed.buffer.lineCount() }) catch "UTF-8";
    wf.drawStrTrunc(pad, wf.win_h - status_h + 10, wf.R_UI, text, wf.win_w -| pad * 2, wf.pal.text_muted, wf.pal.bg);
    if (pending != .none) {
        const mw = @min(wf.win_w -| 32, @as(usize, 620));
        const mh = wf.lineOf(wf.R_UI) * 3 + h + 64;
        const mx = (wf.win_w - mw) / 2;
        const my = (wf.win_h -| mh) / 2;
        wf.panel(mx, my, mw, mh, 10, wf.pal.surface, wf.pal.border, 2);
        wf.drawStrTrunc(mx + 20, my + 20, wf.R_TITLE, "Save your changes?", mw - 40, wf.pal.title, wf.pal.surface);
        wf.drawStrTrunc(mx + 20, my + 24 + wf.lineOf(wf.R_TITLE), wf.R_UI, "Your unsaved edits will be lost.", mw - 40, wf.pal.text_muted, wf.pal.surface);
        const bw = (mw - 56) / 3;
        for ([_][]const u8{ "Save", "Discard", "Cancel" }, 0..) |label, i| {
            confirm_buttons[i] = .{ .x = mx + 20 + i * (bw + 8), .y = my + mh - h - 20, .w = bw, .h = h };
            ui.Button.draw(confirm_buttons[i], label, "", confirm_focus == i, i == 0, false);
        }
    }
    _ = wf.commitSurface();
}
fn digest(bytes: []const u8) void {
    if (!test_mode) return;
    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sum, .{});
    const hex = std.fmt.bytesToHex(sum, .lower);
    log("editor: digest {s}", .{hex});
}
fn save(as: bool) bool {
    const text = ed.contentAlloc(pool.allocator()) catch |e| {
        failed(e);
        return false;
    };
    var transferred = false;
    defer if (!transferred) pool.allocator().free(text);
    if (doc == null) doc = Document.init(authority) catch |e| {
        failed(e);
        return false;
    };
    if (!(doc.?.save(text, as) catch |e| {
        failed(e);
        return false;
    })) return false;
    ed.markSavedOwned(text);
    transferred = true;
    status("Saved");
    log("editor: saved {s} bytes={d}", .{ doc.?.title(), text.len });
    return true;
}
fn perform(action: Pending) void {
    switch (action) {
        .none => {},
        .close => running = false,
        .new => {
            ed.load("") catch |e| {
                failed(e);
                return;
            };
            if (doc) |*d| d.deinit();
            doc = null;
            top = 0;
            left = 0;
            status("");
        },
        .open => {
            var candidate = Document.init(authority) catch |e| {
                failed(e);
                return;
            };
            var retain = false;
            defer if (!retain) candidate.deinit();
            const text = (candidate.open() catch |e| {
                failed(e);
                return;
            }) orelse return;
            ed.load(text) catch |e| {
                failed(e);
                return;
            };
            if (doc) |*d| d.deinit();
            log("editor: loaded {s} bytes={d}", .{ candidate.title(), text.len });
            digest(text);
            doc = candidate;
            retain = true;
            top = 0;
            left = 0;
            status("");
        },
    }
}
fn request(action: Pending) void {
    ed.breakGroup();
    toolbar_focus = null;
    if (ed.dirty()) {
        pending = action;
        confirm_focus = 2;
    } else perform(action);
}
fn confirm(which: usize) void {
    if (which == 2) {
        pending = .none;
        log("editor: close cancelled", .{});
        return;
    }
    if (which == 0 and !save(false)) return;
    const action = pending;
    pending = .none;
    if (which == 1) log("editor: discarded", .{});
    perform(action);
}
fn toolbarAction(index: usize) void {
    toolbar_focus = null;
    ed.breakGroup();
    switch (index) {
        0 => request(.new),
        1 => request(.open),
        2 => {
            _ = save(false);
        },
        3 => {
            _ = save(true);
        },
        4 => {
            finding = !finding;
            query = .{};
        },
        else => {},
    }
}
fn findNext(back: bool) void {
    if (query.len == 0) return;
    if (ed.find(query.buf[0..query.len], back) catch |e| {
        failed(e);
        return;
    }) {
        status("");
        reveal();
    } else status("No matches");
}
fn key(ch: u8) void {
    if (pending != .none) {
        if (ch == 27) confirm(2) else if (ch == '\t') {
            confirm_focus = (confirm_focus + 1) % 3;
        } else if (ch == k.back_tab) {
            confirm_focus = (confirm_focus + 2) % 3;
        } else if (ch == '\n') confirm(confirm_focus);
        return;
    }
    if (ch == k.close_window) {
        request(.close);
        return;
    }
    if (ch == k.new_document) {
        request(.new);
        return;
    }
    if (ch == k.open_document) {
        request(.open);
        return;
    }
    if (ch == k.save_document) {
        _ = save(false);
        return;
    }
    if (ch == k.save_as) {
        _ = save(true);
        return;
    }
    if (ch == k.find) {
        finding = true;
        query = .{};
        toolbar_focus = null;
        return;
    }
    if (finding) {
        if (ch == 27) {
            finding = false;
        } else if (ch == '\n') findNext(false) else if (ch == k.back_tab) findNext(true) else {
            _ = ui.fieldKey(&query, ch);
        }
        return;
    }
    if (ch == k.back_tab) {
        toolbar_focus = if (toolbar_focus) |f| (f + 4) % 5 else 4;
        return;
    }
    if (toolbar_focus) |f| {
        if (ch == '\t') {
            if (f == 4) toolbar_focus = null else toolbar_focus = f + 1;
        } else if (ch == '\n') toolbarAction(f) else if (ch == 27) {
            toolbar_focus = null;
        }
        return;
    }
    message_len = 0;
    const movement: ?core.Movement = switch (ch) {
        k.left, k.select_left, 2 => .left,
        k.right, k.select_right, 6 => .right,
        k.up, k.select_up, 16 => .up,
        k.down, k.select_down, 14 => .down,
        k.home, k.select_home, 1 => .line_start,
        k.end, k.select_end, 5 => .line_end,
        k.word_left, k.select_word_left => .word_left,
        k.word_right, k.select_word_right => .word_right,
        k.doc_home, k.select_doc_home => .document_start,
        k.doc_end, k.select_doc_end => .document_end,
        else => null,
    };
    if (movement) |m| {
        const extend = ch == k.select_left or ch == k.select_right or ch == k.select_up or ch == k.select_down or ch == k.select_home or ch == k.select_end or ch == k.select_word_left or ch == k.select_word_right or ch == k.select_doc_home or ch == k.select_doc_end;
        ed.move(m, extend);
        reveal();
        return;
    }
    switch (ch) {
        k.select_all => ed.selectAll(),
        k.copy, k.cut, 3, 24 => {
            ed.breakGroup();
            const text = ed.selectionAlloc(pool.allocator()) catch |e| {
                failed(e);
                return;
            };
            defer pool.allocator().free(text);
            if (text.len > 0) {
                if (clip.set(text)) {
                    if (ch == k.cut or ch == 24) ed.backspace() catch |e| {
                        failed(e);
                        return;
                    };
                } else status("Clipboard unavailable or selection exceeds 4 KiB.");
            }
        },
        k.paste, 22 => {
            ed.breakGroup();
            if (clip.get()) |text| ed.insert(text) catch |e| {
                failed(e);
                return;
            } else status("Clipboard unavailable.");
            ed.breakGroup();
        },
        k.undo, 26 => {
            _ = ed.undo() catch |e| {
                failed(e);
                return;
            };
        },
        k.redo => {
            _ = ed.redo() catch |e| {
                failed(e);
                return;
            };
        },
        8, 127 => ed.backspace() catch |e| {
            failed(e);
            return;
        },
        k.delete, 4 => ed.deleteForward() catch |e| {
            failed(e);
            return;
        },
        k.delete_word, 23 => {
            if (ed.selection() == null) ed.move(.word_left, true);
            ed.backspace() catch |e| {
                failed(e);
                return;
            };
        },
        11 => {
            if (ed.selection() == null) {
                ed.move(.line_end, true);
                if (ed.selection() == null) ed.move(.right, true);
            }
            const text = ed.selectionAlloc(pool.allocator()) catch |e| {
                failed(e);
                return;
            };
            defer pool.allocator().free(text);
            if (clip.set(text)) ed.backspace() catch |e| {
                failed(e);
                return;
            };
        },
        25 => {
            if (clip.get()) |text| ed.insert(text) catch |e| {
                failed(e);
                return;
            };
        },
        0x1e, 0x1f => {
            for (0..rows()) |_| ed.move(if (ch == 0x1e) .up else .down, false);
        },
        '\n' => ed.newline() catch |e| {
            failed(e);
            return;
        },
        '\t' => {
            const n = 4 - visualCol(ed.buffer.lineSlice(ed.cursor.line), ed.cursor.col) % 4;
            ed.breakGroup();
            ed.insert("    "[0..n]) catch |e| {
                failed(e);
                return;
            };
            ed.breakGroup();
        },
        27 => ed.setCursor(ed.cursor, false),
        else => if (ch >= 32 and ch < 127) {
            ed.insert(&.{ch}) catch |e| {
                failed(e);
                return;
            };
        },
    }
    reveal();
}
fn hitPos(x: usize, y: usize) core.Pos {
    const line = @min(ed.buffer.lineCount() - 1, top + (y -| area.y) / line_h);
    return .{ .line = line, .col = byteCol(ed.buffer.lineSlice(line), left + (x -| area.x -| gutter) / cell) };
}
fn pointer(ev: wf.Event) void {
    const down = ev.btn & 1 != 0;
    const press = down and !wf.ptr_down;
    const release = !down and wf.ptr_down;
    const wheel = shared.ptrWheel(ev.btn);
    if (wheel != 0) {
        top = @intCast(std.math.clamp(@as(isize, @intCast(top)) - @as(isize, wheel) * 3, 0, @as(isize, @intCast(ed.buffer.lineCount() -| rows()))));
        return;
    }
    if (drag_select) {
        if (down) {
            ed.setCursor(hitPos(ev.x, ev.y), true);
            reveal();
        } else drag_select = false;
    }
    const old = wf.Geom{ .x = wf.win_x, .y = wf.win_y, .w = wf.win_w, .h = wf.win_h };
    const was_maximized = wf.maximized;
    const event = wf.onPointer(ev, "Editor");
    switch (event) {
        .close => {
            if (pending != .none) confirm(2) else request(.close);
        },
        .minimized => hidden = true,
        .resize_failed => {
            wf.win_x = old.x;
            wf.win_y = old.y;
            wf.win_w = old.w;
            wf.win_h = old.h;
            wf.maximized = was_maximized;
            status("Not enough display memory to resize. Your edits are safe.");
        },
        .resized => needs_reveal = true,
        else => {},
    }
    if (pending != .none) {
        if (press) for (confirm_buttons, 0..) |r, i| {
            if (ui.contains(r, ev.x, ev.y)) {
                confirm_focus = i;
                pressed = i;
            }
        };
        if (release) {
            if (pressed) |i| {
                if (i < 3 and ui.contains(confirm_buttons[i], ev.x, ev.y)) confirm(i);
            }
            pressed = null;
        }
        return;
    }
    if (press) {
        for (buttons, 0..) |r, i| if (ui.contains(r, ev.x, ev.y)) {
            pressed = i;
            toolbar_focus = i;
            return;
        };
        if (ui.contains(area, ev.x, ev.y)) {
            finding = false;
            toolbar_focus = null;
            const pos = hitPos(ev.x, ev.y);
            ed.setCursor(pos, false);
            const now = usys.cycles();
            if (pos.eql(click_pos) and now - last_click < usys.cycleHz() / 3) {
                ed.selectWordAt(pos);
                last_click = 0;
            } else {
                last_click = now;
                click_pos = pos;
            }
            drag_select = true;
        }
    }
    if (release) {
        if (pressed) |i| {
            if (ui.contains(buttons[i], ev.x, ev.y)) toolbarAction(i);
        }
        pressed = null;
    }
}
export fn umain(log_cap: u64, chan_h: u64, arg: u64) callconv(.c) noreturn {
    log_h = log_cap;
    test_mode = arg == 1;
    const setup = boot.take(chan_h);
    authority = setup.cap(.picker);
    clip.authority = setup.cap(.clip);
    if (test_mode) {
        // Exercise real registered-client teardown beyond the old small pool
        // sizes, and prove a client cannot save before a user chooses a file.
        for (0..128) |_| {
            var probe = Document.init(authority) catch {
                usys.exit(1);
            };
            const rep = usys.callTyped(shared.picker.Req, shared.picker.Resp, probe.chan, .{ .save = .{ .len = 0 } }, 0);
            const denied = switch (rep) {
                .ok => |r| r == .failed and r.failed.code == @intFromEnum(shared.picker.Error.bad_path),
                .err => false,
            };
            probe.deinit();
            if (!denied) {
                log("editor: selection boundary FAILED", .{});
                usys.exit(1);
            }
        }
        log("editor: document clients reclaimed; unselected save denied", .{});
    }
    ed = core.Editor.init(pool.allocator()) catch {
        usys.exit(1);
    };
    wf.setup(setup.cap(.display), log_h, setup.secret(), setup.cap(.font));
    wf.fontReady();
    wf.refreshAppearance();
    wf.useOrdinaryChannel();
    _ = wf.refreshOutput();
    const work = wf.workArea();
    wf.win_w = @min(960, work.w);
    wf.win_h = @min(760, work.h);
    wf.win_x = work.x + (work.w - wf.win_w) / 2;
    wf.win_y = work.y + (work.h - wf.win_h) / 2;
    wf.pointer_tracking = true;
    wf.tick_ms = 250;
    if (!wf.openSurface(true)) usys.exit(1);
    wf.setSurfaceTitle("Editor");
    render();
    log("editor: ready", .{});
    while (running) {
        const ev = wf.nextInput() orelse break;
        if (ev.kind == 7) {
            const old = wf.Geom{ .x = wf.win_x, .y = wf.win_y, .w = wf.win_w, .h = wf.win_h };
            if (!wf.outputChanged(ev, "Editor", hidden)) {
                wf.win_w = old.w;
                wf.win_h = old.h;
                wf.win_x = @min(old.x, wf.scanout_w -| old.w);
                wf.win_y = @min(old.y, wf.scanout_h -| old.h);
                wf.moveSurface(wf.win_x, wf.win_y);
                status("Display resize failed. Your document is still open.");
            }
            needs_reveal = true;
        } else if (ev.kind == 4) {
            wf.win_focused = ev.ch != 0;
            if (!wf.win_focused) {
                drag_select = false;
                pressed = null;
            }
        } else if (ev.kind == 3) {
            hidden = false;
        } else if (ev.kind == 2) {
            if (wf.refreshFontMetrics()) {
                wf.refreshAppearance();
                needs_reveal = true;
            } else continue;
        } else if (ev.kind == 1) pointer(ev) else key(ev.ch);
        if (running and !hidden) render();
    }
    if (doc) |*d| d.deinit();
    ed.deinit();
    wf.closeSurface();
    log("editor: exit", .{});
    usys.exit(0);
}
