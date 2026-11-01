//! The dispatcher: one engine binding per method of a type (methods.zig),
//! generated at compile time. Each decodes JavaScript's arguments into the
//! method's parameter types, calls it, and encodes what it returns:
//!
//!   - bool, numbers and strings pass directly; everything else as JSON
//!     (codec.zig). Strings are the engine's during a sync call (no copy).
//!   - A parameter of type std.mem.Allocator gets the call's arena, one of
//!     type plume.Page the calling page (dom.zig), closed after the call, one
//!     of type std.Io the app's.
//!   - A Zig error is thrown into JavaScript as "plume:<ErrorName>", which
//!     bindings.ts turns into a PlumeError with that code; arguments of the
//!     wrong type throw "plume:InvalidArgument: <what>".
//!   - async_methods run on a thread of their own and settle a Promise; their
//!     arguments are copied first, their result goes as JSON.

const std = @import("std");
const zg = @import("zerog");
const codec = @import("codec.zig");
const methods = @import("methods.zig");
const dom = @import("dom.zig");

pub const BindError = error{BindFailed};

/// What a std.Io parameter gets: the app's (plume.App's `io` option), else
/// std's global single-threaded one. One runtime per process: one value.
pub var io: ?std.Io = null;

fn appIo() std.Io {
    return io orelse std.Io.Threaded.global_single_threaded.io();
}

/// Async calls not settled yet: the app waits for them before it ends.
pub var running: std.atomic.Value(usize) = .init(0);

/// Binds the methods of `instance` under `name` in the view's pages
/// ("App.greet"). The instance must outlive the view.
pub fn bind(view: *zg.zg_view, comptime name: [:0]const u8, comptime T: type, instance: *T) BindError!void {
    inline for (comptime methods.of(T)) |method| {
        const Binding = Dispatch(T, name, method.name);
        const function = if (method.is_async) &Binding.callAsync else &Binding.callSync;
        if (zg.zg_view_bind(view, name ++ "." ++ method.name, function, instance) != zg.ZG_OK)
            return error.BindFailed;
    }
}

const Call = ?*zg.zg_call;
const Value = ?*zg.zg_value;

