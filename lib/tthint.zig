//! tthint — a from-scratch TrueType bytecode hinting interpreter.
//!
//! TrueType glyphs may carry an instruction stream that grid-fits the
//! outline to the pixel grid at a given size, so stems land on whole
//! pixels and small text stays crisp. The instructions are a stack
//! machine over 26.6 fixed-point pixel coordinates with a rich graphics
//! state (projection/freedom vectors, reference points, zones, a round
//! state), a control-value table (CVT), a storage area and user-defined
//! functions. Three programs run: `fpgm` (the font program, once, to
//! define functions), `prep` (the control-value program, once per size,
//! to set up the graphics state and scale the CVT) and each glyph's own
//! program (to move its points).
//!
//! This module is the VM. `lib/font.zig` owns the outlines and drives it:
//! `Hinter.init` runs fpgm+prep for a size; stage 2 will feed a glyph's
//! points in and read the fitted result back. Hinting is best-effort —
//! any malformed program or unimplemented corner returns `error.Hint`,
//! and the caller falls back to the unhinted outline. Freestanding-safe;
//! the one allocator (the caller's) holds the stack, storage, CVT, the
//! function table and the zones.

const std = @import("std");

pub const Error = error{ Hint, OutOfMemory };

// Test-only: the last instruction dispatched, so a failing program can be
// pinpointed. Compiled out of the OS build.
const dbg = @import("builtin").is_test;
var dbg_last: struct { op: u8 = 0, ip: usize = 0, sp: usize = 0 } = .{};

fn u16be(b: []const u8, off: usize) u16 {
    return @as(u16, b[off]) << 8 | b[off + 1];
}
fn i16be(b: []const u8, off: usize) i16 {
    return @bitCast(u16be(b, off));
}

// 26.6 and 2.14 fixed-point. Coordinates and CVT values are F26Dot6
// (1/64 pixel); the projection/freedom vectors are F2Dot14 (1.0 = 0x4000).
pub const F26Dot6 = i32;
const one_px: F26Dot6 = 64;
const F2Dot14 = i32;
const vec_one: F2Dot14 = 0x4000;

const Vec = struct { x: F2Dot14, y: F2Dot14 };

/// a*b/c with rounding, in i64 to avoid overflow.
fn mulDiv(a: i64, b: i64, c: i64) i64 {
    if (c == 0) return 0;
    const s: i64 = if ((a ^ b ^ c) < 0) -1 else 1;
    const num = (if (a < 0) -a else a) * (if (b < 0) -b else b);
    const den = if (c < 0) -c else c;
    return s * @divTrunc(num + @divTrunc(den, 2), den);
}

/// a*b with a 2.14 scale (b is F2Dot14): (a*b) >> 14, rounded.
fn mul214(a: i64, b: i64) i64 {
    return @divTrunc(a * b + 0x2000, 0x4000);
}

// Point flags (our own layout; the glyf on-curve bit is copied in).
pub const flag_on: u8 = 1 << 0; // on-curve (the caller sets it, reads it back)
const flag_touch_x: u8 = 1 << 1;
const flag_touch_y: u8 = 1 << 2;

/// A zone of points the interpreter moves. Zone 1 is the glyph (with
/// contour ends and the four phantom points); zone 0 is the twilight
/// zone, scratch space a program creates points in.
pub const Zone = struct {
    n: usize = 0, // points in use (incl. phantoms for the glyph zone)
    org: [][2]F26Dot6 = &.{}, // scaled original coords (never moved)
    cur: [][2]F26Dot6 = &.{}, // current (fitted) coords
    flags: []u8 = &.{},
    ends: []u16 = &.{}, // contour end indices (glyph zone)
    n_contours: usize = 0,
};

const RoundKind = enum { off, grid, half_grid, double_grid, down, up, super, super45 };

const GraphicsState = struct {
    pv: Vec = .{ .x = vec_one, .y = 0 }, // projection vector
    fv: Vec = .{ .x = vec_one, .y = 0 }, // freedom vector
    dv: Vec = .{ .x = vec_one, .y = 0 }, // dual projection vector
    rp0: u32 = 0,
    rp1: u32 = 0,
    rp2: u32 = 0,
    zp0: u8 = 1,
    zp1: u8 = 1,
    zp2: u8 = 1,
    round: RoundKind = .grid,
    period: F26Dot6 = one_px, // super-round params
    phase: F26Dot6 = 0,
    threshold: F26Dot6 = 32,
    loop: i32 = 1,
    min_dist: F26Dot6 = one_px,
    cv_cut_in: F26Dot6 = 68, // 17/16 px
    sw_cut_in: F26Dot6 = 0,
    sw_value: F26Dot6 = 0,
    delta_base: u32 = 9,
    delta_shift: u32 = 3,
    auto_flip: bool = true,
    instruct_control: u8 = 0,
};

