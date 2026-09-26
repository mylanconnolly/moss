//! Objects (ECMA-262 §10.1): property maps behind hidden classes. An
//! object's `Shape` is its layout — which keys it has, in what order,
//! at which slot, with what attributes — shared by every object that
//! got its properties the same way, so `o.x` at a site that has seen
//! this shape reads one slot without a lookup (the inline cache the VM
//! keeps per instruction). Adding a property follows a transition from
//! the shape to its child; deleting or changing attributes takes the
//! object to a `dictionary` shape of its own, where the map is the
//! object's. Integer-keyed properties of arrays live in a dense
//! `elements` vector while it stays dense.
//!
//! The operations are the specification's internal methods under the
//! specification's names — `getOwnProperty`, `defineOwnProperty`, `get`,
//! `set`, `delete`, `hasProperty`, `ownKeys` — with the ordinary object
//! behaviour; an exotic object (array, arguments, proxy, string wrapper)
//! is marked by `class` and handled where the difference lies.
const std = @import("std");
const heap = @import("heap.zig");
const string = @import("string.zig");
const value = @import("value.zig");
const Cell = heap.Cell;
const Heap = heap.Heap;
const Value = value.Value;
const String = string.String;

pub const Error = error{OutOfMemory};

/// A property key: an atom string or a symbol (both cells), or an
/// array index (a canonical numeric string below 2^32-1).
pub const Key = union(enum) {
    atom: *String,
    symbol: *Symbol,
    index: u32,

    pub fn eql(a: Key, b: Key) bool {
        return switch (a) {
            .atom => |s| b == .atom and b.atom == s,
            .symbol => |s| b == .symbol and b.symbol == s,
            .index => |i| b == .index and b.index == i,
        };
    }
    pub fn hash(k: Key) u32 {
        return switch (k) {
            .atom => |s| s.hash(),
            .symbol => |s| @truncate(@intFromPtr(s) >> 4),
            .index => |i| i *% 2654435761,
        };
    }
    pub fn isCell(k: Key) bool {
        return k != .index;
    }
    pub fn cell(k: Key) ?*Cell {
        return switch (k) {
            .atom => |s| s.cell(),
            .symbol => |s| &s.header,
            .index => null,
        };
    }
};

pub const Symbol = extern struct {
    header: Cell,
    /// The description, or null.
    description: ?*String,
    /// A well-known or registered symbol's identity is its cell.
    registered: bool = false,
    /// A class's private name: invisible to reflection.
    private: bool = false,
    _pad: [6]u8 = @splat(0),
};

pub const Attributes = packed struct(u8) {
    writable: bool = true,
    enumerable: bool = true,
    configurable: bool = true,
    /// The slot holds a getter/setter pair (an `Accessor` cell), not a value.
    accessor: bool = false,
    _pad: u4 = 0,

    pub const default: Attributes = .{};
    pub const hidden: Attributes = .{ .writable = true, .enumerable = false, .configurable = true };
    pub const frozen: Attributes = .{ .writable = false, .enumerable = false, .configurable = false };
};

/// A getter/setter pair, stored in the slot of an accessor property.
pub const Accessor = extern struct {
    header: Cell,
    get: Value, // undefined or a function object
    set: Value,
};

/// A hidden class: an ordered map from keys to slots, shared.
pub const Shape = extern struct {
    header: Cell,
    parent: ?*Shape,
    /// The property this shape added to its parent (none for the root).
    key_kind: u8, // 0 none, 1 atom, 2 symbol, 3 index
    attrs: Attributes,
    /// This object's layout is its own: a dictionary shape's `table` is
    /// authoritative and transitions are not shared.
    dictionary: bool = false,
    _pad: u8 = 0,
    key_index: u32 = 0, // for key_kind 3
    key_cell: ?*Cell, // for key kinds 1 and 2
    /// The slot the key occupies; the shape's property count is slot + 1.
    slot: u32,
    count: u32,
    /// Transitions from this shape: a small list, searched linearly
    /// (most shapes have one or two children).
    transitions: ?*Transitions,
    /// A lookup table built lazily for shapes with many properties, and
    /// always for dictionary shapes.
    table: ?*Table,
    /// The prototype is the object's, not the shape's — but a shape is
    /// only shared between objects with the same prototype, so a cache
    /// hit on the shape is a hit on the prototype chain's start too.
    proto: Value,

    pub fn cell(s: *Shape) *Cell {
        return &s.header;
    }

    pub fn key(s: *const Shape) ?Key {
        return switch (s.key_kind) {
            1 => .{ .atom = @ptrCast(@alignCast(s.key_cell.?)) },
            2 => .{ .symbol = @ptrCast(@alignCast(s.key_cell.?)) },
            3 => .{ .index = s.key_index },
            else => null,
        };
    }
};