fn Dispatch(comptime T: type, comptime binding_name: []const u8, comptime method_name: [:0]const u8) type {
    const function = @field(T, method_name);
    const F = @TypeOf(function);
    const params = @typeInfo(F).@"fn".param_types;
    const Args = std.meta.ArgsTuple(F);
    const R = @typeInfo(F).@"fn".return_type.?;
    const full_name = binding_name ++ "." ++ method_name;

    return struct {
        fn takesPage() bool {
            for (params) |P| {
                if (methods.isInjected(P.?)) return true;
            }
            return false;
        }

        /// The arguments: the instance, arenas, the page (sync calls), and
        /// what JavaScript passed.
        fn decodeArgs(call: Call, instance: *T, arena: std.mem.Allocator, copy: bool, page: ?dom.Page) ArgError!Args {
            var args: Args = undefined;
            const argc = zg.zg_call_argc(call);
            comptime var js_index = 0;
            inline for (params, 0..) |Param, i| {
                const P = Param.?;
                if (i == 0) {
                    args[0] = if (P == T) instance.* else instance;
                } else if (P == std.mem.Allocator) {
                    args[i] = arena;
                } else if (P == std.Io) {
                    args[i] = appIo();
                } else if (comptime methods.isInjected(P)) {
                    args[i] = page.?;
                } else {
                    args[i] = try decodeArg(P, call, js_index, argc, arena, copy);
                    js_index += 1;
                }
            }
            return args;
        }

        fn callSync(call: Call, user: ?*anyopaque) callconv(.c) Value {
            const instance: *T = @ptrCast(@alignCast(user.?));
            var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
            defer arena.deinit();
            const page: ?dom.Page = if (comptime takesPage()) (dom.Page.open(zg.zg_call_view(call).?) catch
                return zg.zg_call_throw(call, "plume:OutOfMemory")) else null;
            defer if (page) |p| p.close();
            const args = decodeArgs(call, instance, arena.allocator(), false, page) catch |err| return throwArgError(call, full_name, err);
            const result = if (@typeInfo(R) == .error_union)
                @call(.auto, function, args) catch |err| return throwError(call, err)
            else
                @call(.auto, function, args);
            return encodeResult(call, arena.allocator(), result);
        }

        const Job = struct {
            arena: std.heap.ArenaAllocator,
            args: Args,
            promise: *zg.zg_promise,
        };

        fn callAsync(call: Call, user: ?*anyopaque) callconv(.c) Value {
            const instance: *T = @ptrCast(@alignCast(user.?));
            var promise: ?*zg.zg_promise = null;
            const value = zg.zg_call_promise(call, &promise);
            const job = std.heap.smp_allocator.create(Job) catch {
                zg.zg_promise_reject(promise, "plume:OutOfMemory");
                return value;
            };
            job.* = .{ .arena = .init(std.heap.smp_allocator), .args = undefined, .promise = promise.? };
            _ = running.fetchAdd(1, .acq_rel);
            // The engine's strings are not the thread's: copied into the arena.
            job.args = decodeArgs(call, instance, job.arena.allocator(), true, null) catch |err| {
                var buffer: [256]u8 = undefined;
                zg.zg_promise_reject(job.promise, argErrorMessage(&buffer, full_name, err));
                finish(job);
                return value;
            };
            const thread = std.Thread.spawn(.{}, run, .{job}) catch {
                zg.zg_promise_reject(job.promise, "plume:SystemResources");
                finish(job);
                return value;
            };
            thread.detach();
            return value;
        }

        fn run(job: *Job) void {
            defer finish(job);
            const result = if (@typeInfo(R) == .error_union)
                @call(.auto, function, job.args) catch |err| {
                    var buffer: [128]u8 = undefined;
                    zg.zg_promise_reject(job.promise, format(&buffer, "plume:{s}", .{@errorName(err)}, "plume:Error"));
                    return;
                }
            else
                @call(.auto, function, job.args);
            const json = codec.encode(job.arena.allocator(), result) catch {
                zg.zg_promise_reject(job.promise, "plume:OutOfMemory");
                return;
            };
            zg.zg_promise_resolve(job.promise, json.ptr, json.len);
        }

        fn finish(job: *Job) void {
            job.arena.deinit();
            std.heap.smp_allocator.destroy(job);
            _ = running.fetchSub(1, .acq_rel);
        }
    };
}

// ---- Arguments ----

const ArgError = error{
    MissingArgument,
    WrongType,
    OutOfRange,
    InvalidArgument,
    OutOfMemory,
};

fn isString(comptime P: type) bool {
    return P == []const u8 or P == []u8;
}

fn isExactInt(comptime P: type) bool {
    const info = @typeInfo(P).int;
    return if (info.signedness == .unsigned) info.bits <= 53 else info.bits <= 54;
}

