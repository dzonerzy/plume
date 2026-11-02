//! The desktop around the page: the window, its screens, the clipboard and
//! the system's dialogs (ZeroG's window API). Runtime thread only: from a
//! worker thread, go through app.dispatch().

const std = @import("std");
const zg = @import("zerog");

pub const Error = error{
    /// Not on this system (window positions on Wayland, for instance).
    Unsupported,
    NotFound,
    /// Taken (a global shortcut another application holds).
    AlreadyExists,
    InvalidArgument,
    /// Called off the runtime thread.
    WrongThread,
    OutOfMemory,
    EngineFailed,
};

pub fn check(result: zg.zg_result) Error!void {
    return switch (result) {
        zg.ZG_OK => {},
        zg.ZG_ERROR_UNSUPPORTED => error.Unsupported,
        zg.ZG_ERROR_NOT_FOUND => error.NotFound,
        zg.ZG_ERROR_ALREADY_EXISTS => error.AlreadyExists,
        zg.ZG_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
        zg.ZG_ERROR_WRONG_THREAD => error.WrongThread,
        zg.ZG_ERROR_OUT_OF_MEMORY => error.OutOfMemory,
        else => error.EngineFailed,
    };
}

/// A NUL-terminated copy of `text` for the engine, from `buffer` when it
/// fits, else from `allocator`.
pub fn cString(allocator: std.mem.Allocator, buffer: []u8, text: []const u8) Error![:0]const u8 {
    if (text.len < buffer.len) {
        @memcpy(buffer[0..text.len], text);
        buffer[text.len] = 0;
        return buffer[0..text.len :0];
    }
    return allocator.dupeSentinel(u8, text, 0) catch error.OutOfMemory;
}

pub const State = enum { normal, minimized, maximized, fullscreen, hidden };
pub const Size = struct { width: u32, height: u32 };
pub const Position = struct { x: i32, y: i32 };
pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };

pub const Screen = struct {
    /// Desktop coordinates, the window system's units.
    bounds: Rect,
    /// The bounds without taskbars, docks and panels.
    work_area: Rect,
    /// Device pixels per logical pixel (1.5 at 150%).
    scale: f32,
    /// Hz; 0 if unknown.
    refresh_rate: f32,
    primary: bool,
    name: []const u8,
};

