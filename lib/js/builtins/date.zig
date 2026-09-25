//! Date (§21.4): time values as milliseconds since the epoch, the
//! calendar arithmetic of §21.4.1 (Day, YearFromTime, MakeDay, ...),
//! the Date Time String Format parser and the toString formats, every
//! getter and setter, and the conversions. Local time is UTC: the
//! engine has no time zone until a host offers one (`Vm.host_tz`), and
//! `Date.now` reads the clock the host installs (`Vm.host_now`).
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const String = b.String;
const asObject = b.asObject;
const asString = b.asString;
const strValue = b.strValue;
const arg = b.arg;

pub const DateData = extern struct { time: f64 };

const ms_per_day: f64 = 86400000;
const nan = std.math.nan(f64);

// ------------------------------------------------- calendar arithmetic

fn day(t: f64) f64 {
    return @floor(t / ms_per_day);
}
fn timeWithinDay(t: f64) f64 {
    return @mod(t, ms_per_day);
}
fn daysInYear(y: f64) f64 {
    if (@mod(y, 4) != 0) return 365;
    if (@mod(y, 100) != 0) return 366;
    if (@mod(y, 400) != 0) return 365;
    return 366;
}
fn dayFromYear(y: f64) f64 {
    return 365 * (y - 1970) + @floor((y - 1969) / 4) - @floor((y - 1901) / 100) + @floor((y - 1601) / 400);
}
fn timeFromYear(y: f64) f64 {
    return ms_per_day * dayFromYear(y);
}
fn yearFromTime(t: f64) f64 {
    // An estimate, corrected by at most one either way.
    var y = @floor(t / (ms_per_day * 365.2425)) + 1970;
    while (timeFromYear(y) > t) y -= 1;
    while (timeFromYear(y + 1) <= t) y += 1;
    return y;
}
fn inLeapYear(t: f64) f64 {
    return if (daysInYear(yearFromTime(t)) == 366) 1 else 0;
}
fn dayWithinYear(t: f64) f64 {
    return day(t) - dayFromYear(yearFromTime(t));
}
const cum_days = [_]f64{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 };
fn monthFromTime(t: f64) f64 {
    const d = dayWithinYear(t);
    const leap = inLeapYear(t);
    var m: usize = 0;
    while (m < 11) : (m += 1) {
        const next = cum_days[m + 1] + (if (m >= 1) leap else 0);
        if (d < next) break;
    }
    return @floatFromInt(m);
}
fn dateFromTime(t: f64) f64 {
    const d = dayWithinYear(t);
    const m: usize = @intFromFloat(monthFromTime(t));
    const leap = inLeapYear(t);
    return d - cum_days[m] - (if (m >= 2) leap else 0) + 1;
}
fn weekDay(t: f64) f64 {
    return @mod(day(t) + 4, 7);
}
fn hourFromTime(t: f64) f64 {
    return @mod(@floor(t / 3600000), 24);
}
fn minFromTime(t: f64) f64 {
    return @mod(@floor(t / 60000), 60);
}
fn secFromTime(t: f64) f64 {
    return @mod(@floor(t / 1000), 60);
}
fn msFromTime(t: f64) f64 {
    return @mod(t, 1000);
}

fn isFiniteAll(vals: []const f64) bool {
    for (vals) |v| if (!std.math.isFinite(v)) return false;
    return true;
}

/// ToIntegerOrInfinity on an already-numeric value.
fn integer(d: f64) f64 {
    if (std.math.isNan(d)) return 0;
    if (std.math.isInf(d)) return d;
    return @trunc(d) + 0.0;
}

fn makeTime(hour: f64, min: f64, sec: f64, ms: f64) f64 {
    if (!isFiniteAll(&.{ hour, min, sec, ms })) return nan;
    return integer(hour) * 3600000 + integer(min) * 60000 + integer(sec) * 1000 + integer(ms);
}

