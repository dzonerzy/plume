//! A window whose page calls Zig: the App type of app.zig, bound with
//! bindings generated at compile time, and the frontend of web/ packed into
//! the binary at build time. The page tries every kind of binding and shows
//! what came back; `hello --smoke` quits once it has, with a failure status if
//! anything was wrong (a test of the build).

const std = @import("std");
const plume = @import("plume");
const app = @import("app.zig");

/// The page reports its checks here.
const Smoke = struct {
    plume_app: *plume.App,
    enabled: bool,
    passed: ?bool = null,

    pub fn report(self: *Smoke, passed: bool, summary: []const u8) void {
        std.debug.print("{s}\n", .{summary});
        self.passed = passed;
        if (self.enabled)
            self.plume_app.quit();
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var smoke_mode = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke"))
            smoke_mode = true;
    }

    var window = try plume.App.init(.{
        .title = "Hello, Plume",
        .width = 760,
        .height = 640,
        .assets = @embedFile("frontend"),
    });
    defer window.deinit();

    var instance: app.App = .{ .plume_app = &window };
    var smoke: Smoke = .{ .plume_app = &window, .enabled = smoke_mode };
    try window.bind("App", app.App, &instance);
    try window.events(app.App.Events).on(.ping, &instance, app.App.onPing);
    try window.bind("Smoke", Smoke, &smoke);
    window.run();

    if (smoke_mode and smoke.passed != true)
        return error.SmokeFailed;
}
