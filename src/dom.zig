//! The page's objects from Zig, read and changed as JavaScript would (ZeroG's
//! object API, zg_ref_*):
//!
//!     pub fn rename(self: *App, page: plume.Page, title: []const u8) !void {
//!         const heading = try page.byId("title");
//!         try heading.set("textContent", title);
//!         try heading.set("style.color", "tomato");
//!     }
//!
//! On the runtime thread only: a sync binding gets a Page by declaring a
//! parameter of that type (JavaScript does not pass it), and app.page() opens
//! one in event handlers and dispatch()ed work. Every Ref and string a Page
//! gives lives until the Page is closed (for a binding's, after the call).
//! Names are property names or dotted paths of them ("document.title",
//! "style.color", "items.0").

const std = @import("std");
const zg = @import("zerog");
const codec = @import("codec.zig");

pub const Error = error{
    /// The view shows no document (yet).
    NoDocument,
    /// A missing step on a path, an element that is not there, or a
    /// reference whose page is gone.
    NotFound,
    /// A value of another type than asked for.
    TypeMismatch,
    /// JavaScript threw: a getter, setter or method. std.log has the message.
    JsException,
    /// Called off the runtime thread.
    WrongThread,
    OutOfMemory,
    EngineFailed,
};

pub const Page = struct {
    /// Bindings get it from the call, not from JavaScript (methods.zig).
    pub const plume_injected = {};

    scope: *Scope,

    const Scope = struct {
        arena: std.heap.ArenaAllocator,
        view: *zg.zg_view,
        refs: std.ArrayList(*zg.zg_ref) = .empty,
        global: ?*zg.zg_ref = null,
    };

    pub fn open(view: *zg.zg_view) Error!Page {
        const scope = std.heap.smp_allocator.create(Scope) catch return error.OutOfMemory;
        scope.* = .{ .arena = .init(std.heap.smp_allocator), .view = view };
        return .{ .scope = scope };
    }

    /// Releases every reference made through the page.
    pub fn close(page: Page) void {
        const scope = page.scope;
        for (scope.refs.items) |ref| zg.zg_ref_release(ref);
        scope.arena.deinit();
        std.heap.smp_allocator.destroy(scope);
    }

    /// Lives as long as the page: for what is read from it.
    pub fn allocator(page: Page) std.mem.Allocator {
        return page.scope.arena.allocator();
    }

    /// The global object (window).
    pub fn window(page: Page) Error!Ref {
        if (page.scope.global) |global| return .{ .page = page, .handle = global };
        const global = zg.zg_view_global(page.scope.view) orelse return error.NoDocument;
        try page.keep(global);
        page.scope.global = global;
        return .{ .page = page, .handle = global };
    }

    pub fn document(page: Page) Error!Ref {
        return (try page.window()).get("document");
    }

    /// document.getElementById(id); error.NotFound if there is none.
    pub fn byId(page: Page, id: []const u8) Error!Ref {
        return nonNull(try (try page.window()).call("document.getElementById", .{id}));
    }

    /// document.querySelector(selector); error.NotFound if nothing matches.
    pub fn query(page: Page, selector: []const u8) Error!Ref {
        return nonNull(try (try page.window()).call("document.querySelector", .{selector}));
    }

    /// document.querySelectorAll(selector), as a slice.
    pub fn queryAll(page: Page, selector: []const u8) Error![]Ref {
        const list = try (try page.window()).call("document.querySelectorAll", .{selector});
        return list.items();
    }

    /// Runs `script` in the page and decodes its result into `T` (through
    /// JSON; void to ignore it).
    pub fn evaluate(page: Page, comptime T: type, script: []const u8) Error!T {
        var result: ?*zg.zg_value = null;
        try check(zg.zg_view_evaluate(page.scope.view, script.ptr, script.len, if (T == void) null else &result));
        if (T == void) return;
        defer zg.zg_value_release(result);
        var length: usize = 0;
        const json = zg.zg_value_to_json(result, &length) orelse return error.EngineFailed;
        return decode(T, page.allocator(), json[0..length]);
    }

    fn keep(page: Page, ref: *zg.zg_ref) Error!void {
        page.scope.refs.append(page.allocator(), ref) catch {
            zg.zg_ref_release(ref);
            return error.OutOfMemory;
        };
    }

    fn wrap(page: Page, ref: ?*zg.zg_ref) Error!Ref {
        const handle = ref orelse return error.EngineFailed;
        try page.keep(handle);
        return .{ .page = page, .handle = handle };
    }

    /// A string the engine returned, copied into the page's arena and freed.
    fn adopt(page: Page, text: [*c]u8, length: usize) Error![]const u8 {
        defer zg.zg_free(text);
        if (text == null) return "";
        return page.allocator().dupe(u8, text[0..length]) catch error.OutOfMemory;
    }

    /// A value made for the engine (released by the caller): a bool, number,
    /// string, Ref, null, or anything else as JSON. Void is undefined (null).
    fn value(page: Page, input: anytype) Error!?*zg.zg_value {
        const X = @TypeOf(input);
        if (X == void) return null;
        if (X == Ref) return zg.zg_value_ref(null, input.handle) orelse error.EngineFailed;
        if (comptime isString(X)) {
            const text: []const u8 = input;
            return zg.zg_value_string_len(null, text.ptr, text.len) orelse error.OutOfMemory;
        }
        switch (@typeInfo(X)) {
            .null => return zg.zg_value_null(null) orelse error.OutOfMemory,
            .optional => return if (input) |payload| page.value(payload) else zg.zg_value_null(null) orelse error.OutOfMemory,
            .bool => return zg.zg_value_bool(null, @intFromBool(input)) orelse error.OutOfMemory,
            .int, .comptime_int => return zg.zg_value_number(null, @floatFromInt(input)) orelse error.OutOfMemory,
            .float, .comptime_float => return zg.zg_value_number(null, @floatCast(input)) orelse error.OutOfMemory,
            else => {
                const json = codec.encode(page.allocator(), input) catch return error.OutOfMemory;
                return zg.zg_value_json(null, json.ptr, json.len) orelse error.TypeMismatch;
            },
        }
    }

    /// The values of the tuple `args` into `out`; how many were made (on an
    /// error, those made are released).
    fn values(page: Page, args: anytype, out: *Values(@TypeOf(args))) Error!usize {
        inline for (0..out.len) |i| {
            out[i] = page.value(args[i]) catch |err| {
                for (out[0..i]) |v| if (v) |made| zg.zg_value_release(made);
                return err;
            };
        }
        return out.len;
    }
};