fn makeDay(year: f64, month: f64, date: f64) f64 {
    if (!isFiniteAll(&.{ year, month, date })) return nan;
    const y = integer(year);
    const m = integer(month);
    const dt = integer(date);
    const ym = y + @floor(m / 12);
    if (!std.math.isFinite(ym)) return nan;
    const mn = @mod(m, 12);
    // The day number of the first day of month mn of year ym.
    if (@abs(ym) > 400000) return nan;
    const leap: f64 = if (daysInYear(ym) == 366) 1 else 0;
    const mi: usize = @intFromFloat(mn);
    const t = dayFromYear(ym) + cum_days[mi] + (if (mi >= 2) leap else 0);
    return t + dt - 1;
}

fn makeDate(d: f64, t: f64) f64 {
    if (!std.math.isFinite(d) or !std.math.isFinite(t)) return nan;
    const tv = d * ms_per_day + t;
    if (!std.math.isFinite(tv)) return nan;
    return tv;
}

fn timeClip(t: f64) f64 {
    if (!std.math.isFinite(t)) return nan;
    if (@abs(t) > 8.64e15) return nan;
    return integer(t) + 0.0;
}

/// LocalTime / UTC: no time zone offset yet.
fn localTime(vm: *Vm, t: f64) f64 {
    _ = vm;
    return t;
}
fn utcFromLocal(vm: *Vm, t: f64) f64 {
    _ = vm;
    return t;
}

// ------------------------------------------------------------ install

pub fn install(vm: *Vm) Error!void {
    const proto = try vm.newObject();
    vm.intrinsics.date_prototype = proto;
    const ctor = try b.installConstructor(vm, "Date", 7, construct, proto);
    _ = try vm.defineNative(ctor, "UTC", 7, utc);
    _ = try vm.defineNative(ctor, "now", 0, now);
    _ = try vm.defineNative(ctor, "parse", 1, parseFn);
    inline for (.{
        .{ "getDate", getDate },                 .{ "getDay", getDay },                       .{ "getFullYear", getFullYear },            .{ "getHours", getHours },
        .{ "getMilliseconds", getMilliseconds }, .{ "getMinutes", getMinutes },               .{ "getMonth", getMonth },                  .{ "getSeconds", getSeconds },
        .{ "getTime", getTime },                 .{ "getTimezoneOffset", getTimezoneOffset }, .{ "getUTCDate", getDate },                 .{ "getUTCDay", getDay },
        .{ "getUTCFullYear", getFullYear },      .{ "getUTCHours", getHours },                .{ "getUTCMilliseconds", getMilliseconds }, .{ "getUTCMinutes", getMinutes },
        .{ "getUTCMonth", getMonth },            .{ "getUTCSeconds", getSeconds },            .{ "valueOf", getTime },                    .{ "getYear", getYear },
    }) |e| _ = try vm.defineNative(proto, e[0], 0, e[1]);
    inline for (.{
        .{ "setDate", setDate, 1 },          .{ "setFullYear", setFullYear, 3 },    .{ "setHours", setHours, 4 },        .{ "setMilliseconds", setMilliseconds, 1 },
        .{ "setMinutes", setMinutes, 3 },    .{ "setMonth", setMonth, 2 },          .{ "setSeconds", setSeconds, 2 },    .{ "setTime", setTime, 1 },
        .{ "setUTCDate", setDate, 1 },       .{ "setUTCFullYear", setFullYear, 3 }, .{ "setUTCHours", setHours, 4 },     .{ "setUTCMilliseconds", setMilliseconds, 1 },
        .{ "setUTCMinutes", setMinutes, 3 }, .{ "setUTCMonth", setMonth, 2 },       .{ "setUTCSeconds", setSeconds, 2 }, .{ "setYear", setYear, 1 },
    }) |e| _ = try vm.defineNative(proto, e[0], e[2], e[1]);
    _ = try vm.defineNative(proto, "toDateString", 0, toDateString);
    _ = try vm.defineNative(proto, "toISOString", 0, toISOString);
    _ = try vm.defineNative(proto, "toJSON", 1, toJSON);
    _ = try vm.defineNative(proto, "toLocaleDateString", 0, toDateString);
    _ = try vm.defineNative(proto, "toLocaleString", 0, toStringFn);
    _ = try vm.defineNative(proto, "toLocaleTimeString", 0, toTimeString);
    _ = try vm.defineNative(proto, "toString", 0, toStringFn);
    _ = try vm.defineNative(proto, "toTimeString", 0, toTimeString);
    const utc_string = try vm.defineNative(proto, "toUTCString", 0, toUTCString);
    try vm.defineValue(proto, "toGMTString", utc_string.asValue(), .hidden);
    const tp = try vm.newNative("[Symbol.toPrimitive]", 1, toPrimitive, Value.undefined_);
    _ = try vm.objects.defineOwn(proto, .{ .symbol = vm.symbols.to_primitive }, tp.asValue(), .{ .writable = false, .enumerable = false, .configurable = true });
}

