//! A window whose page calls Zig: the App type of app.zig, bound with
//! bindings generated at compile time, and the frontend of web/ packed into
//! the binary at build time. The page tries every kind of binding, events,
//! the window, dialogs, the clipboard and menus, and shows what came back;
//! `hello --smoke` quits once it has, with a failure status if anything was
//! wrong (a test of the build).
//!
//! `hello --single-test`: a single-instance run. A second `hello
//! --single-test x y` hands "x y" to the first, which prints it and quits.

const std = @import("std");
const builtin = @import("builtin");
const plume = @import("plume");
const app = @import("app.zig");

/// The page reports its checks here, and gets what only native code can do.
const Smoke = struct {
    plume_app: *plume.App,
    enabled: bool,
    passed: ?bool = null,
    menu_choices: u32 = 0,
    last_menu: [32]u8 = undefined,
    last_menu_len: usize = 0,
    resizes: u32 = 0,
    close_requests: u32 = 0,

    pub fn report(self: *Smoke, passed: bool, summary: []const u8) void {
        std.debug.print("{s}\n", .{summary});
        self.passed = passed;
        if (self.enabled)
            self.plume_app.quit();
    }

    /// Chooses a menu bar item as the system would (Windows: WM_COMMAND).
    pub fn chooseMenu(self: *Smoke, id: []const u8) !void {
        if (builtin.os.tag != .windows) return error.Unsupported;
        const number = try self.plume_app.shell.menus.number(id);
        _ = PostMessageW(self.plume_app.window().nativeHandle(), 0x0111, number, 0); // WM_COMMAND
    }

    /// What Zig's handlers saw.
    pub fn seen(self: *Smoke) struct { menu_choices: u32, last_menu: []const u8, resizes: u32, close_requests: u32 } {
        return .{ .menu_choices = self.menu_choices, .last_menu = self.last_menu[0..self.last_menu_len], .resizes = self.resizes, .close_requests = self.close_requests };
    }

    /// Windows: presses Enter in the next window titled `title` (a message box).
    pub fn pressEnterIn(self: *Smoke, title: []const u8) !void {
        _ = self;
        if (builtin.os.tag != .windows) return error.Unsupported;
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.smp_allocator, title);
        (try std.Thread.spawn(.{}, pressEnter, .{wide})).detach();
    }

    fn pressEnter(title: [:0]u16) void {
        defer std.heap.smp_allocator.free(title);
        for (0..100) |_| {
            if (FindWindowW(null, title.ptr)) |window| {
                _ = PostMessageW(window, 0x0100, 0x0D, 0); // WM_KEYDOWN, VK_RETURN
                return;
            }
            std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(50), .awake) catch {};
        }
    }

    fn onMenu(self: *Smoke, id: []const u8) void {
        self.menu_choices += 1;
        self.last_menu_len = @min(id.len, self.last_menu.len);
        @memcpy(self.last_menu[0..self.last_menu_len], id[0..self.last_menu_len]);
        if (std.mem.eql(u8, id, "dark")) self.plume_app.setMenuChecked("dark", true) catch {};
    }

    fn onWindow(self: *Smoke, event: plume.WindowEvent) void {
        if (event == .resized) self.resizes += 1;
    }

    /// Kept open the first time: the page checks that.
    fn onClose(self: *Smoke) bool {
        self.close_requests += 1;
        return self.close_requests > 1;
    }
};

extern "user32" fn PostMessageW(window: ?*anyopaque, message: u32, wparam: usize, lparam: isize) callconv(.winapi) i32;
extern "user32" fn FindWindowW(class: ?[*:0]const u16, title: [*:0]const u16) callconv(.winapi) ?*anyopaque;

const menu = plume.menu;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var smoke_mode = false;
    var single_test = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) smoke_mode = true;
        if (std.mem.eql(u8, arg, "--single-test")) single_test = true;
    }

    var window = try plume.App.init(.{
        .title = "Hello, Plume",
        .width = 760,
        .height = 640,
        .assets = @embedFile("frontend"),
        .io = init.io,
        .single_instance = if (single_test) .{ .id = "hello-single-test", .args = args } else null,
    });
    defer window.deinit();

    if (single_test) {
        const Second = struct {
            fn launched(plume_app: *plume.App, launch: plume.Launch) void {
                std.debug.print("second launch:", .{});
                for (launch.args[1..]) |arg| std.debug.print(" {s}", .{arg});
                std.debug.print("\n", .{});
                plume_app.quit();
            }
        };
        window.onSecondInstance(&window, Second.launched);
        std.debug.print("first instance: waiting\n", .{});
        window.run();
        return;
    }

    var instance: app.App = .{ .plume_app = &window };
    var smoke: Smoke = .{ .plume_app = &window, .enabled = smoke_mode };
    try window.bind("App", app.App, &instance);
    try window.bind("Smoke", Smoke, &smoke);
    try window.events(app.App.Events).on(.ping, &instance, app.App.onPing);

    try window.setMenu(&.{
        menu.submenu("&File", &.{
            menu.item("open", "&Open…", "Ctrl+O"),
            menu.separator,
            menu.item("quit", "E&xit", null),
        }),
        menu.submenu("&View", &.{
            menu.checkbox("dark", "&Dark mode", false),
            menu.submenu("&Zoom", &.{ menu.item("zoom-in", "Zoom &in", "Ctrl+="), menu.item("zoom-out", "Zoom &out", "Ctrl+-") }),
        }),
    });
    try window.onMenu(&smoke, Smoke.onMenu);
    try window.onWindow(&smoke, Smoke.onWindow);
    window.onClose(&smoke, Smoke.onClose);
    window.run();

    if (smoke_mode and smoke.passed != true)
        return error.SmokeFailed;
}
