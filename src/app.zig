//! A desktop application: the engine's runtime, a context for the
//! application's data, a window and its page, with the frontend embedded in
//! the binary and served under app://localhost/.
//!
//!     var app = try plume.App.init(.{ .title = "Notes", .assets = @embedFile("frontend") });
//!     defer app.deinit();
//!     try app.bind("Notes", Notes, &notes);
//!     app.run();
//!
//! Everything here runs on the runtime thread (the one that called init),
//! except emit, events().emit and dispatch, which any thread may call.

const std = @import("std");
const zg = @import("zerog");
const bindings = @import("bindings.zig");
const desktop = @import("desktop.zig");
const dom = @import("dom.zig");
const menu = @import("menu.zig");
const plume_events = @import("events.zig");
const shell_module = @import("shell.zig");
const single_instance = @import("single_instance.zig");

pub const Options = struct {
    title: [:0]const u8 = "Plume",
    /// Logical pixels.
    width: u32 = 1024,
    height: u32 = 768,
    resizable: bool = true,
    /// No system frame: the page draws its own and marks the regions that
    /// move the window with the CSS property --zg-app-region: drag.
    frameless: bool = false,
    /// What the page leaves transparent shows the desktop behind the window.
    transparent: bool = false,
    /// The application's reverse-DNS name ("com.example.notes"): where its data
    /// (cookies, localStorage, IndexedDB) is kept, and on Linux its windows'
    /// name for the desktop. Null: nothing is kept between runs.
    app_id: ?[:0]const u8 = null,
    /// The frontend, packed at build time (plume's addFrontend) and served
    /// under app://localhost/.
    assets: ?[]const u8 = null,
    /// The page to load; default app://localhost/index.html.
    url: ?[:0]const u8 = null,
    /// During development: the frontend's dev server ("http://localhost:5173"),
    /// loaded instead of the assets and trusted with the bindings (in the
    /// engine's dev profile only).
    dev_server_url: ?[:0]const u8 = null,
    /// The program's Io (main's `init.io`): what bindings declaring a
    /// std.Io parameter get. Null: std's global single-threaded one.
    io: ?std.Io = null,
    /// The window's icon, RGBA8 rows top to bottom (on Windows a window has
    /// the executable's icon without it: addApp embeds the project's).
    icon: ?Icon = null,
    /// What prefers-color-scheme tells the page, and the look of its form
    /// controls and the window's frame: the desktop's (followed as it
    /// changes), or always light or dark.
    color_scheme: ColorScheme = .system,
    /// One instance per user: a second launch hands its arguments to this
    /// one (app.onSecondInstance, the page's "instance:launched" event) and
    /// exits from init. The value names the application (its app_id).
    single_instance: ?SingleInstance = null,
};

pub const ColorScheme = enum { system, light, dark };

pub const Icon = struct { rgba: []const u8, width: u32, height: u32 };

pub const SingleInstance = struct {
    id: []const u8,
    /// This launch's arguments, the program's name first.
    args: []const []const u8 = &.{},
};

/// A second launch of a single-instance application.
pub const Launch = single_instance.Launch;

pub const Error = error{
    /// zg_last_error() says why.
    EngineFailed,
    BindFailed,
    OutOfMemory,
    /// plume.json does not parse.
    InvalidConfig,
};

/// plume.json: what a project's application takes from it (the plume tool
/// reads the rest).
pub const Config = struct {
    name: []const u8 = "app",
    title: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    single_instance: bool = false,
    color_scheme: ColorScheme = .system,
    window: struct {
        width: u32 = 1024,
        height: u32 = 768,
        resizable: bool = true,
        frameless: bool = false,
        transparent: bool = false,
    } = .{},
};

