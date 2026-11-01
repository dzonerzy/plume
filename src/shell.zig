//! The window around the page and what reaches it: the window's events (to
//! Zig handlers and to the page as "window:*" events), its menus, the
//! engine's context menu, and the page runtime's own bindings for the window,
//! dialogs, the clipboard and the screens (runtime.js's Plume.window,
//! Plume.dialog, Plume.clipboard, Plume.screens, Plume.menu).

const std = @import("std");
const builtin = @import("builtin");
const zg = @import("zerog");
const codec = @import("codec.zig");
const desktop = @import("desktop.zig");
const menu = @import("menu.zig");
const events = @import("events.zig");

/// What happens to the window, for app.onWindow's handlers. The page gets the
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

pub const Shell = struct {
    runtime: *zg.zg_runtime,
    window: *zg.zg_window,
    view: *zg.zg_view,
    bus: *events.Bus,
    menus: menu.Menus = .{},
    /// The window's menus are the system's (Windows); else the page draws them.
    native_menus: bool = builtin.os.tag == .windows,
    window_handlers: std.ArrayList(Handler(WindowEvent)) = .empty,
    menu_handlers: std.ArrayList(Handler([]const u8)) = .empty,
    close_handler: ?struct { context: ?*anyopaque, function: *const fn (?*anyopaque) bool } = null,
    /// The page's popup menu waiting for its answer (native menus).
    popup: ?*zg.zg_promise = null,
    /// The engine's context menu being shown (native menus).
    context_menu: ?*zg.zg_context_menu = null,
    dev_profile: bool,
    smoke: bool = false,
    smoke_failed: bool = false,

    const allocator = std.heap.smp_allocator;

    fn Handler(comptime T: type) type {
        return struct { context: ?*anyopaque, function: *const fn (?*anyopaque, T) void };
    }

    pub fn create(runtime: *zg.zg_runtime, window: *zg.zg_window, view: *zg.zg_view, bus: *events.Bus) error{ OutOfMemory, BindFailed }!*Shell {
        const shell = try allocator.create(Shell);
        errdefer allocator.destroy(shell);
        const version = zg.zg_version();
        shell.* = .{
            .runtime = runtime,
            .window = window,
            .view = view,
            .bus = bus,
            .dev_profile = version.profile != null and std.mem.eql(u8, std.mem.span(version.profile), "dev"),
        };

        var callbacks = std.mem.zeroes(zg.zg_window_callbacks);
        callbacks.size = @sizeOf(zg.zg_window_callbacks);
        callbacks.user = shell;
        callbacks.close_requested = closeRequested;
        callbacks.resized = resized;
        callbacks.moved = moved;
        callbacks.focus_changed = focusChanged;
        callbacks.state_changed = stateChanged;
        callbacks.menu_item = menuItem;
        callbacks.screen_changed = screenChanged;
        callbacks.files_dropped = filesDropped;
        if (zg.zg_window_set_callbacks(window, &callbacks) != zg.ZG_OK) return error.BindFailed;

        const bindings = .{
            .{ "__plume.platform", platformBinding },
            .{ "__plume.window", windowBinding },
            .{ "__plume.screens", screensBinding },
            .{ "__plume.clipboard", clipboardBinding },
            .{ "__plume.dialog", dialogBinding },
            .{ "__plume.menu", menuBinding },
            .{ "__plume.menuChosen", menuChosenBinding },
            .{ "__plume.popup", popupBinding },
        };
        inline for (bindings) |binding| {
            if (zg.zg_view_bind(view, binding[0], binding[1], shell) != zg.ZG_OK) return error.BindFailed;
        }
        return shell;
    }

    pub fn destroy(shell: *Shell) void {
        shell.menus.deinit();
        shell.window_handlers.deinit(allocator);
        shell.menu_handlers.deinit(allocator);
        allocator.destroy(shell);
    }

    pub fn api(shell: *Shell) desktop.Window {
        return .{ .handle = shell.window, .runtime = shell.runtime };
    }

    // ---- Handlers ----

    pub fn onWindow(shell: *Shell, context: anytype, comptime handler: anytype) error{OutOfMemory}!void {
        try shell.window_handlers.append(allocator, .{ .context = toOpaque(context), .function = Thunk(@TypeOf(context), WindowEvent, handler).call });
    }

    pub fn onMenu(shell: *Shell, context: anytype, comptime handler: anytype) error{OutOfMemory}!void {
        try shell.menu_handlers.append(allocator, .{ .context = toOpaque(context), .function = Thunk(@TypeOf(context), []const u8, handler).call });
    }

    pub fn onClose(shell: *Shell, context: anytype, comptime handler: anytype) void {
        const C = @TypeOf(context);
        const Close = struct {
            fn call(opaque_context: ?*anyopaque) bool {
                return handler(fromOpaque(C, opaque_context));
            }
        };
        shell.close_handler = .{ .context = toOpaque(context), .function = Close.call };
    }

    fn allowClose(shell: *Shell) bool {
        const handler = shell.close_handler orelse return true;
        return handler.function(handler.context);
    }

    fn windowEvent(shell: *Shell, event: WindowEvent, page_name: []const u8, page_data: anytype) void {
        for (shell.window_handlers.items) |handler| handler.function(handler.context, event);
        shell.bus.emit(page_name, page_data);
    }

    fn chosen(shell: *Shell, id: []const u8) void {
        for (shell.menu_handlers.items) |handler| handler.function(handler.context, id);
        shell.bus.emit("menu", id);
    }

    // ---- Menus ----

    pub const MenuError = error{ OutOfMemory, TooManyItems, EngineFailed } || desktop.Error;

    /// The window's menu bar; null removes it.
    pub fn setMenu(shell: *Shell, items: ?[]const menu.Item) MenuError!void {
        try shell.menus.setBar(items);
        if (shell.native_menus) {
            const native = if (items) |list| try shell.menus.native(list) else null;
            defer if (native) |m| zg.zg_menu_destroy(m);
            // A menu bar shown or removed takes its room from the window's
            // frame, not from the page: the page keeps its size.
            const size = shell.api().size() catch null;
            const result = zg.zg_window_set_menu(shell.window, native);
            if (result != zg.ZG_ERROR_UNSUPPORTED) {
                try desktop.check(result);
                if (size) |s| shell.api().setSize(s) catch {};
                return;
            }
            shell.native_menus = false;
        }
        // Numbered for menuChosen, then drawn by the page.
        if (items) |list| try shell.numberAll(list);
        shell.redrawMenu();
    }

    fn numberAll(shell: *Shell, items: []const menu.Item) MenuError!void {
        for (items) |entry| switch (entry) {
            .action => |action| _ = try shell.menus.number(action.id),
            .checkbox => |box| _ = try shell.menus.number(box.id),
            .separator => {},
            .submenu => |sub| try shell.numberAll(sub.items),
        };
    }

    pub fn setMenuChecked(shell: *Shell, id: []const u8, checked: bool) MenuError!void {
        _ = shell.menus.update(id, checked, null);
        if (shell.native_menus) return desktop.check(zg.zg_window_menu_set_checked(shell.window, try shell.menus.number(id), @intFromBool(checked)));
        shell.redrawMenu();
    }

    pub fn setMenuEnabled(shell: *Shell, id: []const u8, enabled: bool) MenuError!void {
        _ = shell.menus.update(id, null, enabled);
        if (shell.native_menus) return desktop.check(zg.zg_window_menu_set_enabled(shell.window, try shell.menus.number(id), @intFromBool(enabled)));
        shell.redrawMenu();
    }

    /// A popup menu at (x, y), the page's CSS pixels; the chosen item goes to
    /// the onMenu handlers and the page's "menu" event.
    pub fn popupMenu(shell: *Shell, items: []const menu.Item, x: f32, y: f32) MenuError!void {
        if (shell.native_menus) {
            const native = try shell.menus.native(items);
            defer zg.zg_menu_destroy(native);
            return desktop.check(zg.zg_window_popup_menu(shell.window, native, x, y));
        }
        try shell.numberAll(items);
        shell.bus.emit("plume:popup", .{ .items = items, .x = x, .y = y });
    }

    fn redrawMenu(shell: *Shell) void {
        shell.bus.emit("plume:menu", shell.menus.bar);
    }

    // ---- The view's callbacks ----

    /// The page's console and errors to stderr, the engine's context menu,
    /// and with `smoke` the end of the run once the page has loaded.
    pub fn installViewCallbacks(shell: *Shell, smoke: bool) void {
        shell.smoke = smoke;
        var callbacks = std.mem.zeroes(zg.zg_view_callbacks);
        callbacks.size = @sizeOf(zg.zg_view_callbacks);
        callbacks.user = shell;
        callbacks.console = printConsole;
        callbacks.js_error = printError;
        callbacks.context_menu = contextMenu;
        if (smoke) callbacks.load_finished = smokeLoaded;
        zg.zg_view_set_callbacks(shell.view, &callbacks);
    }

    fn smokeLoaded(view: ?*zg.zg_view, url: [*c]const u8, failed: c_int, user: ?*anyopaque) callconv(.c) void {
        _ = view;
        const shell = fromUser(user);
        shell.smoke_failed = failed != 0;
        std.debug.print("plume smoke: {s} {s}\n", .{ if (failed != 0) "failed to load" else "loaded", url });
        zg.zg_runtime_quit(shell.runtime);
    }

    fn printConsole(view: ?*zg.zg_view, message: [*c]const zg.zg_log_message, user: ?*anyopaque) callconv(.c) void {
        _ = view;
        _ = user;
        const m = message.*;
        const level = switch (m.level) {
            zg.ZG_LOG_DEBUG => "debug",
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
    /// Inspect Element). Pages make their own with Plume.menu.popup.
    fn contextMenu(view: ?*zg.zg_view, context_menu: ?*zg.zg_context_menu, user: ?*anyopaque) callconv(.c) void {
        _ = view;
        const shell = fromUser(user);
        const cm = context_menu.?;
        const selected = zg.zg_context_menu_selected_text(cm);
        const wanted = shell.dev_profile or zg.zg_context_menu_is_editable(cm) != 0 or (selected != null and selected[0] != 0);
        if (!shell.native_menus or !wanted or shell.context_menu != null) return zg.zg_context_menu_cancel(cm);
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
        if (count == 0 or zg.zg_window_popup_menu(shell.window, native, x, y) != zg.ZG_OK) return zg.zg_context_menu_cancel(cm);
        shell.context_menu = cm;
    }

    // ---- The window's callbacks ----

    fn closeRequested(window: ?*zg.zg_window, user: ?*anyopaque) callconv(.c) c_int {
        _ = window;
        return @intFromBool(fromUser(user).allowClose());
    }

    fn resized(window: ?*zg.zg_window, width: c_uint, height: c_uint, user: ?*anyopaque) callconv(.c) void {
        _ = window;
        const size: desktop.Size = .{ .width = width, .height = height };
        fromUser(user).windowEvent(.{ .resized = size }, "window:resized", size);
    }

    fn moved(window: ?*zg.zg_window, x: c_int, y: c_int, user: ?*anyopaque) callconv(.c) void {
        _ = window;
        const position: desktop.Position = .{ .x = x, .y = y };
        fromUser(user).windowEvent(.{ .moved = position }, "window:moved", position);
    }

    fn focusChanged(window: ?*zg.zg_window, focused: c_int, user: ?*anyopaque) callconv(.c) void {
        _ = window;
        fromUser(user).windowEvent(.{ .focus = focused != 0 }, "window:focus", focused != 0);
    }

    fn stateChanged(window: ?*zg.zg_window, state: zg.zg_window_state, user: ?*anyopaque) callconv(.c) void {
        _ = window;
        const value = desktop.stateOf(state);
        fromUser(user).windowEvent(.{ .state = value }, "window:state", value);
    }

    fn screenChanged(window: ?*zg.zg_window, user: ?*anyopaque) callconv(.c) void {
        _ = window;
        fromUser(user).windowEvent(.screen, "window:screen", {});
    }

    fn filesDropped(window: ?*zg.zg_window, paths: [*c]const [*c]const u8, count: usize, x: f32, y: f32, user: ?*anyopaque) callconv(.c) c_int {
        _ = window;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const list = arena.allocator().alloc([]const u8, count) catch return 0;
        for (list, 0..) |*path, i| path.* = std.mem.span(paths[i]);
        const dropped: FilesDropped = .{ .paths = list, .x = x, .y = y };
        fromUser(user).windowEvent(.{ .files_dropped = dropped }, "window:files-dropped", dropped);
        return 0; // the page gets its drop event as well
    }

    fn menuItem(window: ?*zg.zg_window, id: c_uint, user: ?*anyopaque) callconv(.c) void {
        _ = window;
        const shell = fromUser(user);
        if (shell.context_menu) |cm| {
            shell.context_menu = null;
            if (id > menu.context_menu_base) zg.zg_context_menu_select(cm, id - menu.context_menu_base) else zg.zg_context_menu_cancel(cm);
            return;
        }
        if (shell.popup) |promise| {
            shell.popup = null;
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            const json = codec.encode(arena.allocator(), shell.menus.name(id)) catch "null";
            zg.zg_promise_resolve(promise, json.ptr, json.len);
            return;
        }
        // 0: a popup dismissed.
        if (shell.menus.name(id)) |name| shell.chosen(name);
    }

    // ---- The page runtime's bindings ----

    fn platformBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        _ = user;
        return zg.zg_value_string(call, if (builtin.os.tag == .windows) "windows" else "linux");
    }

    /// __plume.window(op, json): the window's controls for the page.
    fn windowBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const shell = fromUser(user);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const op = argString(call, 0) orelse return zg.zg_call_throw(call, "plume:InvalidArgument");
        const json = argString(call, 1) orelse "null";
        const result = shell.windowOp(arena.allocator(), op, json) catch |err| return throwError(call, err);
        return zg.zg_value_json(call, result.ptr, result.len);
    }

    fn windowOp(shell: *Shell, a: std.mem.Allocator, op: []const u8, json: []const u8) (desktop.Error || codec.DecodeError)![]const u8 {
        const w = shell.api();
        const eql = std.mem.eql;
        if (eql(u8, op, "minimize")) try w.minimize() //
        else if (eql(u8, op, "maximize")) try w.maximize() //
        else if (eql(u8, op, "restore")) try w.restore() //
        else if (eql(u8, op, "toggleMaximize")) try w.toggleMaximize() //
        else if (eql(u8, op, "center")) try w.center() //
        else if (eql(u8, op, "show")) try w.show() //
        else if (eql(u8, op, "hide")) try w.hide() //
        else if (eql(u8, op, "focus")) try w.focus() //
        else if (eql(u8, op, "close")) {
            if (shell.allowClose()) zg.zg_runtime_quit(shell.runtime);
        } else if (eql(u8, op, "setTitle")) try w.setTitle(try codec.decode([]const u8, a, json)) //
        else if (eql(u8, op, "setSize")) try w.setSize(try codec.decode(desktop.Size, a, json)) //
        else if (eql(u8, op, "setMinSize")) try w.setMinSize(try codec.decode(desktop.Size, a, json)) //
        else if (eql(u8, op, "setMaxSize")) try w.setMaxSize(try codec.decode(desktop.Size, a, json)) //
        else if (eql(u8, op, "setPosition")) try w.setPosition(try codec.decode(desktop.Position, a, json)) //
        else if (eql(u8, op, "setResizable")) try w.setResizable(try codec.decode(bool, a, json)) //
        else if (eql(u8, op, "setAlwaysOnTop")) try w.setAlwaysOnTop(try codec.decode(bool, a, json)) //
        else if (eql(u8, op, "setFullscreen")) w.setFullscreen(try codec.decode(bool, a, json)) //
        else if (eql(u8, op, "size")) return codec.encode(a, try w.size()) //
        else if (eql(u8, op, "position")) return codec.encode(a, try w.position()) //
        else if (eql(u8, op, "state")) return codec.encode(a, w.state()) //
        else if (eql(u8, op, "screen")) return codec.encode(a, try w.screen(a)) //
        else return error.InvalidArgument;
        return "null";
    }

    fn screensBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const shell = fromUser(user);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const list = desktop.screens(shell.runtime, arena.allocator()) catch |err| return throwError(call, err);
        const json = codec.encode(arena.allocator(), list) catch return zg.zg_call_throw(call, "plume:OutOfMemory");
        return zg.zg_value_json(call, json.ptr, json.len);
    }

    /// __plume.clipboard("readText") or ("writeText", text).
    fn clipboardBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const shell = fromUser(user);
        const clipboard: desktop.Clipboard = .{ .runtime = shell.runtime };
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
        const shell = fromUser(user);
        var promise: ?*zg.zg_promise = null;
        const value = zg.zg_call_promise(call, &promise);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const kind = argString(call, 0) orelse "";
        const json = argString(call, 1) orelse "null";
        const shown = if (std.mem.eql(u8, kind, "message")) blk: {
            const box = codec.decode(desktop.MessageBox, arena.allocator(), json) catch break :blk error.InvalidArgument;
            break :blk desktop.showMessageBox(shell.window, box, promise, resolveButton);
        } else blk: {
            const dialog = codec.decode(desktop.FileDialog, arena.allocator(), json) catch break :blk error.InvalidArgument;
            break :blk desktop.showFileDialog(shell.window, dialog, promise, resolvePaths);
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
        const shell = fromUser(user);
        if (shell.native_menus) return zg.zg_value_null(call);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const json = codec.encode(arena.allocator(), shell.menus.bar) catch return zg.zg_value_null(call);
        return zg.zg_value_json(call, json.ptr, json.len);
    }

    /// An item of a menu the page drew was chosen.
    fn menuChosenBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const shell = fromUser(user);
        const id = argString(call, 0) orelse return null;
        if (shell.menus.numbers.contains(id)) shell.chosen(id);
        return null;
    }

    /// __plume.popup(items json, x, y): the page's own popup menu, native;
    /// resolves with the chosen id, or null.
    fn popupBinding(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
        const shell = fromUser(user);
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
        if (shell.popup) |previous| zg.zg_promise_resolve(previous, "null", 4);
        shell.popup = promise;
        shell.popupMenu(items, x, y) catch |err| {
            shell.popup = null;
            var buffer: [64]u8 = undefined;
            zg.zg_promise_reject(promise, errorMessage(&buffer, err));
        };
        return value;
    }
};

