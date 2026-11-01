//! What the frontend can call. Every pub fn taking the App is a binding:
//! frontend/src/bindings.ts gets its exact TypeScript type at every build.

const std = @import("std");

pub const App = struct {
    /// Methods that run on a worker thread and return a Promise.
    pub const async_methods = .{};

    greetings: u32 = 0,

    /// An Allocator parameter gets the call's arena: nothing to free.
    pub fn greet(self: *App, allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        self.greetings += 1;
        return std.fmt.allocPrint(allocator, "Hello {s}, from Zig! (greeting #{d})", .{ name, self.greetings });
    }
};