pub const App = struct {
    runtime: *zg.zg_runtime,
    context: *zg.zg_context,
    handle: *zg.zg_window,
    view: *zg.zg_view,
    url: [:0]const u8,
    bus: *plume_events.Bus,
    shell: *shell_module.Shell,
    instance: ?*single_instance.Instance,

    pub fn init(options: Options) Error!App {
        bindings.io = options.io;
        // Before anything shows: a second instance hands over and goes.
        const instance = if (options.single_instance) |single| blk: {
            const cwd = std.Io.Dir.cwd().realPathFileAlloc(io(), ".", std.heap.smp_allocator) catch null;
            defer if (cwd) |path| std.heap.smp_allocator.free(path);
            const claimed = single_instance.Instance.claim(single.id, .{ .args = single.args, .cwd = cwd orelse "" }) catch |err| {
                std.log.err("plume: single instance: {s}", .{@errorName(err)});
                break :blk null;
            };
            break :blk claimed orelse std.process.exit(0);
        } else null;

        var runtime_config = std.mem.zeroes(zg.zg_runtime_config);
        runtime_config.size = @sizeOf(zg.zg_runtime_config);
        const runtime = zg.zg_runtime_create(&runtime_config) orelse return fail("zg_runtime_create");
        errdefer zg.zg_runtime_destroy(runtime);

        var context_config = std.mem.zeroes(zg.zg_context_config);
        context_config.size = @sizeOf(zg.zg_context_config);
        if (options.app_id) |id| context_config.app_id = id else context_config.ephemeral = 1;
        if (options.dev_server_url) |url| context_config.dev_server_url = url;
        const context = zg.zg_context_create(runtime, &context_config) orelse return fail("zg_context_create");
        if (options.assets) |archive| {
            if (zg.zg_context_mount_assets(context, "app", archive.ptr, archive.len) != zg.ZG_OK)
                return fail("zg_context_mount_assets");
        }

        var window_config = std.mem.zeroes(zg.zg_window_config);
        window_config.size = @sizeOf(zg.zg_window_config);
        window_config.title = options.title;
        window_config.width = options.width;
        window_config.height = options.height;
        window_config.fixed_size = @intFromBool(!options.resizable);
        window_config.frameless = @intFromBool(options.frameless);
        window_config.transparent = @intFromBool(options.transparent);
        const native_window = zg.zg_window_create(context, &window_config) orelse return fail("zg_window_create");
        const view = zg.zg_window_view(native_window).?;
        const bus = plume_events.Bus.create(view, @embedFile("runtime.js")) catch return fail("the page runtime");
        errdefer bus.destroy();
        const shell = shell_module.Shell.create(runtime, native_window, view, bus) catch return fail("the window's bindings");
        _ = zg.zg_view_set_color_scheme(view, colorScheme(options.color_scheme));
        if (options.icon) |icon| {
            // Wayland compositors without the icon protocol take the .desktop file's.
            if (icon.rgba.len == @as(usize, icon.width) * icon.height * 4)
                _ = zg.zg_window_set_icon(native_window, icon.rgba.ptr, icon.width, icon.height);
        }

        return .{
            .runtime = runtime,
            .context = context,
            .handle = native_window,
            .view = view,
            .url = options.dev_server_url orelse options.url orelse "app://localhost/index.html",
            .bus = bus,
            .shell = shell,
            .instance = instance,
        };
    }

    /// The application of a Plume project: `project` is the module plume's
    /// addApp generates (@import("plume_project")): plume.json, the frontend
    /// built into the binary, or the dev server plume dev runs. `init` is
    /// main's: its Io for bindings, its arguments for single_instance.
    pub fn initProject(comptime project: type, process: std.process.Init) Error!App {
        // Lives as long as the process: the strings are the window's.
        const allocator = process.arena.allocator();
        const config = std.json.parseFromSliceLeaky(Config, allocator, project.config, .{ .ignore_unknown_fields = true }) catch
            return error.InvalidConfig;
        const app_id = if (config.app_id) |id| try z(allocator, id) else null;
        return App.init(.{
            .title = try z(allocator, config.title orelse config.name),
            .width = config.window.width,
            .height = config.window.height,
            .resizable = config.window.resizable,
            .frameless = config.window.frameless,
            .transparent = config.window.transparent,
            .app_id = app_id,
            .assets = project.assets,
            .dev_server_url = project.dev_url,
            .io = process.io,
            .icon = if (@hasDecl(project, "icon")) if (project.icon) |rgba| .{ .rgba = rgba, .width = 128, .height = 128 } else null else null,
            .color_scheme = config.color_scheme,
            .single_instance = if (config.single_instance) .{
                .id = config.app_id orelse config.name,
                .args = process.minimal.args.toSlice(allocator) catch return error.OutOfMemory,
            } else null,
        });
    }

    fn z(allocator: std.mem.Allocator, text: []const u8) Error![:0]const u8 {
        return allocator.dupeSentinel(u8, text, 0) catch error.OutOfMemory;
    }

    fn io() std.Io {
        return bindings.io orelse std.Io.Threaded.global_single_threaded.io();
    }

    /// Waits for the async bindings still running (they may emit events or
    /// dispatch work) before the engine goes.
    pub fn deinit(app: *App) void {
        while (bindings.running.load(.acquire) > 0)
            std.Io.sleep(io(), .fromMilliseconds(5), .awake) catch {};
        if (app.instance) |instance| instance.stop();
        app.bus.close();
        // The runtime destroys the context, its window and view.
        zg.zg_runtime_destroy(app.runtime);
        app.shell.destroy();
        app.bus.destroy();
    }

    /// Makes `instance`'s methods callable from the page as `name.method(...)`
    /// (plume.bind). Before run(); the instance must outlive the app.
    pub fn bind(app: *App, comptime name: [:0]const u8, comptime T: type, instance: *T) Error!void {
        bindings.bind(app.view, name, T, instance) catch return error.BindFailed;
    }

    /// Loads the page and runs until the window is closed or quit() is called.
    ///
    /// The page's console messages and uncaught errors go to stderr (the
    /// terminal of plume dev, or of a debug build). With the environment
    /// variable PLUME_SMOKE set, the app quits once its page has loaded, and
    /// exits with status 1 if the load failed: a check that a build starts
    /// (CI, plume's tests).
    pub fn run(app: *App) void {
        const smoke = std.c.getenv("PLUME_SMOKE") != null;
        app.shell.installViewCallbacks(smoke);
        if (app.instance) |instance| instance.listen(app, secondLaunch) catch |err|
            std.log.err("plume: single instance: {s}", .{@errorName(err)});
        _ = zg.zg_view_load_url(app.view, app.url);
        _ = zg.zg_runtime_run(app.runtime);
        if (smoke and app.shell.smoke_failed) std.process.exit(1);
    }

    /// Ends run(); from any thread.
    pub fn quit(app: *App) void {
        zg.zg_runtime_quit(app.runtime);
    }

    // ---- Events ----

    /// Dispatches the event `name` with `value` (as JSON) to the page's
    /// Plume.on listeners. Any thread.
    pub fn emit(app: *App, name: []const u8, value: anytype) void {
        app.bus.emit(name, value);
    }

    /// Calls `handler(context, data)` on the runtime thread for each
    /// Plume.emit(name, data) of the page, with `data` decoded into `T`.
    pub fn on(app: *App, name: []const u8, comptime T: type, context: anytype, comptime handler: anytype) Error!void {
        app.bus.on(name, T, context, handler) catch return error.BindFailed;
    }

    /// Typed events, declared as the fields of `E` (a binding type's
    /// `Events`, which bindings.ts types too). A small value: keep it where
    /// worker threads can emit with it.
    pub fn events(app: *App, comptime E: type) plume_events.Events(E) {
        return .{ .bus = app.bus };
    }

    /// Runs `function(context)` on the runtime thread, where the engine (and
    /// app.page(), app.window()) can be used: from a worker thread, an async
    /// binding for instance. At once when called there.
    pub fn dispatch(app: *App, context: anytype, comptime function: anytype) Error!void {
        app.bus.dispatch(context, function) catch return error.BindFailed;
    }

    /// The page's objects (plume.dom). Close it when done.
    pub fn page(app: *App) dom.Error!dom.Page {
        return dom.Page.open(app.view);
    }

    // ---- The window ----

    pub fn window(app: *App) desktop.Window {
        return app.shell.api();
    }

    /// `handler(context, event)` for each WindowEvent (resized, moved,
    /// focus, state, screen, files_dropped).
    pub fn onWindow(app: *App, context: anytype, comptime handler: anytype) Error!void {
        app.shell.onWindow(context, handler) catch return error.OutOfMemory;
    }

    /// `handler(context) bool` when the user asks to close the window (or the
    /// page calls Plume.window.close()): false keeps it open.
    pub fn onClose(app: *App, context: anytype, comptime handler: anytype) void {
        app.shell.onClose(context, handler);
    }

    /// The connected screens, their names in `allocator`.
    pub fn screens(app: *App, allocator: std.mem.Allocator) desktop.Error![]desktop.Screen {
        return desktop.screens(app.runtime, allocator);
    }

    pub fn clipboard(app: *App) desktop.Clipboard {
        return .{ .runtime = app.runtime };
    }

    pub fn setColorScheme(app: *App, scheme: ColorScheme) void {
        _ = zg.zg_view_set_color_scheme(app.view, colorScheme(scheme));
    }

    fn colorScheme(scheme: ColorScheme) zg.zg_color_scheme {
        return switch (scheme) {
            .system => zg.ZG_COLOR_SCHEME_SYSTEM,
            .light => zg.ZG_COLOR_SCHEME_LIGHT,
            .dark => zg.ZG_COLOR_SCHEME_DARK,
        };
    }

    // ---- Menus ----

    /// The window's menu bar (see plume.menu); null removes it.
    pub fn setMenu(app: *App, items: ?[]const menu.Item) shell_module.Shell.MenuError!void {
        return app.shell.setMenu(items);
    }

    pub fn setMenuChecked(app: *App, id: []const u8, checked: bool) shell_module.Shell.MenuError!void {
        return app.shell.setMenuChecked(id, checked);
    }

    pub fn setMenuEnabled(app: *App, id: []const u8, enabled: bool) shell_module.Shell.MenuError!void {
        return app.shell.setMenuEnabled(id, enabled);
    }

    /// A popup menu at (x, y), the page's CSS pixels.
    pub fn popupMenu(app: *App, items: []const menu.Item, x: f32, y: f32) shell_module.Shell.MenuError!void {
        return app.shell.popupMenu(items, x, y);
    }

    /// `handler(context, id)` when an item of the menu bar or of a popup menu
    /// is chosen (the page gets a "menu" event with the id too).
    pub fn onMenu(app: *App, context: anytype, comptime handler: anytype) Error!void {
        app.shell.onMenu(context, handler) catch return error.OutOfMemory;
    }

    // ---- Dialogs ----

    /// A file dialog; `handler(context, paths)` on the runtime thread, with the
    /// chosen paths (empty if cancelled, valid during the call).
    pub fn fileDialog(app: *App, dialog: desktop.FileDialog, context: anytype, comptime handler: anytype) desktop.Error!void {
        const C = @TypeOf(context);
        const Thunk = struct {
            fn call(opaque_context: ?*anyopaque, paths: []const []const u8) void {
                handler(fromOpaque(C, opaque_context), paths);
            }
        };
        return desktop.showFileDialog(app.handle, dialog, toOpaque(context), Thunk.call);
    }

    /// A message box; `handler(context, button_id)` on the runtime thread.
    pub fn messageBox(app: *App, box: desktop.MessageBox, context: anytype, comptime handler: anytype) desktop.Error!void {
        const C = @TypeOf(context);
        const Thunk = struct {
            fn call(opaque_context: ?*anyopaque, button: i32) void {
                handler(fromOpaque(C, opaque_context), button);
            }
        };
        return desktop.showMessageBox(app.handle, box, toOpaque(context), Thunk.call);
    }

    // ---- Single instance ----

    var second_instance: ?struct { context: ?*anyopaque, function: *const fn (?*anyopaque, Launch) void } = null;

    /// `handler(context, launch)` on the runtime thread when the application
    /// is launched again (with single_instance): its arguments and working
    /// directory. The window comes to the front first.
    pub fn onSecondInstance(app: *App, context: anytype, comptime handler: anytype) void {
        _ = app;
        const C = @TypeOf(context);
        const Thunk = struct {
            fn call(opaque_context: ?*anyopaque, launch: Launch) void {
                handler(fromOpaque(C, opaque_context), launch);
            }
        };
        second_instance = .{ .context = toOpaque(context), .function = Thunk.call };
    }

    /// From the instance's listener thread: to the page at once, and to the
    /// runtime thread for the window and the handler.
    fn secondLaunch(context: ?*anyopaque, json: []const u8) void {
        const app: *App = @ptrCast(@alignCast(context.?));
        app.bus.emitJson("instance:launched", json);
        const Task = struct {
            app: *App,
            json: []u8,

            fn run(task: *@This()) void {
                defer {
                    std.heap.smp_allocator.free(task.json);
                    std.heap.smp_allocator.destroy(task);
                }
                const w = task.app.window();
                if (w.state() == .minimized or w.state() == .hidden) {
                    w.show() catch {};
                    w.restore() catch {};
                }
                w.focus() catch {};
                const handler = second_instance orelse return;
                var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
                defer arena.deinit();
                const launch = std.json.parseFromSliceLeaky(Launch, arena.allocator(), task.json, .{ .ignore_unknown_fields = true }) catch return;
                handler.function(handler.context, launch);
            }
        };
        const task = std.heap.smp_allocator.create(Task) catch return;
        task.* = .{ .app = app, .json = std.heap.smp_allocator.dupe(u8, json) catch {
            std.heap.smp_allocator.destroy(task);
            return;
        } };
        app.bus.dispatch(task, Task.run) catch {};
    }

    fn fail(comptime what: []const u8) Error {
        std.log.err(what ++ ": {s}", .{zg.zg_last_error()});
        return error.EngineFailed;
    }
};

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