/// A window's controls (plume.Window's, over the engine's window API).
pub const Controls = struct {
    handle: *zg.zg_window,
    runtime: *zg.zg_runtime,

    pub fn setTitle(window: Controls, title: []const u8) Error!void {
        var buffer: [256]u8 = undefined;
        const text = try cString(std.heap.smp_allocator, &buffer, title);
        defer if (text.ptr != &buffer) std.heap.smp_allocator.free(text);
        zg.zg_window_set_title(window.handle, text.ptr);
    }

    /// Logical pixels, the page's CSS pixels.
    pub fn setSize(window: Controls, size_: Size) Error!void {
        try check(zg.zg_window_set_size(window.handle, size_.width, size_.height));
    }

    pub fn size(window: Controls) Error!Size {
        var width: c_uint = 0;
        var height: c_uint = 0;
        try check(zg.zg_window_get_size(window.handle, &width, &height));
        return .{ .width = width, .height = height };
    }

    /// The smallest size the user can give the window; 0 for no limit.
    pub fn setMinSize(window: Controls, size_: Size) Error!void {
        try check(zg.zg_window_set_min_size(window.handle, size_.width, size_.height));
    }

    /// The largest size the user can give the window; 0 for no limit.
    pub fn setMaxSize(window: Controls, size_: Size) Error!void {
        try check(zg.zg_window_set_max_size(window.handle, size_.width, size_.height));
    }

    pub fn setResizable(window: Controls, resizable: bool) Error!void {
        try check(zg.zg_window_set_resizable(window.handle, @intFromBool(resizable)));
    }

    /// Desktop coordinates (error.Unsupported on Wayland).
    pub fn setPosition(window: Controls, position_: Position) Error!void {
        try check(zg.zg_window_set_position(window.handle, position_.x, position_.y));
    }

    pub fn position(window: Controls) Error!Position {
        var x: c_int = 0;
        var y: c_int = 0;
        try check(zg.zg_window_get_position(window.handle, &x, &y));
        return .{ .x = x, .y = y };
    }

    pub fn center(window: Controls) Error!void {
        try check(zg.zg_window_center(window.handle));
    }

    pub fn minimize(window: Controls) Error!void {
        try check(zg.zg_window_minimize(window.handle));
    }

    pub fn maximize(window: Controls) Error!void {
        try check(zg.zg_window_maximize(window.handle));
    }

    /// Back to normal from minimized, maximized or fullscreen.
    pub fn restore(window: Controls) Error!void {
        if (window.state() == .fullscreen) zg.zg_window_set_fullscreen(window.handle, 0);
        try check(zg.zg_window_restore(window.handle));
    }

    pub fn toggleMaximize(window: Controls) Error!void {
        if (window.state() == .maximized) try window.restore() else try window.maximize();
    }

    pub fn setFullscreen(window: Controls, fullscreen: bool) void {
        zg.zg_window_set_fullscreen(window.handle, @intFromBool(fullscreen));
    }

    pub fn show(window: Controls) Error!void {
        try check(zg.zg_window_show(window.handle));
    }

    pub fn hide(window: Controls) Error!void {
        try check(zg.zg_window_hide(window.handle));
    }

    /// Above the other windows with the keyboard focus, where the window
    /// system allows it (it may only flash in the taskbar).
    pub fn focus(window: Controls) Error!void {
        try check(zg.zg_window_focus(window.handle));
    }

    pub fn setAlwaysOnTop(window: Controls, on_top: bool) Error!void {
        try check(zg.zg_window_set_always_on_top(window.handle, @intFromBool(on_top)));
    }

    pub fn state(window: Controls) State {
        return stateOf(zg.zg_window_get_state(window.handle));
    }

    /// RGBA8 pixels, rows top to bottom.
    pub fn setIcon(window: Controls, rgba: []const u8, width: u32, height: u32) Error!void {
        if (rgba.len != @as(usize, width) * height * 4) return error.InvalidArgument;
        try check(zg.zg_window_set_icon(window.handle, rgba.ptr, width, height));
    }

    /// The screen the window is mostly on; its name in `allocator`.
    pub fn screen(window: Controls, allocator: std.mem.Allocator) Error!Screen {
        var index: usize = 0;
        try check(zg.zg_window_screen(window.handle, &index));
        return screenAt(window.runtime, allocator, index);
    }

    /// The native handle: HWND on Windows, the X11 window or Wayland surface.
    pub fn nativeHandle(window: Controls) ?*anyopaque {
        return zg.zg_window_native_handle(window.handle);
    }
};

pub fn stateOf(state: zg.zg_window_state) State {
    return switch (state) {
        zg.ZG_WINDOW_MINIMIZED => .minimized,
        zg.ZG_WINDOW_MAXIMIZED => .maximized,
        zg.ZG_WINDOW_FULLSCREEN => .fullscreen,
        zg.ZG_WINDOW_HIDDEN => .hidden,
        else => .normal,
    };
}

/// The connected screens, their names in `allocator`.
pub fn screens(runtime: *zg.zg_runtime, allocator: std.mem.Allocator) Error![]Screen {
    const count = zg.zg_screen_count(runtime);
    const result = allocator.alloc(Screen, count) catch return error.OutOfMemory;
    for (result, 0..) |*item, i| item.* = try screenAt(runtime, allocator, i);
    return result;
}

fn screenAt(runtime: *zg.zg_runtime, allocator: std.mem.Allocator, index: usize) Error!Screen {
    var info = std.mem.zeroes(zg.zg_screen);
    info.size = @sizeOf(zg.zg_screen);
    try check(zg.zg_screen_get(runtime, index, &info));
    const name_len = std.mem.indexOfScalar(u8, &info.name, 0) orelse info.name.len;
    return .{
        .bounds = .{ .x = info.x, .y = info.y, .width = info.width, .height = info.height },
        .work_area = .{ .x = info.work_x, .y = info.work_y, .width = info.work_width, .height = info.work_height },
        .scale = info.scale,
        .refresh_rate = info.refresh_rate,
        .primary = info.primary != 0,
        .name = allocator.dupe(u8, info.name[0..name_len]) catch return error.OutOfMemory,
    };
}

// ---- The clipboard ----

