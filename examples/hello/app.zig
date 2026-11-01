//! What the hello example's page can call: every kind of binding.

const std = @import("std");

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

pub const App = struct {
    /// These run on a worker thread and return a Promise.
    pub const async_methods = .{"slowSquare"};

    greetings: u32 = 0,

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
        var words = std.mem.tokenizeScalar(u8, value, ' ');
        return words.next();
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
