//! A window of the application and its page: control (size, position,
//! states...), its events (to Zig handlers and to the page as "window:*"
//! events), its menus, the engine's context menu, and the page runtime's own
//! bindings (runtime.js's Plume.window, Plume.dialog, Plume.clipboard,
//! Plume.screens, Plume.menu, Plume.notifications, Plume.shortcuts,
//! Plume.windows, Plume.app). Runtime thread, except emit.

const std = @import("std");
const builtin = @import("builtin");
const zg = @import("zerog");
const codec = @import("codec.zig");
const desktop = @import("desktop.zig");
const dom = @import("dom.zig");
const menu = @import("menu.zig");
const events = @import("events.zig");
const App = @import("app.zig").App;

/// What happens to a window, for its onWindow handlers. The page gets the
/// same as events: "window:resized", "window:moved", "window:focus",
/// "window:state", "window:screen" and "window:files-dropped".
pub const WindowEvent = union(enum) {
    resized: desktop.Size,
    moved: desktop.Position,
    focus: bool,
    state: desktop.State,
    /// Another screen, or its scale changed.
    screen,
    /// Files dropped on the window from outside (the page gets a drop event
    /// too, without the paths); valid during the call.
    files_dropped: FilesDropped,
};

pub const FilesDropped = struct { paths: []const []const u8, x: f32, y: f32 };

pub const Options = struct {
    title: []const u8 = "",
    /// Logical pixels.
    width: u32 = 800,
    height: u32 = 600,
    resizable: bool = true,
    frameless: bool = false,
    transparent: bool = false,
    /// A page of the frontend ("settings.html", "#/settings"), or an absolute
    /// URL.
    url: []const u8 = "index.html",
    /// Shown later, with show().
    hidden: bool = false,
};