fn thisTime(vm: *Vm, this: Value) Error!f64 {
    if (!this.isObject() or asObject(this).class != .date) return vm.throwTypeError("this is not a Date object.");
    return asObject(this).internal(DateData).time;
}

fn setThisTime(this: Value, t: f64) void {
    asObject(this).internal(DateData).time = t;
}

fn newDate(vm: *Vm, new_target: Value, t: f64) Error!Value {
    const o = try vm.createFromConstructor(new_target, vm.intrinsics.date_prototype, .date, @sizeOf(DateData));
    o.internal(DateData).time = t;
    return o.asValue();
}

fn currentTime(vm: *Vm) f64 {
    if (vm.host_now) |f| return f();
    return 0;
}

fn construct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    if (new_target.isUndefined()) {
        // Called as a function: the current time as a string.
        return strValue(try formatToString(vm, currentTime(vm)));
    }
    var tv: f64 = undefined;
    if (args.len == 0) {
        tv = currentTime(vm);
    } else if (args.len == 1) {
        const v = args[0];
        if (v.isObject() and asObject(v).class == .date) {
            tv = asObject(v).internal(DateData).time;
        } else {
            const p = try vm.toPrimitive(v, .default);
            if (p.isString()) {
                tv = try parseString(vm, asString(p));
            } else tv = timeClip(try vm.toNumber(p));
        }
    } else {
        tv = try fromComponents(vm, args);
    }
    return newDate(vm, new_target, timeClip(tv));
}

/// The year, month, ... arguments of the constructor and Date.UTC.
fn fromComponents(vm: *Vm, args: []const Value) Error!f64 {
    var y = try vm.toNumber(arg(args, 0));
    const m = if (args.len > 1) try vm.toNumber(args[1]) else 0;
    const dt = if (args.len > 2) try vm.toNumber(args[2]) else 1;
    const h = if (args.len > 3) try vm.toNumber(args[3]) else 0;
    const min = if (args.len > 4) try vm.toNumber(args[4]) else 0;
    const s = if (args.len > 5) try vm.toNumber(args[5]) else 0;
    const ms = if (args.len > 6) try vm.toNumber(args[6]) else 0;
    if (!std.math.isNan(y)) {
        const yi = integer(y);
        if (yi >= 0 and yi <= 99) y = 1900 + yi;
    }
    return makeDate(makeDay(y, m, dt), makeTime(h, min, s, ms));
}

fn utc(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return Value.fromF64(timeClip(try fromComponents(vm, args)));
}

fn now(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return Value.fromF64(currentTime(vm));
}

fn parseFn(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const s = try vm.toString(arg(args, 0));
    return Value.fromF64(try parseString(vm, s));
}

// ------------------------------------------------------------- parsing

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

/// Date.parse: the Date Time String Format (§21.4.1.32), then the
/// toString and toUTCString forms.
fn parseString(vm: *Vm, s: *String) Error!f64 {
    const text = try vm.utf8(s, vm.meta);
    defer vm.meta.free(text);
    if (parseIso(vm, text)) |t| return t;
    if (parseLegacy(text)) |t| return t;
    return nan;
}