pub const Hinter = struct {
    // Font tables (borrowed).
    fpgm: []const u8,
    prep: []const u8,
    cvt_raw: []const u8,
    upem: u32,
    ppem: u32,

    stack: []i32,
    sp: usize = 0,
    storage: []i32,
    cvt: []F26Dot6, // scaled, mutable
    funcs: []Func,
    twilight: Zone,
    glyph: Zone = .{}, // set per glyph
    gs: GraphicsState = .{},
    gs_default: GraphicsState = .{}, // the graphics state prep left, restored per glyph
    call_depth: u32 = 0,

    const Func = struct { defined: bool = false, code: []const u8 = &.{} };

    /// Scale a value in font units to F26.6 pixels at this ppem.
    pub fn scaleFUnit(self: *const Hinter, funits: i64) F26Dot6 {
        return @intCast(mulDiv(funits, @as(i64, self.ppem) * 64, self.upem));
    }

    /// Run one glyph's instructions over a prepared glyph zone (its points
    /// already scaled to 26.6, plus the four phantom points). Starts from
    /// the graphics state prep left; the caller reads `zone.cur` back.
    /// Best-effort: an error means keep the unhinted outline.
    pub fn hintGlyph(self: *Hinter, glyph_zone: Zone, instr: []const u8) Error!void {
        self.glyph = glyph_zone;
        self.gs = self.gs_default;
        self.sp = 0;
        self.call_depth = 0;
        if (instr.len != 0) try self.run(instr);
    }

    /// Set up the interpreter for a size: scale the CVT, run fpgm to
    /// define functions, then prep to establish the graphics state.
    pub fn init(
        a: std.mem.Allocator,
        fpgm: []const u8,
        prep: []const u8,
        cvt_raw: []const u8,
        upem: u32,
        ppem: u32,
        max_stack: usize,
        max_storage: usize,
        max_funcs: usize,
        max_twilight: usize,
    ) Error!Hinter {
        if (upem == 0 or ppem == 0) return Error.Hint;
        var h = Hinter{
            .fpgm = fpgm,
            .prep = prep,
            .cvt_raw = cvt_raw,
            .upem = upem,
            .ppem = ppem,
            .stack = try a.alloc(i32, @max(max_stack, 64)),
            .storage = try a.alloc(i32, @max(max_storage, 1)),
            .cvt = try a.alloc(F26Dot6, @max(cvt_raw.len / 2, 1)),
            .funcs = try a.alloc(Func, @max(max_funcs, 1)),
            .twilight = .{
                .org = try a.alloc([2]F26Dot6, @max(max_twilight, 1)),
                .cur = try a.alloc([2]F26Dot6, @max(max_twilight, 1)),
                .flags = try a.alloc(u8, @max(max_twilight, 1)),
                .n = @max(max_twilight, 1),
            },
        };
        @memset(h.storage, 0);
        for (h.funcs) |*f| f.* = .{};
        @memset(std.mem.sliceAsBytes(h.twilight.org), 0);
        @memset(std.mem.sliceAsBytes(h.twilight.cur), 0);
        @memset(h.twilight.flags, 0);
        // Scale the CVT.
        var i: usize = 0;
        while (i + 1 < cvt_raw.len) : (i += 2) h.cvt[i / 2] = h.scaleFUnit(i16be(cvt_raw, i));

        // fpgm and prep each start from a fresh default graphics state.
        if (fpgm.len != 0) {
            h.gs = .{};
            h.sp = 0;
            try h.run(fpgm);
        }
        if (prep.len != 0) {
            h.gs = .{};
            h.sp = 0;
            try h.run(prep);
        }
        h.gs_default = h.gs; // the state each glyph program starts from
        return h;
    }

    // ---- stack helpers ----
    fn push(self: *Hinter, v: i32) Error!void {
        if (self.sp >= self.stack.len) return Error.Hint;
        self.stack[self.sp] = v;
        self.sp += 1;
    }
    fn pop(self: *Hinter) Error!i32 {
        if (self.sp == 0) return Error.Hint;
        self.sp -= 1;
        return self.stack[self.sp];
    }
    fn popU(self: *Hinter) Error!u32 {
        return @bitCast(try self.pop());
    }

    fn zone(self: *Hinter, zp: u8) *Zone {
        return if (zp == 0) &self.twilight else &self.glyph;
    }

    // ---- rounding ----
    fn roundValue(self: *const Hinter, x: F26Dot6) F26Dot6 {
        switch (self.gs.round) {
            .off => return x,
            .grid => return roundSuper(x, one_px, 0, 32),
            .half_grid => return roundSuper(x, one_px, 32, 32),
            .double_grid => return roundSuper(x, 32, 0, 16),
            .down => return roundSuper(x, one_px, 0, 0),
            .up => return roundSuper(x, one_px, 0, 63),
            .super, .super45 => return roundSuper(x, self.gs.period, self.gs.phase, self.gs.threshold),
        }
    }

    // ---- vectors / projection ----
    fn project(self: *const Hinter, x: F26Dot6, y: F26Dot6) F26Dot6 {
        return @intCast((@as(i64, x) * self.gs.pv.x + @as(i64, y) * self.gs.pv.y) >> 14);
    }
    fn dualProject(self: *const Hinter, x: F26Dot6, y: F26Dot6) F26Dot6 {
        return @intCast((@as(i64, x) * self.gs.dv.x + @as(i64, y) * self.gs.dv.y) >> 14);
    }
    fn fDotP(self: *const Hinter) i64 {
        const v: i64 = (@as(i64, self.gs.fv.x) * self.gs.pv.x + @as(i64, self.gs.fv.y) * self.gs.pv.y) >> 14;
        return if (v == 0) 0x4000 else v;
    }

    /// Move point `pi` in zone `z` by `dist` (F26.6) along the freedom
    /// vector, touching the axes the freedom vector spans.
    fn movePoint(self: *Hinter, z: *Zone, pi: usize, dist: F26Dot6) Error!void {
        if (pi >= z.n) return Error.Hint;
        const fdotp = self.fDotP();
        if (self.gs.fv.x != 0) {
            z.cur[pi][0] += @intCast(mulDiv(dist, self.gs.fv.x, fdotp));
            z.flags[pi] |= flag_touch_x;
        }
        if (self.gs.fv.y != 0) {
            z.cur[pi][1] += @intCast(mulDiv(dist, self.gs.fv.y, fdotp));
            z.flags[pi] |= flag_touch_y;
        }
    }

    // ---- instruction stream ----
    /// Bytes to advance over the instruction at `ip` (handles inline PUSH
    /// data). Returns 0 on a truncated stream.
    fn insnLen(code: []const u8, ip: usize) usize {
        const op = code[ip];
        return switch (op) {
            0x40 => if (ip + 1 < code.len) 2 + @as(usize, code[ip + 1]) else 0, // NPUSHB
            0x41 => if (ip + 1 < code.len) 2 + @as(usize, code[ip + 1]) * 2 else 0, // NPUSHW
            0xB0...0xB7 => 1 + (@as(usize, op - 0xB0) + 1), // PUSHB[n]
            0xB8...0xBF => 1 + (@as(usize, op - 0xB8) + 1) * 2, // PUSHW[n]
            else => 1,
        };
    }

    /// From `ip` (just past an IF or ELSE), skip forward to the matching
    /// ELSE (if `want_else`) or EIF, honouring nesting. Returns the index
    /// of the byte AFTER that marker.
    fn skipBranch(code: []const u8, start: usize, want_else: bool) Error!usize {
        var ip = start;
        var depth: usize = 0;
        while (ip < code.len) {
            const op = code[ip];
            const len = insnLen(code, ip);
            if (len == 0) return Error.Hint;
            if (op == 0x58) { // IF
                depth += 1;
            } else if (op == 0x59) { // EIF
                if (depth == 0) return ip + 1;
                depth -= 1;
            } else if (op == 0x1B and depth == 0 and want_else) { // ELSE at our level
                return ip + 1;
            }
            ip += len;
        }
        return Error.Hint;
    }

    /// Execute a code stream (a program or a function body).
    fn run(self: *Hinter, code: []const u8) Error!void {
        var ip: usize = 0;
        while (ip < code.len) {
            const op = code[ip];
            const len = insnLen(code, ip);
            if (len == 0 or ip + len > code.len) return Error.Hint;
            var next = ip + len;
            if (dbg) dbg_last = .{ .op = op, .ip = ip, .sp = self.sp };
            switch (op) {
                // ---- push ----
                0x40 => { // NPUSHB
                    const n = code[ip + 1];
                    var k: usize = 0;
                    while (k < n) : (k += 1) try self.push(code[ip + 2 + k]);
                },
                0x41 => { // NPUSHW
                    const n = code[ip + 1];
                    var k: usize = 0;
                    while (k < n) : (k += 1) try self.push(i16be(code, ip + 2 + k * 2));
                },
                0xB0...0xB7 => {
                    const n = @as(usize, op - 0xB0) + 1;
                    var k: usize = 0;
                    while (k < n) : (k += 1) try self.push(code[ip + 1 + k]);
                },
                0xB8...0xBF => {
                    const n = @as(usize, op - 0xB8) + 1;
                    var k: usize = 0;
                    while (k < n) : (k += 1) try self.push(i16be(code, ip + 1 + k * 2));
                },
                // ---- stack ----
                0x20 => { // DUP
                    const v = try self.pop();
                    try self.push(v);
                    try self.push(v);
                },
                0x21 => _ = try self.pop(), // POP
                0x22 => self.sp = 0, // CLEAR
                0x23 => { // SWAP
                    const b = try self.pop();
                    const a2 = try self.pop();
                    try self.push(b);
                    try self.push(a2);
                },
                0x24 => try self.push(@intCast(self.sp)), // DEPTH
                0x25 => { // CINDEX
                    const k: usize = @intCast(try self.pop());
                    if (k == 0 or k > self.sp) return Error.Hint;
                    try self.push(self.stack[self.sp - k]);
                },
                0x26 => { // MINDEX: move the k-th-from-top element to the top
                    const k: usize = @intCast(try self.pop());
                    if (k == 0 or k > self.sp) return Error.Hint;
                    const v = self.stack[self.sp - k];
                    var j = self.sp - k;
                    while (j + 1 < self.sp) : (j += 1) self.stack[j] = self.stack[j + 1];
                    self.stack[self.sp - 1] = v; // count unchanged (removed one, re-added on top)
                },
                0x8A => { // ROLL
                    const c = try self.pop();
                    const b = try self.pop();
                    const a2 = try self.pop();
                    try self.push(b);
                    try self.push(c);
                    try self.push(a2);
                },
                // ---- arithmetic / logic ----
                0x60 => { const b = try self.pop(); const a2 = try self.pop(); try self.push(a2 +% b); }, // ADD
                0x61 => { const b = try self.pop(); const a2 = try self.pop(); try self.push(a2 -% b); }, // SUB
                0x62 => { const b = try self.pop(); const a2 = try self.pop(); if (b == 0) return Error.Hint; try self.push(@intCast(mulDiv(a2, 64, b))); }, // DIV (26.6)
                0x63 => { const b = try self.pop(); const a2 = try self.pop(); try self.push(@intCast(mulDiv(a2, b, 64))); }, // MUL (26.6)
                0x64 => { const a2 = try self.pop(); try self.push(if (a2 < 0) -a2 else a2); }, // ABS
                0x65 => { const a2 = try self.pop(); try self.push(-a2); }, // NEG
                0x66 => { const a2 = try self.pop(); try self.push(a2 & ~@as(i32, 63)); }, // FLOOR
                0x67 => { const a2 = try self.pop(); try self.push((a2 + 63) & ~@as(i32, 63)); }, // CEILING
                0x50 => { const b = try self.pop(); const a2 = try self.pop(); try self.push(@intFromBool(a2 < b)); }, // LT
                0x51 => { const b = try self.pop(); const a2 = try self.pop(); try self.push(@intFromBool(a2 <= b)); }, // LTEQ
                0x52 => { const b = try self.pop(); const a2 = try self.pop(); try self.push(@intFromBool(a2 > b)); }, // GT
                0x53 => { const b = try self.pop(); const a2 = try self.pop(); try self.push(@intFromBool(a2 >= b)); }, // GTEQ
                0x54 => { const b = try self.pop(); const a2 = try self.pop(); try self.push(@intFromBool(a2 == b)); }, // EQ
                0x55 => { const b = try self.pop(); const a2 = try self.pop(); try self.push(@intFromBool(a2 != b)); }, // NEQ
                0x56 => { const a2 = try self.pop(); try self.push(@intFromBool(@rem(@divTrunc(a2 + 32, 64), 2) != 0)); }, // ODD (rounded)
                0x57 => { const a2 = try self.pop(); try self.push(@intFromBool(@rem(@divTrunc(a2 + 32, 64), 2) == 0)); }, // EVEN
                0x5A => { const b = try self.pop(); const a2 = try self.pop(); try self.push(@intFromBool(a2 != 0 and b != 0)); }, // AND
                0x5B => { const b = try self.pop(); const a2 = try self.pop(); try self.push(@intFromBool(a2 != 0 or b != 0)); }, // OR
                0x5C => { const a2 = try self.pop(); try self.push(@intFromBool(a2 == 0)); }, // NOT
                0x8B => { const b = try self.pop(); const a2 = try self.pop(); try self.push(@max(a2, b)); }, // MAX
                0x8C => { const b = try self.pop(); const a2 = try self.pop(); try self.push(@min(a2, b)); }, // MIN
                // ---- rounding ops ----
                0x68, 0x69, 0x6A, 0x6B => { const a2 = try self.pop(); try self.push(self.roundValue(a2)); }, // ROUND[ab]
                0x6C, 0x6D, 0x6E, 0x6F => { const a2 = try self.pop(); try self.push(a2); }, // NROUND[ab]
                // ---- control flow ----
                0x58 => { // IF
                    const cond = try self.pop();
                    if (cond == 0) next = try skipBranch(code, next, true);
                },
                0x1B => next = try skipBranch(code, next, false), // ELSE (true branch fell through)
                0x59 => {}, // EIF
                0x1C => { // JMPR
                    const off = try self.pop();
                    next = try relJump(ip, off);
                },
                0x78 => { // JROT
                    const cond = try self.pop();
                    const off = try self.pop();
                    if (cond != 0) next = try relJump(ip, off);
                },
                0x79 => { // JROF
                    const cond = try self.pop();
                    const off = try self.pop();
                    if (cond == 0) next = try relJump(ip, off);
                },
                // ---- functions ----
                0x2C => { // FDEF
                    const fn_no: usize = @intCast(try self.pop());
                    if (fn_no >= self.funcs.len) return Error.Hint;
                    const body_start = next;
                    const body_end = try findEndf(code, next);
                    self.funcs[fn_no] = .{ .defined = true, .code = code[body_start..body_end] };
                    next = body_end + 1; // past ENDF
                },
                0x2D => return, // ENDF (returns from the function body)
                0x2B => { // CALL
                    const fn_no: usize = @intCast(try self.pop());
                    try self.callFn(fn_no);
                },
                0x2A => { // LOOPCALL
                    const fn_no: usize = @intCast(try self.pop());
                    var count = try self.pop();
                    while (count > 0) : (count -= 1) try self.callFn(fn_no);
                },
                // ---- storage / CVT ----
                0x42 => { const v = try self.pop(); const idx: usize = @intCast(try self.pop()); if (idx >= self.storage.len) return Error.Hint; self.storage[idx] = v; }, // WS
                0x43 => { const idx: usize = @intCast(try self.pop()); if (idx >= self.storage.len) return Error.Hint; try self.push(self.storage[idx]); }, // RS
                0x44 => { const v = try self.pop(); const idx: usize = @intCast(try self.pop()); if (idx >= self.cvt.len) return Error.Hint; self.cvt[idx] = v; }, // WCVTP (pixels)
                0x70 => { const v = try self.pop(); const idx: usize = @intCast(try self.pop()); if (idx >= self.cvt.len) return Error.Hint; self.cvt[idx] = self.scaleFUnit(v); }, // WCVTF (funits)
                0x45 => { const idx: usize = @intCast(try self.pop()); if (idx >= self.cvt.len) return Error.Hint; try self.push(self.cvt[idx]); }, // RCVT
                // ---- graphics-state setters ----
                0x00, 0x01 => { // SVTCA[a]: set both vectors to an axis
                    const axis_x = (op & 1) != 0;
                    const v = Vec{ .x = if (axis_x) vec_one else 0, .y = if (axis_x) 0 else vec_one };
                    self.gs.pv = v;
                    self.gs.fv = v;
                    self.gs.dv = v;
                },
                0x02, 0x03 => { const axis_x = (op & 1) != 0; self.gs.pv = axisVec(axis_x); self.gs.dv = self.gs.pv; }, // SPVTCA
                0x04, 0x05 => { const axis_x = (op & 1) != 0; self.gs.fv = axisVec(axis_x); }, // SFVTCA
                0x06, 0x07, 0x08, 0x09, 0x86, 0x87 => try self.setVectorToLine(op), // SPVTL/SFVTL/SDPVTL
                0x0A => { const y = try self.pop(); const x = try self.pop(); self.gs.pv = normalize(x, y); self.gs.dv = self.gs.pv; }, // SPVFS
                0x0B => { const y = try self.pop(); const x = try self.pop(); self.gs.fv = normalize(x, y); }, // SFVFS
                0x0C => { try self.push(self.gs.pv.x); try self.push(self.gs.pv.y); }, // GPV
                0x0D => { try self.push(self.gs.fv.x); try self.push(self.gs.fv.y); }, // GFV
                0x0E => self.gs.fv = self.gs.pv, // SFVTPV
                0x10 => self.gs.rp0 = try self.popU(), // SRP0
                0x11 => self.gs.rp1 = try self.popU(), // SRP1
                0x12 => self.gs.rp2 = try self.popU(), // SRP2
                0x13 => self.gs.zp0 = try self.popZone(), // SZP0
                0x14 => self.gs.zp1 = try self.popZone(), // SZP1
                0x15 => self.gs.zp2 = try self.popZone(), // SZP2
                0x16 => { const z = try self.popZone(); self.gs.zp0 = z; self.gs.zp1 = z; self.gs.zp2 = z; }, // SZPS
                0x17 => self.gs.loop = try self.pop(), // SLOOP
                0x18 => self.gs.round = .grid, // RTG
                0x19 => self.gs.round = .half_grid, // RTHG
                0x3D => self.gs.round = .double_grid, // RTDG
                0x7A => self.gs.round = .off, // ROFF
                0x7C => self.gs.round = .up, // RUTG
                0x7D => self.gs.round = .down, // RDTG
                0x76 => try self.setSuperRound(false), // SROUND
                0x77 => try self.setSuperRound(true), // S45ROUND
                0x1A => self.gs.min_dist = try self.pop(), // SMD
                0x1D => self.gs.cv_cut_in = try self.pop(), // SCVTCI
                0x1E => self.gs.sw_cut_in = try self.pop(), // SSWCI
                0x1F => self.gs.sw_value = self.scaleFUnit(try self.pop()), // SSW (value in funits)
                0x4D => self.gs.auto_flip = true, // FLIPON
                0x4E => self.gs.auto_flip = false, // FLIPOFF
                0x5E => self.gs.delta_base = try self.popU(), // SDB
                0x5F => self.gs.delta_shift = try self.popU(), // SDS
                0x8E => { const sel = try self.pop(); const val = try self.pop(); if (sel == 1 or sel == 2 or sel == 3) self.gs.instruct_control = @intCast(val & 0xff); }, // INSTCTRL
                0x85 => _ = try self.pop(), // SCANCTRL (grayscale: ignore)
                0x8D => _ = try self.pop(), // SCANTYPE
                0x7E => _ = try self.pop(), // SANGW (obsolete)
                0x7F => _ = try self.pop(), // AA (obsolete)
                // ---- measurement ----
                0x4B => try self.push(@intCast(self.ppem)), // MPPEM
                0x4C => try self.push(@intCast(self.ppem * 64)), // MPS (point size ~ ppem)
                0x88 => { const sel = try self.pop(); try self.push(getInfo(sel)); }, // GETINFO
                0x91 => { _ = try self.pop(); try self.push(0); try self.push(0); }, // GETVARIATION (no variations)
                0x46, 0x47 => try self.opGC(op), // GC
                0x49, 0x4A => try self.opMD(op), // MD
                // ---- point movement (used mostly by glyph programs) ----
                0x2E, 0x2F => try self.opMDAP(op), // MDAP[a]
                0x3E, 0x3F => try self.opMIAP(op), // MIAP[a]
                0xC0...0xDF => try self.opMDRP(op), // MDRP
                0xE0...0xFF => try self.opMIRP(op), // MIRP
                0x3A, 0x3B => try self.opMSIRP(op), // MSIRP
                0x39 => try self.opIP(), // IP
                0x3C => try self.opAlignRp(), // ALIGNRP
                0x27 => try self.opAlignPts(), // ALIGNPTS
                0x30, 0x31 => try self.opIUP(op), // IUP[a]
                0x32, 0x33 => try self.opSHP(op), // SHP
                0x34, 0x35 => try self.opSHC(op), // SHC
                0x36, 0x37 => try self.opSHZ(op), // SHZ
                0x38 => try self.opSHPIX(), // SHPIX
                0x48 => try self.opSCFS(), // SCFS
                0x80 => try self.opFlipPt(), // FLIPPT
                0x81, 0x82 => try self.opFlipRg(op), // FLIPRGON/OFF
                0x29 => try self.opUTP(), // UTP
                0x0F => try self.opISect(), // ISECT
                // ---- deltas ----
                0x5D, 0x71, 0x72 => try self.opDeltaP(op), // DELTAP1/2/3
                0x73, 0x74, 0x75 => try self.opDeltaC(op), // DELTAC1/2/3
                0x4F => _ = try self.pop(), // DEBUG
                else => return Error.Hint, // IDEF (0x89) and anything unknown: fall back
            }
            ip = next;
        }
    }

    fn callFn(self: *Hinter, fn_no: usize) Error!void {
        if (fn_no >= self.funcs.len or !self.funcs[fn_no].defined) return Error.Hint;
        if (self.call_depth >= 128) return Error.Hint;
        self.call_depth += 1;
        defer self.call_depth -= 1;
        try self.run(self.funcs[fn_no].code);
    }

    fn popZone(self: *Hinter) Error!u8 {
        const z = try self.pop();
        if (z != 0 and z != 1) return Error.Hint;
        return @intCast(z);
    }

    fn setVectorToLine(self: *Hinter, op: u8) Error!void {
        // SPVTL[a] 0x06/07, SFVTL[a] 0x08/09, SDPVTL[a] 0x86/87.
        const p2 = try self.popU();
        const p1 = try self.popU();
        const za = self.zone(self.gs.zp2);
        const zb = self.zone(self.gs.zp1);
        if (p1 >= zb.n or p2 >= za.n) return Error.Hint;
        var dx = za.cur[p2][0] - zb.cur[p1][0];
        var dy = za.cur[p2][1] - zb.cur[p1][1];
        const perp = (op == 0x07 or op == 0x09 or op == 0x87);
        if (perp) {
            const t = dx;
            dx = -dy;
            dy = t;
        }
        const v = normalize(dx, dy);
        switch (op) {
            0x06, 0x07 => { self.gs.pv = v; self.gs.dv = v; },
            0x08, 0x09 => self.gs.fv = v,
            else => { // SDPVTL: dual set from ORIGINAL coords
                var odx = za.org[p2][0] - zb.org[p1][0];
                var ody = za.org[p2][1] - zb.org[p1][1];
                if (perp) { const t = odx; odx = -ody; ody = t; }
                self.gs.dv = normalize(odx, ody);
                self.gs.pv = v;
            },
        }
    }

    fn setSuperRound(self: *Hinter, is45: bool) Error!void {
        const n: u32 = @intCast(try self.popU() & 0xff);
        // period: bits 6-7, phase: bits 4-5, threshold: bits 0-3.
        const base: F26Dot6 = if (is45) 46 else 64; // sqrt2/2 px ≈ 45.25 → 46 (approx)
        const period: F26Dot6 = switch ((n >> 6) & 3) {
            0 => @divTrunc(base, 2),
            1 => base,
            2 => base * 2,
            else => base,
        };
        const phase: F26Dot6 = @intCast(((n >> 4) & 3) * @as(u32, @intCast(period)) / 4);
        const tsel = n & 0xf;
        const threshold: F26Dot6 = if (tsel == 0) period - 1 else @intCast(@divTrunc((@as(i64, tsel) - 4) * @as(i64, period), 8));
        self.gs.round = if (is45) .super45 else .super;
        self.gs.period = period;
        self.gs.phase = phase;
        self.gs.threshold = threshold;
    }

    fn opGC(self: *Hinter, op: u8) Error!void {
        const pi: usize = @intCast(try self.popU());
        const z = self.zone(self.gs.zp2);
        if (pi >= z.n) return Error.Hint;
        const c = if (op == 0x46) self.project(z.cur[pi][0], z.cur[pi][1]) else self.dualProject(z.org[pi][0], z.org[pi][1]);
        try self.push(c);
    }

    fn opMD(self: *Hinter, op: u8) Error!void {
        const p2: usize = @intCast(try self.popU());
        const p1: usize = @intCast(try self.popU());
        const za = self.zone(self.gs.zp1);
        const zb = self.zone(self.gs.zp0);
        if (p2 >= za.n or p1 >= zb.n) return Error.Hint;
        const d = if (op == 0x49)
            self.project(zb.cur[p1][0] - za.cur[p2][0], zb.cur[p1][1] - za.cur[p2][1])
        else
            self.dualProject(zb.org[p1][0] - za.org[p2][0], zb.org[p1][1] - za.org[p2][1]);
        try self.push(d);
    }

    fn opMDAP(self: *Hinter, op: u8) Error!void {
        const pi: usize = @intCast(try self.popU());
        const z = self.zone(self.gs.zp0);
        if (pi >= z.n) return Error.Hint;
        if (op == 0x2F) { // round to grid
            const cur = self.project(z.cur[pi][0], z.cur[pi][1]);
            const dist = self.roundValue(cur) - cur;
            try self.movePoint(z, pi, dist);
        } else {
            // touch only
            if (self.gs.fv.x != 0) z.flags[pi] |= flag_touch_x;
            if (self.gs.fv.y != 0) z.flags[pi] |= flag_touch_y;
        }
        self.gs.rp0 = @intCast(pi);
        self.gs.rp1 = @intCast(pi);
    }

    fn opMIAP(self: *Hinter, op: u8) Error!void {
        const cvti: usize = @intCast(try self.popU());
        const pi: usize = @intCast(try self.popU());
        const z = self.zone(self.gs.zp0);
        if (pi >= z.n or cvti >= self.cvt.len) return Error.Hint;
        var cv = self.cvt[cvti];
        // In the twilight zone MIAP sets the point's original position too.
        if (self.gs.zp0 == 0) {
            z.org[pi][0] = @intCast(mul214(cv, self.gs.pv.x));
            z.org[pi][1] = @intCast(mul214(cv, self.gs.pv.y));
            z.cur[pi] = z.org[pi];
        }
        const cur = self.project(z.cur[pi][0], z.cur[pi][1]);
        if (op == 0x3F) { // round + cut-in
            if (@abs(cv - cur) > self.gs.cv_cut_in) cv = cur;
            cv = self.roundValue(cv);
        }
        try self.movePoint(z, pi, cv - cur);
        self.gs.rp0 = @intCast(pi);
        self.gs.rp1 = @intCast(pi);
    }

    fn opMDRP(self: *Hinter, op: u8) Error!void {
        const pi: usize = @intCast(try self.popU());
        const z1 = self.zone(self.gs.zp1);
        const z0 = self.zone(self.gs.zp0);
        if (pi >= z1.n or self.gs.rp0 >= z0.n) return Error.Hint;
        const rp0 = self.gs.rp0;
        var dist = self.dualProject(z1.org[pi][0] - z0.org[rp0][0], z1.org[pi][1] - z0.org[rp0][1]);
        dist = self.applyMDRP(op, dist);
        const cur = self.project(z1.cur[pi][0] - z0.cur[rp0][0], z1.cur[pi][1] - z0.cur[rp0][1]);
        try self.movePoint(z1, pi, dist - cur);
        self.gs.rp1 = rp0;
        self.gs.rp2 = @intCast(pi);
        if ((op & 0x10) != 0) self.gs.rp0 = @intCast(pi);
    }

    fn opMIRP(self: *Hinter, op: u8) Error!void {
        const cvti: usize = @intCast(try self.popU());
        const pi: usize = @intCast(try self.popU());
        const z1 = self.zone(self.gs.zp1);
        const z0 = self.zone(self.gs.zp0);
        if (pi >= z1.n or self.gs.rp0 >= z0.n or cvti >= self.cvt.len) return Error.Hint;
        const rp0 = self.gs.rp0;
        var cv = self.cvt[cvti];
        // cut-in against the original distance
        const org = self.dualProject(z1.org[pi][0] - z0.org[rp0][0], z1.org[pi][1] - z0.org[rp0][1]);
        if (self.gs.auto_flip and (cv < 0) != (org < 0)) cv = -cv;
        const cur = self.project(z1.cur[pi][0] - z0.cur[rp0][0], z1.cur[pi][1] - z0.cur[rp0][1]);
        var dist = cv;
        if ((op & 0x04) != 0) { // round
            if (@abs(cv - org) > self.gs.cv_cut_in) dist = org;
            dist = self.roundValue(dist);
        }
        dist = self.applyMinDist(op, dist);
        try self.movePoint(z1, pi, dist - cur);
        self.gs.rp1 = rp0;
        self.gs.rp2 = @intCast(pi);
        if ((op & 0x10) != 0) self.gs.rp0 = @intCast(pi);
    }

    fn opMSIRP(self: *Hinter, op: u8) Error!void {
        const d = try self.pop();
        const pi: usize = @intCast(try self.popU());
        const z1 = self.zone(self.gs.zp1);
        const z0 = self.zone(self.gs.zp0);
        if (pi >= z1.n or self.gs.rp0 >= z0.n) return Error.Hint;
        const rp0 = self.gs.rp0;
        const cur = self.project(z1.cur[pi][0] - z0.cur[rp0][0], z1.cur[pi][1] - z0.cur[rp0][1]);
        try self.movePoint(z1, pi, d - cur);
        self.gs.rp1 = rp0;
        self.gs.rp2 = @intCast(pi);
        if ((op & 0x01) != 0) self.gs.rp0 = @intCast(pi);
    }

    fn applyMDRP(self: *Hinter, op: u8, dist_in: F26Dot6) F26Dot6 {
        var dist = dist_in;
        // single-width cut-in
        if (@abs(dist - self.gs.sw_value) < self.gs.sw_cut_in) {
            dist = if (dist >= 0) self.gs.sw_value else -self.gs.sw_value;
        }
        if ((op & 0x04) != 0) dist = self.roundValue(dist);
        return self.applyMinDist(op, dist);
    }

    fn applyMinDist(self: *Hinter, op: u8, dist_in: F26Dot6) F26Dot6 {
        var dist = dist_in;
        if ((op & 0x08) != 0) { // min-distance
            if (dist >= 0) {
                if (dist < self.gs.min_dist) dist = self.gs.min_dist;
            } else {
                if (dist > -self.gs.min_dist) dist = -self.gs.min_dist;
            }
        }
        return dist;
    }

    fn opIP(self: *Hinter) Error!void {
        // Interpolate `loop` points between rp1 and rp2 by their original
        // relative positions along the projection.
        const z1 = self.zone(self.gs.zp1);
        const z0 = self.zone(self.gs.zp0);
        if (self.gs.rp1 >= z0.n or self.gs.rp2 >= z1.n) return Error.Hint;
        const org_ref1 = self.dualProject(z0.org[self.gs.rp1][0], z0.org[self.gs.rp1][1]);
        const org_ref2 = self.dualProject(z1.org[self.gs.rp2][0], z1.org[self.gs.rp2][1]);
        const cur_ref1 = self.project(z0.cur[self.gs.rp1][0], z0.cur[self.gs.rp1][1]);
        const cur_ref2 = self.project(z1.cur[self.gs.rp2][0], z1.cur[self.gs.rp2][1]);
        const org_span = org_ref2 - org_ref1;
        const cur_span = cur_ref2 - cur_ref1;
        const zp2 = self.zone(self.gs.zp2);
        var count = self.gs.loop;
        self.gs.loop = 1;
        while (count > 0) : (count -= 1) {
            const pi: usize = @intCast(try self.popU());
            if (pi >= zp2.n) return Error.Hint;
            const org_p = self.dualProject(zp2.org[pi][0], zp2.org[pi][1]);
            const cur_p = self.project(zp2.cur[pi][0], zp2.cur[pi][1]);
            const new_p = if (org_span != 0)
                cur_ref1 + @as(F26Dot6, @intCast(mulDiv(org_p - org_ref1, cur_span, org_span)))
            else
                cur_ref1 + (org_p - org_ref1);
            try self.movePoint(zp2, pi, new_p - cur_p);
        }
    }

    fn opAlignRp(self: *Hinter) Error!void {
        const z0 = self.zone(self.gs.zp0);
        if (self.gs.rp0 >= z0.n) return Error.Hint;
        const zp1 = self.zone(self.gs.zp1);
        var count = self.gs.loop;
        self.gs.loop = 1;
        while (count > 0) : (count -= 1) {
            const pi: usize = @intCast(try self.popU());
            if (pi >= zp1.n) return Error.Hint;
            const cur = self.project(zp1.cur[pi][0] - z0.cur[self.gs.rp0][0], zp1.cur[pi][1] - z0.cur[self.gs.rp0][1]);
            try self.movePoint(zp1, pi, -cur);
        }
    }

    fn opAlignPts(self: *Hinter) Error!void {
        const p2: usize = @intCast(try self.popU());
        const p1: usize = @intCast(try self.popU());
        const z1 = self.zone(self.gs.zp1);
        const z0 = self.zone(self.gs.zp0);
        if (p1 >= z0.n or p2 >= z1.n) return Error.Hint;
        const d = self.project(z0.cur[p1][0] - z1.cur[p2][0], z0.cur[p1][1] - z1.cur[p2][1]);
        const half = @divTrunc(d, 2);
        try self.movePoint(z1, p2, half);
        try self.movePoint(z0, p1, -(d - half));
    }

    fn opSHP(self: *Hinter, op: u8) Error!void {
        const d = try self.shiftAmount(op);
        const zp2 = self.zone(self.gs.zp2);
        var count = self.gs.loop;
        self.gs.loop = 1;
        while (count > 0) : (count -= 1) {
            const pi: usize = @intCast(try self.popU());
            if (pi >= zp2.n) return Error.Hint;
            try self.movePoint(zp2, pi, d);
        }
    }

    fn opSHC(self: *Hinter, op: u8) Error!void {
        const ci: usize = @intCast(try self.popU());
        const d = try self.shiftAmount(op);
        const z = self.zone(self.gs.zp2);
        if (ci >= z.n_contours) return Error.Hint;
        const start: usize = if (ci == 0) 0 else @as(usize, z.ends[ci - 1]) + 1;
        const end: usize = @as(usize, z.ends[ci]) + 1;
        var pi = start;
        while (pi < end and pi < z.n) : (pi += 1) try self.movePoint(z, pi, d);
    }

    fn opSHZ(self: *Hinter, op: u8) Error!void {
        const zi = try self.popZone();
        const d = try self.shiftAmount(op);
        const z = self.zone(zi);
        var pi: usize = 0;
        while (pi < z.n) : (pi += 1) try self.movePoint(z, pi, d);
    }

    /// The projected shift a SHP/SHC/SHZ applies: the movement rp (rp1 for
    /// a=0 in zp0, rp2 for a=1 in zp1) has already undergone under hinting.
    fn shiftAmount(self: *Hinter, op: u8) Error!F26Dot6 {
        const use_rp1 = (op & 1) == 0;
        const rp = if (use_rp1) self.gs.rp1 else self.gs.rp2;
        const z = if (use_rp1) self.zone(self.gs.zp0) else self.zone(self.gs.zp1);
        if (rp >= z.n) return Error.Hint;
        return self.project(z.cur[rp][0] - z.org[rp][0], z.cur[rp][1] - z.org[rp][1]);
    }

    fn opSHPIX(self: *Hinter) Error!void {
        const amt = try self.pop();
        const zp2 = self.zone(self.gs.zp2);
        var count = self.gs.loop;
        self.gs.loop = 1;
        while (count > 0) : (count -= 1) {
            const pi: usize = @intCast(try self.popU());
            if (pi >= zp2.n) return Error.Hint;
            // move along the freedom vector by `amt` pixels
            if (self.gs.fv.x != 0) { zp2.cur[pi][0] += @intCast(mul214(amt, self.gs.fv.x)); zp2.flags[pi] |= flag_touch_x; }
            if (self.gs.fv.y != 0) { zp2.cur[pi][1] += @intCast(mul214(amt, self.gs.fv.y)); zp2.flags[pi] |= flag_touch_y; }
        }
    }

    fn opSCFS(self: *Hinter) Error!void {
        const val = try self.pop();
        const pi: usize = @intCast(try self.popU());
        const z = self.zone(self.gs.zp2);
        if (pi >= z.n) return Error.Hint;
        const cur = self.project(z.cur[pi][0], z.cur[pi][1]);
        try self.movePoint(z, pi, val - cur);
    }

    fn opIUP(self: *Hinter, op: u8) Error!void {
        // Interpolate untouched points per contour along one axis. Only
        // meaningful for the glyph zone; a no-op if it has no contours.
        const z = &self.glyph;
        if (z.n_contours == 0) return;
        const is_x = (op & 1) != 0;
        const touch_bit: u8 = if (is_x) flag_touch_x else flag_touch_y;
        const axis: usize = if (is_x) 0 else 1;
        var c: usize = 0;
        var start: usize = 0;
        while (c < z.n_contours) : (c += 1) {
            const end: usize = z.ends[c];
            if (end >= z.n) return Error.Hint;
            iupContour(z, start, end, axis, touch_bit);
            start = end + 1;
        }
    }

    fn opFlipPt(self: *Hinter) Error!void {
        const z = &self.glyph;
        var count = self.gs.loop;
        self.gs.loop = 1;
        while (count > 0) : (count -= 1) {
            const pi: usize = @intCast(try self.popU());
            if (pi >= z.n) return Error.Hint;
            z.flags[pi] ^= flag_on;
        }
    }

    fn opFlipRg(self: *Hinter, op: u8) Error!void {
        const hi: usize = @intCast(try self.popU());
        const lo: usize = @intCast(try self.popU());
        const z = &self.glyph;
        var pi = lo;
        while (pi <= hi and pi < z.n) : (pi += 1) {
            if (op == 0x81) z.flags[pi] |= flag_on else z.flags[pi] &= ~flag_on;
        }
    }

    fn opUTP(self: *Hinter) Error!void {
        const pi: usize = @intCast(try self.popU());
        const z = self.zone(self.gs.zp0);
        if (pi >= z.n) return Error.Hint;
        var clear: u8 = 0xff;
        if (self.gs.fv.x != 0) clear &= ~flag_touch_x;
        if (self.gs.fv.y != 0) clear &= ~flag_touch_y;
        z.flags[pi] &= clear;
    }

    fn opISect(self: *Hinter) Error!void {
        // ISECT: move point to the intersection of two lines. Rare; we
        // pop its five args and leave the point where it is (best-effort).
        _ = try self.pop();
        _ = try self.pop();
        _ = try self.pop();
        _ = try self.pop();
        _ = try self.pop();
    }

    fn opDeltaP(self: *Hinter, op: u8) Error!void {
        const nn: usize = @intCast(try self.popU());
        const base: u32 = self.gs.delta_base + switch (op) {
            0x5D => @as(u32, 0),
            0x71 => 16,
            else => 32,
        };
        const z = self.zone(self.gs.zp0);
        var k: usize = 0;
        while (k < nn) : (k += 1) {
            const pi: usize = @intCast(try self.popU());
            const arg: u32 = @intCast(try self.popU() & 0xff);
            self.applyDelta(z, pi, arg, base) catch return Error.Hint;
        }
    }

    fn opDeltaC(self: *Hinter, op: u8) Error!void {
        const nn: usize = @intCast(try self.popU());
        const base: u32 = self.gs.delta_base + switch (op) {
            0x73 => @as(u32, 0),
            0x74 => 16,
            else => 32,
        };
        var k: usize = 0;
        while (k < nn) : (k += 1) {
            const ci: usize = @intCast(try self.popU());
            const arg: u32 = @intCast(try self.popU() & 0xff);
            if (ci >= self.cvt.len) return Error.Hint;
            const ppem_sel = base + ((arg >> 4) & 0xf);
            if (ppem_sel != self.ppem) continue;
            self.cvt[ci] += deltaStep(arg, self.gs.delta_shift);
        }
    }

    fn applyDelta(self: *Hinter, z: *Zone, pi: usize, arg: u32, base: u32) Error!void {
        if (pi >= z.n) return Error.Hint;
        const ppem_sel = base + ((arg >> 4) & 0xf);
        if (ppem_sel != self.ppem) return;
        try self.movePoint(z, pi, deltaStep(arg, self.gs.delta_shift));
    }
};

