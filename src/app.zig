//! A desktop application: the engine's runtime, a context for the
//! application's data, its windows and their pages, with the frontend
//! embedded in the binary and served under app://localhost/; and what it
//! has of the desktop around them: tray icons, notifications, global
//! shortcuts, starting at login, opening links with the system.
//!
//!     const app = try plume.App.init(.{ .title = "Notes", .assets = @embedFile("frontend") });
//!     defer app.deinit();
//!     try app.bind("Notes", Notes, &notes);
//!     app.run();
//!
//! Everything here runs on the runtime thread (the one that called init),
//! except emit, events().emit, dispatch and quit, which any thread may call.

const std = @import("std");
const zg = @import("zerog");
const bindings = @import("bindings.zig");
const codec = @import("codec.zig");
const desktop = @import("desktop.zig");
const dom = @import("dom.zig");
const menu = @import("menu.zig");
const plume_events = @import("events.zig");
const single_instance = @import("single_instance.zig");
const system = @import("system.zig");
const tray_module = @import("tray.zig");
const update = @import("update.zig");
const window_module = @import("window.zig");

pub const Window = window_module.Window;
pub const WindowOptions = window_module.Options;
pub const Tray = tray_module.Tray;

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
    /// The main window starts hidden (a tray application's, for one).
    hidden: bool = false,
    /// The application's reverse-DNS name ("com.example.notes"): where its data
    /// (cookies, localStorage, IndexedDB) is kept, its notifications' sender,
    /// its entry to start at login, and on Linux its windows' name for the
    /// desktop. Null: nothing is kept between runs.
    app_id: ?[:0]const u8 = null,
    /// A short name (plume.json's "name"): what identifies the application
    /// without an app_id, and names its update downloads.
    name: ?[]const u8 = null,
    /// This build's version ("1.2.3"): what updates compare with.
    version: []const u8 = "0.0.0",
    /// Where updates come from (plume.update); null: none.
    update: ?update.Config = null,
    /// The frontend, packed at build time (plume's addFrontend) and served
    /// under app://localhost/.
    assets: ?[]const u8 = null,
    /// The main window's page: a page of the frontend ("index.html") or an
    /// absolute URL.
    url: []const u8 = "index.html",
    /// During development: the frontend's dev server ("http://localhost:5173"),
    /// whose pages are loaded instead of the assets and trusted with the
    /// bindings (in the engine's dev profile only).
    dev_server_url: ?[:0]const u8 = null,
    /// The program's Io (main's `init.io`): what bindings declaring a
    /// std.Io parameter get. Null: std's global single-threaded one.
    io: ?std.Io = null,
    /// The program's arguments, its name first (Plume.app.args() in pages).
    args: []const []const u8 = &.{},
    /// The windows' and the tray's icon, RGBA8 rows top to bottom (on
    /// Windows a window has the executable's: addApp embeds the project's).
    icon: ?Icon = null,
    /// The icon as a PNG file's bytes: what notifications show.
    icon_png: ?[]const u8 = null,
    /// What prefers-color-scheme tells the pages, and the look of their form
    /// controls, the windows' frames and menus: the desktop's (followed as it
    /// changes), or always light or dark.
    color_scheme: ColorScheme = .system,
    /// One instance per user: a second launch hands its arguments to this
    /// one (app.onSecondInstance, the pages' "instance:launched" event) and
    /// exits from init. The value names the application (its app_id).
    single_instance: ?SingleInstance = null,
    /// No window: the main page is rendered into memory, at this device
    /// scale (plume.testing drives it). Not for run().
    headless: ?Headless = null,
};

pub const Headless = struct { scale: f32 = 1 };

/// The process's runtime once a headless app made it (zg_runtime_create
/// works once per process): the next headless apps take it.
var headless_runtime: ?*zg.zg_runtime = null;

pub const ColorScheme = enum { system, light, dark };

pub const Icon = struct { rgba: []const u8, width: u32, height: u32 };

pub const SingleInstance = struct {
    id: []const u8,
    /// This launch's arguments, the program's name first.
    args: []const []const u8 = &.{},
};

/// A second launch of a single-instance application.
pub const Launch = single_instance.Launch;

/// A notification (app.notify): a title, a body, up to three buttons. A
/// notification with the tag of one still shown replaces it.
pub const Notification = struct {
    title: []const u8,
    body: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    actions: []const []const u8 = &.{},
};

/// A notification clicked (`action` -1) or one of its buttons (its index).
pub const NotificationAction = struct { tag: []const u8, action: i32 };

/// An item chosen in a context menu (app.setContextMenu): the menu's name,
/// the item's id, and the data-plume-menu-data of the element clicked.
pub const ContextMenuChoice = struct { menu: []const u8, id: []const u8, data: []const u8 };

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
    /// As plume's tools default it (the executable's resources, packages).
    version: []const u8 = "0.1.0",
    update: ?update.Config = null,
    single_instance: bool = false,
    color_scheme: ColorScheme = .system,
    window: struct {
        width: u32 = 1024,
        height: u32 = 768,
        resizable: bool = true,
        frameless: bool = false,
        transparent: bool = false,
        hidden: bool = false,
    } = .{},
};