const Cursor = struct {
    s: []const u8,
    i: usize = 0,
    fn digits(c: *Cursor, n: usize) ?u32 {
        if (c.i + n > c.s.len) return null;
        var v: u32 = 0;
        for (c.s[c.i .. c.i + n]) |ch| {
            if (ch < '0' or ch > '9') return null;
            v = v * 10 + (ch - '0');
        }
        c.i += n;
        return v;
    }
    fn eat(c: *Cursor, ch: u8) bool {
        if (c.i < c.s.len and c.s[c.i] == ch) {
            c.i += 1;
            return true;
        }
        return false;
    }
    fn done(c: *Cursor) bool {
        return c.i == c.s.len;
    }
};

fn parseIso(vm: *Vm, text: []const u8) ?f64 {
    var c = Cursor{ .s = text };
    var year: f64 = undefined;
    if (c.eat('+') or c.eat('-')) {
        const neg = text[0] == '-';
        const y = c.digits(6) orelse return null;
        if (neg and y == 0) return null; // -000000 is invalid
        year = @floatFromInt(y);
        if (neg) year = -year;
    } else {
        year = @floatFromInt(c.digits(4) orelse return null);
    }
    var month: f64 = 1;
    var date: f64 = 1;
    var hour: f64 = 0;
    var min: f64 = 0;
    var sec: f64 = 0;
    var ms: f64 = 0;
    var has_time = false;
    var offset: ?f64 = null;
    if (c.eat('-')) {
        month = @floatFromInt(c.digits(2) orelse return null);
        if (c.eat('-')) date = @floatFromInt(c.digits(2) orelse return null);
    }
    if (c.eat('T')) {
        has_time = true;
        hour = @floatFromInt(c.digits(2) orelse return null);
        if (!c.eat(':')) return null;
        min = @floatFromInt(c.digits(2) orelse return null);
        if (c.eat(':')) {
            sec = @floatFromInt(c.digits(2) orelse return null);
            if (c.eat('.')) {
                // 1 to 3+ fraction digits; only the first three count.
                var n: usize = 0;
                var v: f64 = 0;
                var scale: f64 = 100;
                while (c.i < c.s.len and c.s[c.i] >= '0' and c.s[c.i] <= '9') : (c.i += 1) {
                    if (n < 3) v += @as(f64, @floatFromInt(c.s[c.i] - '0')) * scale;
                    scale /= 10;
                    n += 1;
                }
                if (n == 0) return null;
                ms = v;
            }
        }
        if (c.eat('Z')) {
            offset = 0;
        } else if (c.i < c.s.len and (c.s[c.i] == '+' or c.s[c.i] == '-')) {
            const neg = c.s[c.i] == '-';
            c.i += 1;
            const oh = c.digits(2) orelse return null;
            if (!c.eat(':')) return null;
            const om = c.digits(2) orelse return null;
            var off: f64 = @floatFromInt(oh * 60 + om);
            if (neg) off = -off;
            offset = off;
        }
    }
    if (!c.done()) return null;
    if (month < 1 or month > 12 or date < 1 or date > 31 or hour > 24 or min > 59 or sec > 59) return null;
    if (hour == 24 and (min != 0 or sec != 0 or ms != 0)) return null;
    // Days per month check.
    const dim = [_]f64{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (date > dim[@intFromFloat(month - 1)]) return null;
    var t = makeDate(makeDay(year, month - 1, date), makeTime(hour, min, sec, ms));
    if (offset) |off| {
        t -= off * 60000;
    } else if (has_time) {
        // Date-time forms without an offset are local time (UTC here).
        t = utcFromLocal(vm, t);
    }
    return timeClip(t);
}

/// "Tue Sep 25 2026 10:00:00 GMT+0000 (...)", "Tue, 25 Sep 2026 10:00:00 GMT"
/// and the looser forms implementations accept: a month name, a day,
/// a year, an optional time and an optional zone.
fn parseLegacy(text_in: []const u8) ?f64 {
    var month: ?f64 = null;
    var nums: [4]struct { v: f64, len: usize, signed: bool } = undefined;
    var nn: usize = 0;
    var hour: f64 = 0;
    var min: f64 = 0;
    var sec: f64 = 0;
    var offset: f64 = 0;
    var it = std.mem.tokenizeAny(u8, text_in, " ,");
    while (it.next()) |w| {
        if (w[0] == '(') break;
        var is_day = false;
        for (day_names) |dn| if (std.ascii.startsWithIgnoreCase(w, dn)) {
            is_day = true;
        };
        if (is_day) continue;
        var is_month = false;
        for (month_names, 0..) |mn, mi| if (std.ascii.startsWithIgnoreCase(w, mn)) {
            month = @floatFromInt(mi);
            is_month = true;
        };
        if (is_month) continue;
        if (std.mem.indexOfScalar(u8, w, ':') != null) {
            var parts = std.mem.splitScalar(u8, w, ':');
            hour = @floatFromInt(std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null);
            min = @floatFromInt(std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null);
            if (parts.next()) |ss| sec = @floatFromInt(std.fmt.parseInt(u32, ss, 10) catch return null);
            continue;
        }
        if (std.ascii.startsWithIgnoreCase(w, "GMT") or std.ascii.startsWithIgnoreCase(w, "UTC") or std.mem.eql(u8, w, "Z")) {
            const rest = if (w.len > 3) w[3..] else "";
            if (rest.len == 5 and (rest[0] == '+' or rest[0] == '-')) {
                const oh = std.fmt.parseInt(u32, rest[1..3], 10) catch return null;
                const om = std.fmt.parseInt(u32, rest[3..5], 10) catch return null;
                offset = @floatFromInt(oh * 60 + om);
                if (rest[0] == '-') offset = -offset;
            } else if (rest.len != 0) return null;
            continue;
        }
        if ((w[0] == '+' or w[0] == '-') and w.len == 5 and nn > 0) {
            const oh = std.fmt.parseInt(u32, w[1..3], 10) catch return null;
            const om = std.fmt.parseInt(u32, w[3..5], 10) catch return null;
            offset = @floatFromInt(oh * 60 + om);
            if (w[0] == '-') offset = -offset;
            continue;
        }
        const num = std.fmt.parseInt(i32, w, 10) catch return null;
        if (nn == nums.len) return null;
        nums[nn] = .{ .v = @floatFromInt(num), .len = w.len, .signed = w[0] == '+' or w[0] == '-' };
        nn += 1;
    }
    const m = month orelse return null;
    var date: ?f64 = null;
    var year: ?f64 = null;
    for (nums[0..nn]) |n| {
        if (date == null and !n.signed and n.len <= 2 and n.v >= 1 and n.v <= 31 and year == null) {
            date = n.v;
        } else if (year == null) {
            year = n.v;
        } else if (date == null) {
            date = n.v;
        } else return null;
    }
    const y = year orelse return null;
    return timeClip(makeDate(makeDay(y, m, date orelse 1), makeTime(hour, min, sec, 0)) - offset * 60000);
}

// ---------------------------------------------------------- formatting

/// The broken-down fields of a time value, unsigned for the formatters
/// (a signed integer prints its sign under a width).
const Fields = struct {
    year: i64,
    month: usize,
    date: u32,
    weekday: usize,
    hour: u32,
    min: u32,
    sec: u32,
    ms: u32,
    fn of(t: f64) Fields {
        return .{
            .year = @intFromFloat(yearFromTime(t)),
            .month = @intFromFloat(monthFromTime(t)),
            .date = @intFromFloat(dateFromTime(t)),
            .weekday = @intFromFloat(weekDay(t)),
            .hour = @intFromFloat(hourFromTime(t)),
            .min = @intFromFloat(minFromTime(t)),
            .sec = @intFromFloat(secFromTime(t)),
            .ms = @intFromFloat(msFromTime(t)),
        };
    }
    fn absYear(f: Fields) u64 {
        return @intCast(if (f.year < 0) -f.year else f.year);
    }
};

fn formatDatePart(buf: []u8, t: f64) []const u8 {
    const f = Fields.of(t);
    if (f.year >= 0) return std.fmt.bufPrint(buf, "{s} {s} {d:0>2} {d:0>4}", .{ day_names[f.weekday], month_names[f.month], f.date, f.absYear() }) catch "";
    return std.fmt.bufPrint(buf, "{s} {s} {d:0>2} -{d:0>4}", .{ day_names[f.weekday], month_names[f.month], f.date, f.absYear() }) catch "";
}

fn formatTimePart(buf: []u8, t: f64) []const u8 {
    const f = Fields.of(t);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2} GMT+0000 (Coordinated Universal Time)", .{ f.hour, f.min, f.sec }) catch "";
}

