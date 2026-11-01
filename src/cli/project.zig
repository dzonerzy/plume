//! A Plume project: the directory with plume.json, and what plume dev and
//! plume build take from it.

const std = @import("std");
const cli = @import("main.zig");

pub const Config = struct {
    name: []const u8,
    profile: []const u8 = "minimal",
    /// false, true, or "best" (slower, a little smaller).
    compress: std.json.Value = .{ .bool = false },
    frontend: struct {
        dir: []const u8 = "frontend",
        dev_url: []const u8 = "http://localhost:5173",
    } = .{},
};

pub const Project = struct {
    config: Config,

    pub fn load(context: *cli.Context) !Project {
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, "plume.json", context.arena, .limited(1 << 20)) catch {
            cli.fail("no plume.json here: run plume in a project's directory (plume init creates one)", .{});
            return error.Reported;
        };
        const config = std.json.parseFromSliceLeaky(Config, context.arena, text, .{ .ignore_unknown_fields = true }) catch |err| {
            cli.fail("plume.json: {s}", .{@errorName(err)});
            return error.Reported;
        };
        return .{ .config = config };
    }

    /// The dev server's port, from frontend.dev_url.
    pub fn devPort(project: Project) u16 {
        const url = project.config.frontend.dev_url;
        const colon = std.mem.lastIndexOfScalar(u8, url, ':') orelse return 5173;
        const end = std.mem.indexOfScalarPos(u8, url, colon, '/') orelse url.len;
        return std.fmt.parseInt(u16, url[colon + 1 .. end], 10) catch 5173;
    }

    /// Vite's command line script, wherever npm installed it.
    pub fn viteScript(project: Project, context: *cli.Context) ?[]const u8 {
        const candidates = [_][]const u8{
            "node_modules/vite/bin/vite.js",
            std.fmt.allocPrint(context.arena, "{s}/node_modules/vite/bin/vite.js", .{project.config.frontend.dir}) catch return null,
        };
        for (candidates) |candidate| {
            if (cli.exists(context, candidate))
                return std.Io.Dir.cwd().realPathFileAlloc(context.io, candidate, context.arena) catch candidate;
        }
        return null;
    }

    /// npm install, unless node_modules exists already.
    pub fn ensureDependencies(project: Project, context: *cli.Context) !void {
        _ = project;
        if (cli.exists(context, "node_modules"))
            return;
        cli.step("installing the frontend's dependencies (npm install)", .{});
        try cli.run(context, &.{ "npm", "install" }, null);
    }
};