pub const App = struct {
    runtime: *zg.zg_runtime,
    context: *zg.zg_context,
    bus: *plume_events.Bus,
    /// Every open window, the main one first.
    windows: std.ArrayList(*Window) = .empty,
    main_window: *Window = undefined,
    instance: ?*single_instance.Instance,

    // What windows take when created.
    color_scheme: zg.zg_color_scheme,
    icon: ?Icon,
    smoke: bool,
    smoke_failed: bool = false,
    dev_profile: bool,

    /// Owned: the application's names, where pages are, its arguments.
    strings: std.heap.ArenaAllocator,
    title: []const u8,
    app_id: ?[]const u8,
    name: []const u8,
    /// "app://localhost/" or the dev server's, with the final '/'.
    base_url: []const u8,
    start_url: []const u8,
    args: []const []const u8,
    icon_png: ?[]const u8,
    version: []const u8,
    update_config: ?update.Config,

    bound: std.ArrayList(Bound) = .empty,
    shutdowns: std.ArrayList(Hook) = .empty,
    startups: std.ArrayList(StartupHook) = .empty,
    menu_handlers: std.ArrayList(Handler([]const u8)) = .empty,
    context_handlers: std.ArrayList(Handler(ContextMenuChoice)) = .empty,
    notification_handlers: std.ArrayList(Handler(NotificationAction)) = .empty,
    shortcut_handlers: std.ArrayList(Handler([]const u8)) = .empty,
    external_handler: ?struct { context: ?*anyopaque, function: *const fn (?*anyopaque, []const u8) bool } = null,
    second_instance: ?struct { context: ?*anyopaque, function: *const fn (?*anyopaque, Launch) void } = null,
    /// Declarative context menus by name (data-plume-menu), in `strings`.
    context_menus: std.StringHashMapUnmanaged([]const menu.Item) = .empty,
    trays: std.ArrayList(*Tray) = .empty,
    notifications_ready: bool = false,
    /// Global shortcuts' names: id - 1 → name ("" once unregistered).
    shortcuts: std.ArrayList([]const u8) = .empty,
    shortcut_callback: bool = false,

    const allocator = std.heap.smp_allocator;

    fn Handler(comptime T: type) type {
        return struct { context: ?*anyopaque, function: *const fn (?*anyopaque, T) void };
    }

    const Bound = struct { instance: *anyopaque, apply: *const fn (*zg.zg_view, *anyopaque) bindings.BindError!void };
    const Hook = struct { instance: *anyopaque, function: *const fn (*anyopaque) void };
    const StartupHook = struct { instance: *anyopaque, function: *const fn (*anyopaque, *App) void };

    pub fn init(options: Options) Error!*App {
        bindings.io = options.io;
        // An update being checked (update.zig): it starts, says its version, ends.
        if (std.c.getenv("PLUME_VERIFY") != null) {
            var buffer: [128]u8 = undefined;
            var stdout: std.Io.File.Writer = .init(.stdout(), io(), &buffer);
            stdout.interface.print("plume-verify {s}\n", .{options.version}) catch {};
            stdout.interface.flush() catch {};
            std.process.exit(0);
        }
        // What an update left behind.
        if (options.update != null) {
            if (std.Thread.spawn(.{}, update.cleanup, .{io()})) |thread| thread.detach() else |_| {}
        }
        // Before anything shows: a second instance hands over and goes.
        const instance = if (options.single_instance != null and options.headless != null) null else if (options.single_instance) |single| blk: {
            const cwd = std.Io.Dir.cwd().realPathFileAlloc(io(), ".", allocator) catch null;
            defer if (cwd) |path| allocator.free(path);
            const claimed = single_instance.Instance.claim(single.id, .{ .args = single.args, .cwd = cwd orelse "" }) catch |err| {
                std.log.err("plume: single instance: {s}", .{@errorName(err)});
                break :blk null;
            };
            break :blk claimed orelse std.process.exit(0);
        } else null;

        // One runtime per process: headless apps (a test run's, one after the
        // other) share one, kept to the end of the process.
        const runtime = if (options.headless != null and headless_runtime != null) headless_runtime.? else blk: {
            var runtime_config = std.mem.zeroes(zg.zg_runtime_config);
            runtime_config.size = @sizeOf(zg.zg_runtime_config);
            const created = zg.zg_runtime_create(&runtime_config) orelse return fail("zg_runtime_create");
            if (options.headless != null) headless_runtime = created;
            break :blk created;
        };
        errdefer if (options.headless == null) zg.zg_runtime_destroy(runtime);

        var context_config = std.mem.zeroes(zg.zg_context_config);
        context_config.size = @sizeOf(zg.zg_context_config);
        if (options.app_id) |name| context_config.app_id = name else context_config.ephemeral = 1;
        if (options.dev_server_url) |url| context_config.dev_server_url = url;
        const context = zg.zg_context_create(runtime, &context_config) orelse return fail("zg_context_create");
        errdefer if (options.headless != null) zg.zg_context_destroy(context);
        if (options.assets) |archive| {
            if (zg.zg_context_mount_assets(context, "app", archive.ptr, archive.len) != zg.ZG_OK)
                return fail("zg_context_mount_assets");
        }

        const app = try allocator.create(App);
        errdefer allocator.destroy(app);
        const version = zg.zg_version();
        app.* = .{
            .runtime = runtime,
            .context = context,
            .bus = undefined,
            .instance = instance,
            .color_scheme = colorScheme(options.color_scheme),
            .icon = null,
            .smoke = std.c.getenv("PLUME_SMOKE") != null,
            .dev_profile = version.profile != null and std.mem.eql(u8, std.mem.span(version.profile), "dev"),
            .strings = .init(allocator),
            .title = undefined,
            .app_id = null,
            .name = undefined,
            .base_url = undefined,
            .start_url = undefined,
            .args = &.{},
            .icon_png = options.icon_png,
            .version = undefined,
            .update_config = null,
        };
        errdefer app.strings.deinit();
        const a = app.strings.allocator();
        app.title = try a.dupe(u8, options.title);
        app.app_id = if (options.app_id) |name| try a.dupe(u8, name) else null;
        app.name = try a.dupe(u8, options.name orelse options.app_id orelse options.title);
        app.base_url = if (options.dev_server_url) |url|
            (if (std.mem.endsWith(u8, url, "/")) try a.dupe(u8, url) else try std.mem.concat(a, u8, &.{ url, "/" }))
        else
            "app://localhost/";
        app.start_url = try a.dupe(u8, options.url);
        app.version = try a.dupe(u8, options.version);
        if (options.update) |config| app.update_config = .{
            .github = try a.dupe(u8, config.github),
            .public_key = try a.dupe(u8, config.public_key),
            .api_url = try a.dupe(u8, config.api_url),
        };
        const args = try a.alloc([]const u8, options.args.len);
        for (args, options.args) |*copy, arg| copy.* = try a.dupe(u8, arg);
        app.args = args;
        if (options.icon) |icon| {
            if (icon.rgba.len == @as(usize, icon.width) * icon.height * 4) app.icon = icon;
        }

        app.bus = plume_events.Bus.create(runtime) catch return error.OutOfMemory;
        errdefer app.bus.destroy();
        app.main_window = if (options.headless) |headless|
            Window.createHeadless(app, options.width, options.height, headless.scale, true) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.BindFailed => error.BindFailed,
                error.EngineFailed => error.EngineFailed,
            }
        else Window.create(app, .{
            .title = options.title,
            .width = options.width,
            .height = options.height,
            .resizable = options.resizable,
            .frameless = options.frameless,
            .transparent = options.transparent,
            .hidden = options.hidden,
            .url = options.url,
        }, true) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.BindFailed => error.BindFailed,
            error.EngineFailed => error.EngineFailed,
        };
        try app.windows.append(allocator, app.main_window);
        return app;
    }

    /// The application of a Plume project: `project` is the module plume's
    /// addApp generates (@import("plume_project")): plume.json, the frontend
    /// built into the binary, or the dev server plume dev runs. `init` is
    /// main's: its Io for bindings, its arguments.
    pub fn initProject(comptime project: type, process: std.process.Init) Error!*App {
        // Lives as long as the process: the strings are the window's.
        const a = process.arena.allocator();
        const args = process.minimal.args.toSlice(a) catch return error.OutOfMemory;
        return App.init(try projectOptions(project, a, process.io, args));
    }

    /// The options initProject gives init, from the project's plume.json (in
    /// `a`, which must outlive the app): plume.testing starts a project's app
    /// headless with them.
    pub fn projectOptions(comptime project: type, a: std.mem.Allocator, program_io: ?std.Io, args: []const []const u8) Error!Options {
        const config = std.json.parseFromSliceLeaky(Config, a, project.config, .{ .ignore_unknown_fields = true }) catch
            return error.InvalidConfig;
        const app_id = if (config.app_id) |name| try z(a, name) else null;
        const icon_size = if (@hasDecl(project, "icon_size")) project.icon_size else 128;
        return .{
            .title = try z(a, config.title orelse config.name),
            .width = config.window.width,
            .height = config.window.height,
            .resizable = config.window.resizable,
            .frameless = config.window.frameless,
            .transparent = config.window.transparent,
            .hidden = config.window.hidden,
            .app_id = app_id,
            .name = config.name,
            .version = config.version,
            .update = config.update,
            .assets = project.assets,
            .dev_server_url = project.dev_url,
            .io = program_io,
            .args = args,
            .icon = if (@hasDecl(project, "icon")) if (project.icon) |rgba| .{ .rgba = rgba, .width = icon_size, .height = icon_size } else null else null,
            .icon_png = if (@hasDecl(project, "icon_png")) project.icon_png else null,
            .color_scheme = config.color_scheme,
            .single_instance = if (config.single_instance) .{ .id = config.app_id orelse config.name, .args = args } else null,
        };
    }

    fn z(a: std.mem.Allocator, text: []const u8) Error![:0]const u8 {
        return a.dupeSentinel(u8, text, 0) catch error.OutOfMemory;
    }

    fn io() std.Io {
        return bindings.io orelse std.Io.Threaded.global_single_threaded.io();
    }

    /// The program's Io (Options.io), or std's global single-threaded one.
    pub fn programIo(app: *const App) std.Io {
        _ = app;
        return io();
    }

    /// Waits for the async bindings still running (they may emit events or
    /// dispatch work), runs the bound types' shutdown, then ends the engine.
    pub fn deinit(app: *App) void {
        while (bindings.running.load(.acquire) > 0)
            std.Io.sleep(io(), .fromMilliseconds(5), .awake) catch {};
        var i = app.shutdowns.items.len;
        while (i > 0) {
            i -= 1;
            app.shutdowns.items[i].function(app.shutdowns.items[i].instance);
        }
        if (app.instance) |instance| instance.stop();
        const headless = app.main_window.isHeadless();
        for (app.trays.items) |t| t.destroy();
        for (app.windows.items) |w| w.destroy();
        // The process's runtime stays for the next headless app.
        if (headless) {
            // Work posted for this app's bus runs before the bus goes.
            zg.zg_runtime_update(app.runtime);
            zg.zg_context_destroy(app.context);
        } else zg.zg_runtime_destroy(app.runtime);
        app.bus.destroy();
        app.windows.deinit(allocator);
        app.trays.deinit(allocator);
        app.bound.deinit(allocator);
        app.shutdowns.deinit(allocator);
        app.startups.deinit(allocator);
        app.menu_handlers.deinit(allocator);
        app.context_handlers.deinit(allocator);
        app.notification_handlers.deinit(allocator);
        app.shortcut_handlers.deinit(allocator);
        app.context_menus.deinit(allocator);
        app.shortcuts.deinit(allocator);
        app.strings.deinit();
        allocator.destroy(app);
    }

    /// What identifies the application to the system: its app_id, else its
    /// name.
    pub fn id(app: *const App) []const u8 {
        return app.app_id orelse app.name;
    }

    /// Makes `instance`'s methods callable from every window's pages as
    /// `name.method(...)` (plume.bind), those of windows opened later too.
    /// The instance must outlive the app.
    ///
    /// Two methods are the application's, not the pages': `startup(self,
    /// app: *plume.App)` runs when run() starts, before the main window's
    /// page loads; `shutdown(self)` in deinit, before the engine goes (in
    /// the reverse order of the binds).
    pub fn bind(app: *App, comptime name: [:0]const u8, comptime T: type, instance: *T) Error!void {
        const Apply = struct {
            fn apply(view: *zg.zg_view, opaque_instance: *anyopaque) bindings.BindError!void {
                return bindings.bind(view, name, T, @ptrCast(@alignCast(opaque_instance)));
            }
            fn startup(opaque_instance: *anyopaque, plume_app: *App) void {
                const self: *T = @ptrCast(@alignCast(opaque_instance));
                const params = @typeInfo(@TypeOf(T.startup)).@"fn".param_types.len;
                const result = if (params == 1) T.startup(self) else T.startup(self, plume_app);
                if (@typeInfo(@TypeOf(result)) == .error_union) {
                    _ = result catch |err| std.log.err("plume: {s}.startup failed: {s}", .{ name, @errorName(err) });
                }
            }
            fn shutdown(opaque_instance: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(opaque_instance));
                const result = T.shutdown(self);
                if (@typeInfo(@TypeOf(result)) == .error_union) {
                    _ = result catch |err| std.log.err("plume: {s}.shutdown failed: {s}", .{ name, @errorName(err) });
                }
            }
        };
        for (app.windows.items) |w| Apply.apply(w.view, instance) catch return error.BindFailed;
        try app.bound.append(allocator, .{ .instance = instance, .apply = Apply.apply });
        if (@hasDecl(T, "startup")) try app.startups.append(allocator, .{ .instance = instance, .function = Apply.startup });
        if (@hasDecl(T, "shutdown")) try app.shutdowns.append(allocator, .{ .instance = instance, .function = Apply.shutdown });
    }

    /// For a new window: what bind() bound.
    pub fn applyBindings(app: *App, view: *zg.zg_view) error{BindFailed}!void {
        for (app.bound.items) |b| try b.apply(view, b.instance);
    }

    /// Loads the main window's page and runs until the main window is closed
    /// or quit() is called.
    ///
    /// The pages' console messages and uncaught errors go to stderr (the
    /// terminal of plume dev, or of a debug build). With the environment
    /// variable PLUME_SMOKE set, the app quits once its main page has
    /// loaded, and exits with status 1 if the load failed: a check that a
    /// build starts (CI, plume's tests).
    pub fn run(app: *App) void {
        if (app.instance) |instance| instance.listen(app, secondLaunch) catch |err|
            std.log.err("plume: single instance: {s}", .{@errorName(err)});
        for (app.startups.items) |hook| hook.function(hook.instance, app);
        app.main_window.load(app.start_url) catch |err|
            std.log.err("plume: the main page: {s}", .{@errorName(err)});
        _ = zg.zg_runtime_run(app.runtime);
        if (app.smoke and app.smoke_failed) std.process.exit(1);
    }

    /// Ends run(); from any thread.
    pub fn quit(app: *App) void {
        zg.zg_runtime_quit(app.runtime);
    }

    /// "app://localhost/<page>" (or the dev server's) for a page of the
    /// frontend; an absolute URL as it is. Free it with smp_allocator.
    pub fn pageURL(app: *const App, page_or_url: []const u8) error{OutOfMemory}![:0]u8 {
        if (std.mem.indexOf(u8, page_or_url, "://") != null) return allocator.dupeSentinel(u8, page_or_url, 0);
        const page_path = std.mem.trimStart(u8, page_or_url, "/");
        return std.mem.concatWithSentinel(allocator, u8, &.{ app.base_url, page_path }, 0);
    }

    // ---- Windows ----

    /// The main window.
    pub fn window(app: *App) *Window {
        return app.main_window;
    }

    /// Another window, showing a page of the frontend with the same
    /// bindings. Closing it destroys it; closing the main window ends the
    /// application.
    pub fn openWindow(app: *App, options: WindowOptions) error{ OutOfMemory, EngineFailed, BindFailed }!*Window {
        const w = try Window.create(app, options, false);
        errdefer w.destroy();
        try app.windows.append(allocator, w);
        return w;
    }

    /// From a window that closed (its onClose allowed it).
    pub fn windowClosed(app: *App, w: *Window) void {
        if (w.main) return app.quit();
        for (app.windows.items, 0..) |item, i| {
            if (item == w) {
                _ = app.windows.orderedRemove(i);
                break;
            }
        }
        for (app.trays.items) |t| {
            if (t.attached == w) t.attached = null;
        }
        // The engine destroys it once out of its calls.
        w.destroy();
    }

    /// The main window's handlers (see Window.onWindow).
    pub fn onWindow(app: *App, context: anytype, comptime handler: anytype) Error!void {
        app.main_window.onWindow(context, handler) catch return error.OutOfMemory;
    }

    /// `handler(context) bool` when the user asks to close the main window
    /// (or its page calls Plume.window.close()): false keeps it open.
    pub fn onClose(app: *App, context: anytype, comptime handler: anytype) void {
        app.main_window.onClose(context, handler);
    }

    // ---- Events ----

    /// Dispatches the event `name` with `value` (as JSON) to every window's
    /// Plume.on listeners. Any thread.
    pub fn emit(app: *App, name: []const u8, value: anytype) void {
        app.bus.emit(name, value);
    }

    /// Calls `handler(context, data)` on the runtime thread for each
    /// Plume.emit(name, data) of a page, with `data` decoded into `T`.
    pub fn on(app: *App, name: []const u8, comptime T: type, context: anytype, comptime handler: anytype) Error!void {
        app.bus.on(name, T, context, handler) catch return error.OutOfMemory;
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
        app.bus.dispatch(context, function) catch return error.OutOfMemory;
    }

    /// The main window's page objects (plume.dom). Close it when done.
    pub fn page(app: *App) dom.Error!dom.Page {
        return app.main_window.page();
    }

    // ---- The desktop ----

    /// The connected screens, their names in `a`.
    pub fn screens(app: *App, a: std.mem.Allocator) desktop.Error![]desktop.Screen {
        return desktop.screens(app.runtime, a);
    }

    pub fn clipboard(app: *App) desktop.Clipboard {
        return .{ .runtime = app.runtime };
    }

    /// Every window's, and those opened later.
    pub fn setColorScheme(app: *App, scheme: ColorScheme) void {
        app.color_scheme = colorScheme(scheme);
        for (app.windows.items) |w| _ = zg.zg_view_set_color_scheme(w.view, app.color_scheme);
    }

    fn colorScheme(scheme: ColorScheme) zg.zg_color_scheme {
        return switch (scheme) {
            .system => zg.ZG_COLOR_SCHEME_SYSTEM,
            .light => zg.ZG_COLOR_SCHEME_LIGHT,
            .dark => zg.ZG_COLOR_SCHEME_DARK,
        };
    }

    /// Opens `url` with the system: a web page in the default browser, a
    /// mailto: link in the mail program, a file:// path with its program.
    pub fn openURL(app: *App, url: []const u8) desktop.Error!void {
        const text = allocator.dupeSentinel(u8, url, 0) catch return error.OutOfMemory;
        defer allocator.free(text);
        return desktop.check(zg.zg_open_url(app.runtime, text.ptr));
    }

    /// Opens a file or a folder with the system's program for it.
    pub fn openPath(app: *App, path: []const u8) desktop.Error!void {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const absolute = std.Io.Dir.cwd().realPathFileAlloc(io(), path, arena.allocator()) catch return error.NotFound;
        return app.openURL(fileURL(arena.allocator(), absolute) catch return error.OutOfMemory);
    }

    fn fileURL(a: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, if (path.len > 0 and path[0] == '/') "file://" else "file:///");
        for (path) |c| switch (c) {
            '\\' => try out.append(a, '/'),
            'A'...'Z', 'a'...'z', '0'...'9', '/', '-', '_', '.', '~', ':' => try out.append(a, c),
            else => try out.print(a, "%{X:0>2}", .{c}),
        };
        return out.items;
    }

    /// `handler(context, url) bool` for a link to another site (or
    /// window.open of one): true if it took care of it; false, or without a
    /// handler, the default browser opens it.
    pub fn onExternalLink(app: *App, context: anytype, comptime handler: anytype) void {
        const C = @TypeOf(context);
        const External = struct {
            fn call(opaque_context: ?*anyopaque, url: []const u8) bool {
                return handler(plume_events.fromOpaque(C, opaque_context), url);
            }
        };
        app.external_handler = .{ .context = plume_events.toOpaque(context), .function = External.call };
    }

    /// From a window's page.
    pub fn openExternal(app: *App, url: []const u8) void {
        if (app.external_handler) |handler| {
            if (handler.function(handler.context, url)) return;
        }
        app.openURL(url) catch |err| std.log.warn("plume: could not open {s}: {s}", .{ url, @errorName(err) });
    }

    /// Whether the application starts when the user logs in.
    pub fn startsAtLogin(app: *App) bool {
        return system.startsAtLogin(io(), app.id());
    }

    /// Starts the application when the user logs in (this executable, where
    /// it is now), or no more.
    pub fn setStartAtLogin(app: *App, enabled: bool) system.Error!void {
        return system.setStartAtLogin(io(), app.id(), app.title, enabled);
    }

    // ---- Menus ----

    /// The main window's menu bar (see plume.menu); null removes it.
    pub fn setMenu(app: *App, items: ?[]const menu.Item) Window.MenuError!void {
        return app.main_window.setMenu(items);
    }

    pub fn setMenuChecked(app: *App, item_id: []const u8, checked: bool) Window.MenuError!void {
        return app.main_window.setMenuChecked(item_id, checked);
    }

    pub fn setMenuEnabled(app: *App, item_id: []const u8, enabled: bool) Window.MenuError!void {
        return app.main_window.setMenuEnabled(item_id, enabled);
    }

    /// A popup menu at (x, y) of the main window, its page's CSS pixels.
    pub fn popupMenu(app: *App, items: []const menu.Item, x: f32, y: f32) Window.MenuError!void {
        return app.main_window.popupMenu(items, x, y);
    }

    /// `handler(context, id)` when an item of a window's menu bar, a popup
    /// menu or a tray menu is chosen (the window's page, or every page for a
    /// tray's, gets a "menu" event with the id too).
    pub fn onMenu(app: *App, context: anytype, comptime handler: anytype) Error!void {
        try app.menu_handlers.append(allocator, .{ .context = plume_events.toOpaque(context), .function = Thunk(@TypeOf(context), []const u8, handler).call });
    }

    /// From a window (null: a tray).
    pub fn menuChosen(app: *App, from: ?*Window, item_id: []const u8) void {
        for (app.menu_handlers.items) |handler| handler.function(handler.context, item_id);
        app.bus.emitTo(if (from) |w| w.view else null, "menu", item_id);
    }

    /// A context menu for the pages' elements marked data-plume-menu="name":
    /// a right click on one shows it (natively on Windows), and the chosen
    /// item goes to onContextMenu's handlers and the page's "menu:context"
    /// event, with the element's data-plume-menu-data. Null removes it.
    pub fn setContextMenu(app: *App, name: []const u8, items: ?[]const menu.Item) Error!void {
        if (items) |list| {
            const a = app.strings.allocator();
            const owned = try menu.copy(a, list);
            const entry = try app.context_menus.getOrPut(allocator, name);
            if (!entry.found_existing) entry.key_ptr.* = try a.dupe(u8, name);
            entry.value_ptr.* = owned;
        } else _ = app.context_menus.remove(name);
    }

    pub fn contextMenu(app: *App, name: []const u8) ?[]const menu.Item {
        return app.context_menus.get(name);
    }

    pub fn onContextMenu(app: *App, context: anytype, comptime handler: anytype) Error!void {
        try app.context_handlers.append(allocator, .{ .context = plume_events.toOpaque(context), .function = Thunk(@TypeOf(context), ContextMenuChoice, handler).call });
    }

    pub fn contextMenuChosen(app: *App, from: *Window, name: []const u8, item_id: []const u8, data: []const u8) void {
        const choice: ContextMenuChoice = .{ .menu = name, .id = item_id, .data = data };
        for (app.context_handlers.items) |handler| handler.function(handler.context, choice);
        from.emit("menu:context", choice);
    }

    // ---- Dialogs ----

    /// A file dialog over the main window; `handler(context, paths)` on the
    /// runtime thread, with the chosen paths (empty if cancelled, valid
    /// during the call).
    pub fn fileDialog(app: *App, dialog: desktop.FileDialog, context: anytype, comptime handler: anytype) desktop.Error!void {
        const C = @TypeOf(context);
        const Paths = struct {
            fn call(opaque_context: ?*anyopaque, paths: []const []const u8) void {
                handler(plume_events.fromOpaque(C, opaque_context), paths);
            }
        };
        return desktop.showFileDialog(app.main_window.handle orelse return error.Unsupported, dialog, plume_events.toOpaque(context), Paths.call);
    }

    /// A message box over the main window; `handler(context, button_id)` on
    /// the runtime thread.
    pub fn messageBox(app: *App, box: desktop.MessageBox, context: anytype, comptime handler: anytype) desktop.Error!void {
        const C = @TypeOf(context);
        const Button = struct {
            fn call(opaque_context: ?*anyopaque, button: i32) void {
                handler(plume_events.fromOpaque(C, opaque_context), button);
            }
        };
        return desktop.showMessageBox(app.main_window.handle orelse return error.Unsupported, box, plume_events.toOpaque(context), Button.call);
    }

    // ---- Tray ----

    /// A tray icon (plume.Tray): the application's icon unless the options
    /// give another. Destroyed with the app, or by destroyTray.
    pub fn createTray(app: *App, options: tray_module.Options) tray_module.Error!*Tray {
        const t = try Tray.create(app, options);
        errdefer t.destroy();
        try app.trays.append(allocator, t);
        return t;
    }

    pub fn destroyTray(app: *App, t: *Tray) void {
        for (app.trays.items, 0..) |item, i| {
            if (item == t) {
                _ = app.trays.swapRemove(i);
                break;
            }
        }
        t.destroy();
    }

    // ---- Notifications ----

    /// Shows a notification, sent by the application (its app_id, title and
    /// icon). desktop.Error.Unsupported without a notification service.
    pub fn notify(app: *App, notification: Notification) desktop.Error!void {
        try app.prepareNotifications();
        if (notification.actions.len > 3) return error.InvalidArgument;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var actions: [3][*c]const u8 = undefined;
        for (notification.actions, 0..) |action, i| actions[i] = (a.dupeSentinel(u8, action, 0) catch return error.OutOfMemory).ptr;
        var shown = std.mem.zeroes(zg.zg_notification);
        shown.size = @sizeOf(zg.zg_notification);
        shown.title = (a.dupeSentinel(u8, notification.title, 0) catch return error.OutOfMemory).ptr;
        if (notification.body) |body| shown.body = (a.dupeSentinel(u8, body, 0) catch return error.OutOfMemory).ptr;
        if (notification.tag) |tag| shown.tag = (a.dupeSentinel(u8, tag, 0) catch return error.OutOfMemory).ptr;
        shown.actions = &actions;
        shown.action_count = notification.actions.len;
        return desktop.check(zg.zg_notification_show(app.runtime, &shown));
    }

    /// Takes away the notification with `tag`.
    pub fn removeNotification(app: *App, tag: []const u8) desktop.Error!void {
        try app.prepareNotifications();
        const text = allocator.dupeSentinel(u8, tag, 0) catch return error.OutOfMemory;
        defer allocator.free(text);
        return desktop.check(zg.zg_notification_remove(app.runtime, text.ptr));
    }

    /// `handler(context, NotificationAction)` when a notification is clicked
    /// (the pages get a "notification" event too).
    pub fn onNotification(app: *App, context: anytype, comptime handler: anytype) Error!void {
        try app.notification_handlers.append(allocator, .{ .context = plume_events.toOpaque(context), .function = Thunk(@TypeOf(context), NotificationAction, handler).call });
    }

    fn prepareNotifications(app: *App) desktop.Error!void {
        if (app.notifications_ready) return;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var config = std.mem.zeroes(zg.zg_notifications_config);
        config.size = @sizeOf(zg.zg_notifications_config);
        config.app_id = (a.dupeSentinel(u8, app.id(), 0) catch return error.OutOfMemory).ptr;
        config.app_name = (a.dupeSentinel(u8, app.title, 0) catch return error.OutOfMemory).ptr;
        // The icon as a file, where the notification service can read it.
        if (app.icon_png) |png| icon: {
            const directory = system.cacheDirectory(a, io(), app.id()) catch break :icon;
            const path = std.fs.path.joinZ(a, &.{ directory, "icon.png" }) catch return error.OutOfMemory;
            std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = png }) catch break :icon;
            config.icon_path = path.ptr;
        }
        config.user = app;
        config.activated = notificationActivated;
        try desktop.check(zg.zg_runtime_set_notifications(app.runtime, &config));
        app.notifications_ready = true;
    }

    fn notificationActivated(rt: ?*zg.zg_runtime, tag: [*c]const u8, action: c_int, user: ?*anyopaque) callconv(.c) void {
        _ = rt;
        const app: *App = @ptrCast(@alignCast(user.?));
        const chosen: NotificationAction = .{ .tag = if (tag != null) std.mem.span(tag) else "", .action = action };
        for (app.notification_handlers.items) |handler| handler.function(handler.context, chosen);
        app.bus.emit("notification", chosen);
    }

    // ---- Global shortcuts ----

    /// A key combination pressed anywhere, whichever application has the
    /// keyboard ("Ctrl+Shift+K"): onShortcut's handlers and the pages'
    /// "shortcut" event get `name`. AlreadyExists if another application
    /// holds it, Unsupported on Wayland without the GlobalShortcuts portal.
    pub fn registerShortcut(app: *App, name: []const u8, accelerator: []const u8) desktop.Error!void {
        if (!app.shortcut_callback) {
            try desktop.check(zg.zg_runtime_set_shortcut_callback(app.runtime, shortcutPressed, app));
            app.shortcut_callback = true;
        }
        if (app.shortcutId(name) != null) return error.AlreadyExists;
        // A free slot, else a new one.
        const slot = for (app.shortcuts.items, 0..) |item, i| {
            if (item.len == 0) break i;
        } else blk: {
            app.shortcuts.append(allocator, "") catch return error.OutOfMemory;
            break :blk app.shortcuts.items.len - 1;
        };
        const keys = allocator.dupeSentinel(u8, accelerator, 0) catch return error.OutOfMemory;
        defer allocator.free(keys);
        try desktop.check(zg.zg_shortcut_register(app.runtime, @intCast(slot + 1), keys.ptr));
        app.shortcuts.items[slot] = app.strings.allocator().dupe(u8, name) catch return error.OutOfMemory;
    }

    pub fn unregisterShortcut(app: *App, name: []const u8) desktop.Error!void {
        const number = app.shortcutId(name) orelse return error.NotFound;
        app.shortcuts.items[number - 1] = "";
        return desktop.check(zg.zg_shortcut_unregister(app.runtime, number));
    }

    pub fn onShortcut(app: *App, context: anytype, comptime handler: anytype) Error!void {
        try app.shortcut_handlers.append(allocator, .{ .context = plume_events.toOpaque(context), .function = Thunk(@TypeOf(context), []const u8, handler).call });
    }

    fn shortcutId(app: *App, name: []const u8) ?c_uint {
        for (app.shortcuts.items, 0..) |item, i| {
            if (item.len > 0 and std.mem.eql(u8, item, name)) return @intCast(i + 1);
        }
        return null;
    }

    fn shortcutPressed(rt: ?*zg.zg_runtime, number: c_uint, user: ?*anyopaque) callconv(.c) void {
        _ = rt;
        const app: *App = @ptrCast(@alignCast(user.?));
        if (number == 0 or number > app.shortcuts.items.len) return;
        const name = app.shortcuts.items[number - 1];
        if (name.len == 0) return;
        for (app.shortcut_handlers.items) |handler| handler.function(handler.context, name);
        app.bus.emit("shortcut", name);
    }

    // ---- The pages' Plume.app ----

    pub const AppOpError = desktop.Error || system.Error || codec.DecodeError;

    /// __plume.app(op, json) of a page.
    pub fn appOp(app: *App, a: std.mem.Allocator, op: []const u8, json: []const u8) AppOpError![]const u8 {
        const eql = std.mem.eql;
        if (eql(u8, op, "openURL")) try app.openURL(try codec.decode([]const u8, a, json)) //
        else if (eql(u8, op, "openPath")) try app.openPath(try codec.decode([]const u8, a, json)) //
        else if (eql(u8, op, "quit")) app.quit() //
        else if (eql(u8, op, "args")) return codec.encode(a, app.args) //
        else if (eql(u8, op, "startsAtLogin")) return codec.encode(a, app.startsAtLogin()) //
        else if (eql(u8, op, "setStartAtLogin")) try app.setStartAtLogin(try codec.decode(bool, a, json)) //
        else if (eql(u8, op, "notify")) try app.notify(try codec.decode(Notification, a, json)) //
        else if (eql(u8, op, "removeNotification")) try app.removeNotification(try codec.decode([]const u8, a, json)) //
        else if (eql(u8, op, "registerShortcut")) {
            const shortcut = try codec.decode(struct { name: []const u8, accelerator: []const u8 }, a, json);
            try app.registerShortcut(shortcut.name, shortcut.accelerator);
        } else if (eql(u8, op, "unregisterShortcut")) try app.unregisterShortcut(try codec.decode([]const u8, a, json)) //
        else return error.InvalidArgument;
        return "null";
    }

    // ---- Updates ----

    pub const Release = update.Release;
    pub const UpdateError = update.Error;

    /// The latest release on GitHub if it is newer than this build (plume.json's
    /// "update"; see plume.update), its strings in `a`. Blocks on the network:
    /// from a worker thread.
    pub fn checkForUpdate(app: *App, a: std.mem.Allocator) UpdateError!?Release {
        const config = app.update_config orelse return error.NotConfigured;
        return update.check(a, io(), config, app.name, app.version);
    }

    /// Downloads `release`, checks its signature and that it starts, and puts
    /// it in this executable's place: the next start runs it (restart() now).
    /// Blocks: from a worker thread.
    pub fn installUpdate(app: *App, a: std.mem.Allocator, release: Release) UpdateError!void {
        const config = app.update_config orelse return error.NotConfigured;
        return update.install(a, io(), config, release);
    }

    /// Starts the executable again, with this launch's arguments, and quits.
    pub fn restart(app: *App) UpdateError!void {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        try update.restart(arena.allocator(), io(), app.args);
        app.quit();
    }

    /// __plume.update(op, json) of a page: "check" and "install" settle a
    /// Promise from a worker thread; "restart".
    pub fn updateBinding(app: *App, call: ?*zg.zg_call, op: []const u8, json: []const u8) ?*zg.zg_value {
        if (std.mem.eql(u8, op, "restart")) {
            app.restart() catch |err| return window_module.throwError(call, err);
            return null;
        }
        var promise: ?*zg.zg_promise = null;
        const value = zg.zg_call_promise(call, &promise);
        const install = std.mem.eql(u8, op, "install");
        if (!install and !std.mem.eql(u8, op, "check")) {
            zg.zg_promise_reject(promise, "plume:InvalidArgument");
            return value;
        }
        const Job = struct {
            app: *App,
            promise: *zg.zg_promise,
            install: bool,
            json: []u8,

            fn run(job: *@This()) void {
                defer {
                    allocator.free(job.json);
                    allocator.destroy(job);
                    _ = bindings.running.fetchSub(1, .acq_rel);
                }
                var arena: std.heap.ArenaAllocator = .init(allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const result: UpdateError![]const u8 = if (job.install) blk: {
                    const release = codec.decode(Release, a, job.json) catch break :blk error.NoAsset;
                    job.app.installUpdate(a, release) catch |err| break :blk err;
                    break :blk "null";
                } else blk: {
                    const release = job.app.checkForUpdate(a) catch |err| break :blk err;
                    break :blk codec.encode(a, release) catch error.OutOfMemory;
                };
                const answer = result catch |err| {
                    var buffer: [64]u8 = undefined;
                    zg.zg_promise_reject(job.promise, window_module.errorMessage(&buffer, err));
                    return;
                };
                zg.zg_promise_resolve(job.promise, answer.ptr, answer.len);
            }
        };
        const job = allocator.create(Job) catch {
            zg.zg_promise_reject(promise, "plume:OutOfMemory");
            return value;
        };
        job.* = .{ .app = app, .promise = promise.?, .install = install, .json = allocator.dupe(u8, json) catch {
            allocator.destroy(job);
            zg.zg_promise_reject(promise, "plume:OutOfMemory");
            return value;
        } };
        _ = bindings.running.fetchAdd(1, .acq_rel);
        const thread = std.Thread.spawn(.{}, Job.run, .{job}) catch {
            _ = bindings.running.fetchSub(1, .acq_rel);
            allocator.free(job.json);
            allocator.destroy(job);
            zg.zg_promise_reject(promise, "plume:SystemResources");
            return value;
        };
        thread.detach();
        return value;
    }

    // ---- Single instance ----

    /// `handler(context, launch)` on the runtime thread when the application
    /// is launched again (with single_instance): its arguments and working
    /// directory. The main window comes to the front first.
    pub fn onSecondInstance(app: *App, context: anytype, comptime handler: anytype) void {
        const C = @TypeOf(context);
        const Second = struct {
            fn call(opaque_context: ?*anyopaque, launch: Launch) void {
                handler(plume_events.fromOpaque(C, opaque_context), launch);
            }
        };
        app.second_instance = .{ .context = plume_events.toOpaque(context), .function = Second.call };
    }

    /// From the instance's listener thread: to the pages, and to the runtime
    /// thread for the window and the handler.
    fn secondLaunch(context: ?*anyopaque, json: []const u8) void {
        const app: *App = @ptrCast(@alignCast(context.?));
        app.bus.emitJson(null, "instance:launched", json);
        const Task = struct {
            app: *App,
            json: []u8,

            fn run(task: *@This()) void {
                defer {
                    allocator.free(task.json);
                    allocator.destroy(task);
                }
                const w = task.app.main_window;
                if (w.state() == .minimized or w.state() == .hidden) {
                    w.show() catch {};
                    w.restore() catch {};
                }
                w.focus() catch {};
                const handler = task.app.second_instance orelse return;
                var arena: std.heap.ArenaAllocator = .init(allocator);
                defer arena.deinit();
                const launch = std.json.parseFromSliceLeaky(Launch, arena.allocator(), task.json, .{ .ignore_unknown_fields = true }) catch return;
                handler.function(handler.context, launch);
            }
        };
        const task = allocator.create(Task) catch return;
        task.* = .{ .app = app, .json = allocator.dupe(u8, json) catch {
            allocator.destroy(task);
            return;
        } };
        app.bus.dispatch(task, Task.run) catch {};
    }

    fn fail(comptime what: []const u8) Error {
        std.log.err(what ++ ": {s}", .{zg.zg_last_error()});
        return error.EngineFailed;
    }
};

fn Thunk(comptime C: type, comptime T: type, comptime handler: anytype) type {
    return struct {
        fn call(opaque_context: ?*anyopaque, value: T) void {
            const result = handler(plume_events.fromOpaque(C, opaque_context), value);
            if (@typeInfo(@TypeOf(result)) == .error_union) {
                _ = result catch |err| std.log.err("plume: a handler failed: {s}", .{@errorName(err)});
            }
        }
    };
}