/// A value of the page: an element, an object, anything JavaScript has.
pub const Ref = struct {
    page: Page,
    handle: *zg.zg_ref,

    pub fn get(ref: Ref, name: []const u8) Error!Ref {
        const path = try ref.cstr(name);
        var out: ?*zg.zg_ref = null;
        try check(zg.zg_ref_get(ref.handle, path, &out));
        return ref.page.wrap(out);
    }

    /// Copied: lives as long as the page.
    pub fn getString(ref: Ref, name: []const u8) Error![]const u8 {
        var out: [*c]u8 = null;
        var length: usize = 0;
        try check(zg.zg_ref_get_string(ref.handle, try ref.cstr(name), &out, &length));
        return ref.page.adopt(out, length);
    }

    pub fn getNumber(ref: Ref, name: []const u8) Error!f64 {
        var out: f64 = 0;
        try check(zg.zg_ref_get_number(ref.handle, try ref.cstr(name), &out));
        return out;
    }

    pub fn getBool(ref: Ref, name: []const u8) Error!bool {
        var out: c_int = 0;
        try check(zg.zg_ref_get_bool(ref.handle, try ref.cstr(name), &out));
        return out != 0;
    }

    /// Any value, through JSON, as `T` (structs, slices, optionals...).
    pub fn getAs(ref: Ref, comptime T: type, name: []const u8) Error!T {
        var out: [*c]u8 = null;
        var length: usize = 0;
        try check(zg.zg_ref_get_json(ref.handle, try ref.cstr(name), &out, &length));
        return decode(T, ref.page.allocator(), try ref.page.adopt(out, length));
    }

    /// Sets `name` to `value`: a bool, number, string, Ref, null, or anything
    /// else as JSON.
    pub fn set(ref: Ref, name: []const u8, value: anytype) Error!void {
        const converted = try ref.page.value(value);
        defer if (converted) |v| zg.zg_value_release(v);
        try check(zg.zg_ref_set(ref.handle, try ref.cstr(name), converted));
    }

    /// Calls the method at `name` (`this` its object) with the values of the
    /// tuple `args`, converted as set() does.
    pub fn call(ref: Ref, name: []const u8, args: anytype) Error!Ref {
        var values: Values(@TypeOf(args)) = undefined;
        const count = try ref.page.values(args, &values);
        defer for (values[0..count]) |v| if (v) |value| zg.zg_value_release(value);
        var out: ?*zg.zg_ref = null;
        try check(zg.zg_ref_call_method(ref.handle, try ref.cstr(name), count, &values, &out));
        return ref.page.wrap(out);
    }

    /// call(), the result ignored.
    pub fn invoke(ref: Ref, name: []const u8, args: anytype) Error!void {
        var values: Values(@TypeOf(args)) = undefined;
        const count = try ref.page.values(args, &values);
        defer for (values[0..count]) |v| if (v) |value| zg.zg_value_release(value);
        try check(zg.zg_ref_call_method(ref.handle, try ref.cstr(name), count, &values, null));
    }

    pub fn toString(ref: Ref) Error![]const u8 {
        var out: [*c]u8 = null;
        var length: usize = 0;
        try check(zg.zg_ref_to_string(ref.handle, &out, &length));
        return ref.page.adopt(out, length);
    }

    pub fn toNumber(ref: Ref) Error!f64 {
        var out: f64 = 0;
        try check(zg.zg_ref_to_number(ref.handle, &out));
        return out;
    }

    pub fn toBool(ref: Ref) Error!bool {
        var out: c_int = 0;
        try check(zg.zg_ref_to_bool(ref.handle, &out));
        return out != 0;
    }

    pub fn as(ref: Ref, comptime T: type) Error!T {
        var out: [*c]u8 = null;
        var length: usize = 0;
        try check(zg.zg_ref_to_json(ref.handle, &out, &length));
        return decode(T, ref.page.allocator(), try ref.page.adopt(out, length));
    }

    /// null or undefined.
    pub fn isNull(ref: Ref) bool {
        const kind = zg.zg_ref_type(ref.handle);
        return kind == zg.ZG_TYPE_NULL or kind == zg.ZG_TYPE_UNDEFINED;
    }

    /// The items of an array or array-like (a NodeList, for instance).
    pub fn items(ref: Ref) Error![]Ref {
        const count: usize = @intFromFloat(@max(0, try ref.getNumber("length")));
        const result = ref.page.allocator().alloc(Ref, count) catch return error.OutOfMemory;
        var buffer: [24]u8 = undefined;
        for (result, 0..) |*item, i| {
            const index = std.fmt.bufPrint(&buffer, "{d}", .{i}) catch unreachable;
            item.* = try ref.get(index);
        }
        return result;
    }

    fn cstr(ref: Ref, name: []const u8) Error![*:0]const u8 {
        return (ref.page.allocator().dupeSentinel(u8, name, 0) catch return error.OutOfMemory).ptr;
    }
};