fn Thunk(comptime C: type, comptime T: type, comptime handler: anytype) type {
    return struct {
        fn call(opaque_context: ?*anyopaque, value: T) void {
            const result = handler(fromOpaque(C, opaque_context), value);
            if (@typeInfo(@TypeOf(result)) == .error_union) {
                _ = result catch |err| std.log.err("plume: a handler failed: {s}", .{@errorName(err)});
            }
        }
    };
}

fn fromUser(user: ?*anyopaque) *Shell {
    return @ptrCast(@alignCast(user.?));
}

fn argString(call: ?*zg.zg_call, index: usize) ?[]const u8 {
    if (index >= zg.zg_call_argc(call) or zg.zg_call_arg_type(call, index) != zg.ZG_TYPE_STRING) return null;
    var length: usize = 0;
    const text = zg.zg_call_arg_string(call, index, &length) orelse return null;
    return text[0..length];
}

fn throwError(call: ?*zg.zg_call, err: anyerror) ?*zg.zg_value {
    var buffer: [64]u8 = undefined;
    return zg.zg_call_throw(call, errorMessage(&buffer, err));
}

/// "plume:<ErrorName>", which bindings.ts turns into a PlumeError.
fn errorMessage(buffer: []u8, err: anyerror) [*:0]const u8 {
    const message: [:0]const u8 = std.mem.printSentinel(buffer, "plume:{s}", .{@errorName(err)}, 0) catch "plume:Error";
    return message.ptr;
}

fn slice(pointer: [*c]const u8, length: usize) []const u8 {
    return if (pointer == null) "" else pointer[0..length];
}

fn toOpaque(context: anytype) ?*anyopaque {
    const C = @TypeOf(context);
    return switch (@typeInfo(C)) {
        .null => null,
        .optional => if (context) |pointer| @ptrCast(@constCast(pointer)) else null,
        .pointer => @ptrCast(@constCast(context)),
        else => @compileError("a handler's context is a pointer (or null), not " ++ @typeName(C)),
    };
}

fn fromOpaque(comptime C: type, pointer: ?*anyopaque) C {
    return switch (@typeInfo(C)) {
        .null => null,
        .optional => @ptrCast(@alignCast(pointer)),
        else => @ptrCast(@alignCast(pointer.?)),
    };
}