pub const Transitions = struct {
    list: std.ArrayList(struct { key: Key, attrs: Attributes, child: *Shape }) = .empty,
};

/// A key → (slot, attrs) map for a shape.
pub const Table = struct {
    map: std.HashMapUnmanaged(Key, Entry, KeyContext, 80) = .empty,
    /// Keys in insertion order (deletions leave holes, `present` false).
    order: std.ArrayList(struct { key: Key, present: bool }) = .empty,
    pub const Entry = struct { slot: u32, attrs: Attributes };
};

pub const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        return k.hash();
    }
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.eql(b);
    }
};

/// What kind of object: the ordinary one, or an exotic one whose
/// internal methods differ, or an ordinary one with internal slots.
pub const Class = enum(u8) { ordinary, array, function, bound_function, arguments, error_, boolean, number, string, symbol, bigint, date, regexp, map, set, weak_map, weak_set, promise, proxy, array_buffer, typed_array, data_view, iterator, iterator_helper, generator, namespace, global };

pub const Object = extern struct {
    header: Cell,
    shape: *Shape,
    class: Class,
    extensible: bool = true,
    /// Some integer-keyed properties live in the shape table (non-default
    /// attributes, or far past the dense part): the dense path must
    /// check there first.
    sparse_indexes: bool = false,
    /// The object is some object's prototype: a structural change to it
    /// (a property added, removed or redefined, its own prototype set)
    /// bumps `Objects.proto_epoch`, which the add-property caches check.
    is_prototype: bool = false,
    /// The class's internal slots, if any, follow the struct in the cell
    /// (a function's code and environment, a wrapper's primitive, ...).
    _pad: [4]u8 = @splat(0),
    /// Property values by slot: inline for the first few, then an
    /// overflow vector.
    inline_slots: [4]Value,
    overflow: ?*Slots,
    /// Dense integer-keyed elements (arrays; any object may have some).
    elements: ?*Elements,

    pub const inline_count = 4;

    pub fn cell(o: *Object) *Cell {
        return &o.header;
    }
    pub fn asValue(o: *Object) Value {
        return Value.fromCell(&o.header);
    }

    pub fn slot(o: *Object, i: u32) *Value {
        if (i < inline_count) return &o.inline_slots[i];
        return &o.overflow.?.itemsPtr()[i - inline_count];
    }

    /// The internal-slot area after the struct, for `class`es that have one.
    pub fn internal(o: *Object, comptime T: type) *T {
        const base: [*]u8 = @ptrCast(o);
        return @ptrCast(@alignCast(base + internalOffset()));
    }
    pub fn internalOffset() usize {
        return (@sizeOf(Object) + 15) & ~@as(usize, 15);
    }
};

/// Overflow property slots (a cell, so the collector sees it).
pub const Slots = extern struct {
    header: Cell,
    len: u32,
    cap: u32,
    pub fn itemsPtr(s: *Slots) [*]Value {
        const base: [*]u8 = @ptrCast(s);
        return @ptrCast(@alignCast(base + @sizeOf(Slots)));
    }
    pub fn items(s: *Slots) []Value {
        return s.itemsPtr()[0..s.cap];
    }
};

/// Dense elements: values by index, `Value.empty` for a hole.
pub const Elements = extern struct {
    header: Cell,
    len: u32, // the array's length (may exceed the dense part)
    cap: u32,
    pub fn itemsPtr(e: *Elements) [*]Value {
        const base: [*]u8 = @ptrCast(e);
        return @ptrCast(@alignCast(base + @sizeOf(Elements)));
    }
    pub fn items(e: *Elements) []Value {
        return e.itemsPtr()[0..e.cap];
    }
};

