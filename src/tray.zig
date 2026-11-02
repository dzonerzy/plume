//! A system tray icon (ZeroG's zg_tray: the notification area on Windows,
//! a StatusNotifierItem on Linux), with a menu defined as the window's
//! (plume.menu): chosen items go to the app's onMenu handlers and the
//! pages' "menu" event, clicks to onActivated and the pages' "tray:activated".
//! A window attached to it shows by the icon on a click, and hides on the
//! next. Runtime thread.

const std = @import("std");
const zg = @import("zerog");
const desktop = @import("desktop.zig");
const events = @import("events.zig");
const menu = @import("menu.zig");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;

pub const Options = struct {
    tooltip: ?[]const u8 = null,
    /// RGBA8, rows top to bottom; null: the application's icon.
    icon: ?Icon = null,
    menu: ?[]const menu.Item = null,
};

pub const Icon = struct { rgba: []const u8, width: u32, height: u32 };

pub const Error = error{ OutOfMemory, Unsupported, EngineFailed, TooManyItems, NoIcon };

pub const Tray = struct {
    app: *App,
    handle: *zg.zg_tray,
    menus: menu.Menus = .{},
    activated_handlers: std.ArrayList(Handler) = .empty,
    attached: ?*Window = null,

    const allocator = std.heap.smp_allocator;

    const Handler = struct { context: ?*anyopaque, function: *const fn (?*anyopaque, desktop.Position) void };

    pub fn create(app: *App, options: Options) Error!*Tray {
        const icon = options.icon orelse if (app.icon) |own| Icon{ .rgba = own.rgba, .width = own.width, .height = own.height } else return error.NoIcon;
        const tray = try allocator.create(Tray);
        errdefer allocator.destroy(tray);
        tray.* = .{ .app = app, .handle = undefined };
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        var config = std.mem.zeroes(zg.zg_tray_config);
        config.size = @sizeOf(zg.zg_tray_config);
        config.icon_rgba = icon.rgba.ptr;
        config.icon_width = icon.width;
        config.icon_height = icon.height;
        if (options.tooltip) |text| config.tooltip = (try arena.allocator().dupeSentinel(u8, text, 0)).ptr;
        config.id = (try arena.allocator().dupeSentinel(u8, app.id(), 0)).ptr;
        var callbacks = std.mem.zeroes(zg.zg_tray_callbacks);
        callbacks.size = @sizeOf(zg.zg_tray_callbacks);
        callbacks.user = tray;
        callbacks.activated = activated;
        callbacks.menu_item = menuItem;
        tray.handle = zg.zg_tray_create(app.runtime, &config, &callbacks) orelse {
            std.log.warn("plume: no tray: {s}", .{zg.zg_last_error()});
            return error.Unsupported;
        };
        errdefer zg.zg_tray_destroy(tray.handle);
        if (options.menu) |items| try tray.setMenu(items);
        return tray;
    }

    pub fn destroy(tray: *Tray) void {
        zg.zg_tray_destroy(tray.handle);
        tray.menus.deinit();
        tray.activated_handlers.deinit(allocator);
        allocator.destroy(tray);
    }

    pub fn setIcon(tray: *Tray, icon: Icon) Error!void {
        if (icon.rgba.len != @as(usize, icon.width) * icon.height * 4) return error.NoIcon;
        try check(zg.zg_tray_set_icon(tray.handle, icon.rgba.ptr, icon.width, icon.height));
    }

    pub fn setTooltip(tray: *Tray, tooltip: []const u8) Error!void {
        const text = try allocator.dupeSentinel(u8, tooltip, 0);
        defer allocator.free(text);
        try check(zg.zg_tray_set_tooltip(tray.handle, text.ptr));
    }

    /// Its menu (plume.menu items); null removes it.
    pub fn setMenu(tray: *Tray, items: ?[]const menu.Item) Error!void {
        if (items) |list| {
            const native = tray.menus.native(list) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.TooManyItems => error.TooManyItems,
                error.EngineFailed => error.EngineFailed,
            };
            defer zg.zg_menu_destroy(native);
            try check(zg.zg_tray_set_menu(tray.handle, native));
        } else try check(zg.zg_tray_set_menu(tray.handle, null));
    }

    pub fn setMenuChecked(tray: *Tray, id: []const u8, checked: bool) Error!void {
        try check(zg.zg_tray_menu_set_checked(tray.handle, try tray.menus.number(id), @intFromBool(checked)));
    }

    pub fn setMenuEnabled(tray: *Tray, id: []const u8, enabled: bool) Error!void {
        try check(zg.zg_tray_menu_set_enabled(tray.handle, try tray.menus.number(id), @intFromBool(enabled)));
    }

    /// `handler(context, position)` on a click, where it was.
    pub fn onActivated(tray: *Tray, context: anytype, comptime handler: anytype) error{OutOfMemory}!void {
        const C = @TypeOf(context);
        const Thunk = struct {
            fn call(opaque_context: ?*anyopaque, at: desktop.Position) void {
                handler(events.fromOpaque(C, opaque_context), at);
            }
        };
        try tray.activated_handlers.append(allocator, .{ .context = events.toOpaque(context), .function = Thunk.call });
    }

    /// A click shows `window` by the icon (above it, as the taskbar is at the
    /// bottom; inside the screen's work area), the next one hides it. Null
    /// detaches.
    pub fn attachWindow(tray: *Tray, window: ?*Window) void {
        tray.attached = window;
    }

    fn toggleAttached(tray: *Tray, at: desktop.Position) void {
        const window = tray.attached orelse return;
        if (window.state() != .hidden and window.state() != .minimized) {
            window.hide() catch {};
            return;
        }
        var x: c_int = at.x;
        var y: c_int = at.y;
        var width: c_uint = 0;
        var height: c_uint = 0;
        if (zg.zg_tray_get_rect(tray.handle, &x, &y, &width, &height) != zg.ZG_OK) {
            x = at.x;
            y = at.y;
        }
        window.show() catch {};
        const size = window.size() catch desktop.Size{ .width = 360, .height = 480 };
        const screen = window.screen(allocator) catch null;
        defer if (screen) |s| allocator.free(s.name);
        // Logical size to the desktop's units, roughly: the screen's scale.
        const scale: f32 = if (screen) |s| s.scale else 1;
        const w: i32 = @intFromFloat(@as(f32, @floatFromInt(size.width)) * scale);
        const h: i32 = @intFromFloat(@as(f32, @floatFromInt(size.height)) * scale);
        var left: i32 = x + @as(i32, @intCast(width / 2)) - @divTrunc(w, 2);
        var top: i32 = y - h - 8;
        if (screen) |s| {
            const area = s.work_area;
            left = std.math.clamp(left, area.x, area.x + @as(i32, @intCast(area.width)) - w);
            if (top < area.y) top = y + @as(i32, @intCast(height)) + 8;
            top = std.math.clamp(top, area.y, area.y + @as(i32, @intCast(area.height)) - h);
        }
        window.setPosition(.{ .x = left, .y = top }) catch {};
        window.focus() catch {};
    }

    fn activated(handle: ?*zg.zg_tray, x: c_int, y: c_int, user: ?*anyopaque) callconv(.c) void {
        _ = handle;
        const tray: *Tray = @ptrCast(@alignCast(user.?));
        const at: desktop.Position = .{ .x = x, .y = y };
        tray.toggleAttached(at);
        for (tray.activated_handlers.items) |handler| handler.function(handler.context, at);
        tray.app.bus.emit("tray:activated", at);
    }

    fn menuItem(handle: ?*zg.zg_tray, id: c_uint, user: ?*anyopaque) callconv(.c) void {
        _ = handle;
        const tray: *Tray = @ptrCast(@alignCast(user.?));
        if (tray.menus.name(id)) |name| tray.app.menuChosen(null, name);
    }
};

fn check(result: zg.zg_result) Error!void {
    return switch (result) {
        zg.ZG_OK => {},
        zg.ZG_ERROR_UNSUPPORTED => error.Unsupported,
        zg.ZG_ERROR_OUT_OF_MEMORY => error.OutOfMemory,
        else => error.EngineFailed,
    };
}