fn decodeArg(comptime P: type, call: Call, index: usize, argc: usize, arena: std.mem.Allocator, copy: bool) ArgError!P {
    if (index >= argc) {
        if (@typeInfo(P) == .optional) return null;
        return error.MissingArgument;
    }
    const kind = zg.zg_call_arg_type(call, index);
    if (comptime isString(P)) {
        if (kind != zg.ZG_TYPE_STRING) return error.WrongType;
        var length: usize = 0;
        const text = zg.zg_call_arg_string(call, index, &length) orelse return error.WrongType;
        if (copy or P == []u8) return try arena.dupe(u8, text[0..length]);
        return text[0..length];
    }
    switch (@typeInfo(P)) {
        .bool => {
            if (kind != zg.ZG_TYPE_BOOLEAN) return error.WrongType;
            return zg.zg_call_arg_bool(call, index) != 0;
        },
        .int => {
            if (comptime isExactInt(P)) {
                if (kind != zg.ZG_TYPE_NUMBER) return error.WrongType;
                const number = zg.zg_call_arg_number(call, index);
                if (@trunc(number) != number or @abs(number) > 9007199254740992) return error.OutOfRange;
                return std.math.cast(P, @as(i64, @intFromFloat(number))) orelse error.OutOfRange;
            }
            if (kind != zg.ZG_TYPE_BIGINT and kind != zg.ZG_TYPE_NUMBER) return error.WrongType;
            return std.math.cast(P, zg.zg_call_arg_int64(call, index)) orelse error.OutOfRange;
        },
        .float => {
            if (kind != zg.ZG_TYPE_NUMBER) return error.WrongType;
            return @floatCast(zg.zg_call_arg_number(call, index));
        },
        else => {
            var length: usize = 0;
            const json = zg.zg_call_arg_json(call, index, &length) orelse return error.WrongType;
            return codec.decode(P, arena, json[0..length]) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidArgument => error.InvalidArgument,
            };
        },
    }
}

fn argErrorMessage(buffer: []u8, comptime full_name: []const u8, err: ArgError) [*:0]const u8 {
    const detail = switch (err) {
        error.MissingArgument => "an argument is missing",
        error.WrongType => "an argument has the wrong type",
        error.OutOfRange => "a number is out of range or not whole",
        error.InvalidArgument => "an argument does not match its type",
        error.OutOfMemory => "out of memory",
    };
    const code = if (err == error.OutOfMemory) "OutOfMemory" else "InvalidArgument";
    return format(buffer, "plume:{s}: {s}: {s}", .{ code, full_name, detail }, "plume:InvalidArgument");
}

/// A NUL-terminated message in `buffer`, or `fallback` if it does not fit.
fn format(buffer: []u8, comptime fmt: []const u8, args: anytype, comptime fallback: [:0]const u8) [*:0]const u8 {
    const text: [:0]const u8 = std.mem.printSentinel(buffer, fmt, args, 0) catch fallback;
    return text.ptr;
}

fn throwArgError(call: Call, comptime full_name: []const u8, err: ArgError) Value {
    var buffer: [256]u8 = undefined;
    return zg.zg_call_throw(call, argErrorMessage(&buffer, full_name, err));
}

fn throwError(call: Call, err: anyerror) Value {
    var buffer: [128]u8 = undefined;
    return zg.zg_call_throw(call, format(&buffer, "plume:{s}", .{@errorName(err)}, "plume:Error"));
}

// ---- Results ----

fn encodeResult(call: Call, arena: std.mem.Allocator, result: anytype) Value {
    const X = @TypeOf(result);
    if (comptime isString(X))
        return zg.zg_value_string_len(call, result.ptr, result.len);
    switch (@typeInfo(X)) {
        .void => return null,
        .bool => return zg.zg_value_bool(call, @intFromBool(result)),
        .int => {
            if (comptime isExactInt(X))
                return zg.zg_value_number(call, @floatFromInt(result));
            if (std.math.cast(i64, result)) |wide|
                return zg.zg_value_int64(call, wide);
            return zg.zg_value_number(call, @floatFromInt(result));
        },
        .comptime_int => return zg.zg_value_number(call, @floatFromInt(result)),
        .float => return zg.zg_value_number(call, @floatCast(result)),
        .optional => if (result) |payload| return encodeResult(call, arena, payload) else return zg.zg_value_null(call),
        .pointer => |info| if (info.size == .one and @typeInfo(info.child) == .array and @typeInfo(info.child).array.child == u8) {
            // A string literal.
            const text: []const u8 = result;
            return zg.zg_value_string_len(call, text.ptr, text.len);
        },
        else => {},
    }
    const json = codec.encode(arena, result) catch return zg.zg_call_throw(call, "plume:OutOfMemory");
    return zg.zg_value_json(call, json.ptr, json.len);
}