/// The object system over a heap: root shapes, allocation, and the
/// internal methods.
pub const Objects = struct {
    heap: *Heap,
    strings: *string.Strings,
    meta: std.mem.Allocator,
    /// The empty shape for each prototype seen: objects created with
    /// prototype P start here. Keyed by the prototype's cell (null for
    /// no prototype).
    root_shapes: std.AutoHashMapUnmanaged(u64, *Shape) = .empty,
    /// Bumped by every structural change to an object that is some
    /// object's prototype: the add-property caches' validity.
    proto_epoch: u64 = 1,
    /// Some prototype carries an integer-keyed property (or an array's
    /// chain left the intrinsic one): element stores into holes must
    /// walk the chain. Never cleared.
    proto_has_indexes: bool = false,

    pub fn init(h: *Heap, strings: *string.Strings, meta: std.mem.Allocator) Objects {
        return .{ .heap = h, .strings = strings, .meta = meta };
    }

    pub fn deinit(os: *Objects) void {
        os.root_shapes.deinit(os.meta);
    }

    pub fn markRoots(os: *Objects, m: *heap.Marker) void {
        var it = os.root_shapes.valueIterator();
        while (it.next()) |s| m.markCell(s.*.cell());
    }

    // ------------------------------------------------------- shapes

    fn newShape(os: *Objects, parent: ?*Shape, key: ?Key, attrs: Attributes, proto: Value) Error!*Shape {
        const c = try os.heap.alloc(.shape, @sizeOf(Shape));
        const s = c.as(Shape);
        s.parent = parent;
        s.proto = proto;
        s.attrs = attrs;
        s.transitions = null;
        s.table = null;
        if (key) |k| {
            s.key_kind = switch (k) {
                .atom => 1,
                .symbol => 2,
                .index => 3,
            };
            s.key_cell = k.cell();
            if (k == .index) s.key_index = k.index;
            s.slot = if (parent) |p| p.count else 0;
            s.count = s.slot + 1;
        } else {
            s.key_kind = 0;
            s.key_cell = null;
            s.slot = 0;
            s.count = if (parent) |p| p.count else 0;
        }
        return s;
    }

    /// The empty shape for objects with prototype `proto`.
    pub fn rootShape(os: *Objects, proto: Value) Error!*Shape {
        const g = try os.root_shapes.getOrPut(os.meta, proto.bits);
        if (g.found_existing) return g.value_ptr.*;
        const s = try os.newShape(null, null, .default, proto);
        g.value_ptr.* = s;
        return s;
    }

    /// The shape after adding `key` with `attrs` to `shape`.
    fn transition(os: *Objects, shape: *Shape, key: Key, attrs: Attributes) Error!*Shape {
        if (shape.transitions) |tr| for (tr.list.items) |t| if (t.key.eql(key) and @as(u8, @bitCast(t.attrs)) == @as(u8, @bitCast(attrs))) return t.child;
        const child = try os.newShape(shape, key, attrs, shape.proto);
        if (shape.transitions == null) {
            const tr = try os.meta.create(Transitions);
            tr.* = .{};
            shape.transitions = tr;
        }
        try shape.transitions.?.list.append(os.meta, .{ .key = key, .attrs = attrs, .child = child });
        return child;
    }

    /// Where `key` lives in `shape`: walking the chain, or the table
    /// when there is one (built at 8 properties).
    pub fn lookup(os: *Objects, shape: *Shape, key: Key) Error!?Table.Entry {
        if (shape.table) |t| return t.map.get(key);
        if (shape.count >= 8 and !shape.dictionary) {
            try os.buildTable(shape);
            return shape.table.?.map.get(key);
        }
        var s: ?*Shape = shape;
        while (s) |sh| : (s = sh.parent) {
            const k = sh.key() orelse break;
            if (k.eql(key)) return .{ .slot = sh.slot, .attrs = sh.attrs };
        }
        return null;
    }

    fn buildTable(os: *Objects, shape: *Shape) Error!void {
        const t = try os.meta.create(Table);
        t.* = .{};
        // In insertion order: the chain is newest first.
        var chain: std.ArrayList(*Shape) = .empty;
        defer chain.deinit(os.meta);
        var s: ?*Shape = shape;
        while (s) |sh| : (s = sh.parent) {
            if (sh.key() == null) break;
            try chain.append(os.meta, sh);
        }
        var i = chain.items.len;
        while (i > 0) {
            i -= 1;
            const sh = chain.items[i];
            try t.map.put(os.meta, sh.key().?, .{ .slot = sh.slot, .attrs = sh.attrs });
            try t.order.append(os.meta, .{ .key = sh.key().?, .present = true });
        }
        shape.table = t;
    }

    /// The object's own shape, to change without affecting sharers.
    fn toDictionary(os: *Objects, o: *Object) Error!void {
        if (o.shape.dictionary) return;
        const old = o.shape;
        const s = try os.newShape(null, null, .default, old.proto);
        s.dictionary = true;
        s.count = old.count;
        if (old.table == null) try os.buildTable(old);
        const t = try os.meta.create(Table);
        t.* = .{};
        var it = old.table.?.map.iterator();
        while (it.next()) |e| try t.map.put(os.meta, e.key_ptr.*, e.value_ptr.*);
        try t.order.appendSlice(os.meta, old.table.?.order.items);
        s.table = t;
        o.shape = s;
    }

    // ------------------------------------------------------ objects

    /// An ordinary object with prototype `proto` and `class`; `extra`
    /// bytes of internal slots after the struct.
    pub fn create(os: *Objects, proto: Value, class: Class, extra: usize) Error!*Object {
        const shape = try os.rootShape(proto);
        if (proto.isObject()) os.markPrototype(proto.asCell().as(Object));
        const c = try os.heap.alloc(.object, Object.internalOffset() + extra);
        const o = c.as(Object);
        o.shape = shape;
        o.class = class;
        o.extensible = true;
        o.sparse_indexes = false;
        o.inline_slots = @splat(Value.undefined_);
        o.overflow = null;
        o.elements = null;
        return o;
    }

    pub fn protoOf(_: *Objects, o: *Object) Value {
        return o.shape.proto;
    }

    /// [[SetPrototypeOf]] for an ordinary object: false when it must not.
    pub fn setProto(os: *Objects, o: *Object, p: Value) Error!bool {
        if (p.eqlBits(o.shape.proto)) return true;
        if (!o.extensible) return false;
        // No cycles.
        var q = p;
        while (q.isObject()) : (q = q.asCell().as(Object).shape.proto) if (q.asCell() == &o.header) return false;
        try os.toDictionary(o);
        o.shape.proto = p;
        if (p.isObject()) os.markPrototype(p.asCell().as(Object));
        if (o.is_prototype) os.proto_epoch += 1;
        return true;
    }

    /// `p` is now some object's prototype: index keys it already has
    /// count from here on.
    fn markPrototype(os: *Objects, p: *Object) void {
        if (p.is_prototype) return;
        p.is_prototype = true;
        if (p.sparse_indexes) os.proto_has_indexes = true;
        if (p.elements) |e| if (e.len > 0) {
            os.proto_has_indexes = true;
        };
    }

    pub fn growSlots(os: *Objects, o: *Object, need: u32) Error!void {
        if (need <= Object.inline_count) return;
        const want = need - Object.inline_count;
        if (o.overflow) |ov| if (ov.cap >= want) return;
        var cap: u32 = if (o.overflow) |ov| ov.cap * 2 else 4;
        while (cap < want) cap *= 2;
        const c = try os.heap.alloc(.bytes, @sizeOf(Slots) + @as(usize, cap) * @sizeOf(Value));
        c.kind = .bytes;
        const ns = c.as(Slots);
        ns.cap = cap;
        ns.len = want;
        const items = ns.items();
        @memset(items, Value.undefined_);
        if (o.overflow) |ov| @memcpy(items[0..ov.cap], ov.items());
        os.heap.writeBarrier(&o.header, Value.fromCell(c));
        o.overflow = ns;
    }

    /// [[GetOwnProperty]] of an ordinary object: the descriptor pieces.
    pub const Own = struct { val: Value, attrs: Attributes, slot: ?u32 };

    pub fn getOwn(os: *Objects, o: *Object, key: Key) Error!?Own {
        if (key == .index) {
            if (o.elements) |e| if (key.index < e.cap) {
                const v = e.items()[key.index];
                if (!v.isEmpty()) return .{ .val = v, .attrs = .default, .slot = null };
            };
            if (o.class == .string) if (os.stringIndexProperty(o, key.index)) |v| return .{ .val = v, .attrs = .{ .writable = false, .enumerable = true, .configurable = false }, .slot = null };
        }
        const e = (try os.lookup(o.shape, key)) orelse return null;
        return .{ .val = o.slot(e.slot).*, .attrs = e.attrs, .slot = e.slot };
    }

    fn stringIndexProperty(os: *Objects, o: *Object, i: u32) ?Value {
        const s = o.internal(*String).*;
        if (i >= s.len) return null;
        const flat = os.strings.flatten(s) catch return null;
        const unit = [_]u16{flat.unitAt(i)};
        const ch = os.strings.fromUnits(&unit) catch return null;
        return Value.fromCell(ch.cell());
    }

    /// Add or overwrite an own data property with `attrs` (a define:
    /// no setters, no prototype walk). Returns false when the object is
    /// not extensible and the key is new, or the property is not
    /// configurable and the change is not allowed.
    pub fn defineOwn(os: *Objects, o: *Object, key: Key, v: Value, attrs: Attributes) Error!bool {
        if (o.is_prototype) os.proto_epoch += 1;
        // Integer keys of arrays and of plain objects live in the dense
        // elements (a BigInteger keeps its digits on `this[i]`, 2026-09-25).
        if (key == .index and (o.class == .array or o.class == .ordinary)) if (try os.defineElement(o, key.index, v, attrs)) return true;
        if (try os.lookup(o.shape, key)) |e| {
            const same_attrs = @as(u8, @bitCast(e.attrs)) == @as(u8, @bitCast(attrs));
            if (!e.attrs.configurable) {
                // Only a writable data property may change value; nothing else.
                if (!same_attrs or e.attrs.accessor or !e.attrs.writable) {
                    if (!(e.attrs.writable and !e.attrs.accessor and same_attrs)) return false;
                }
            }
            if (!same_attrs) {
                try os.toDictionary(o);
                try o.shape.table.?.map.put(os.meta, key, .{ .slot = e.slot, .attrs = attrs });
            }
            os.heap.writeBarrier(&o.header, v);
            o.slot(e.slot).* = v;
            return true;
        }
        if (!o.extensible) return false;
        if (key == .index) o.sparse_indexes = true;
        if (o.shape.dictionary) {
            const t = o.shape.table.?;
            const slot = o.shape.count;
            o.shape.count += 1;
            try os.growSlots(o, o.shape.count);
            try t.map.put(os.meta, key, .{ .slot = slot, .attrs = attrs });
            try t.order.append(os.meta, .{ .key = key, .present = true });
            os.heap.writeBarrier(&o.header, v);
            o.slot(slot).* = v;
            return true;
        }
        const child = try os.transition(o.shape, key, attrs);
        try os.growSlots(o, child.count);
        os.heap.writeBarrier(&o.header, v);
        o.shape = child;
        o.slot(child.slot).* = v;
        return true;
    }

    /// Define or redefine regardless of configurability (the caller has
    /// validated the change per §10.1.6.3).
    pub fn defineOwnForce(os: *Objects, o: *Object, key: Key, v: Value, attrs: Attributes) Error!bool {
        if (o.is_prototype) os.proto_epoch += 1;
        if (try os.lookup(o.shape, key)) |e| {
            try os.toDictionary(o);
            try o.shape.table.?.map.put(os.meta, key, .{ .slot = e.slot, .attrs = attrs });
            os.heap.writeBarrier(&o.header, v);
            o.slot(e.slot).* = v;
            return true;
        }
        if (key == .index) if (o.elements) |el| if (key.index < el.cap and !el.items()[key.index].isEmpty()) {
            // A dense element changing attributes: move it to the map.
            el.items()[key.index] = Value.empty;
        };
        // A redefinition is never blocked by non-extensibility.
        const was_extensible = o.extensible;
        o.extensible = true;
        defer o.extensible = was_extensible;
        return os.defineOwn(o, key, v, attrs);
    }

    /// An array's dense element, when it stays dense (the index within
    /// or just past the used part, default attributes).
    /// How far past the dense part an integer key may land and still be
    /// an element (8 KB of holes at most); farther is a named property.
    pub const elements_gap_max: u32 = 1024;

    fn defineElement(os: *Objects, o: *Object, i: u32, v: Value, attrs: Attributes) Error!bool {
        if (@as(u8, @bitCast(attrs)) != @as(u8, @bitCast(Attributes.default))) return false;
        if (o.sparse_indexes) if ((try os.lookup(o.shape, .{ .index = i })) != null) return false;
        const e = o.elements orelse blk: {
            if (i > elements_gap_max) return false;
            break :blk try os.growElements(o, @max(8, i + 1));
        };
        if (i >= e.cap) {
            if (i > e.cap + elements_gap_max) return false; // too sparse: a named property instead
            _ = try os.growElements(o, i + 1);
        }
        const el = o.elements.?;
        os.heap.writeBarrier(&o.header, v);
        el.items()[i] = v;
        if (i >= el.len) el.len = i + 1;
        return true;
    }

    pub fn growElements(os: *Objects, o: *Object, need: u32) Error!*Elements {
        var cap: u32 = if (o.elements) |e| e.cap else 0;
        if (cap >= need) return o.elements.?;
        cap = @max(8, cap);
        while (cap < need) cap = cap * 3 / 2 + 8;
        const c = try os.heap.alloc(.bytes, @sizeOf(Elements) + @as(usize, cap) * @sizeOf(Value));
        const ne = c.as(Elements);
        ne.cap = cap;
        const items = ne.items();
        @memset(items, Value.empty);
        if (o.elements) |old| {
            @memcpy(items[0..old.cap], old.items());
            ne.len = old.len;
        } else ne.len = 0;
        os.heap.writeBarrier(&o.header, Value.fromCell(c));
        o.elements = ne;
        return ne;
    }

    /// [[Delete]]: false when the property is not configurable.
    pub fn delete(os: *Objects, o: *Object, key: Key) Error!bool {
        if (o.is_prototype) os.proto_epoch += 1;
        if (key == .index) if (o.elements) |e| if (key.index < e.cap and !e.items()[key.index].isEmpty()) {
            e.items()[key.index] = Value.empty;
            return true;
        };
        const e = (try os.lookup(o.shape, key)) orelse return true;
        if (!e.attrs.configurable) return false;
        try os.toDictionary(o);
        const t = o.shape.table.?;
        _ = t.map.remove(key);
        for (t.order.items) |*ent| if (ent.key.eql(key)) {
            ent.present = false;
        };
        o.slot(e.slot).* = Value.undefined_;
        return true;
    }

    /// Own keys in the specification's order: integer indexes ascending,
    /// then strings in insertion order, then symbols in insertion order.
    pub fn ownKeys(os: *Objects, o: *Object, out: *std.ArrayList(Key)) Error!void {
        if (o.elements) |e| for (e.items(), 0..) |v, i| if (!v.isEmpty()) try out.append(os.meta, .{ .index = @intCast(i) });
        if (o.class == .string) {
            const s = o.internal(*String).*;
            for (0..s.len) |i| try out.append(os.meta, .{ .index = @intCast(i) });
        }
        // Index-keyed named properties (sparse) come first too, ascending.
        var indexes: std.ArrayList(u32) = .empty;
        defer indexes.deinit(os.meta);
        var strings_: std.ArrayList(Key) = .empty;
        defer strings_.deinit(os.meta);
        var symbols: std.ArrayList(Key) = .empty;
        defer symbols.deinit(os.meta);
        if (o.shape.table == null and o.shape.count > 0) try os.buildTable(o.shape);
        if (o.shape.table) |t| {
            for (t.order.items) |ent| {
                if (!ent.present) continue;
                switch (ent.key) {
                    .index => |i| try indexes.append(os.meta, i),
                    .atom => try strings_.append(os.meta, ent.key),
                    .symbol => try symbols.append(os.meta, ent.key),
                }
            }
        }
        std.mem.sort(u32, indexes.items, {}, std.sort.asc(u32));
        for (indexes.items) |i| try out.append(os.meta, .{ .index = i });
        try out.appendSlice(os.meta, strings_.items);
        try out.appendSlice(os.meta, symbols.items);
    }

    /// Trace an object's references.
    pub fn trace(o: *Object, m: *heap.Marker) void {
        m.markCell(o.shape.cell());
        for (o.inline_slots) |v| m.markValue(v);
        if (o.overflow) |ov| {
            m.markCell(&ov.header);
            for (ov.items()) |v| m.markValue(v);
        }
        if (o.elements) |e| {
            m.markCell(&e.header);
            for (e.items()) |v| m.markValue(v);
        }
    }

    pub fn traceShape(s: *Shape, m: *heap.Marker) void {
        if (s.parent) |p| m.markCell(p.cell());
        if (s.key_cell) |k| m.markCell(k);
        m.markValue(s.proto);
        if (s.transitions) |tr| for (tr.list.items) |t| {
            if (t.key.cell()) |c| m.markCell(c);
            m.markCell(t.child.cell());
        };
        if (s.table) |t| {
            var it = t.map.keyIterator();
            while (it.next()) |k| if (k.cell()) |c| m.markCell(c);
        }
    }

    pub fn traceAccessor(a: *Accessor, m: *heap.Marker) void {
        m.markValue(a.get);
        m.markValue(a.set);
    }

    pub fn traceSymbol(s: *Symbol, m: *heap.Marker) void {
        if (s.description) |d| m.markCell(d.cell());
    }

    /// Free a shape's bookkeeping (the heap's finalizer for shape cells).
    pub fn finalizeShape(os: *Objects, s: *Shape) void {
        if (s.transitions) |tr| {
            tr.list.deinit(os.meta);
            os.meta.destroy(tr);
            s.transitions = null;
        }
        if (s.table) |t| {
            t.map.deinit(os.meta);
            t.order.deinit(os.meta);
            os.meta.destroy(t);
            s.table = null;
        }
    }
};