fn deltaStep(arg: u32, shift: u32) F26Dot6 {
    // low nibble: a signed magnitude in 1/(2^shift) pixels (no zero step).
    var steps: i32 = @intCast(arg & 0xf);
    steps -= 8;
    if (steps >= 0) steps += 1; // skip 0
    const denom: i32 = @as(i32, 1) << @intCast(shift);
    return @intCast(@divTrunc(@as(i64, steps) * 64, denom));
}

fn axisVec(x: bool) Vec {
    return .{ .x = if (x) vec_one else 0, .y = if (x) 0 else vec_one };
}

fn normalize(x: F26Dot6, y: F26Dot6) Vec {
    if (x == 0 and y == 0) return .{ .x = vec_one, .y = 0 };
    const fx: f64 = @floatFromInt(x);
    const fy: f64 = @floatFromInt(y);
    const len = @sqrt(fx * fx + fy * fy);
    return .{
        .x = @intFromFloat(fx / len * @as(f64, vec_one)),
        .y = @intFromFloat(fy / len * @as(f64, vec_one)),
    };
}

fn getInfo(sel: i32) i32 {
    var res: i32 = 0;
    if ((sel & 1) != 0) res |= 35; // interpreter version 35 (grayscale, classic)
    // Not rotated, not stretched, no ClearType/subpixel — all zero.
    return res;
}

