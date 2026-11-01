//! plume build [--compress[=best]] [--profile minimal|standard|dev] [--debug]
//!
//! The frontend built by Vite (npm run build), packed into the release
//! executable with the engine; build/bin/<name>. With --compress (or
//! "compress": true / "best" in plume.json) the executable is then
//! compressed by UPX, linked into plume.

const std = @import("std");
const cli = @import("main.zig");
const Project = @import("project.zig").Project;

const Compression = enum { none, normal, best };

pub fn run(context: *cli.Context) !void {
    const project = try Project.load(context);
    var compression: Compression = switch (project.config.compress) {
        .bool => |on| if (on) .normal else .none,
        .string => |level| if (cli.eql(level, "best")) .best else .normal,
        else => .none,
    };
    var profile = project.config.profile;
    var optimize: []const u8 = "small";

    var i: usize = 0;
    while (i < context.args.len) : (i += 1) {
        const arg = context.args[i];
        if (cli.eql(arg, "--compress")) {
            compression = .normal;
        } else if (cli.eql(arg, "--compress=best")) {
            compression = .best;
        } else if (cli.eql(arg, "--no-compress")) {
            compression = .none;
        } else if (cli.eql(arg, "--debug")) {
            optimize = "debug";
        } else if (cli.eql(arg, "--profile") and i + 1 < context.args.len) {
            i += 1;
            profile = context.args[i];
        } else {
            cli.fail("unknown option {s}", .{arg});
            return error.Reported;
        }
    }

    try project.ensureDependencies(context);
    // bindings.ts first: the frontend's type check needs it.
    cli.step("generating the bindings (frontend/src/bindings.ts)", .{});
    try cli.run(context, &.{ "zig", "build", "bindings" }, null);
    cli.step("building the frontend (npm run build)", .{});
    try cli.run(context, &.{ "npm", "run", "build" }, project.config.frontend.dir);

    cli.step("building {s} ({s}, {s} engine)", .{ project.config.name, optimize, profile });
    try cli.run(context, &.{
        "zig",                                                      "build",
        try std.fmt.allocPrint(context.arena, "-Doptimize={s}", .{optimize}),
        try std.fmt.allocPrint(context.arena, "-Dprofile={s}", .{profile}),
        "--prefix",                                                 "build",
    }, null);

    const executable = try std.fs.path.join(context.arena, &.{ "build", "bin", cli.executableName(context, project.config.name) });
    const size = try fileSize(context, executable);
    if (compression != .none) {
        cli.step("compressing with UPX{s}", .{if (compression == .best) " (--best: this takes minutes)" else ""});
        const args: []const []const u8 = if (compression == .best) &.{ "-qq", "--best", executable } else &.{ "-qq", executable };
        const code = cli.upx(context, args);
        if (code != 0) {
            cli.fail("UPX failed (exit code {d}); the executable is left uncompressed", .{code});
            return error.Reported;
        }
        const compressed = try fileSize(context, executable);
        std.debug.print("\n{s}: {d:.1} MB (compressed from {d:.1} MB)\n", .{ executable, megabytes(compressed), megabytes(size) });
    } else {
        std.debug.print("\n{s}: {d:.1} MB\n", .{ executable, megabytes(size) });
    }
}

fn fileSize(context: *cli.Context, path: []const u8) !u64 {
    const stat = std.Io.Dir.cwd().statFile(context.io, path, .{}) catch {
        cli.fail("{s} was not built", .{path});
        return error.Reported;
    };
    return stat.size;
}

fn megabytes(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
}