// ------------------------------------------------------------- tests

const TestRuntime = struct {
    heap: Heap,
    strings: string.Strings,
    objects: Objects,
    keep: std.ArrayList(*Cell) = .empty,

    fn trace(h: *Heap, c: *Cell, m: *heap.Marker) void {
        const rt: *TestRuntime = @fieldParentPtr("heap", h);
        _ = rt;
        switch (c.kind) {
            .string => string.Strings.trace(c.as(String), m),
            .object => Objects.trace(c.as(Object), m),
            .shape => Objects.traceShape(c.as(Shape), m),
            .symbol => Objects.traceSymbol(c.as(Symbol), m),
            else => {},
        }
    }
    fn roots(ctx: *anyopaque, m: *heap.Marker) void {
        const rt: *TestRuntime = @ptrCast(@alignCast(ctx));
        for (rt.keep.items) |c| m.markCell(c);
        rt.strings.markRoots(m);
        rt.objects.markRoots(m);
    }
    fn finalize(h: *Heap, c: *Cell) void {
        const rt: *TestRuntime = @fieldParentPtr("heap", h);
        switch (c.kind) {
            .shape => rt.objects.finalizeShape(c.as(Shape)),
            .string => rt.strings.forget(c.as(String)),
            else => {},
        }
    }
};