fn nonNull(ref: Ref) Error!Ref {
    if (ref.isNull()) return error.NotFound;
    return ref;
}

fn Values(comptime Args: type) type {
    return [@typeInfo(Args).@"struct".field_names.len]?*zg.zg_value;
}

fn decode(comptime T: type, allocator: std.mem.Allocator, json: []const u8) Error!T {
    return codec.decode(T, allocator, json) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidArgument => error.TypeMismatch,
    };
}

fn check(result: zg.zg_result) Error!void {
    switch (result) {
        zg.ZG_OK => return,
        zg.ZG_ERROR_NOT_FOUND => return error.NotFound,
        zg.ZG_ERROR_TYPE => return error.TypeMismatch,
        zg.ZG_ERROR_WRONG_THREAD => return error.WrongThread,
        zg.ZG_ERROR_OUT_OF_MEMORY => return error.OutOfMemory,
        zg.ZG_ERROR_JS_EXCEPTION => {
            std.log.warn("plume: JavaScript threw: {s}", .{zg.zg_last_error()});
            return error.JsException;
        },
        else => {
            std.log.warn("plume: {s}", .{zg.zg_last_error()});
            return error.EngineFailed;
        },
    }
}

fn isString(comptime X: type) bool {
    if (X == []const u8 or X == []u8 or X == [:0]const u8) return true;
    return switch (@typeInfo(X)) {
        .pointer => |info| info.size == .one and switch (@typeInfo(info.child)) {
            .array => |array| array.child == u8,
            else => false,
        },
        else => false,
    };
}