fn relJump(ip: usize, off: i32) Error!usize {
    const target = @as(i64, @intCast(ip)) + off;
    if (target < 0) return Error.Hint;
    return @intCast(target);
}

/// Find the ENDF matching the FDEF whose body starts at `start` (FDEFs do
/// not nest, but a body may contain IFs). Returns the ENDF's index.
fn findEndf(code: []const u8, start: usize) Error!usize {
    var ip = start;
    while (ip < code.len) {
        const op = code[ip];
        if (op == 0x2D) return ip; // ENDF
        const len = Hinter.insnLen(code, ip);
        if (len == 0) return Error.Hint;
        ip += len;
    }
    return Error.Hint;
}

/// General super-rounding (OpenType `Round_Super`), engine compensation 0.
fn roundSuper(distance: F26Dot6, period: F26Dot6, phase: F26Dot6, threshold: F26Dot6) F26Dot6 {
    if (period == 0) return distance;
    const p: i64 = period;
    if (distance >= 0) {
        var val: i64 = (@as(i64, distance) - phase + threshold);
        val = @divFloor(val, p) * p;
        val += phase;
        if (val < 0) val = phase;
        return @intCast(val);
    } else {
        var val: i64 = (-(@as(i64, distance)) - phase + threshold);
        val = @divFloor(val, p) * p;
        val += phase;
        if (val < 0) val = phase;
        return @intCast(-val);
    }
}

