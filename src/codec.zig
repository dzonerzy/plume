//! Zig values to JSON and back, as bindings pass them to and from JavaScript
//! (and as typescript.zig types them):
//!
//!   bool                   boolean
//!   integers, floats       number
//!   []const u8             string
//!   slices, arrays         arrays
//!   structs                objects, one property per field
//!   enums                  the tag's name, a string
//!   union(enum)            { "tag": name, "value": payload } (no "value" for void)
//!   ?T                     null or T
//!   Bytes                  an array of numbers (0-255); a binding's own
//!                          Bytes argument or result is a Uint8Array instead
//!                          (bindings.zig, without JSON)
//!
//! Decoding is strict about types and lenient about extra object properties;
//! a missing field takes its default value or fails.

const std = @import("std");

/// Binary data (plume.Bytes): a Uint8Array in JavaScript.
pub const Bytes = struct {
    data: []const u8,
};

pub const DecodeError = error{
    /// The JSON does not match the Zig type (wrong type, missing field,
    /// unknown enum tag, integer out of range).
    InvalidArgument,
    OutOfMemory,
};

/// `value` as JSON, allocated with `allocator`.
pub fn encode(allocator: std.mem.Allocator, value: anytype) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    write(&stringify, value) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write(s: *std.json.Stringify, value: anytype) std.json.Stringify.Error!void {
    const T = @TypeOf(value);
    if (T == Bytes) {
        try s.beginArray();
        for (value.data) |byte| try s.write(byte);
        return s.endArray();
    }
    switch (@typeInfo(T)) {
        .void, .null => try s.write(null),
        .bool, .int, .comptime_int, .float, .comptime_float => try s.write(value),
        .optional => if (value) |payload| try write(s, payload) else try s.write(null),
        .@"enum" => try s.write(@tagName(value)),
        .enum_literal => try s.write(@tagName(value)),
        .pointer => |pointer| switch (pointer.size) {
            .slice => if (pointer.child == u8) {
                try s.write(value);
            } else {
                try s.beginArray();
                for (value) |item| try write(s, item);
                try s.endArray();
            },
            .one => switch (@typeInfo(pointer.child)) {
                // String literals: *const [N:0]u8.
                .array => |array| if (array.child == u8) try s.write(@as([]const u8, value)) else try write(s, value.*),
                else => try write(s, value.*),
            },
            else => @compileError("cannot pass " ++ @typeName(T) ++ " to JavaScript"),
        },
        .array => {
            try s.beginArray();
            for (value) |item| try write(s, item);
            try s.endArray();
        },
        .@"struct" => |info| {
            try s.beginObject();
            inline for (info.field_names) |name| {
                try s.objectField(name);
                try write(s, @field(value, name));
            }
            try s.endObject();
        },
        .@"union" => |info| {
            if (info.tag_type == null)
                @compileError("only tagged unions pass to JavaScript: " ++ @typeName(T));
            try s.beginObject();
            try s.objectField("tag");
            try s.write(@tagName(value));
            switch (value) {
                inline else => |payload| if (@TypeOf(payload) != void) {
                    try s.objectField("value");
                    try write(s, payload);
                },
            }
            try s.endObject();
        },
        else => @compileError("cannot pass " ++ @typeName(T) ++ " to JavaScript"),
    }
}

/// The JSON as a `T`. Everything it points to is allocated with `allocator`
/// (an arena: nothing is freed piecemeal).
pub fn decode(comptime T: type, allocator: std.mem.Allocator, json: []const u8) DecodeError!T {
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArgument,
    };
    return fromValue(T, allocator, value);
}