fn formatToString(vm: *Vm, tv: f64) Error!*String {
    if (std.math.isNan(tv)) return vm.strings.fromUtf8("Invalid Date");
    const t = localTime(vm, tv);
    var b1: [48]u8 = undefined;
    var b2: [64]u8 = undefined;
    var out: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&out, "{s} {s}", .{ formatDatePart(&b1, t), formatTimePart(&b2, t) }) catch "";
    return vm.strings.fromUtf8(s);
}

fn toStringFn(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return strValue(try formatToString(vm, try thisTime(vm, this)));
}

fn toDateString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const tv = try thisTime(vm, this);
    if (std.math.isNan(tv)) return vm.str("Invalid Date");
    var buf: [48]u8 = undefined;
    return vm.str(formatDatePart(&buf, localTime(vm, tv)));
}

fn toTimeString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const tv = try thisTime(vm, this);
    if (std.math.isNan(tv)) return vm.str("Invalid Date");
    var buf: [64]u8 = undefined;
    return vm.str(formatTimePart(&buf, localTime(vm, tv)));
}

fn toUTCString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const t = try thisTime(vm, this);
    if (std.math.isNan(t)) return vm.str("Invalid Date");
    const f = Fields.of(t);
    var buf: [64]u8 = undefined;
    const s = if (f.year >= 0) std.fmt.bufPrint(&buf, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{ day_names[f.weekday], f.date, month_names[f.month], f.absYear(), f.hour, f.min, f.sec }) catch "" else std.fmt.bufPrint(&buf, "{s}, {d:0>2} {s} -{d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{ day_names[f.weekday], f.date, month_names[f.month], f.absYear(), f.hour, f.min, f.sec }) catch "";
    return vm.str(s);
}