// --------------------------------------------------------------- IUP

/// Interpolate the untouched points of one contour (indices lo..=hi) along
/// `axis` (0=x,1=y) between the touched points, per the TrueType IUP rule.
fn iupContour(z: *Zone, lo: usize, hi: usize, axis: usize, touch_bit: u8) void {
    const n = hi - lo + 1;
    if (n == 0) return;
    // First touched point in the contour.
    var first: ?usize = null;
    var i = lo;
    while (i <= hi) : (i += 1) {
        if (z.flags[i] & touch_bit != 0) {
            first = i;
            break;
        }
    }
    const f = first orelse return; // no touched point: contour unchanged
    // Walk touched→touched arcs around the ring, interpolating between.
    var p = f;
    while (true) {
        // next touched point after p (wrapping)
        var q = if (p == hi) lo else p + 1;
        while (q != f) {
            if (z.flags[q] & touch_bit != 0) break;
            q = if (q == hi) lo else q + 1;
        }
        // Handle the ring arc that starts at the last touched point.
        if (z.flags[q] & touch_bit == 0) q = f;
        interpArc(z, lo, hi, p, q, axis);
        p = q;
        if (p == f) break;
    }
}

fn interpArc(z: *Zone, lo: usize, hi: usize, p: usize, q: usize, axis: usize) void {
    // Interpolate untouched points strictly between p and q (moving
    // forward with wraparound) using original coords as the reference.
    const cp = z.cur[p][axis];
    const cq = z.cur[q][axis];
    const op = z.org[p][axis];
    const oq = z.org[q][axis];
    var i = if (p == hi) lo else p + 1;
    while (i != q) {
        const oi = z.org[i][axis];
        var new: F26Dot6 = undefined;
        const omin = @min(op, oq);
        const omax = @max(op, oq);
        if (oi <= omin) {
            new = (if (op <= oq) cp else cq) + (oi - omin);
        } else if (oi >= omax) {
            new = (if (op <= oq) cq else cp) + (oi - omax);
        } else {
            const denom = oq - op;
            if (denom == 0) {
                new = cp;
            } else {
                new = cp + @as(F26Dot6, @intCast(mulDiv(oi - op, cq - cp, denom)));
            }
        }
        z.cur[i][axis] = new;
        i = if (i == hi) lo else i + 1;
    }
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "interpreter runs a synthetic fpgm+prep: push, arith, CVT, storage, IF, FDEF/CALL, round" {
    const a = testing.allocator;
    // fpgm defines function 0: it doubles CVT[0] in place.
    //   FDEF(0): PUSHB 0 ; DUP ; RCVT ; PUSHB 2 ; MUL ; WCVTP is awkward with
    //   stack order, so build it explicitly.
    // Simpler: fn 0 = { PUSHB[0] 0 ; PUSHB[0] 0 ; RCVT ; DUP ; ADD ; WCVTP }
    //   RCVT expects idx on stack -> pushes value; then we need (idx, value)
    //   for WCVTP. Layout the stack carefully below.
    const fpgm = [_]u8{
        0xB0, 0x00, // PUSHB[0] 0   -> fn number
        0x2C, //       FDEF
        0xB0, 0x00, //   PUSHB[0] 0     [0]
        0xB0, 0x00, //   PUSHB[0] 0     [0,0]
        0x45, //         RCVT           [0, cvt0]
        0x20, //         DUP            [0, cvt0, cvt0]
        0x60, //         ADD            [0, 2*cvt0]
        0x44, //         WCVTP          []
        0x2D, //       ENDF
    };
    // prep: CALL fn 0, then store MPPEM into storage[0], and set RTG+round 100.
    const prep = [_]u8{
        0xB0, 0x00, // PUSHB[0] 0
        0x2B, //       CALL 0        (doubles cvt[0])
        0x4B, //       MPPEM          [ppem]
        0xB0, 0x00, // PUSHB[0] 0     [ppem, 0]
        0x23, //       SWAP           [0, ppem]
        0x42, //       WS             storage[0]=ppem
        0x18, //       RTG
        0xB8, 0x00, 0x64, // PUSHW[0] 100
        0x68, //       ROUND[..]      round(100) -> 128
        0xB0, 0x01, // PUSHB[0] 1
        0x23, //       SWAP           [1, rounded]
        0x42, //       WS             storage[1]=round(100)
    };
    // one CVT entry = 10 funits; upem 1000, ppem 64 -> scaled 10*64*64/1000 = 40.96 -> 41
    const cvt = [_]u8{ 0x00, 0x0A };
    const h = try Hinter.init(a, &fpgm, &prep, &cvt, 1000, 64, 256, 16, 16, 16);
    defer {
        a.free(h.stack);
        a.free(h.storage);
        a.free(h.cvt);
        a.free(h.funcs);
        a.free(h.twilight.org);
        a.free(h.twilight.cur);
        a.free(h.twilight.flags);
    }
    const scaled: i32 = @intCast(@divTrunc(@as(i64, 10) * 64 * 64 + 500, 1000)); // 41
    try testing.expectEqual(scaled * 2, h.cvt[0]); // fn 0 doubled it
    try testing.expectEqual(@as(i32, 64), h.storage[0]); // MPPEM
    try testing.expectEqual(@as(i32, 128), h.storage[1]); // round(100) to grid = 2px
}

test "runs a real font's fpgm+prep (IBM Plex Mono) across sizes" {
    const a = testing.allocator;
    const fpgm = @embedFile("tthint/plexmono-fpgm.bin");
    const prep = @embedFile("tthint/plexmono-prep.bin");
    const cvt = @embedFile("tthint/plexmono-cvt.bin");
    // IBM Plex Mono: unitsPerEm 1000; maxp under-reports, so we provision
    // generously (256 funcs though it claims 0). Every UI ppem must set up
    // clean — the CVT scaled and the graphics state established.
    var ppem: u32 = 8;
    while (ppem <= 48) : (ppem += 2) {
        const h = Hinter.init(a, fpgm, prep, cvt, 1000, ppem, 1200, 64, 256, 16) catch |e| {
            std.debug.print("init failed at ppem={d}: {any}; last op=0x{x} ip={d} sp={d}\n", .{ ppem, e, dbg_last.op, dbg_last.ip, dbg_last.sp });
            return e;
        };
        defer {
            a.free(h.stack);
            a.free(h.storage);
            a.free(h.cvt);
            a.free(h.funcs);
            a.free(h.twilight.org);
            a.free(h.twilight.cur);
            a.free(h.twilight.flags);
        }
        try testing.expectEqual(@as(usize, 32), h.cvt.len); // 64 bytes / 2
        // The CVT scaled with ppem: at least one entry grows with size.
        try testing.expect(h.ppem == ppem);
    }
}

test "hintGlyph: a glyph program grid-fits a point (MDAP round)" {
    const a = testing.allocator;
    // No fpgm/prep; default graphics state (proj/free = x-axis, round to
    // grid). A two-point zone; the program rounds point 0 to the grid.
    var h = try Hinter.init(a, "", "", "", 1000, 16, 256, 16, 16, 16);
    defer {
        a.free(h.stack);
        a.free(h.storage);
        a.free(h.cvt);
        a.free(h.funcs);
        a.free(h.twilight.org);
        a.free(h.twilight.cur);
        a.free(h.twilight.flags);
    }
    var org = [_][2]F26Dot6{ .{ 100, 0 }, .{ 300, 0 } }; // 1.5625px, 4.6875px
    var cur = org;
    var flags = [_]u8{ flag_on, flag_on };
    var ends = [_]u16{1};
    const zone = Zone{ .n = 2, .org = &org, .cur = &cur, .flags = &flags, .ends = &ends, .n_contours = 1 };
    // PUSHB[0] 0 ; MDAP[1]  — round point 0 to the grid along x.
    const instr = [_]u8{ 0xB0, 0x00, 0x2F };
    try h.hintGlyph(zone, &instr);
    try testing.expectEqual(@as(F26Dot6, 128), cur[0][0]); // 100 → nearest grid (2px)
    try testing.expectEqual(@as(F26Dot6, 300), cur[1][0]); // untouched
    try testing.expect(flags[0] & flag_touch_x != 0); // MDAP touched it
}

test "roundSuper: grid rounding is nearest pixel" {
    try testing.expectEqual(@as(F26Dot6, 128), roundSuper(100, 64, 0, 32)); // 1.5625px -> 2px
    try testing.expectEqual(@as(F26Dot6, 128), roundSuper(96, 64, 0, 32)); // 1.5px -> 2px
    try testing.expectEqual(@as(F26Dot6, 64), roundSuper(64, 64, 0, 32)); // exactly 1px
    try testing.expectEqual(@as(F26Dot6, 0), roundSuper(31, 64, 0, 32)); // <0.5px -> 0
    try testing.expectEqual(@as(F26Dot6, -128), roundSuper(-96, 64, 0, 32));
}