/// A parsed JSON value as a `T`.
pub fn fromValue(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value) DecodeError!T {
    if (T == Bytes) {
        const items = switch (value) {
            .array => |array| array.items,
            else => return error.InvalidArgument,
        };
        const data = try allocator.alloc(u8, items.len);
        for (items, data) |item, *byte| byte.* = try fromValue(u8, allocator, item);
        return .{ .data = data };
    }
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => return switch (value) {
            .bool => |b| b,
            else => error.InvalidArgument,
        },
        .int => return switch (value) {
            .integer => |i| std.math.cast(T, i) orelse error.InvalidArgument,
            .float => |f| floatToInt(T, f),
            .number_string => |text| std.fmt.parseInt(T, text, 10) catch error.InvalidArgument,
            else => error.InvalidArgument,
        },
        .float => return switch (value) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            .number_string => |text| std.fmt.parseFloat(T, text) catch error.InvalidArgument,
            else => error.InvalidArgument,
        },
        .optional => |optional| return switch (value) {
            .null => null,
            else => try fromValue(optional.child, allocator, value),
        },
        .@"enum" => return switch (value) {
            .string => |text| std.meta.stringToEnum(T, text) orelse error.InvalidArgument,
            else => error.InvalidArgument,
        },
        .pointer => |pointer| {
            if (pointer.size != .slice)
                @compileError("bindings take slices, not " ++ @typeName(T));
            if (pointer.child == u8) {
                return switch (value) {
                    .string => |text| text,
                    else => error.InvalidArgument,
                };
            }
            const items = switch (value) {
                .array => |array| array.items,
                else => return error.InvalidArgument,
            };
            const result = try allocator.alloc(pointer.child, items.len);
            for (items, result) |item, *slot| slot.* = try fromValue(pointer.child, allocator, item);
            return result;
        },
        .array => |array| {
            const items = switch (value) {
                .array => |list| list.items,
                else => return error.InvalidArgument,
            };
            if (items.len != array.len)
                return error.InvalidArgument;
            var result: T = undefined;
            for (items, &result) |item, *slot| slot.* = try fromValue(array.child, allocator, item);
            return result;
        },
        .@"struct" => |info| {
            const object = switch (value) {
                .object => |map| map,
                else => return error.InvalidArgument,
            };
            var result: T = undefined;
            inline for (info.field_names, info.field_types, info.field_attrs) |name, FieldType, attrs| {
                if (object.get(name)) |property| {
                    @field(result, name) = try fromValue(FieldType, allocator, property);
                } else if (attrs.defaultValue(FieldType)) |default| {
                    @field(result, name) = default;
                } else if (@typeInfo(FieldType) == .optional) {
                    @field(result, name) = null;
                } else {
                    return error.InvalidArgument;
                }
            }
            return result;
        },
        .@"union" => |info| {
            if (info.tag_type == null)
                @compileError("only tagged unions come from JavaScript: " ++ @typeName(T));
            const object = switch (value) {
                .object => |map| map,
                else => return error.InvalidArgument,
            };
            const tag = switch (object.get("tag") orelse return error.InvalidArgument) {
                .string => |text| text,
                else => return error.InvalidArgument,
            };
            inline for (info.field_names, info.field_types) |name, FieldType| {
                if (std.mem.eql(u8, tag, name)) {
                    if (FieldType == void)
                        return @unionInit(T, name, {});
                    const payload = object.get("value") orelse return error.InvalidArgument;
                    return @unionInit(T, name, try fromValue(FieldType, allocator, payload));
                }
            }
            return error.InvalidArgument;
        },
        else => @compileError("cannot take " ++ @typeName(T) ++ " from JavaScript"),
    }
}

/// A JSON number as an integer: whole, and exact (up to 2^53), in T's range.
fn floatToInt(comptime T: type, f: f64) DecodeError!T {
    if (@trunc(f) != f or @abs(f) > 9007199254740992)
        return error.InvalidArgument;
    const whole: i64 = @intFromFloat(f);
    return std.math.cast(T, whole) orelse error.InvalidArgument;
}

// ---- Tests ----

const testing = std.testing;

const Shape = union(enum) {
    circle: f64,
    square: struct { side: u32 },
    none,
};

const Entry = struct {
    name: []const u8,
    size: u64,
    kind: enum { file, folder } = .file,
    tags: []const []const u8 = &.{},
    shape: Shape = .none,
    parent: ?[]const u8 = null,
};

test "encode: every kind of value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entry: Entry = .{ .name = "notes.txt", .size = 12, .tags = &.{ "a", "b" }, .shape = .{ .square = .{ .side = 3 } } };
    try testing.expectEqualStrings(
        \\{"name":"notes.txt","size":12,"kind":"file","tags":["a","b"],"shape":{"tag":"square","value":{"side":3}},"parent":null}
    , try encode(a, entry));
    try testing.expectEqualStrings("{\"tag\":\"none\"}", try encode(a, @as(Shape, .none)));
    try testing.expectEqualStrings("\"hi\"", try encode(a, "hi"));
    try testing.expectEqualStrings("[1,2,3]", try encode(a, [_]u8{ 1, 2, 3 }));
    try testing.expectEqualStrings("null", try encode(a, @as(?u8, null)));
}

test "decode: round trips and defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entry = try decode(Entry, a,
        \\{"name":"x","size":5,"kind":"folder","shape":{"tag":"circle","value":1.5},"extra":true}
    );
    try testing.expectEqualStrings("x", entry.name);
    try testing.expectEqual(@as(u64, 5), entry.size);
    try testing.expectEqual(.folder, entry.kind);
    try testing.expectEqual(@as(f64, 1.5), entry.shape.circle);
    try testing.expectEqual(@as(usize, 0), entry.tags.len);
    try testing.expectEqual(@as(?[]const u8, null), entry.parent);
    const again = try decode(Entry, a, try encode(a, entry));
    try testing.expectEqualStrings(entry.name, again.name);
}

test "bytes: arrays of numbers inside JSON" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Blob = struct { name: []const u8, content: Bytes };
    try testing.expectEqualStrings("{\"name\":\"b\",\"content\":[0,7,255]}", try encode(a, Blob{ .name = "b", .content = .{ .data = &.{ 0, 7, 255 } } }));
    const blob = try decode(Blob, a, "{\"name\":\"b\",\"content\":[1,2]}");
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, blob.content.data);
    try testing.expectError(error.InvalidArgument, decode(Bytes, a, "[256]"));
}

test "decode: wrong types are errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidArgument, decode(Entry, a, "{\"size\":1}"));
    try testing.expectError(error.InvalidArgument, decode(u8, a, "300"));
    try testing.expectError(error.InvalidArgument, decode(u8, a, "1.5"));
    try testing.expectError(error.InvalidArgument, decode(Shape, a, "{\"tag\":\"triangle\"}"));
    try testing.expectError(error.InvalidArgument, decode([]const u8, a, "12"));
    try testing.expectError(error.InvalidArgument, decode(bool, a, "not json"));
}
