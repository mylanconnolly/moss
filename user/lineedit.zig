//! A line editor for the console byte pipe: cursor movement, history,
//! kill/yank-free editing keys, and tab completion through a host
//! callback. Terminal-agnostic beyond the basics every terminal speaks
//! (CR, backspace, CSI arrows/home/end/delete, clear-to-EOL).

pub const max_line = 512;
pub const history_len = 16;
pub const max_candidates = 32;
pub const candidate_len = 64;

pub const Io = struct {
    ctx: *anyopaque,
    /// Blocking read of at least one byte into buf; returns count.
    read: *const fn (ctx: *anyopaque, buf: []u8) usize,
    write: *const fn (ctx: *anyopaque, bytes: []const u8) void,
    /// Fill `out` with completions of `word` (first = command position);
    /// returns the count. A candidate ending in '/' is a directory.
    complete: *const fn (ctx: *anyopaque, word: []const u8, first: bool, out: *[max_candidates][candidate_len]u8, lens: *[max_candidates]usize) usize,
};

pub const Editor = struct {
    io: Io,
    prompt: []const u8,
    buf: [max_line]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    hist: [history_len][max_line]u8 = undefined,
    hist_lens: [history_len]usize = @splat(0),
    hist_count: usize = 0,
    /// Browsing position: hist_count = editing the live line.
    hist_pos: usize = 0,
    saved: [max_line]u8 = undefined,
    saved_len: usize = 0,
    esc: enum { none, esc, csi } = .none,
    csi_arg: usize = 0,

    /// Edit one line. Returns the line (empty on ctrl-c). The prompt is
    /// printed here so redraws can reproduce it.
    pub fn readLine(e: *Editor, out: []u8) usize {
        e.len = 0;
        e.cursor = 0;
        e.hist_pos = e.hist_count;
        e.esc = .none;
        e.io.write(e.io.ctx, e.prompt);
        var chunk: [64]u8 = undefined;
        while (true) {
            const n = e.io.read(e.io.ctx, &chunk);
            for (chunk[0..n]) |c| {
                switch (e.key(c)) {
                    .none => {},
                    .done => {
                        e.io.write(e.io.ctx, "\r\n");
                        e.remember();
                        const k = @min(e.len, out.len);
                        @memcpy(out[0..k], e.buf[0..k]);
                        return k;
                    },
                    .cancel => {
                        e.io.write(e.io.ctx, "^C\r\n");
                        return 0;
                    },
                }
            }
        }
    }

    const Outcome = enum { none, done, cancel };

    fn key(e: *Editor, c: u8) Outcome {
        switch (e.esc) {
            .esc => {
                if (c == '[' or c == 'O') {
                    e.esc = .csi;
                    e.csi_arg = 0;
                } else e.esc = .none;
                return .none;
            },
            .csi => {
                if (c >= '0' and c <= '9') {
                    e.csi_arg = e.csi_arg * 10 + (c - '0');
                    return .none;
                }
                e.esc = .none;
                switch (c) {
                    'A' => e.histMove(true),
                    'B' => e.histMove(false),
                    'C' => if (e.cursor < e.len) {
                        e.cursor += 1;
                        e.io.write(e.io.ctx, "\x1b[C");
                    },
                    'D' => if (e.cursor > 0) {
                        e.cursor -= 1;
                        e.io.write(e.io.ctx, "\x1b[D");
                    },
                    'H' => e.home(),
                    'F' => e.end(),
                    '~' => switch (e.csi_arg) {
                        1, 7 => e.home(),
                        4, 8 => e.end(),
                        3 => e.deleteAt(),
                        else => {},
                    },
                    else => {},
                }
                return .none;
            },
            .none => {},
        }
        switch (c) {
            '\r', '\n' => return .done,
            0x03 => return .cancel,
            0x1b => e.esc = .esc,
            0x7f, 0x08 => if (e.cursor > 0) {
                e.cursor -= 1;
                e.deleteAt();
            },
            0x01 => e.home(),
            0x05 => e.end(),
            0x02 => if (e.cursor > 0) {
                e.cursor -= 1;
                e.io.write(e.io.ctx, "\x1b[D");
            },
            0x06 => if (e.cursor < e.len) {
                e.cursor += 1;
                e.io.write(e.io.ctx, "\x1b[C");
            },
            0x0b => { // ctrl-k: kill to end
                e.len = e.cursor;
                e.redraw();
            },
            0x15 => { // ctrl-u: kill line
                e.len = 0;
                e.cursor = 0;
                e.redraw();
            },
            0x0c => { // ctrl-l: clear screen
                e.io.write(e.io.ctx, "\x1b[2J\x1b[H");
                e.redraw();
            },
            0x09 => e.complete(),
            // Printable ASCII, and every byte of a UTF-8 sequence.
            else => if ((c >= 0x20 and c < 0x7f) or c >= 0x80) e.insert(c),
        }
        return .none;
    }

    fn insert(e: *Editor, c: u8) void {
        if (e.len == max_line) return;
        var i = e.len;
        while (i > e.cursor) : (i -= 1) e.buf[i] = e.buf[i - 1];
        e.buf[e.cursor] = c;
        e.len += 1;
        e.cursor += 1;
        if (e.cursor == e.len) {
            e.io.write(e.io.ctx, &[_]u8{c});
        } else e.redraw();
    }

    fn deleteAt(e: *Editor) void {
        if (e.cursor >= e.len) return;
        for (e.cursor..e.len - 1) |i| e.buf[i] = e.buf[i + 1];
        e.len -= 1;
        e.redraw();
    }

    fn home(e: *Editor) void {
        e.cursor = 0;
        e.redraw();
    }

    fn end(e: *Editor) void {
        e.cursor = e.len;
        e.redraw();
    }

    /// Repaint the prompt + line and put the cursor back.
    fn redraw(e: *Editor) void {
        e.io.write(e.io.ctx, "\r");
        e.io.write(e.io.ctx, e.prompt);
        e.io.write(e.io.ctx, e.buf[0..e.len]);
        e.io.write(e.io.ctx, "\x1b[K");
        if (e.cursor < e.len) {
            var seq: [16]u8 = undefined;
            const n = fmtCsi(&seq, e.len - e.cursor, 'D');
            e.io.write(e.io.ctx, seq[0..n]);
        }
    }

    fn fmtCsi(out: *[16]u8, n: usize, final: u8) usize {
        out[0] = 0x1b;
        out[1] = '[';
        var digits: [20]u8 = undefined;
        var d: usize = 0;
        var v = n;
        while (true) {
            digits[d] = '0' + @as(u8, @intCast(v % 10));
            d += 1;
            v /= 10;
            if (v == 0) break;
        }
        var k: usize = 2;
        while (d > 0) : (k += 1) {
            d -= 1;
            out[k] = digits[d];
        }
        out[k] = final;
        return k + 1;
    }

    // ------------------------------------------------------------ history

    fn remember(e: *Editor) void {
        if (e.len == 0) return;
        if (e.hist_count > 0) {
            const last = (e.hist_count - 1) % history_len;
            if (e.hist_lens[last] == e.len and eql(e.hist[last][0..e.len], e.buf[0..e.len])) return;
        }
        const slot = e.hist_count % history_len;
        @memcpy(e.hist[slot][0..e.len], e.buf[0..e.len]);
        e.hist_lens[slot] = e.len;
        e.hist_count += 1;
    }

    fn histMove(e: *Editor, up: bool) void {
        const oldest = if (e.hist_count > history_len) e.hist_count - history_len else 0;
        if (up) {
            if (e.hist_pos == oldest) return;
            if (e.hist_pos == e.hist_count) {
                @memcpy(e.saved[0..e.len], e.buf[0..e.len]);
                e.saved_len = e.len;
            }
            e.hist_pos -= 1;
        } else {
            if (e.hist_pos == e.hist_count) return;
            e.hist_pos += 1;
        }
        if (e.hist_pos == e.hist_count) {
            @memcpy(e.buf[0..e.saved_len], e.saved[0..e.saved_len]);
            e.len = e.saved_len;
        } else {
            const slot = e.hist_pos % history_len;
            @memcpy(e.buf[0..e.hist_lens[slot]], e.hist[slot][0..e.hist_lens[slot]]);
            e.len = e.hist_lens[slot];
        }
        e.cursor = e.len;
        e.redraw();
    }

    // --------------------------------------------------------- completion

    fn complete(e: *Editor) void {
        // The word under the cursor and whether it is in command position.
        var start = e.cursor;
        while (start > 0 and e.buf[start - 1] != ' ') start -= 1;
        var first = true;
        var i = start;
        while (i > 0) {
            i -= 1;
            const c = e.buf[i];
            if (c == ' ') continue;
            first = c == '|' or c == '(' or c == ';' or c == '{';
            break;
        }
        var cands: [max_candidates][candidate_len]u8 = undefined;
        var lens: [max_candidates]usize = undefined;
        const n = e.io.complete(e.io.ctx, e.buf[start..e.cursor], first, &cands, &lens);
        if (n == 0) return;
        // Common prefix of every candidate.
        var common = lens[0];
        for (cands[1..n], lens[1..n]) |c, l| {
            var k: usize = 0;
            while (k < common and k < l and c[k] == cands[0][k]) k += 1;
            common = k;
        }
        const word_len = e.cursor - start;
        if (common > word_len) {
            e.replaceWord(start, cands[0][0..common]);
        }
        if (n == 1) {
            const last = cands[0][lens[0] - 1];
            if (last != '/') e.insert(' ');
            return;
        }
        // Ambiguous: show the candidates, then repaint the line.
        e.io.write(e.io.ctx, "\r\n");
        for (cands[0..n], lens[0..n]) |c, l| {
            e.io.write(e.io.ctx, c[0..l]);
            e.io.write(e.io.ctx, "  ");
        }
        e.io.write(e.io.ctx, "\r\n");
        e.redraw();
    }

    fn replaceWord(e: *Editor, start: usize, text: []const u8) void {
        const tail_len = e.len - e.cursor;
        if (start + text.len + tail_len > max_line) return;
        var tail: [max_line]u8 = undefined;
        @memcpy(tail[0..tail_len], e.buf[e.cursor..e.len]);
        @memcpy(e.buf[start .. start + text.len], text);
        @memcpy(e.buf[start + text.len .. start + text.len + tail_len], tail[0..tail_len]);
        e.len = start + text.len + tail_len;
        e.cursor = start + text.len;
        e.redraw();
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