test "object: shapes are shared, slots read back, transitions and dictionaries" {
    const region = try std.testing.allocator.alloc(u8, 1 << 20);
    defer std.testing.allocator.free(region);
    var rt: TestRuntime = undefined;
    rt.keep = .empty;
    rt.heap = Heap.init(region, std.testing.allocator, TestRuntime.trace);
    rt.heap.finalizer = TestRuntime.finalize;
    rt.strings = string.Strings.init(&rt.heap, std.testing.allocator);
    rt.objects = Objects.init(&rt.heap, &rt.strings, std.testing.allocator);
    defer {
        rt.heap.deinit(); // finalizers first: they use the tables below
        rt.objects.deinit();
        rt.strings.deinit();
        rt.keep.deinit(std.testing.allocator);
    }
    try rt.heap.addRoot(.{ .ctx = &rt, .trace = TestRuntime.roots });
    const os = &rt.objects;
    const kx: Key = .{ .atom = try rt.strings.atom("x") };
    const ky: Key = .{ .atom = try rt.strings.atom("y") };
    try rt.keep.append(std.testing.allocator, kx.atom.cell());
    try rt.keep.append(std.testing.allocator, ky.atom.cell());
    const a = try os.create(Value.null_, .ordinary, 0);
    const b = try os.create(Value.null_, .ordinary, 0);
    try rt.keep.append(std.testing.allocator, a.cell());
    try rt.keep.append(std.testing.allocator, b.cell());
    try std.testing.expect(try os.defineOwn(a, kx, Value.fromInt(1), .default));
    try std.testing.expect(try os.defineOwn(a, ky, Value.fromInt(2), .default));
    try std.testing.expect(try os.defineOwn(b, kx, Value.fromInt(10), .default));
    try std.testing.expect(try os.defineOwn(b, ky, Value.fromInt(20), .default));
    try std.testing.expectEqual(a.shape, b.shape); // the same path, the same hidden class
    try std.testing.expectEqual(@as(i32, 2), (try os.getOwn(a, ky)).?.val.asInt());
    try std.testing.expectEqual(@as(i32, 10), (try os.getOwn(b, kx)).?.val.asInt());
    // Many properties: the table kicks in; deletion makes a dictionary.
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        var buf: [8]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "p{d}", .{i});
        const k: Key = .{ .atom = try rt.strings.atom(name) };
        try rt.keep.append(std.testing.allocator, k.atom.cell());
        try std.testing.expect(try os.defineOwn(a, k, Value.fromInt(@intCast(i)), .default));
    }
    try std.testing.expectEqual(@as(i32, 7), (try os.getOwn(a, .{ .atom = try rt.strings.atom("p7") })).?.val.asInt());
    try std.testing.expect(try os.delete(a, kx));
    try std.testing.expect(a.shape.dictionary);
    try std.testing.expect((try os.getOwn(a, kx)) == null);
    try std.testing.expectEqual(@as(i32, 2), (try os.getOwn(a, ky)).?.val.asInt());
    try std.testing.expect(!a.shape.dictionary or b.shape != a.shape);
    // Keys in order: y then p0..p19 (x deleted).
    var keys: std.ArrayList(Key) = .empty;
    defer keys.deinit(std.testing.allocator);
    try os.ownKeys(a, &keys);
    try std.testing.expectEqual(@as(usize, 21), keys.items.len);
    try std.testing.expect(keys.items[0].atom == ky.atom);
    // Arrays: dense elements.
    const arr = try os.create(Value.null_, .array, 0);
    try rt.keep.append(std.testing.allocator, arr.cell());
    try std.testing.expect(try os.defineOwn(arr, .{ .index = 0 }, Value.fromInt(5), .default));
    try std.testing.expect(try os.defineOwn(arr, .{ .index = 3 }, Value.fromInt(8), .default));
    try std.testing.expectEqual(@as(i32, 8), (try os.getOwn(arr, .{ .index = 3 })).?.val.asInt());
    try std.testing.expect((try os.getOwn(arr, .{ .index = 1 })) == null);
    try std.testing.expectEqual(@as(u32, 4), arr.elements.?.len);
    // A collection keeps everything rooted intact.
    rt.heap.collect();
    try std.testing.expectEqual(@as(i32, 20), (try os.getOwn(b, ky)).?.val.asInt());
    try std.testing.expectEqual(@as(i32, 8), (try os.getOwn(arr, .{ .index = 3 })).?.val.asInt());
}
