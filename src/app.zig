//! A desktop application: the engine's runtime, a context for the
//! application's data, a window and its page, with the frontend embedded in
//! the binary and served under app://localhost/.
//!
//!     var app = try plume.App.init(.{ .title = "Notes", .assets = @embedFile("frontend") });
//!     defer app.deinit();
//!     try app.bind("Notes", Notes, &notes);
//!     app.run();

const std = @import("std");
const zg = @import("zerog");
const bindings = @import("bindings.zig");

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
};

pub const Error = error{
    /// zg_last_error() says why.
    EngineFailed,
    BindFailed,
};

pub const App = struct {
    runtime: *zg.zg_runtime,
    context: *zg.zg_context,
    window: *zg.zg_window,
    view: *zg.zg_view,
    url: [:0]const u8,

    pub fn init(options: Options) Error!App {
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
        const window = zg.zg_window_create(context, &window_config) orelse return fail("zg_window_create");

        return .{
            .runtime = runtime,
            .context = context,
            .window = window,
            .view = zg.zg_window_view(window).?,
            .url = options.dev_server_url orelse options.url orelse "app://localhost/index.html",
        };
    }

    pub fn deinit(app: *App) void {
        // The runtime destroys the context, its window and view.
        zg.zg_runtime_destroy(app.runtime);
    }

    /// Makes `instance`'s methods callable from the page as `name.method(...)`
    /// (plume.bind). Before run(); the instance must outlive the app.
    pub fn bind(app: *App, comptime name: [:0]const u8, comptime T: type, instance: *T) Error!void {
        bindings.bind(app.view, name, T, instance) catch return error.BindFailed;
    }

    /// Loads the page and runs until the window is closed or quit() is called.
    pub fn run(app: *App) void {
        _ = zg.zg_view_load_url(app.view, app.url);
        _ = zg.zg_runtime_run(app.runtime);
    }

    /// Ends run(); from any thread.
    pub fn quit(app: *App) void {
        zg.zg_runtime_quit(app.runtime);
    }

    fn fail(comptime what: []const u8) Error {
        std.log.err(what ++ ": {s}", .{zg.zg_last_error()});
        return error.EngineFailed;
    }
};