pub const Window = struct {
    app: *App,
    handle: *zg.zg_window,
    view: *zg.zg_view,
    main: bool,
    menus: menu.Menus = .{},
    /// The window's menus are the system's (Windows); else the page draws them.
    native_menus: bool = builtin.os.tag == .windows,
    window_handlers: std.ArrayList(Handler(WindowEvent)) = .empty,
    close_handler: ?struct { context: ?*anyopaque, function: *const fn (?*anyopaque) bool } = null,
    /// The page's popup menu waiting for its answer (native menus).
    popup: ?*zg.zg_promise = null,
    /// A declarative context menu being shown (native menus): its name and data.
    context_choice: ?struct { name: []u8, data: []u8 } = null,
    /// The engine's context menu being shown (native menus).
    context_menu: ?*zg.zg_context_menu = null,
    closed: bool = false,

    const allocator = std.heap.smp_allocator;

    fn Handler(comptime T: type) type {
        return struct { context: ?*anyopaque, function: *const fn (?*anyopaque, T) void };
    }

    /// A new window of `app`'s context, its page loading. Runtime thread.
    pub fn create(app: *App, options: Options, main: bool) error{ OutOfMemory, EngineFailed, BindFailed }!*Window {
        var config = std.mem.zeroes(zg.zg_window_config);
        config.size = @sizeOf(zg.zg_window_config);
        const title = try allocator.dupeSentinel(u8, options.title, 0);
        defer allocator.free(title);
        config.title = title.ptr;
        config.width = options.width;
        config.height = options.height;
        config.fixed_size = @intFromBool(!options.resizable);
        config.frameless = @intFromBool(options.frameless);
        config.transparent = @intFromBool(options.transparent);
        config.hidden = @intFromBool(options.hidden);
        const handle = zg.zg_window_create(app.context, &config) orelse {
            std.log.err("plume: zg_window_create: {s}", .{zg.zg_last_error()});
            return error.EngineFailed;
        };
        errdefer zg.zg_window_destroy(handle);
        const window = try allocator.create(Window);
        errdefer allocator.destroy(window);
        window.* = .{ .app = app, .handle = handle, .view = zg.zg_window_view(handle).?, .main = main };

        var callbacks = std.mem.zeroes(zg.zg_window_callbacks);
        callbacks.size = @sizeOf(zg.zg_window_callbacks);
        callbacks.user = window;
        callbacks.close_requested = closeRequested;
        callbacks.resized = resized;
        callbacks.moved = moved;
        callbacks.focus_changed = focusChanged;
        callbacks.state_changed = stateChanged;
        callbacks.menu_item = menuItem;
        callbacks.screen_changed = screenChanged;
        callbacks.files_dropped = filesDropped;
        if (zg.zg_window_set_callbacks(handle, &callbacks) != zg.ZG_OK) return error.BindFailed;

        inline for (.{
            .{ "__plume.platform", platformBinding },     .{ "__plume.window", windowBinding },
            .{ "__plume.screens", screensBinding },       .{ "__plume.clipboard", clipboardBinding },
            .{ "__plume.dialog", dialogBinding },         .{ "__plume.menu", menuBinding },
            .{ "__plume.menuChosen", menuChosenBinding }, .{ "__plume.popup", popupBinding },
            .{ "__plume.app", appBinding },               .{ "__plume.contextMenu", contextMenuBinding },
            .{ "__plume.update", updateBinding },
        }) |binding| {
            if (zg.zg_view_bind(window.view, binding[0], binding[1], window) != zg.ZG_OK) return error.BindFailed;
        }
        try app.bus.attach(window.view, @embedFile("runtime.js"));
        try app.applyBindings(window.view);
        window.installViewCallbacks();
        _ = zg.zg_view_set_color_scheme(window.view, app.color_scheme);
        if (app.icon) |icon| {
            // The executable's on Windows (addApp's resource); the window's elsewhere.
            if (builtin.os.tag != .windows) _ = zg.zg_window_set_icon(handle, icon.rgba.ptr, icon.width, icon.height);
        }
        // The main window's page loads in app.run(), once everything is bound.
        if (!main) try window.load(options.url);
        return window;
    }

    /// Loads a page of the frontend ("settings.html") or an absolute URL.
    pub fn load(window: *Window, page_or_url: []const u8) error{ OutOfMemory, EngineFailed }!void {
        const url = try window.app.pageURL(page_or_url);
        defer allocator.free(url);
        if (zg.zg_view_load_url(window.view, url.ptr) != zg.ZG_OK) return error.EngineFailed;
    }

    /// Runtime thread; the app's windows list is the App's to change.
    pub fn destroy(window: *Window) void {
        window.app.bus.detach(window.view);
        zg.zg_window_destroy(window.handle);
        window.menus.deinit();
        window.window_handlers.deinit(allocator);
        if (window.context_choice) |choice| {
            allocator.free(choice.name);
            allocator.free(choice.data);
        }
        allocator.destroy(window);
    }

    fn controls(window: *Window) desktop.Controls {
        return .{ .handle = window.handle, .runtime = window.app.runtime };
    }

    // ---- Control ----

    pub fn setTitle(window: *Window, title: []const u8) desktop.Error!void {
        return window.controls().setTitle(title);
    }
    pub fn setSize(window: *Window, new_size: desktop.Size) desktop.Error!void {
        return window.controls().setSize(new_size);
    }
    pub fn size(window: *Window) desktop.Error!desktop.Size {
        return window.controls().size();
    }
    pub fn setMinSize(window: *Window, minimum: desktop.Size) desktop.Error!void {
        return window.controls().setMinSize(minimum);
    }
    pub fn setMaxSize(window: *Window, maximum: desktop.Size) desktop.Error!void {
        return window.controls().setMaxSize(maximum);
    }
    pub fn setResizable(window: *Window, resizable: bool) desktop.Error!void {
        return window.controls().setResizable(resizable);
    }
    pub fn setPosition(window: *Window, position_: desktop.Position) desktop.Error!void {
        return window.controls().setPosition(position_);
    }
    pub fn position(window: *Window) desktop.Error!desktop.Position {
        return window.controls().position();
    }
    pub fn center(window: *Window) desktop.Error!void {
        return window.controls().center();
    }
    pub fn minimize(window: *Window) desktop.Error!void {
        return window.controls().minimize();
    }
    pub fn maximize(window: *Window) desktop.Error!void {
        return window.controls().maximize();
    }
    pub fn restore(window: *Window) desktop.Error!void {
        return window.controls().restore();
    }
    pub fn toggleMaximize(window: *Window) desktop.Error!void {
        return window.controls().toggleMaximize();
    }
    pub fn setFullscreen(window: *Window, fullscreen: bool) void {
        window.controls().setFullscreen(fullscreen);
    }
    pub fn show(window: *Window) desktop.Error!void {
        return window.controls().show();
    }
    pub fn hide(window: *Window) desktop.Error!void {
        return window.controls().hide();
    }
    pub fn focus(window: *Window) desktop.Error!void {
        return window.controls().focus();
    }
    pub fn setAlwaysOnTop(window: *Window, on_top: bool) desktop.Error!void {
        return window.controls().setAlwaysOnTop(on_top);
    }
    pub fn state(window: *Window) desktop.State {
        return window.controls().state();
    }
    pub fn setIcon(window: *Window, rgba: []const u8, width: u32, height: u32) desktop.Error!void {
        return window.controls().setIcon(rgba, width, height);
    }
    /// The screen the window is mostly on; its name in `allocator_`.
    pub fn screen(window: *Window, allocator_: std.mem.Allocator) desktop.Error!desktop.Screen {
        return window.controls().screen(allocator_);
    }
    /// HWND on Windows, the X11 window or Wayland surface.
    pub fn nativeHandle(window: *Window) ?*anyopaque {
        return window.controls().nativeHandle();
    }

    /// As the user closing it: the onClose handler may keep it open. The
    /// main window's close ends the application; another's destroys it.
    pub fn close(window: *Window) void {
        if (!window.allowClose()) return;
        window.closed = true;
        window.app.windowClosed(window);
    }

    // ---- Its page ----

    /// To this window's Plume.on listeners. Any thread.
    pub fn emit(window: *Window, name: []const u8, value: anytype) void {
        window.app.bus.emitTo(window.view, name, value);
    }

    /// The page's objects (plume.dom). Close it when done.
    pub fn page(window: *Window) dom.Error!dom.Page {
        return dom.Page.open(window.view);
    }

    // ---- Handlers ----

    pub fn onWindow(window: *Window, context: anytype, comptime handler: anytype) error{OutOfMemory}!void {
        try window.window_handlers.append(allocator, .{ .context = events.toOpaque(context), .function = Thunk(@TypeOf(context), WindowEvent, handler).call });
    }

    /// `handler(context) bool` when the user asks to close the window (or
    /// the page calls Plume.window.close()): false keeps it open.
    pub fn onClose(window: *Window, context: anytype, comptime handler: anytype) void {
        const C = @TypeOf(context);
        const Close = struct {
            fn call(opaque_context: ?*anyopaque) bool {
                return handler(events.fromOpaque(C, opaque_context));
            }
        };
        window.close_handler = .{ .context = events.toOpaque(context), .function = Close.call };
    }

    fn allowClose(window: *Window) bool {
        const handler = window.close_handler orelse return true;
        return handler.function(handler.context);
    }

    fn windowEvent(window: *Window, event: WindowEvent, page_name: []const u8, page_data: anytype) void {
        for (window.window_handlers.items) |handler| handler.function(handler.context, event);
        window.emit(page_name, page_data);
    }

    // ---- Menus ----

    pub const MenuError = error{ OutOfMemory, TooManyItems, EngineFailed } || desktop.Error;

    /// The window's menu bar; null removes it.
    pub fn setMenu(window: *Window, items: ?[]const menu.Item) MenuError!void {
        try window.menus.setBar(items);
        if (window.native_menus) {
            const native = if (items) |list| try window.menus.native(list) else null;
            defer if (native) |m| zg.zg_menu_destroy(m);
            // A menu bar shown or removed takes its room from the window's
            // frame, not from the page: the page keeps its size.
            const size_ = window.size() catch null;
            const result = zg.zg_window_set_menu(window.handle, native);
            if (result != zg.ZG_ERROR_UNSUPPORTED) {
                try desktop.check(result);
                if (size_) |s| window.setSize(s) catch {};
                return;
            }
            window.native_menus = false;
        }
        // Numbered for menuChosen, then drawn by the page.
        if (items) |list| try window.menus.numberAll(list);
        window.redrawMenu();
    }

    pub fn setMenuChecked(window: *Window, id: []const u8, checked: bool) MenuError!void {
        _ = window.menus.update(id, checked, null);
        if (window.native_menus) return desktop.check(zg.zg_window_menu_set_checked(window.handle, try window.menus.number(id), @intFromBool(checked)));
        window.redrawMenu();
    }

    pub fn setMenuEnabled(window: *Window, id: []const u8, enabled: bool) MenuError!void {
        _ = window.menus.update(id, null, enabled);
        if (window.native_menus) return desktop.check(zg.zg_window_menu_set_enabled(window.handle, try window.menus.number(id), @intFromBool(enabled)));
        window.redrawMenu();
    }

    /// A popup menu at (x, y), the page's CSS pixels; the chosen item goes to
    /// the app's onMenu handlers and the page's "menu" event.
    pub fn popupMenu(window: *Window, items: []const menu.Item, x: f32, y: f32) MenuError!void {
        if (window.native_menus) {
            const native = try window.menus.native(items);
            defer zg.zg_menu_destroy(native);
            return desktop.check(zg.zg_window_popup_menu(window.handle, native, x, y));
        }
        try window.menus.numberAll(items);
        window.emit("plume:popup", .{ .items = items, .x = x, .y = y });
    }

    fn redrawMenu(window: *Window) void {
        window.emit("plume:menu", window.menus.bar);
    }

    /// A declarative context menu (app.setContextMenu) for the page.
    fn showContextMenu(window: *Window, name: []const u8, data: []const u8, x: f32, y: f32) MenuError!void {
        const items = window.app.contextMenu(name) orelse return error.NotFound;
        if (window.context_choice) |choice| {
            allocator.free(choice.name);
            allocator.free(choice.data);
            window.context_choice = null;
        }
        if (!window.native_menus) {
            try window.menus.numberAll(items);
            window.emit("plume:context-popup", .{ .name = name, .data = data, .items = items, .x = x, .y = y });
            return;
        }
        window.context_choice = .{ .name = try allocator.dupe(u8, name), .data = try allocator.dupe(u8, data) };
        const native = try window.menus.native(items);
        defer zg.zg_menu_destroy(native);
        return desktop.check(zg.zg_window_popup_menu(window.handle, native, x, y));
    }

    // ---- The view's callbacks ----

    /// The page's console and errors to stderr, the engine's context menu,
    /// links to other sites, and with PLUME_SMOKE the end of the run once the
    /// main window's page has loaded.
    fn installViewCallbacks(window: *Window) void {
        var callbacks = std.mem.zeroes(zg.zg_view_callbacks);
        callbacks.size = @sizeOf(zg.zg_view_callbacks);
        callbacks.user = window;
        callbacks.console = printConsole;
        callbacks.js_error = printError;
        callbacks.context_menu = contextMenuCallback;
        callbacks.open_external = openExternal;
        if (window.main and window.app.smoke) callbacks.load_finished = smokeLoaded;
        zg.zg_view_set_callbacks(window.view, &callbacks);
    }

    fn smokeLoaded(view: ?*zg.zg_view, url: [*c]const u8, failed: c_int, user: ?*anyopaque) callconv(.c) void {
        _ = view;
        const window = fromUser(user);
        window.app.smoke_failed = failed != 0;
        std.debug.print("plume smoke: {s} {s}\n", .{ if (failed != 0) "failed to load" else "loaded", url });
        zg.zg_runtime_quit(window.app.runtime);
    }

    /// A link to another site, or window.open of one: the app's
    /// onExternalLink handler, else the default browser.
    fn openExternal(view: ?*zg.zg_view, url: [*c]const u8, user: ?*anyopaque) callconv(.c) void {
        _ = view;
        fromUser(user).app.openExternal(std.mem.span(url));
    }

    fn printConsole(view: ?*zg.zg_view, message: [*c]const zg.zg_log_message, user: ?*anyopaque) callconv(.c) void {
        _ = view;
        _ = user;
        const m = message.*;
        // Hidden by default, as browsers' consoles do (Vite's chatter, for one).
        if (m.level == zg.ZG_LOG_DEBUG) return;
        const level = switch (m.level) {
            zg.ZG_LOG_INFO => "log",
            zg.ZG_LOG_WARNING => "warn",
            else => "error",
        };
        const source = if (m.source == zg.ZG_LOG_SOURCE_CONSOLE) "console." else "page ";
        const text = slice(m.message, m.message_len);
        // The engine reports a script error here before js_error has it.
        last_engine_error = if (m.source != zg.ZG_LOG_SOURCE_CONSOLE and m.level == zg.ZG_LOG_ERROR) std.hash.Wyhash.hash(0, text) else 0;
        std.debug.print("{s}{s}: {s}", .{ source, level, text });
        if (m.file_len > 0) std.debug.print("  ({s}:{d})", .{ slice(m.file, m.file_len), m.line });
        std.debug.print("\n", .{});
    }

    fn printError(view: ?*zg.zg_view, err: [*c]const zg.zg_js_error, user: ?*anyopaque) callconv(.c) void {
        _ = view;
        _ = user;
        const e = err.*;
        const message = slice(e.message, e.message_len);
        // Already printed by the engine's console message: only the stack.
        const repeated = last_engine_error != 0 and last_engine_error == std.hash.Wyhash.hash(0, message);
        last_engine_error = 0;
        if (!repeated) {
            const kind = if (e.unhandled_rejection != 0) "unhandled rejection" else "uncaught error";
            std.debug.print("page {s}: {s}", .{ kind, message });
            if (e.file_len > 0) std.debug.print("  ({s}:{d}:{d})", .{ slice(e.file, e.file_len), e.line, e.column });
            std.debug.print("\n", .{});
        }
        if (e.stack_len > 0) std.debug.print("{s}\n", .{slice(e.stack, e.stack_len)});
    }

    var last_engine_error: u64 = 0;

    /// The engine's own context menu (copy, paste...), as a native popup: in
    /// text fields, on selected text, and anywhere in the dev profile (for
    /// Inspect Element). Pages make their own with Plume.menu.popup or
    /// data-plume-menu.
    fn contextMenuCallback(view: ?*zg.zg_view, context_menu: ?*zg.zg_context_menu, user: ?*anyopaque) callconv(.c) void {
        _ = view;
        const window = fromUser(user);
        const cm = context_menu.?;
        const selected = zg.zg_context_menu_selected_text(cm);
        const wanted = window.app.dev_profile or zg.zg_context_menu_is_editable(cm) != 0 or (selected != null and selected[0] != 0);
        if (!window.native_menus or !wanted or window.context_menu != null) return zg.zg_context_menu_cancel(cm);
        const native = zg.zg_menu_create() orelse return zg.zg_context_menu_cancel(cm);
        defer zg.zg_menu_destroy(native);
        var count: usize = 0;
        for (0..zg.zg_context_menu_item_count(cm)) |i| {
            const entry = zg.zg_context_menu_item_at(cm, i).*;
            if (entry.parent != 0) continue; // submenus' items: not shown
            const result = switch (entry.kind) {
                zg.ZG_CONTEXT_MENU_ITEM_SEPARATOR => zg.zg_menu_add_separator(native),
                zg.ZG_CONTEXT_MENU_ITEM_ACTION, zg.ZG_CONTEXT_MENU_ITEM_CHECKBOX => zg.zg_menu_add_item(native, menu.context_menu_base + entry.id, entry.label, null, menu.flags(entry.kind == zg.ZG_CONTEXT_MENU_ITEM_CHECKBOX, entry.checked != 0, entry.enabled != 0)),
                else => continue,
            };
            if (result == zg.ZG_OK and entry.kind != zg.ZG_CONTEXT_MENU_ITEM_SEPARATOR) count += 1;
        }
        var x: f32 = 0;
        var y: f32 = 0;
        zg.zg_context_menu_position(cm, &x, &y);
        if (count == 0 or zg.zg_window_popup_menu(window.handle, native, x, y) != zg.ZG_OK) return zg.zg_context_menu_cancel(cm);
        window.context_menu = cm;
    }

    // ---- The window's callbacks ----

    fn closeRequested(handle: ?*zg.zg_window, user: ?*anyopaque) callconv(.c) c_int {
        _ = handle;
        const window = fromUser(user);
        if (!window.allowClose()) return 0;
        window.closed = true;
        window.app.windowClosed(window);
        // Destroyed by the app (another window), or the loop ends (the main one).
        return 1;
    }

    fn resized(handle: ?*zg.zg_window, width: c_uint, height: c_uint, user: ?*anyopaque) callconv(.c) void {
        _ = handle;
        const size_: desktop.Size = .{ .width = width, .height = height };
        fromUser(user).windowEvent(.{ .resized = size_ }, "window:resized", size_);
    }

    fn moved(handle: ?*zg.zg_window, x: c_int, y: c_int, user: ?*anyopaque) callconv(.c) void {
        _ = handle;
        const position_: desktop.Position = .{ .x = x, .y = y };
        fromUser(user).windowEvent(.{ .moved = position_ }, "window:moved", position_);
    }

    fn focusChanged(handle: ?*zg.zg_window, focused: c_int, user: ?*anyopaque) callconv(.c) void {
        _ = handle;
        fromUser(user).windowEvent(.{ .focus = focused != 0 }, "window:focus", focused != 0);
    }

    fn stateChanged(handle: ?*zg.zg_window, state_: zg.zg_window_state, user: ?*anyopaque) callconv(.c) void {
        _ = handle;
        const value = desktop.stateOf(state_);
        fromUser(user).windowEvent(.{ .state = value }, "window:state", value);
    }

    fn screenChanged(handle: ?*zg.zg_window, user: ?*anyopaque) callconv(.c) void {
        _ = handle;
        fromUser(user).windowEvent(.screen, "window:screen", {});
    }

    fn filesDropped(handle: ?*zg.zg_window, paths: [*c]const [*c]const u8, count: usize, x: f32, y: f32, user: ?*anyopaque) callconv(.c) c_int {
        _ = handle;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const list = arena.allocator().alloc([]const u8, count) catch return 0;
        for (list, 0..) |*path, i| path.* = std.mem.span(paths[i]);
        const dropped: FilesDropped = .{ .paths = list, .x = x, .y = y };
        fromUser(user).windowEvent(.{ .files_dropped = dropped }, "window:files-dropped", dropped);
        return 0; // the page gets its drop event as well
    }

    fn menuItem(handle: ?*zg.zg_window, id: c_uint, user: ?*anyopaque) callconv(.c) void {
        _ = handle;
        const window = fromUser(user);
        if (window.context_menu) |cm| {
            window.context_menu = null;
            if (id > menu.context_menu_base) zg.zg_context_menu_select(cm, id - menu.context_menu_base) else zg.zg_context_menu_cancel(cm);
            return;
        }
        if (window.popup) |promise| {
            window.popup = null;
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            const json = codec.encode(arena.allocator(), window.menus.name(id)) catch "null";
            zg.zg_promise_resolve(promise, json.ptr, json.len);
            return;
        }
        if (window.context_choice) |choice| {
            window.context_choice = null;
            defer {
                allocator.free(choice.name);
                allocator.free(choice.data);
            }
            if (window.menus.name(id)) |name| window.app.contextMenuChosen(window, choice.name, name, choice.data);
            return;
        }
        // 0: a popup dismissed.
        if (window.menus.name(id)) |name| window.app.menuChosen(window, name);
    }

    // ---- The page runtime's bindings ----

    fn platformBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        _ = user;
        return zg.zg_value_string(call, if (builtin.os.tag == .windows) "windows" else "linux");
    }

    /// __plume.window(op, json): the window's controls for its page.
    fn windowBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const window = fromUser(user);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const op = argString(call, 0) orelse return zg.zg_call_throw(call, "plume:InvalidArgument");
        const json = argString(call, 1) orelse "null";
        const result = window.windowOp(arena.allocator(), op, json) catch |err| return throwError(call, err);
        return zg.zg_value_json(call, result.ptr, result.len);
    }

    fn windowOp(window: *Window, a: std.mem.Allocator, op: []const u8, json: []const u8) (desktop.Error || codec.DecodeError || error{BindFailed})![]const u8 {
        const eql = std.mem.eql;
        if (eql(u8, op, "minimize")) try window.minimize() //
        else if (eql(u8, op, "maximize")) try window.maximize() //
        else if (eql(u8, op, "restore")) try window.restore() //
        else if (eql(u8, op, "toggleMaximize")) try window.toggleMaximize() //
        else if (eql(u8, op, "center")) try window.center() //
        else if (eql(u8, op, "show")) try window.show() //
        else if (eql(u8, op, "hide")) try window.hide() //
        else if (eql(u8, op, "focus")) try window.focus() //
        else if (eql(u8, op, "close")) window.close() //
        else if (eql(u8, op, "setTitle")) try window.setTitle(try codec.decode([]const u8, a, json)) //
        else if (eql(u8, op, "setSize")) try window.setSize(try codec.decode(desktop.Size, a, json)) //
        else if (eql(u8, op, "setMinSize")) try window.setMinSize(try codec.decode(desktop.Size, a, json)) //
        else if (eql(u8, op, "setMaxSize")) try window.setMaxSize(try codec.decode(desktop.Size, a, json)) //
        else if (eql(u8, op, "setPosition")) try window.setPosition(try codec.decode(desktop.Position, a, json)) //
        else if (eql(u8, op, "setResizable")) try window.setResizable(try codec.decode(bool, a, json)) //
        else if (eql(u8, op, "setAlwaysOnTop")) try window.setAlwaysOnTop(try codec.decode(bool, a, json)) //
        else if (eql(u8, op, "setFullscreen")) window.setFullscreen(try codec.decode(bool, a, json)) //
        else if (eql(u8, op, "size")) return codec.encode(a, try window.size()) //
        else if (eql(u8, op, "position")) return codec.encode(a, try window.position()) //
        else if (eql(u8, op, "state")) return codec.encode(a, window.state()) //
        else if (eql(u8, op, "screen")) return codec.encode(a, try window.screen(a)) //
        else if (eql(u8, op, "open")) {
            // Plume.windows.open: another window of the application.
            const options = try codec.decode(Options, a, json);
            _ = window.app.openWindow(options) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.EngineFailed,
            };
        } else return error.InvalidArgument;
        return "null";
    }

    /// __plume.app(op, json): the application for its pages.
    fn appBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const window = fromUser(user);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const op = argString(call, 0) orelse return zg.zg_call_throw(call, "plume:InvalidArgument");
        const json = argString(call, 1) orelse "null";
        const result = window.app.appOp(arena.allocator(), op, json) catch |err| return throwError(call, err);
        return zg.zg_value_json(call, result.ptr, result.len);
    }

    /// __plume.update(op, json): updates, for the application's pages.
    fn updateBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const window = fromUser(user);
        const op = argString(call, 0) orelse return zg.zg_call_throw(call, "plume:InvalidArgument");
        return window.app.updateBinding(call, op, argString(call, 1) orelse "null");
    }

    fn screensBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const window = fromUser(user);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const list = desktop.screens(window.app.runtime, arena.allocator()) catch |err| return throwError(call, err);
        const json = codec.encode(arena.allocator(), list) catch return zg.zg_call_throw(call, "plume:OutOfMemory");
        return zg.zg_value_json(call, json.ptr, json.len);
    }

    /// __plume.clipboard("readText") or ("writeText", text).
    fn clipboardBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const window = fromUser(user);
        const clipboard: desktop.Clipboard = .{ .runtime = window.app.runtime };
        const op = argString(call, 0) orelse return zg.zg_call_throw(call, "plume:InvalidArgument");
        if (std.mem.eql(u8, op, "writeText")) {
            clipboard.writeText(argString(call, 1) orelse "") catch |err| return throwError(call, err);
            return null;
        }
        const text = clipboard.readText(allocator) catch |err| return throwError(call, err);
        defer if (text) |t| allocator.free(t);
        return if (text) |t| zg.zg_value_string_len(call, t.ptr, t.len) else zg.zg_value_null(call);
    }

    /// __plume.dialog(kind, json): "file" (a FileDialog) resolves with the
    /// paths, "message" (a MessageBox) with the button's id.
    fn dialogBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const window = fromUser(user);
        var promise: ?*zg.zg_promise = null;
        const value = zg.zg_call_promise(call, &promise);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const kind = argString(call, 0) orelse "";
        const json = argString(call, 1) orelse "null";
        const shown = if (std.mem.eql(u8, kind, "message")) blk: {
            const box = codec.decode(desktop.MessageBox, arena.allocator(), json) catch break :blk error.InvalidArgument;
            break :blk desktop.showMessageBox(window.handle, box, promise, resolveButton);
        } else blk: {
            const dialog = codec.decode(desktop.FileDialog, arena.allocator(), json) catch break :blk error.InvalidArgument;
            break :blk desktop.showFileDialog(window.handle, dialog, promise, resolvePaths);
        };
        shown catch |err| {
            var buffer: [64]u8 = undefined;
            zg.zg_promise_reject(promise, errorMessage(&buffer, err));
        };
        return value;
    }

    fn resolvePaths(context: ?*anyopaque, paths: []const []const u8) void {
        const promise: *zg.zg_promise = @ptrCast(context.?);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const json = codec.encode(arena.allocator(), paths) catch "[]";
        zg.zg_promise_resolve(promise, json.ptr, json.len);
    }

    fn resolveButton(context: ?*anyopaque, button: i32) void {
        const promise: *zg.zg_promise = @ptrCast(context.?);
        var buffer: [16]u8 = undefined;
        const json = std.fmt.bufPrint(&buffer, "{d}", .{button}) catch "-1";
        zg.zg_promise_resolve(promise, json.ptr, json.len);
    }

    /// The menu bar for the page to draw: null when the system draws it.
    fn menuBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const window = fromUser(user);
        if (window.native_menus) return zg.zg_value_null(call);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const json = codec.encode(arena.allocator(), window.menus.bar) catch return zg.zg_value_null(call);
        return zg.zg_value_json(call, json.ptr, json.len);
    }

    /// An item of a menu the page drew was chosen: (id) for the menu bar and
    /// Zig's popups, (id, name, data) for a declarative context menu.
    fn menuChosenBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const window = fromUser(user);
        const id = argString(call, 0) orelse return null;
        if (!window.menus.numbers.contains(id)) return null;
        if (argString(call, 1)) |name| {
            window.app.contextMenuChosen(window, name, id, argString(call, 2) orelse "");
        } else window.app.menuChosen(window, id);
        return null;
    }

    /// __plume.popup(items json, x, y): the page's own popup menu, native;
    /// resolves with the chosen id, or null.
    fn popupBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const window = fromUser(user);
        var promise: ?*zg.zg_promise = null;
        const value = zg.zg_call_promise(call, &promise);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const items = codec.decode([]const menu.Item, arena.allocator(), argString(call, 0) orelse "[]") catch {
            zg.zg_promise_reject(promise, "plume:InvalidArgument");
            return value;
        };
        const x: f32 = @floatCast(zg.zg_call_arg_number(call, 1));
        const y: f32 = @floatCast(zg.zg_call_arg_number(call, 2));
        if (window.popup) |previous| zg.zg_promise_resolve(previous, "null", 4);
        window.popup = promise;
        window.popupMenu(items, x, y) catch |err| {
            window.popup = null;
            var buffer: [64]u8 = undefined;
            zg.zg_promise_reject(promise, errorMessage(&buffer, err));
        };
        return value;
    }

    /// __plume.contextMenu(name, data, x, y): a declarative context menu
    /// (data-plume-menu) at the right click.
    fn contextMenuBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const window = fromUser(user);
        const name = argString(call, 0) orelse return zg.zg_call_throw(call, "plume:InvalidArgument");
        const data = argString(call, 1) orelse "";
        const x: f32 = @floatCast(zg.zg_call_arg_number(call, 2));
        const y: f32 = @floatCast(zg.zg_call_arg_number(call, 3));
        window.showContextMenu(name, data, x, y) catch |err| return throwError(call, err);
        return null;
    }
};

