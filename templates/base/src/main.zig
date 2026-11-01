const std = @import("std");
const plume = @import("plume");
const App = @import("app.zig").App;

pub fn main(init: std.process.Init) !void {
    // The window of plume.json, showing the frontend (built into the binary,
    // or Vite's dev server under plume dev).
    var window = try plume.App.initProject(@import("plume_project"), init);
    defer window.deinit();

    // App's pub fns, callable from the frontend (frontend/src/bindings.ts),
    // and its events, which any thread can send.
    var app: App = .{ .events = window.events(App.Events) };
    try window.bind("App", App, &app);

    window.run();
}