fn isoString(vm: *Vm, t: f64) Error!*String {
    const f = Fields.of(t);
    var buf: [48]u8 = undefined;
    const ymd = if (f.year >= 0 and f.year <= 9999) std.fmt.bufPrint(&buf, "{d:0>4}", .{f.absYear()}) catch "" else if (f.year < 0) std.fmt.bufPrint(&buf, "-{d:0>6}", .{f.absYear()}) catch "" else std.fmt.bufPrint(&buf, "+{d:0>6}", .{f.absYear()}) catch "";
    var out: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&out, "{s}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ ymd, f.month + 1, f.date, f.hour, f.min, f.sec, f.ms }) catch "";
    return vm.strings.fromUtf8(s);
}

fn toISOString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const t = try thisTime(vm, this);
    if (!std.math.isFinite(t)) return vm.throwRangeError("Invalid time value");
    return strValue(try isoString(vm, t));
}

fn toJSON(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const tv = try vm.toPrimitive(o.asValue(), .number);
    if (tv.isNumber() and !std.math.isFinite(tv.asNumber())) return Value.null_;
    return vm.invoke(o.asValue(), .{ .atom = vm.atoms.toISOString }, &.{});
}

fn toPrimitive(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("Date.prototype[Symbol.toPrimitive] called on non-object");
    const hint = arg(args, 0);
    if (!hint.isString()) return vm.throwTypeError("Invalid hint");
    var buf: [16]u8 = undefined;
    const h = b.utf8Buf(vm, asString(hint), &buf) catch "";
    if (std.mem.eql(u8, h, "string") or std.mem.eql(u8, h, "default")) return vm.ordinaryToPrimitive(asObject(this), .string);
    if (std.mem.eql(u8, h, "number")) return vm.ordinaryToPrimitive(asObject(this), .number);
    return vm.throwTypeError("Invalid hint");
}

