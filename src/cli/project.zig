//! A Plume project: the directory with plume.json, and what plume dev and
//! plume build take from it.

const std = @import("std");
const cli = @import("main.zig");

pub const Config = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    /// "1.2.3": the executable's version information, the packages', and
    /// what updates compare.
    version: []const u8 = "0.1.0",
    publisher: ?[]const u8 = null,
    description: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    /// Files the application opens (plume package registers it for them):
    /// opened, the file's path is an argument of the launch.
    file_associations: []const FileAssociation = &.{},
    /// URL schemes ("myapp" for myapp://...) the application handles: the
    /// URL is an argument of the launch.
    protocols: []const []const u8 = &.{},
    /// Code signing of the executable and the installer (Windows, signtool):
    /// a .pfx file (its password in the environment variable password_env),
    /// or a certificate of the user's store by its SHA-1 thumbprint.
    signing: ?struct {
        certificate: ?[]const u8 = null,
        thumbprint: ?[]const u8 = null,
        password_env: []const u8 = "PLUME_SIGN_PASSWORD",
        /// RFC 3161; null: not timestamped (the signature ends with the
        /// certificate).
        timestamp_url: ?[]const u8 = "http://timestamp.digicert.com",
    } = null,
    /// Signed updates from GitHub releases (plume.update).
    update: ?struct { github: []const u8, public_key: []const u8 } = null,
    /// Linux: the .desktop file's categories ("Utility;Development;").
    categories: []const u8 = "Utility;",
    profile: []const u8 = "minimal",
    /// false, true, or "best" (slower, a little smaller).
    compress: std.json.Value = .{ .bool = false },
    frontend: struct {
        dir: []const u8 = "frontend",
        dev_url: []const u8 = "http://localhost:5173",
    } = .{},
};

pub const FileAssociation = struct {
    /// Without the dot: "md".
    ext: []const u8,
    /// "Markdown document".
    name: []const u8,
    /// "text/markdown"; default application/x-<app name>-<ext>.
    mime: ?[]const u8 = null,
};

pub const Project = struct {
    config: Config,

    pub fn title(project: Project) []const u8 {
        return project.config.title orelse project.config.name;
    }

    pub fn appId(project: Project, context: *cli.Context) []const u8 {
        return project.config.app_id orelse std.fmt.allocPrint(context.arena, "plume.{s}", .{project.config.name}) catch project.config.name;
    }

    pub fn publisher(project: Project) []const u8 {
        return project.config.publisher orelse project.config.name;
    }

    /// As build.zig puts it in the executable's version information.
    pub fn copyright(project: Project, context: *cli.Context) []const u8 {
        return project.config.copyright orelse std.fmt.allocPrint(context.arena, "Copyright (C) {s}", .{project.publisher()}) catch "";
    }

    pub fn description(project: Project) []const u8 {
        return project.config.description orelse project.title();
    }

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
