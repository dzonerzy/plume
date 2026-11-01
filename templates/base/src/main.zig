const std = @import("std");
const plume = @import("plume");
const App = @import("app.zig").App;

pub fn main() !void {
    // The window of plume.json, showing the frontend (built into the binary,
    // or Vite's dev server under plume dev).
    var window = try plume.App.initProject(@import("plume_project"));
    defer window.deinit();

    // App's pub fns, callable from the frontend (frontend/src/bindings.ts).
    var app: App = .{};
    try window.bind("App", App, &app);

    window.run();
}