// ------------------------------------------------------------- getters

fn getter(vm: *Vm, this: Value, comptime f: fn (f64) f64, local: bool) Error!Value {
    const t = try thisTime(vm, this);
    if (std.math.isNan(t)) return Value.fromF64(nan);
    return Value.fromF64(f(if (local) localTime(vm, t) else t));
}

fn getDate(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return getter(vm, this, dateFromTime, true);
}
fn getDay(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return getter(vm, this, weekDay, true);
}
fn getFullYear(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return getter(vm, this, yearFromTime, true);
}
fn getHours(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return getter(vm, this, hourFromTime, true);
}
fn getMilliseconds(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return getter(vm, this, msFromTime, true);
}
fn getMinutes(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return getter(vm, this, minFromTime, true);
}
fn getMonth(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return getter(vm, this, monthFromTime, true);
}
fn getSeconds(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return getter(vm, this, secFromTime, true);
}
fn getTime(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return Value.fromF64(try thisTime(vm, this));
}
fn getTimezoneOffset(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const t = try thisTime(vm, this);
    if (std.math.isNan(t)) return Value.fromF64(nan);
    return Value.fromF64(0);
}
fn getYear(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const t = try thisTime(vm, this);
    if (std.math.isNan(t)) return Value.fromF64(nan);
    return Value.fromF64(yearFromTime(localTime(vm, t)) - 1900);
}

// ------------------------------------------------------------- setters

fn setTime(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    _ = try thisTime(vm, this);
    const t = timeClip(try vm.toNumber(arg(args, 0)));
    setThisTime(this, t);
    return Value.fromF64(t);
}

/// The pattern the setters share: read the current time, coerce every
/// argument (in order, even when the date is invalid), rebuild.
fn setMilliseconds(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    var t = localTime(vm, try thisTime(vm, this));
    const ms = try vm.toNumber(arg(args, 0));
    if (std.math.isNan(t)) return Value.fromF64(nan);
    t = makeDate(day(t), makeTime(hourFromTime(t), minFromTime(t), secFromTime(t), ms));
    const u = timeClip(utcFromLocal(vm, t));
    setThisTime(this, u);
    return Value.fromF64(u);
}

fn setSeconds(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    var t = localTime(vm, try thisTime(vm, this));
    const s = try vm.toNumber(arg(args, 0));
    const ms = if (args.len > 1) try vm.toNumber(args[1]) else msFromTime(t);
    if (std.math.isNan(t)) return Value.fromF64(nan);
    t = makeDate(day(t), makeTime(hourFromTime(t), minFromTime(t), s, ms));
    const u = timeClip(utcFromLocal(vm, t));
    setThisTime(this, u);
    return Value.fromF64(u);
}

fn setMinutes(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    var t = localTime(vm, try thisTime(vm, this));
    const m = try vm.toNumber(arg(args, 0));
    const s = if (args.len > 1) try vm.toNumber(args[1]) else secFromTime(t);
    const ms = if (args.len > 2) try vm.toNumber(args[2]) else msFromTime(t);
    if (std.math.isNan(t)) return Value.fromF64(nan);
    t = makeDate(day(t), makeTime(hourFromTime(t), m, s, ms));
    const u = timeClip(utcFromLocal(vm, t));
    setThisTime(this, u);
    return Value.fromF64(u);
}