/// The system's clipboard (once a window exists).
pub const Clipboard = struct {
    runtime: *zg.zg_runtime,

    /// Its data of a MIME type ("text/plain", "text/html", "image/png"...),
    /// in `allocator`; null if it holds none.
    pub fn read(clipboard: Clipboard, allocator: std.mem.Allocator, mime_type: [:0]const u8) Error!?[]u8 {
        var data: [*c]u8 = null;
        var length: usize = 0;
        const result = zg.zg_clipboard_read(clipboard.runtime, mime_type.ptr, &data, &length);
        if (result == zg.ZG_ERROR_NOT_FOUND) return null;
        try check(result);
        defer zg.zg_free(data);
        return allocator.dupe(u8, data[0..length]) catch error.OutOfMemory;
    }

    pub fn readText(clipboard: Clipboard, allocator: std.mem.Allocator) Error!?[]u8 {
        return clipboard.read(allocator, "text/plain");
    }

    /// Replaces its contents with one item per type.
    pub fn write(clipboard: Clipboard, items: []const struct { mime_type: [:0]const u8, data: []const u8 }) Error!void {
        var types: [8][*c]const u8 = undefined;
        var datas: [8]?*const anyopaque = undefined;
        var lengths: [8]usize = undefined;
        if (items.len > types.len) return error.InvalidArgument;
        for (items, 0..) |item, i| {
            types[i] = item.mime_type.ptr;
            datas[i] = item.data.ptr;
            lengths[i] = item.data.len;
        }
        try check(zg.zg_clipboard_write(clipboard.runtime, items.len, &types, &datas, &lengths));
    }

    pub fn writeText(clipboard: Clipboard, text: []const u8) Error!void {
        try clipboard.write(&.{.{ .mime_type = "text/plain", .data = text }});
    }

    /// HTML, with its text for the applications that take only text.
    pub fn writeHtml(clipboard: Clipboard, html: []const u8, text: []const u8) Error!void {
        try clipboard.write(&.{ .{ .mime_type = "text/html", .data = html }, .{ .mime_type = "text/plain", .data = text } });
    }
};

// ---- Dialogs ----

pub const FileFilter = struct {
    /// "Images"
    name: []const u8,
    /// Extensions separated by ';' ("png;jpg"), or "*".
    pattern: []const u8,
};

pub const FileDialog = struct {
    pub const Kind = enum { open, open_folder, save };
    kind: Kind = .open,
    /// Null: the system's.
    title: ?[]const u8 = null,
    /// The accept button's label; null: the system's.
    accept_label: ?[]const u8 = null,
    /// A folder to start in, or (save) a suggested file path.
    location: ?[]const u8 = null,
    /// Not for open_folder.
    filters: []const FileFilter = &.{},
    /// open and open_folder: several may be chosen.
    multiple: bool = false,
};

pub const MessageBox = struct {
    pub const Kind = enum { info, warning, @"error" };
    pub const Button = struct {
        id: i32,
        label: []const u8,
        /// Chosen by Enter.
        default: bool = false,
        /// Chosen by Escape and by closing the box.
        cancel: bool = false,
    };
    kind: Kind = .info,
    title: []const u8 = "",
    message: []const u8,
    /// In display order; none: one "OK", id 0.
    buttons: []const Button = &.{},
};

/// The chosen paths (empty if the user cancelled), valid during the call.
pub const FileDialogFn = *const fn (context: ?*anyopaque, paths: []const []const u8) void;
/// The chosen button's id (the cancel one if the box was closed, -1 if none).
pub const MessageBoxFn = *const fn (context: ?*anyopaque, button: i32) void;

