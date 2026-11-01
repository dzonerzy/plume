//! What the hello example's page can call: every kind of binding, events both
//! ways, and the page's objects from Zig.

const std = @import("std");
const plume = @import("plume");

pub const Mood = enum { happy, curious, tired };

pub const Person = struct {
    name: []const u8,
    age: u32,
    mood: Mood = .curious,
    tags: []const []const u8 = &.{},
};

pub const Greeting = struct {
    text: []const u8,
    letters: usize,
    shout: bool,
};

pub const Shape = union(enum) {
    circle: f64,
    rectangle: struct { width: f64, height: f64 },
    point,
};

pub const Ping = struct { text: []const u8, times: u32 };
pub const Pong = struct { text: []const u8 };

pub const App = struct {
    /// These run on a worker thread and return a Promise.
    pub const async_methods = .{ "slowSquare", "countdown", "stampLater", "burst" };
    /// Not bindings: main.zig registers it for the page's "ping" events.
    pub const hidden = .{"onPing"};

    /// The events Zig and the page exchange; bindings.ts types them.
    pub const Events = struct {
        ping: Ping,
        pong: Pong,
        tick: u32,
        done: void,
        stamped: []const u8,
        burst: Burst,
    };

    pub const Burst = struct { thread: u32, index: u32 };

    greetings: u32 = 0,
    /// Set by main.zig: events and the runtime thread, from any thread.
    plume_app: ?*plume.App = null,

    fn events(self: *App) plume.Events(Events) {
        return self.plume_app.?.events(Events);
    }

    /// The page's Plume.emit("ping", ...), on the runtime thread: answered
    /// with a "pong".
    pub fn onPing(self: *App, ping: Ping) void {
        var buffer: [256]u8 = undefined;
        var text: std.ArrayList(u8) = .initBuffer(&buffer);
        for (0..ping.times) |_| text.appendSliceBounded(ping.text) catch break;
        self.events().emit(.pong, .{ .text = text.items });
    }

    /// From a worker thread: "tick" events counting down, then "done".
    pub fn countdown(self: *App, from: u32) u32 {
        var i = from;
        while (i > 0) : (i -= 1) self.events().emit(.tick, i);
        self.events().emit(.done, {});
        return from;
    }

    /// `threads` threads emitting `each` "burst" events, at once.
    pub fn burst(self: *App, threads: u32, each: u32) !u32 {
        const Emitter = struct {
            fn run(app: *App, thread: u32, n: u32) void {
                for (0..n) |index| app.events().emit(.burst, .{ .thread = thread, .index = @intCast(index) });
            }
        };
        var spawned: [16]std.Thread = undefined;
        const total = @min(threads, spawned.len);
        for (spawned[0..total], 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, Emitter.run, .{ self, @as(u32, @intCast(i)), each });
        for (spawned[0..total]) |thread| thread.join();
        return total * each;
    }

    /// From a worker thread: work handed to the runtime thread, which writes
    /// into the page and says so with a "stamped" event.
    pub fn stampLater(self: *App, text: []const u8) !void {
        const Stamp = struct {
            app: *App,
            text: []u8,

            fn run(stamp: *@This()) void {
                defer {
                    std.heap.smp_allocator.free(stamp.text);
                    std.heap.smp_allocator.destroy(stamp);
                }
                const page = stamp.app.plume_app.?.page() catch return;
                defer page.close();
                const element = page.byId("stamp") catch return;
                element.set("textContent", stamp.text) catch return;
                stamp.app.events().emit(.stamped, stamp.text);
            }
        };
        // The call's arguments are freed when it returns: the task owns a copy.
        const stamp = try std.heap.smp_allocator.create(Stamp);
        stamp.* = .{ .app = self, .text = try std.heap.smp_allocator.dupe(u8, text) };
        try self.plume_app.?.dispatch(stamp, Stamp.run);
    }

    /// The calling page's objects: plume.Page is not passed from JavaScript.
    pub fn setText(self: *App, page: plume.Page, id: []const u8, text: []const u8) !void {
        _ = self;
        const element = try page.byId(id);
        try element.set("textContent", text);
    }

    pub fn pageTitle(self: *App, page: plume.Page) ![]const u8 {
        _ = self;
        return (try page.document()).getString("title");
    }

    /// Calls a page function with arguments and reads what it returned.
    pub fn words(self: *App, page: plume.Page, text: []const u8) !struct { count: u32, words: []const []const u8 } {
        _ = self;
        const window = try page.window();
        const list = try window.call("String.prototype.split.call", .{ text, " " });
        return .{
            .count = @intFromFloat(try list.getNumber("length")),
            .words = try list.as([]const []const u8),
        };
    }

    /// A string in, a string out: App.greet("Plume").
    pub fn greet(self: *App, allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        self.greetings += 1;
        return std.fmt.allocPrint(allocator, "Hello, {s}, from Zig", .{name});
    }

    pub fn add(self: *App, a: i32, b: i32) i32 {
        _ = self;
        return a + b;
    }

    /// Structs, enums and slices both ways, as objects, strings and arrays.
    pub fn describe(self: *App, allocator: std.mem.Allocator, person: Person) !Greeting {
        _ = self;
        const text = try std.fmt.allocPrint(allocator, "{s} ({d}) is {s}, {d} tags", .{ person.name, person.age, @tagName(person.mood), person.tags.len });
        return .{ .text = text, .letters = person.name.len, .shout = person.mood == .happy };
    }

    /// A tagged union in: { tag: "circle", value: 2 }.
    pub fn area(self: *App, shape: Shape) f64 {
        _ = self;
        return switch (shape) {
            .circle => |radius| std.math.pi * radius * radius,
            .rectangle => |r| r.width * r.height,
            .point => 0,
        };
    }

    /// Optionals: null in, null out.
    pub fn firstWord(self: *App, text: ?[]const u8) ?[]const u8 {
        _ = self;
        const value = text orelse return null;
        var tokens = std.mem.tokenizeScalar(u8, value, ' ');
        return tokens.next();
    }

    /// Integers past 2^53 are BigInts.
    pub fn double(self: *App, value: i64) i64 {
        _ = self;
        return value * 2;
    }

    /// Errors become exceptions with the error's name as their code.
    pub fn divide(self: *App, a: f64, b: f64) error{DivisionByZero}!f64 {
        _ = self;
        if (b == 0) return error.DivisionByZero;
        return a / b;
    }

    /// On a worker thread: App.slowSquare(9) is a Promise of 81.
    pub fn slowSquare(self: *App, value: u32) error{TooBig}!u64 {
        _ = self;
        if (value > 1_000_000) return error.TooBig;
        return @as(u64, value) * value;
    }

    pub fn count(self: *App) u32 {
        return self.greetings;
    }
};