fn setHours(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    var t = localTime(vm, try thisTime(vm, this));
    const h = try vm.toNumber(arg(args, 0));
    const m = if (args.len > 1) try vm.toNumber(args[1]) else minFromTime(t);
    const s = if (args.len > 2) try vm.toNumber(args[2]) else secFromTime(t);
    const ms = if (args.len > 3) try vm.toNumber(args[3]) else msFromTime(t);
    if (std.math.isNan(t)) return Value.fromF64(nan);
    t = makeDate(day(t), makeTime(h, m, s, ms));
    const u = timeClip(utcFromLocal(vm, t));
    setThisTime(this, u);
    return Value.fromF64(u);
}

fn setDate(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    var t = localTime(vm, try thisTime(vm, this));
    const dt = try vm.toNumber(arg(args, 0));
    if (std.math.isNan(t)) return Value.fromF64(nan);
    t = makeDate(makeDay(yearFromTime(t), monthFromTime(t), dt), timeWithinDay(t));
    const u = timeClip(utcFromLocal(vm, t));
    setThisTime(this, u);
    return Value.fromF64(u);
}

fn setMonth(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    var t = localTime(vm, try thisTime(vm, this));
    const m = try vm.toNumber(arg(args, 0));
    const dt = if (args.len > 1) try vm.toNumber(args[1]) else dateFromTime(t);
    if (std.math.isNan(t)) return Value.fromF64(nan);
    t = makeDate(makeDay(yearFromTime(t), m, dt), timeWithinDay(t));
    const u = timeClip(utcFromLocal(vm, t));
    setThisTime(this, u);
    return Value.fromF64(u);
}

fn setFullYear(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    var t = try thisTime(vm, this);
    t = if (std.math.isNan(t)) 0 else localTime(vm, t);
    const y = try vm.toNumber(arg(args, 0));
    const m = if (args.len > 1) try vm.toNumber(args[1]) else monthFromTime(t);
    const dt = if (args.len > 2) try vm.toNumber(args[2]) else dateFromTime(t);
    const nd = makeDate(makeDay(y, m, dt), timeWithinDay(t));
    const u = timeClip(utcFromLocal(vm, nd));
    setThisTime(this, u);
    return Value.fromF64(u);
}

fn setYear(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    var t = try thisTime(vm, this);
    t = if (std.math.isNan(t)) 0 else localTime(vm, t);
    var y = try vm.toNumber(arg(args, 0));
    if (std.math.isNan(y)) {
        setThisTime(this, nan);
        return Value.fromF64(nan);
    }
    const yi = integer(y);
    if (yi >= 0 and yi <= 99) y = 1900 + yi;
    const nd = makeDate(makeDay(y, monthFromTime(t), dateFromTime(t)), timeWithinDay(t));
    const u = timeClip(utcFromLocal(vm, nd));
    setThisTime(this, u);
    return Value.fromF64(u);
}

test "date: calendar arithmetic round-trips" {
    const t = makeDate(makeDay(2026, 8, 25), makeTime(10, 30, 15, 250));
    try std.testing.expectEqual(@as(f64, 2026), yearFromTime(t));
    try std.testing.expectEqual(@as(f64, 8), monthFromTime(t));
    try std.testing.expectEqual(@as(f64, 25), dateFromTime(t));
    try std.testing.expectEqual(@as(f64, 5), weekDay(t)); // a Friday
    try std.testing.expectEqual(@as(f64, 10), hourFromTime(t));
    try std.testing.expectEqual(@as(f64, 250), msFromTime(t));
    try std.testing.expectEqual(@as(f64, 0), makeDate(makeDay(1970, 0, 1), 0));
    try std.testing.expectEqual(@as(f64, 29), dateFromTime(makeDate(makeDay(2024, 1, 29), 0)));
    try std.testing.expectEqual(@as(f64, 1969), yearFromTime(-1));
    try std.testing.expectEqual(@as(f64, 31), dateFromTime(-1));
}
