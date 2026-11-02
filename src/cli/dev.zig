//! plume dev: the application on the frontend's dev server.
//!
//! The app is built with the engine's dev profile (the Web Inspector: F12)
//! pointed at Vite, which reloads the page as the frontend changes. When a Zig
//! file, build.zig or plume.json changes, the app is rebuilt (with
//! bindings.ts) while it keeps running, then restarted; if the build fails,
//! it runs on and the errors stay on the terminal. Closing the app ends
//! plume dev.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("main.zig");
const Project = @import("project.zig").Project;

pub fn run(context: *cli.Context) !void {
    const project = try Project.load(context);
    try project.ensureDependencies(context);
    const vite = project.viteScript(context) orelse {
        cli.fail("Vite is not in node_modules: npm install", .{});
        return error.Reported;
    };
    const port = project.devPort();

    // First the app (and bindings.ts, which the frontend imports).
    if (!build(context, project)) return error.Reported;

    cli.step("starting Vite on {s}", .{project.config.frontend.dev_url});
    var vite_process = try Supervised.start(context, &.{ "node", vite, "--port", try std.fmt.allocPrint(context.arena, "{d}", .{port}), "--strictPort" }, project.config.frontend.dir);
    defer vite_process.stop(context);
    if (!waitForPort(context, port, 30_000)) {
        cli.fail("Vite did not start on port {d}", .{port});
        return error.Reported;
    }

    // A copy runs: the build can replace the executable while it does (Windows
    // keeps a running one locked), and the app keeps running while it builds.
    const name = cli.executableName(context, project.config.name);
    const built = try std.fs.path.join(context.arena, &.{ "zig-out", "bin", name });
    const running = try std.fs.path.join(context.arena, &.{ "zig-out", "dev", name });
    try stage(context, built, running);
    cli.step("running {s}: edit the frontend for live reload, Zig files to rebuild; close the window to stop", .{project.config.name});
    var app = try Supervised.start(context, &.{running}, null);
    var sources = try sourceStamp(context);

    while (true) {
        try std.Io.sleep(context.io, .fromMilliseconds(400), .awake);
        if (app.exited.load(.acquire)) {
            app.join();
            break;
        }
        if (vite_process.exited.load(.acquire)) {
            cli.fail("Vite stopped", .{});
            app.stop(context);
            return error.Reported;
        }
        const now = try sourceStamp(context);
        if (now == sources) continue;
        sources = now;
        cli.step("Zig sources changed: rebuilding (the app keeps running)", .{});
        if (!build(context, project)) {
            cli.fail("the build failed: the app runs on; fix the error and save", .{});
            continue;
        }
        if (app.exited.load(.acquire)) {
            app.join();
            break;
        }
        app.stop(context);
        try stage(context, built, running);
        cli.step("running {s} again", .{project.config.name});
        app = try Supervised.start(context, &.{running}, null);
    }
}

/// `built` copied to `running` (a stopped app's).
fn stage(context: *cli.Context, built: []const u8, running: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(running)) |directory| try cwd.createDirPath(context.io, directory);
    // Just stopped: Windows may hold the file a moment longer.
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        cwd.copyFile(built, cwd, running, context.io, .{}) catch |err| {
            if (attempt < 20) {
                try std.Io.sleep(context.io, .fromMilliseconds(100), .awake);
                continue;
            }
            cli.fail("cannot copy {s} to {s}: {s}", .{ built, running, @errorName(err) });
            return error.Reported;
        };
        return;
    }
}

fn build(context: *cli.Context, project: Project) bool {
    cli.step("building {s} (dev profile)", .{project.config.name});
    cli.run(context, &.{
        "zig",
        "build",
        "-Dprofile=dev",
        std.fmt.allocPrint(context.arena, "-Ddev-url={s}", .{project.config.frontend.dev_url}) catch return false,
    }, null) catch return false;
    return true;
}

/// A child process watched by a thread of its own, so that its end is seen
/// without blocking, and stopped by the OS when asked.
const Supervised = struct {
    child: std.process.Child,
    thread: std.Thread,
    exited: std.atomic.Value(bool) = .init(false),

    fn start(context: *cli.Context, argv: []const []const u8, cwd: ?[]const u8) !*Supervised {
        const self = try context.arena.create(Supervised);
        self.* = .{
            .child = std.process.spawn(context.io, .{ .argv = argv, .cwd = if (cwd) |path| .{ .path = path } else .inherit }) catch |err| {
                cli.fail("cannot run {s}: {s}", .{ argv[0], @errorName(err) });
                return error.Reported;
            },
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, watch, .{ self, context.io });
        return self;
    }

    fn watch(self: *Supervised, io: std.Io) void {
        _ = self.child.wait(io) catch {};
        self.exited.store(true, .release);
    }

    fn join(self: *Supervised) void {
        self.thread.join();
    }

    fn stop(self: *Supervised, context: *cli.Context) void {
        _ = context;
        if (!self.exited.load(.acquire)) {
            if (self.child.id) |id| terminate(id);
        }
        self.thread.join();
    }
};

extern "kernel32" fn TerminateProcess(process: std.os.windows.HANDLE, exit_code: c_uint) callconv(.winapi) std.os.windows.BOOL;

fn terminate(id: std.process.Child.Id) void {
    if (builtin.os.tag == .windows) {
        _ = TerminateProcess(id, 1);
    } else {
        std.posix.kill(id, .TERM) catch {};
    }
}

/// Whether something accepts connections on localhost:port within the time.
fn waitForPort(context: *cli.Context, port: u16, timeout_ms: i64) bool {
    var waited: i64 = 0;
    while (waited < timeout_ms) : (waited += 200) {
        for ([_][]const u8{ "127.0.0.1", "::1" }) |host| {
            const address = std.Io.net.IpAddress.parse(host, port) catch continue;
            if (address.connect(context.io, .{ .mode = .stream })) |stream| {
                stream.close(context.io);
                return true;
            } else |_| {}
        }
        std.Io.sleep(context.io, .fromMilliseconds(200), .awake) catch return false;
    }
    return false;
}

/// A hash of the Zig sources' paths and modification times (src/, build.zig,
/// plume.json): it changes when one does.
fn sourceStamp(context: *cli.Context) !u64 {
    const io = context.io;
    var hasher: std.hash.Wyhash = .init(0);
    for ([_][]const u8{ "build.zig", "build.zig.zon", "plume.json" }) |file| {
        const stat = std.Io.Dir.cwd().statFile(io, file, .{}) catch continue;
        hasher.update(file);
        hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
    }
    var source = std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true }) catch return hasher.final();
    defer source.close(io);
    var walker = try source.walk(context.arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        hasher.update(entry.path);
        hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
    }
    return hasher.final();
}
