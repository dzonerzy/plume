//! Events between Zig and the page, both ways, and work handed to the runtime
//! thread.
//!
//! Zig → page: emit(name, value) from any thread. On the runtime thread the
//! event is dispatched at once (zg_view_emit). From another thread it is
//! queued and handed over through the pump: the page runtime (runtime.js)
//! keeps a call to __plume.pump() pending, a Promise the engine lets any
//! thread settle; it resolves with the queued events, which the runtime
//! dispatches, then calls __plume.drain() for the work queued by dispatch(),
//! which runs there, on the runtime thread.
//!
//! Page → Zig: Plume.emit(name, data) calls __plume.emit, which runs the
//! handlers registered with on() on the runtime thread, the data decoded into
//! their type (codec.zig).

const std = @import("std");
const zg = @import("zerog");
const codec = @import("codec.zig");

pub const Error = error{ BindFailed, OutOfMemory };

pub const Bus = struct {
    view: *zg.zg_view,
    runtime_thread: std.Thread.Id,
    lock: SpinLock = .{},
    /// Queued events, as the items of a JSON array.
    queued: std.ArrayList(u8) = .empty,
    tasks: std.ArrayList(Task) = .empty,
    /// The page runtime's pending __plume.pump() call.
    pump: ?*zg.zg_promise = null,
    /// Runtime thread only.
    handlers: std.ArrayList(Handler) = .empty,

    const allocator = std.heap.smp_allocator;

    const Task = struct {
        function: *const fn (?*anyopaque) void,
        context: ?*anyopaque,
    };

    const Handler = struct {
        name: []const u8,
        context: ?*anyopaque,
        function: *const fn (?*anyopaque, std.mem.Allocator, []const u8) void,
    };

    /// The bus of `view`, whose bindings (__plume.*) and page runtime it
    /// installs. On the runtime thread, before the page loads.
    pub fn create(view: *zg.zg_view, runtime_script: []const u8) Error!*Bus {
        const bus = try allocator.create(Bus);
        errdefer allocator.destroy(bus);
        bus.* = .{ .view = view, .runtime_thread = std.Thread.getCurrentId() };
        inline for (.{ .{ "__plume.pump", pumpBinding }, .{ "__plume.drain", drainBinding }, .{ "__plume.emit", emitBinding } }) |binding| {
            if (zg.zg_view_bind(view, binding[0], binding[1], bus) != zg.ZG_OK) return error.BindFailed;
        }
        if (zg.zg_view_add_script(view, runtime_script.ptr, runtime_script.len) != zg.ZG_OK) return error.BindFailed;
        return bus;
    }

    /// After the runtime is destroyed; nothing may emit or dispatch any more.
    pub fn destroy(bus: *Bus) void {
        for (bus.handlers.items) |handler| allocator.free(handler.name);
        bus.handlers.deinit(allocator);
        bus.queued.deinit(allocator);
        bus.tasks.deinit(allocator);
        allocator.destroy(bus);
    }

    /// Settles the pending pump call, if any (before the runtime is destroyed:
    /// a pending promise keeps its page alive).
    pub fn close(bus: *Bus) void {
        bus.lock.lock();
        defer bus.lock.unlock();
        if (bus.pump) |promise| zg.zg_promise_resolve(promise, "null", 4);
        bus.pump = null;
    }

    // ---- Zig → page ----

    /// Dispatches `name` with `value` (as JSON) to the page's Plume.on
    /// listeners. Any thread; an event the page does not listen to is lost.
    pub fn emit(bus: *Bus, name: []const u8, value: anytype) void {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const data = codec.encode(arena.allocator(), value) catch return logDropped(name);
        bus.emitJson(name, data);
    }

    /// emit() with the data already as JSON.
    pub fn emitJson(bus: *Bus, name: []const u8, data: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const quoted = codec.encode(arena.allocator(), name) catch return logDropped(name);
        const message = std.mem.concat(arena.allocator(), u8, &.{ "{\"name\":", quoted, ",\"data\":", data, "}" }) catch
            return logDropped(name);

        if (std.Thread.getCurrentId() == bus.runtime_thread) {
            _ = zg.zg_view_emit(bus.view, "plume:event", message.ptr, message.len);
            return;
        }
        bus.lock.lock();
        defer bus.lock.unlock();
        if (bus.queued.items.len > 0) bus.queued.append(allocator, ',') catch return logDropped(name);
        bus.queued.appendSlice(allocator, message) catch return logDropped(name);
        bus.settle();
    }

    /// Runs `function(context)` on the runtime thread: at once when called
    /// there, else as soon as the page runtime is running (the work waits
    /// while a page loads).
    pub fn dispatch(bus: *Bus, context: anytype, comptime function: anytype) error{OutOfMemory}!void {
        const C = @TypeOf(context);
        if (std.Thread.getCurrentId() == bus.runtime_thread) {
            function(context);
            return;
        }
        const Thunk = struct {
            fn run(opaque_context: ?*anyopaque) void {
                function(fromOpaque(C, opaque_context));
            }
        };
        bus.lock.lock();
        defer bus.lock.unlock();
        try bus.tasks.append(allocator, .{ .function = Thunk.run, .context = toOpaque(context) });
        bus.settle();
    }

    /// With the lock held: hands what is queued to the pending pump call.
    fn settle(bus: *Bus) void {
        const promise = bus.pump orelse return;
        if (bus.queued.items.len == 0 and bus.tasks.items.len == 0) return;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const batch = std.mem.concat(arena.allocator(), u8, &.{
            "{\"events\":[", bus.queued.items, "],\"tasks\":", if (bus.tasks.items.len > 0) "true" else "false", "}",
        }) catch return; // stays queued for the next pump
        zg.zg_promise_resolve(promise, batch.ptr, batch.len);
        bus.pump = null;
        bus.queued.clearRetainingCapacity();
    }

    // ---- Page → Zig ----

    /// Calls `handler(context, data)` on the runtime thread for each
    /// Plume.emit(name, data) of the page, `data` decoded into `T` (valid
    /// during the call). `context` is a pointer (or null); the handler may
    /// return an error, which is logged. Data that does not match `T` is
    /// logged and dropped.
    pub fn on(bus: *Bus, name: []const u8, comptime T: type, context: anytype, comptime handler: anytype) error{OutOfMemory}!void {
        const C = @TypeOf(context);
        const Thunk = struct {
            fn call(opaque_context: ?*anyopaque, arena: std.mem.Allocator, json: []const u8) void {
                const data = codec.decode(T, arena, json) catch {
                    std.log.warn("plume: an event's data does not match {s}: {s}", .{ @typeName(T), json });
                    return;
                };
                const result = handler(fromOpaque(C, opaque_context), data);
                if (@typeInfo(@TypeOf(result)) == .error_union) {
                    _ = result catch |err| std.log.err("plume: an event handler failed: {s}", .{@errorName(err)});
                }
            }
        };
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try bus.handlers.append(allocator, .{ .name = owned, .context = toOpaque(context), .function = Thunk.call });
    }

    /// Removes every handler of `name`.
    pub fn off(bus: *Bus, name: []const u8) void {
        var i: usize = 0;
        while (i < bus.handlers.items.len) {
            if (std.mem.eql(u8, bus.handlers.items[i].name, name)) {
                allocator.free(bus.handlers.items[i].name);
                _ = bus.handlers.orderedRemove(i);
            } else i += 1;
        }
    }

    // ---- The page runtime's bindings ----

    fn pumpBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const bus: *Bus = @ptrCast(@alignCast(user.?));
        var promise: ?*zg.zg_promise = null;
        const value = zg.zg_call_promise(call, &promise);
        bus.lock.lock();
        defer bus.lock.unlock();
        // A previous page's call, still pending: ended.
        if (bus.pump) |previous| zg.zg_promise_resolve(previous, "null", 4);
        bus.pump = promise;
        bus.settle();
        return value;
    }

    fn drainBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        _ = call;
        const bus: *Bus = @ptrCast(@alignCast(user.?));
        bus.lock.lock();
        var tasks = bus.tasks;
        bus.tasks = .empty;
        bus.lock.unlock();
        defer tasks.deinit(allocator);
        for (tasks.items) |task| task.function(task.context);
        return null;
    }

    fn emitBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const bus: *Bus = @ptrCast(@alignCast(user.?));
        var name_len: usize = 0;
        var json_len: usize = 0;
        const name = zg.zg_call_arg_string(call, 0, &name_len) orelse return null;
        const json = zg.zg_call_arg_string(call, 1, &json_len) orelse return null;
        // A handler may add or remove handlers: by index, over a snapshot of the count.
        const count = bus.handlers.items.len;
        var i: usize = 0;
        while (i < @min(count, bus.handlers.items.len)) : (i += 1) {
            const handler = bus.handlers.items[i];
            if (!std.mem.eql(u8, handler.name, name[0..name_len])) continue;
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            handler.function(handler.context, arena.allocator(), json[0..json_len]);
        }
        return null;
    }
};

