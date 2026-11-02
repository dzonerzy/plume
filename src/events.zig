//! Events between Zig and the pages, both ways, and work handed to the
//! runtime thread.
//!
//! Zig → pages: emit(name, value) from any thread, to every window or to one.
//! On the runtime thread the event goes to the pages at once (zg_view_emit,
//! the "plume:event" the page runtime listens to); from another thread it is
//! posted to the runtime thread (zg_runtime_post), in order.
//!
//! Page → Zig: Plume.emit(name, data) in any window calls __plume.emit, which
//! runs the handlers registered with on() on the runtime thread, the data
//! decoded into their type (codec.zig).

const std = @import("std");
const zg = @import("zerog");
const codec = @import("codec.zig");

pub const Error = error{ BindFailed, OutOfMemory };

pub const Bus = struct {
    runtime: *zg.zg_runtime,
    runtime_thread: std.Thread.Id,
    /// The windows' views. Runtime thread.
    views: std.ArrayList(*zg.zg_view) = .empty,
    /// Runtime thread.
    handlers: std.ArrayList(Handler) = .empty,

    const allocator = std.heap.smp_allocator;

    const Handler = struct {
        name: []const u8,
        context: ?*anyopaque,
        function: *const fn (?*anyopaque, std.mem.Allocator, []const u8) void,
    };

    /// On the runtime thread.
    pub fn create(runtime: *zg.zg_runtime) Error!*Bus {
        const bus = try allocator.create(Bus);
        bus.* = .{ .runtime = runtime, .runtime_thread = std.Thread.getCurrentId() };
        return bus;
    }

    pub fn destroy(bus: *Bus) void {
        for (bus.handlers.items) |handler| allocator.free(handler.name);
        bus.handlers.deinit(allocator);
        bus.views.deinit(allocator);
        allocator.destroy(bus);
    }

    /// A window's view: its pages get the page runtime and __plume.emit.
    pub fn attach(bus: *Bus, view: *zg.zg_view, runtime_script: []const u8) Error!void {
        if (zg.zg_view_bind(view, "__plume.emit", emitBinding, bus) != zg.ZG_OK) return error.BindFailed;
        if (zg.zg_view_add_script(view, runtime_script.ptr, runtime_script.len) != zg.ZG_OK) return error.BindFailed;
        try bus.views.append(allocator, view);
    }

    /// Before the view goes.
    pub fn detach(bus: *Bus, view: *zg.zg_view) void {
        for (bus.views.items, 0..) |item, i| {
            if (item == view) {
                _ = bus.views.swapRemove(i);
                return;
            }
        }
    }

    // ---- Zig → pages ----

    /// To every window's Plume.on listeners. Any thread.
    pub fn emit(bus: *Bus, name: []const u8, value: anytype) void {
        bus.emitTo(null, name, value);
    }

    /// To one window's (null: every window's). Any thread; an event its page
    /// does not listen to is lost.
    pub fn emitTo(bus: *Bus, view: ?*zg.zg_view, name: []const u8, value: anytype) void {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const data = codec.encode(arena.allocator(), value) catch return logDropped(name);
        bus.emitJson(view, name, data);
    }

    /// emitTo() with the data already as JSON.
    pub fn emitJson(bus: *Bus, view: ?*zg.zg_view, name: []const u8, data: []const u8) void {
        const quoted = codec.encode(allocator, name) catch return logDropped(name);
        defer allocator.free(quoted);
        const message = std.mem.concat(allocator, u8, &.{ "{\"name\":", quoted, ",\"data\":", data, "}" }) catch return logDropped(name);
        if (std.Thread.getCurrentId() == bus.runtime_thread) {
            defer allocator.free(message);
            bus.deliver(view, message);
            return;
        }
        // Owned by the task until it runs.
        const task = allocator.create(Delivery) catch {
            allocator.free(message);
            return logDropped(name);
        };
        task.* = .{ .bus = bus, .view = view, .message = message };
        if (zg.zg_runtime_post(bus.runtime, Delivery.run, task) != zg.ZG_OK) {
            allocator.free(message);
            allocator.destroy(task);
            logDropped(name);
        }
    }

    const Delivery = struct {
        bus: *Bus,
        view: ?*zg.zg_view,
        message: []u8,

        fn run(user: ?*anyopaque) callconv(.c) void {
            const task: *Delivery = @ptrCast(@alignCast(user.?));
            defer {
                allocator.free(task.message);
                allocator.destroy(task);
            }
            task.bus.deliver(task.view, task.message);
        }
    };

    fn deliver(bus: *Bus, view: ?*zg.zg_view, message: []const u8) void {
        for (bus.views.items) |item| {
            // A window closed since: not there any more.
            if (view != null and view != item) continue;
            _ = zg.zg_view_emit(item, "plume:event", message.ptr, message.len);
        }
    }

    /// Runs `function(context)` on the runtime thread: at once when called
    /// there, else soon (zg_runtime_post), in order with the events.
    pub fn dispatch(bus: *Bus, context: anytype, comptime function: anytype) error{OutOfMemory}!void {
        const C = @TypeOf(context);
        if (std.Thread.getCurrentId() == bus.runtime_thread) {
            function(context);
            return;
        }
        const Task = struct {
            context: C,

            fn run(user: ?*anyopaque) callconv(.c) void {
                const task: *@This() = @ptrCast(@alignCast(user.?));
                const value = task.context;
                allocator.destroy(task);
                function(value);
            }
        };
        const task = try allocator.create(Task);
        task.* = .{ .context = context };
        if (zg.zg_runtime_post(bus.runtime, Task.run, task) != zg.ZG_OK) {
            allocator.destroy(task);
            return error.OutOfMemory;
        }
    }

    // ---- Page → Zig ----

    /// Calls `handler(context, data)` on the runtime thread for each
    /// Plume.emit(name, data) of a page, `data` decoded into `T` (valid
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

        /// To every window. Any thread.
        pub fn emit(self: @This(), comptime name: Name, value: @FieldType(E, @tagName(name))) void {
            self.bus.emit(@tagName(name), value);
        }

        pub fn on(self: @This(), comptime name: Name, context: anytype, comptime handler: anytype) error{OutOfMemory}!void {
            try self.bus.on(@tagName(name), @FieldType(E, @tagName(name)), context, handler);
        }
    };
}

pub fn toOpaque(context: anytype) ?*anyopaque {
    const C = @TypeOf(context);
    return switch (@typeInfo(C)) {
        .null => null,
        .optional => if (context) |pointer| @ptrCast(@constCast(pointer)) else null,
        .pointer => @ptrCast(@constCast(context)),
        else => @compileError("a handler's context is a pointer (or null), not " ++ @typeName(C)),
    };
}

pub fn fromOpaque(comptime C: type, pointer: ?*anyopaque) C {
    return switch (@typeInfo(C)) {
        .null => null,
        .optional => @ptrCast(@alignCast(pointer)),
        else => @ptrCast(@alignCast(pointer.?)),
    };
}

fn logDropped(name: []const u8) void {
    std.log.err("plume: out of memory: the event {s} was dropped", .{name});
}