fn Thunk(comptime C: type, comptime T: type, comptime handler: anytype) type {
    return struct {
        fn call(opaque_context: ?*anyopaque, value: T) void {
            const result = handler(events.fromOpaque(C, opaque_context), value);
            if (@typeInfo(@TypeOf(result)) == .error_union) {
                _ = result catch |err| std.log.err("plume: a handler failed: {s}", .{@errorName(err)});
            }
        }
    };
}

fn fromUser(user: ?*anyopaque) *Window {
    return @ptrCast(@alignCast(user.?));
}

pub fn argString(call: ?*zg.zg_call, index: usize) ?[]const u8 {
    if (index >= zg.zg_call_argc(call) or zg.zg_call_arg_type(call, index) != zg.ZG_TYPE_STRING) return null;
    var length: usize = 0;
    const text = zg.zg_call_arg_string(call, index, &length) orelse return null;
    return text[0..length];
}

pub fn throwError(call: ?*zg.zg_call, err: anyerror) ?*zg.zg_value {
    var buffer: [64]u8 = undefined;
    return zg.zg_call_throw(call, errorMessage(&buffer, err));
}

/// "plume:<ErrorName>", which bindings.ts turns into a PlumeError.
pub fn errorMessage(buffer: []u8, err: anyerror) [*:0]const u8 {
    const message: [:0]const u8 = std.mem.printSentinel(buffer, "plume:{s}", .{@errorName(err)}, 0) catch "plume:Error";
    return message.ptr;
}

fn slice(pointer: [*c]const u8, length: usize) []const u8 {
    return if (pointer == null) "" else pointer[0..length];
}
