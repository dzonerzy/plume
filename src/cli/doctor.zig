//! plume doctor: what building Plume applications needs, and what is here.

const std = @import("std");
const cli = @import("main.zig");

pub fn run(context: *cli.Context) !void {
    var problems: usize = 0;

    if (cli.output(context, &.{ "zig", "version" })) |version| {
        const ok = std.mem.startsWith(u8, version, "0.17.");
        report(ok, "Zig {s}{s}", .{ version, if (ok) "" else " (Plume needs 0.17)" });
        if (!ok) problems += 1;
    } else {
        report(false, "Zig: not found (https://ziglang.org/download/, 0.17)", .{});
        problems += 1;
    }

    if (cli.output(context, &.{ "node", "--version" })) |version| {
        // "v22.19.0" → 22.
        const digits = std.mem.trimStart(u8, version, "v");
        const end = std.mem.indexOfScalar(u8, digits, '.') orelse digits.len;
        const major = std.fmt.parseInt(u32, digits[0..end], 10) catch 0;
        const ok = major >= 20;
        report(ok, "Node.js {s}{s}", .{ version, if (ok) "" else " (Vite 8 needs 20.19 or later)" });
        if (!ok) problems += 1;
    } else {
        report(false, "Node.js: not found (https://nodejs.org)", .{});
        problems += 1;
    }

    if (cli.output(context, &.{ "npm", "--version" })) |version| {
        report(true, "npm {s}", .{version});
    } else {
        report(false, "npm: not found (it comes with Node.js)", .{});
        problems += 1;
    }

    if (cli.output(context, &.{ "git", "--version" })) |version| {
        report(true, "{s} (plume init fetches Plume with it)", .{version});
    } else {
        report(false, "git: not found (plume init fetches Plume with it)", .{});
        problems += 1;
    }

    if (problems == 0) {
        std.debug.print("\nEverything plume needs is here.\n", .{});
    } else {
        std.debug.print("\n{d} problem{s} above.\n", .{ problems, if (problems == 1) "" else "s" });
        return error.Reported;
    }
}

fn report(ok: bool, comptime format: []const u8, args: anytype) void {
    std.debug.print("{s} " ++ format ++ "\n", .{if (ok) "\x1b[32m✓\x1b[0m" else "\x1b[31m✗\x1b[0m"} ++ args);
}
