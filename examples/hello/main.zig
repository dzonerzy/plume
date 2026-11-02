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
    tray: bool = false,
    external: [128]u8 = undefined,
    external_len: usize = 0,

    pub fn report(self: *Smoke, passed: bool, summary: []const u8) void {
        std.debug.print("{s}\n", .{summary});
        self.passed = passed;
        if (self.enabled)
            self.plume_app.quit();
    }

    /// Chooses a menu bar item as the system would (Windows: WM_COMMAND).
    pub fn chooseMenu(self: *Smoke, id: []const u8) !void {
        if (builtin.os.tag != .windows) return error.Unsupported;
        const number = try self.plume_app.window().menus.number(id);
        _ = PostMessageW(self.plume_app.window().nativeHandle(), 0x0111, number, 0); // WM_COMMAND
    }

    /// From the second window's page: every window hears how many there are.
    pub fn childReady(self: *Smoke) void {
        self.plume_app.emit("child-ready", self.plume_app.windows.items.len);
    }

    pub fn windowCount(self: *Smoke) usize {
        return self.plume_app.windows.items.len;
    }

    /// What Zig's handlers saw.
    pub fn seen(self: *Smoke) struct { menu_choices: u32, last_menu: []const u8, resizes: u32, close_requests: u32, external: []const u8 } {
        return .{ .menu_choices = self.menu_choices, .last_menu = self.last_menu[0..self.last_menu_len], .resizes = self.resizes, .close_requests = self.close_requests, .external = self.external[0..self.external_len] };
    }

    /// Windows: chooses the first item of the next popup menu (Down, Enter).
    pub fn chooseFirstPopupItem(self: *Smoke) !void {
        _ = self;
        if (builtin.os.tag != .windows) return error.Unsupported;
        (try std.Thread.spawn(.{}, choosePopup, .{})).detach();
    }

    fn choosePopup() void {
        const menu_class = std.unicode.utf8ToUtf16LeStringLiteral("#32768");
        for (0..100) |_| {
            if (FindWindowW(menu_class, null)) |popup| {
                std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(100), .awake) catch {};
                _ = PostMessageW(popup, 0x0100, 0x28, 0); // WM_KEYDOWN, VK_DOWN
                _ = PostMessageW(popup, 0x0100, 0x0D, 0); // WM_KEYDOWN, VK_RETURN
                return;
            }
            std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(50), .awake) catch {};
        }
    }

    /// Links to other sites: Zig takes them (app.onExternalLink).
    fn onExternalLink(self: *Smoke, url: []const u8) bool {
        self.external_len = @min(url.len, self.external.len);
        @memcpy(self.external[0..self.external_len], url[0..self.external_len]);
        return true;
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
extern "user32" fn FindWindowW(class: ?[*:0]const u16, title: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;

const menu = plume.menu;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var smoke_mode = false;
    var single_test = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) smoke_mode = true;
        if (std.mem.eql(u8, arg, "--single-test")) single_test = true;
    }

    const window = try plume.App.init(.{
        .title = "Hello, Plume",
        .name = "hello",
        .width = 760,
        .height = 640,
        .assets = @embedFile("frontend"),
        .io = init.io,
        .args = args,
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
        window.onSecondInstance(window, Second.launched);
        std.debug.print("first instance: waiting\n", .{});
        window.run();
        return;
    }

    var instance: app.App = .{ .plume_app = window };
    var smoke: Smoke = .{ .plume_app = window, .enabled = smoke_mode };
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
    try window.setContextMenu("row", &.{ menu.item("edit", "&Edit", null), menu.item("delete", "&Delete", null) });

    // A tray icon (a plain square: hello has no icon of its own), where the
    // desktop has a tray.
    var pixels: [16 * 16 * 4]u8 = undefined;
    for (0..16 * 16) |i| @memcpy(pixels[i * 4 ..][0..4], &[4]u8{ 0x3d, 0x7b, 0xe0, 0xff });
    const tray = window.createTray(.{
        .tooltip = "Hello, Plume",
        .icon = .{ .rgba = &pixels, .width = 16, .height = 16 },
        .menu = &.{ menu.checkbox("dark", "&Dark mode", false), menu.separator, menu.item("quit", "E&xit", null) },
    }) catch |err| blk: {
        std.debug.print("no tray: {s}\n", .{@errorName(err)});
        break :blk null;
    };
    if (tray) |t| {
        try t.setTooltip("Hello, Plume (tray)");
        try t.setMenuEnabled("quit", true);
        t.attachWindow(window.window());
    }
    smoke.tray = tray != null;

    // The rest of the desktop API, analysed by the compiler (the page checks
    // what a smoke run can without notifications popping up).
    inline for (.{ plume.App.notify, plume.App.removeNotification, plume.App.onNotification, plume.App.registerShortcut, plume.App.unregisterShortcut, plume.App.onShortcut, plume.App.openURL, plume.App.openPath, plume.App.onExternalLink, plume.App.startsAtLogin, plume.App.setStartAtLogin, plume.App.onContextMenu, plume.App.destroyTray, plume.App.appOp, plume.Tray.setIcon, plume.Tray.onActivated }) |function| _ = &function;
    try window.onMenu(&smoke, Smoke.onMenu);
    try window.onWindow(&smoke, Smoke.onWindow);
    window.onClose(&smoke, Smoke.onClose);
    window.onExternalLink(&smoke, Smoke.onExternalLink);
    window.run();

    if (smoke_mode and smoke.passed != true)
        return error.SmokeFailed;
}
