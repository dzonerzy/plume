//! plume: desktop applications in Zig with a web frontend.
//!
//!   plume init <name> --template vanilla|react|svelte|vue   (alias: new)
//!   plume dev                     the app on Vite's dev server, rebuilt as Zig changes
//!   plume build [--compress[=best]] the release executable in build/bin/
//!   plume test                    the UI tests, headless
//!   plume package                 build/bin's, as installers and packages
//!   plume doctor                  what plume needs: Zig 0.17, Node, npm
//!   plume version

const std = @import("std");
const build_options = @import("build_options");

pub const Context = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    args: []const [:0]const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var context: Context = .{ .io = init.io, .arena = init.arena.allocator(), .environ = init.environ_map, .args = args };
    const command = if (args.len >= 2) args[1] else "help";
    const rest = if (args.len >= 2) args[2..] else args[0..0];
    context.args = rest;

    const result = if (eql(command, "init") or eql(command, "new"))
        @import("init.zig").run(&context)
    else if (eql(command, "dev"))
        @import("dev.zig").run(&context)
    else if (eql(command, "build"))
        @import("build_app.zig").run(&context)
    else if (eql(command, "package"))
        @import("package.zig").run(&context)
    else if (eql(command, "test"))
        @import("test.zig").run(&context)
    else if (eql(command, "update"))
        @import("update.zig").run(&context)
    else if (eql(command, "doctor"))
        @import("doctor.zig").run(&context)
    else if (eql(command, "upx"))
        return upxCommand(&context)
    else if (eql(command, "version") or eql(command, "--version") or eql(command, "-v")) {
        printVersion();
        return 0;
    } else if (eql(command, "help") or eql(command, "--help") or eql(command, "-h")) {
        printHelp();
        return 0;
    } else {
        fail("unknown command \"{s}\" (plume help lists them)", .{command});
        return 2;
    };
    result catch |err| switch (err) {
        // Already explained.
        error.Reported => return 1,
        else => {
            fail("{s}", .{@errorName(err)});
            return 1;
        },
    };
    return 0;
}

fn printVersion() void {
    const commit = build_options.commit;
    std.debug.print("plume {s} ({s}), with UPX {s}\n", .{ build_options.version, commit[0..@min(12, commit.len)], build_options.upx_version });
}

fn printHelp() void {
    std.debug.print(
        \\plume: desktop applications in Zig with a web frontend
        \\
        \\Usage:
        \\  plume init <name> [--template vanilla|react|svelte|vue] [--no-install]
        \\                    create a project (alias: plume new); default template: vanilla
        \\  plume dev         run the app on the frontend's dev server; Zig changes rebuild it
        \\  plume build [--compress[=best]]
        \\                    build the release executable into build/bin/, compressed with
        \\                    UPX if asked (or if plume.json says "compress": true)
        \\  plume test [--update-snapshots] [filter]
        \\                    the UI tests (src/tests.zig): the app headless, no window or
        \\                    display needed; snapshots in tests/snapshots/<os>/
        \\  plume package [--format nsis|zip|deb|tar|appimage]... [--skip-build]
        \\                    build, then package for users into build/package/: an
        \\                    installer on Windows (NSIS; a zip without it), a .deb,
        \\                    a .tar.gz and an AppImage (with appimagetool) on Linux
        \\  plume update keygen | sign <file>... [--key <file>]
        \\                    the keys of signed updates: update.key and the public key
        \\                    for plume.json's "update"; <file>.sig signatures
        \\  plume doctor    check what plume needs: Zig 0.17, Node.js, npm
        \\  plume version
        \\
        \\Projects: plume.json (name, window, profile), src/ (Zig), frontend/ (Vite).
        \\
    , .{});
}

// ---- Shared helpers ----

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Reported to the user: the command then fails with error.Reported.
pub fn fail(comptime format: []const u8, args: anytype) void {
    std.debug.print("plume: " ++ format ++ "\n", args);
}

pub fn step(comptime format: []const u8, args: anytype) void {
    std.debug.print("\x1b[1m•\x1b[0m " ++ format ++ "\n", args);
}

/// Runs a command to completion, its output on the terminal.
pub fn run(context: *Context, argv: []const []const u8, cwd: ?[]const u8) !void {
    var child = std.process.spawn(context.io, .{ .argv = argv, .cwd = if (cwd) |path| .{ .path = path } else .inherit, .environ_map = context.environ }) catch |err| {
        fail("cannot run {s}: {s}", .{ argv[0], @errorName(err) });
        return error.Reported;
    };
    const term = try child.wait(context.io);
    if (!term.success()) {
        fail("{s} failed ({f})", .{ argv[0], term });
        return error.Reported;
    }
}

/// A command's standard output, or null if it cannot run or fails.
pub fn output(context: *Context, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(context.arena, context.io, .{ .argv = argv }) catch return null;
    if (!result.term.success()) return null;
    return std.mem.trim(u8, result.stdout, " \r\n\t");
}

pub fn exists(context: *Context, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(context.io, path, .{}) catch return false;
    return true;
}

/// The executable's file name on this OS.
pub fn executableName(context: *Context, name: []const u8) []const u8 {
    return if (@import("builtin").os.tag == .windows) std.fmt.allocPrint(context.arena, "{s}.exe", .{name}) catch name else name;
}

// ---- UPX, linked in ----

extern fn plume_upx(argc: c_int, argv: [*]const ?[*:0]const u8) c_int;

/// UPX's command line in process (UPX's exit code).
pub fn upx(context: *Context, args: []const []const u8) u8 {
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    argv.append(context.arena, "upx") catch return 1;
    for (args) |arg| argv.append(context.arena, (context.arena.dupeSentinel(u8, arg, 0) catch return 1).ptr) catch return 1;
    return @intCast(plume_upx(@intCast(argv.items.len), argv.items.ptr));
}

/// `plume upx ...`: UPX's own command line, for those who want it.
fn upxCommand(context: *Context) u8 {
    var args: std.ArrayList([]const u8) = .empty;
    for (context.args) |arg| args.append(context.arena, arg) catch return 1;
    return upx(context, args.items);
}