/// Shows a file dialog, modal to `window`; `done(context, paths)` gets the
/// answer later, on the runtime thread, exactly once.
pub fn showFileDialog(window: *zg.zg_window, dialog: FileDialog, context: ?*anyopaque, done: FileDialogFn) Error!void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const filters = a.alloc(zg.zg_file_filter, dialog.filters.len) catch return error.OutOfMemory;
    for (dialog.filters, filters) |filter, *out| out.* = .{
        .name = (a.dupeSentinel(u8, filter.name, 0) catch return error.OutOfMemory).ptr,
        .pattern = (a.dupeSentinel(u8, filter.pattern, 0) catch return error.OutOfMemory).ptr,
    };
    var config = std.mem.zeroes(zg.zg_file_dialog);
    config.size = @sizeOf(zg.zg_file_dialog);
    config.kind = switch (dialog.kind) {
        .open => zg.ZG_FILE_DIALOG_OPEN,
        .open_folder => zg.ZG_FILE_DIALOG_OPEN_FOLDER,
        .save => zg.ZG_FILE_DIALOG_SAVE,
    };
    config.title = try optionalC(a, dialog.title);
    config.accept_label = try optionalC(a, dialog.accept_label);
    config.location = try optionalC(a, dialog.location);
    config.filters = filters.ptr;
    config.filter_count = filters.len;
    config.multiple = @intFromBool(dialog.multiple);

    const request = std.heap.smp_allocator.create(FileRequest) catch return error.OutOfMemory;
    request.* = .{ .context = context, .done = done };
    check(zg.zg_window_file_dialog(window, &config, FileRequest.answer, request)) catch |err| {
        std.heap.smp_allocator.destroy(request);
        return err;
    };
}

const FileRequest = struct {
    context: ?*anyopaque,
    done: FileDialogFn,

    fn answer(window: ?*zg.zg_window, result: zg.zg_result, paths: [*c]const [*c]const u8, count: usize, user: ?*anyopaque) callconv(.c) void {
        _ = window;
        const request: *FileRequest = @ptrCast(@alignCast(user.?));
        defer std.heap.smp_allocator.destroy(request);
        if (result != zg.ZG_OK) std.log.warn("plume: the file dialog failed: {s}", .{zg.zg_last_error()});
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(std.heap.smp_allocator);
        if (result == zg.ZG_OK) for (0..count) |i| {
            list.append(std.heap.smp_allocator, std.mem.span(paths[i])) catch break;
        };
        request.done(request.context, list.items);
    }
};

/// Shows a message box, modal to `window`; `done(context, button)` gets the
/// answer later, on the runtime thread, exactly once.
pub fn showMessageBox(window: *zg.zg_window, box: MessageBox, context: ?*anyopaque, done: MessageBoxFn) Error!void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const buttons = a.alloc(zg.zg_message_button, box.buttons.len) catch return error.OutOfMemory;
    for (box.buttons, buttons) |button, *out| out.* = .{
        .id = button.id,
        .label = (a.dupeSentinel(u8, button.label, 0) catch return error.OutOfMemory).ptr,
        .flags = (if (button.default) @as(c_uint, zg.ZG_MESSAGE_BUTTON_DEFAULT) else 0) |
            (if (button.cancel) @as(c_uint, zg.ZG_MESSAGE_BUTTON_CANCEL) else 0),
    };
    var config = std.mem.zeroes(zg.zg_message_box);
    config.size = @sizeOf(zg.zg_message_box);
    config.kind = switch (box.kind) {
        .info => zg.ZG_MESSAGE_INFO,
        .warning => zg.ZG_MESSAGE_WARNING,
        .@"error" => zg.ZG_MESSAGE_ERROR,
    };
    config.title = (a.dupeSentinel(u8, box.title, 0) catch return error.OutOfMemory).ptr;
    config.message = (a.dupeSentinel(u8, box.message, 0) catch return error.OutOfMemory).ptr;
    config.buttons = buttons.ptr;
    config.button_count = buttons.len;

    const request = std.heap.smp_allocator.create(MessageRequest) catch return error.OutOfMemory;
    request.* = .{ .context = context, .done = done };
    check(zg.zg_window_message_box(window, &config, MessageRequest.answer, request)) catch |err| {
        std.heap.smp_allocator.destroy(request);
        return err;
    };
}

const MessageRequest = struct {
    context: ?*anyopaque,
    done: MessageBoxFn,

    fn answer(window: ?*zg.zg_window, result: zg.zg_result, button: c_int, user: ?*anyopaque) callconv(.c) void {
        _ = window;
        const request: *MessageRequest = @ptrCast(@alignCast(user.?));
        defer std.heap.smp_allocator.destroy(request);
        if (result != zg.ZG_OK) std.log.warn("plume: the message box failed: {s}", .{zg.zg_last_error()});
        request.done(request.context, if (result == zg.ZG_OK) button else -1);
    }
};

fn optionalC(allocator: std.mem.Allocator, text: ?[]const u8) Error![*c]const u8 {
    const value = text orelse return null;
    return (allocator.dupeSentinel(u8, value, 0) catch return error.OutOfMemory).ptr;
}