/// Typed events: the fields of `E` are the event names, their types the data.
/// The same declaration (`pub const Events = struct { ... }` in the binding
/// type) gives bindings.ts its typed Events.on and Events.emit.
pub fn Events(comptime E: type) type {
    return struct {
        bus: *Bus,

        pub const Name = std.meta.FieldEnum(E);

        pub fn emit(self: @This(), comptime name: Name, value: @FieldType(E, @tagName(name))) void {
            self.bus.emit(@tagName(name), value);
        }

        pub fn on(self: @This(), comptime name: Name, context: anytype, comptime handler: anytype) error{OutOfMemory}!void {
            try self.bus.on(@tagName(name), @FieldType(E, @tagName(name)), context, handler);
        }
    };
}

fn toOpaque(context: anytype) ?*anyopaque {
    const C = @TypeOf(context);
    return switch (@typeInfo(C)) {
        .null => null,
        .optional => if (context) |pointer| @ptrCast(@constCast(pointer)) else null,
        .pointer => @ptrCast(@constCast(context)),
        else => @compileError("an event or dispatch context is a pointer (or null), not " ++ @typeName(C)),
    };
}

fn fromOpaque(comptime C: type, pointer: ?*anyopaque) C {
    return switch (@typeInfo(C)) {
        .null => null,
        .optional => @ptrCast(@alignCast(pointer)),
        else => @ptrCast(@alignCast(pointer.?)),
    };
}

fn logDropped(name: []const u8) void {
    std.log.err("plume: out of memory: the event {s} was dropped", .{name});
}

/// The queue's lock: held for a few appends, from a handful of threads.
const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};
