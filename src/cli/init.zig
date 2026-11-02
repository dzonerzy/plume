//! plume init <name> [--template vanilla|react|svelte|vue] [--no-install]
//!            [--title <text>] [--app-id <id>] [--plume <path>]
//!
//! Writes a project from the templates embedded in plume (templates/: base/
//! for every project, <template>/ for its frontend), with Plume as a Zig
//! dependency (fetched with zig fetch, or --plume: a local checkout), then
//! runs npm install.

const std = @import("std");
const assets = @import("assets");
const cli = @import("main.zig");
const build_options = @import("build_options");

const templates = [_][]const u8{ "vanilla", "react", "svelte", "vue" };

pub fn run(context: *cli.Context) !void {
    var name: ?[]const u8 = null;
    var template: []const u8 = "vanilla";
    var install = true;
    var title: ?[]const u8 = null;
    var app_id: ?[]const u8 = null;
    var plume_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < context.args.len) : (i += 1) {
        const arg = context.args[i];
        if (cli.eql(arg, "--no-install")) {
            install = false;
        } else if (cli.eql(arg, "--template") or cli.eql(arg, "-t") or cli.eql(arg, "--title") or cli.eql(arg, "--app-id") or cli.eql(arg, "--plume")) {
            i += 1;
            if (i == context.args.len) {
                cli.fail("{s} needs a value", .{arg});
                return error.Reported;
            }
            const value = context.args[i];
            if (cli.eql(arg, "--title")) title = value else if (cli.eql(arg, "--app-id")) app_id = value else if (cli.eql(arg, "--plume")) plume_path = value else template = value;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            cli.fail("unknown option {s}", .{arg});
            return error.Reported;
        } else if (name == null) {
            name = arg;
        } else {
            cli.fail("one project name only ({s}, then {s})", .{ name.?, arg });
            return error.Reported;
        }
    }

    const project = name orelse {
        cli.fail("usage: plume init <name> [--template vanilla|react|svelte|vue]", .{});
        return error.Reported;
    };
    if (!validName(project)) {
        cli.fail("\"{s}\": a project name is lowercase letters, digits and '-', starting with a letter", .{project});
        return error.Reported;
    }
    for (templates) |known| {
        if (cli.eql(known, template)) break;
    } else {
        cli.fail("no template \"{s}\": vanilla, react, svelte or vue", .{template});
        return error.Reported;
    }
    if (cli.exists(context, project)) {
        cli.fail("{s} exists already", .{project});
        return error.Reported;
    }

    const project_title = title orelse try titleOf(context.arena, project);
    const project_app_id = app_id orelse try std.fmt.allocPrint(context.arena, "com.example.{s}", .{project});
    const values = [_][2][]const u8{
        .{ "{{name}}", project },
        .{ "{{title}}", project_title },
        .{ "{{app_id}}", project_app_id },
    };

    cli.step("creating {s} ({s} template)", .{ project, template });
    const files = try assets.unpack(context.arena, @embedFile("templates"));
    const io = context.io;
    const cwd = std.Io.Dir.cwd();
    var written: usize = 0;
    for (files) |file| {
        // "/base/src/main.zig", "/react/frontend/src/Root.tsx".
        const relative = for ([_][]const u8{ "base", template }) |part| {
            const prefix = try std.fmt.allocPrint(context.arena, "/{s}/", .{part});
            if (std.mem.startsWith(u8, file.path, prefix)) break file.path[prefix.len..];
        } else continue;
        // Packed without the dot (a dotfile would be easy to lose).
        const target_name = if (cli.eql(relative, "gitignore")) ".gitignore" else relative;
        const target = try std.fs.path.join(context.arena, &.{ project, target_name });
        if (std.fs.path.dirname(target)) |directory| try cwd.createDirPath(io, directory);
        // Images as they are; text with the project's name and title.
        const binary = std.mem.endsWith(u8, relative, ".png") or std.mem.endsWith(u8, relative, ".ico");
        const data = if (binary) file.data else try substitute(context.arena, file.data, &values);
        try cwd.writeFile(io, .{ .sub_path = target, .data = data });
        written += 1;
    }

    // build.zig.zon: the package's name, a fingerprint of its own, Plume.
    const zig_name = try context.arena.dupe(u8, project);
    std.mem.replaceScalar(u8, zig_name, '-', '_');
    var id: u32 = 0;
    while (id == 0 or id == 0xffffffff) {
        var bytes: [4]u8 = undefined;
        io.random(&bytes);
        id = std.mem.readInt(u32, &bytes, .little);
    }
    const fingerprint = (@as(u64, std.hash.Crc32.hash(zig_name)) << 32) | id;
    const plume_dependency = if (plume_path) |path| blk: {
        const absolute = try cwd.realPathFileAlloc(io, path, context.arena);
        const from = try cwd.realPathFileAlloc(io, project, context.arena);
        const relative = try std.fs.path.relativeAlloc(context.arena, from, null, from, absolute);
        std.mem.replaceScalar(u8, relative, '\\', '/');
        break :blk try std.fmt.allocPrint(context.arena, "        .plume = .{{ .path = \"{s}\" }},\n", .{relative});
    } else "";
    const zon = try std.fmt.allocPrint(context.arena,
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x{x}, // Changing this has security and trust implications.
        \\    .minimum_zig_version = "0.17.0",
        \\    .dependencies = .{{
        \\{s}    }},
        \\    .paths = .{{ "build.zig", "build.zig.zon", "src", "plume.json" }},
        \\}}
        \\
    , .{ zig_name, fingerprint, plume_dependency });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(context.arena, &.{ project, "build.zig.zon" }), .data = zon });
    cli.step("wrote {d} files", .{written + 1});

    if (plume_path == null) {
        const url = try std.fmt.allocPrint(context.arena, "git+https://github.com/dzonerzy/plume#{s}", .{build_options.commit});
        cli.step("adding Plume to build.zig.zon (zig fetch)", .{});
        try cli.run(context, &.{ "zig", "fetch", "--save=plume", url }, project);
    }
    if (install) {
        cli.step("installing the frontend's dependencies (npm install)", .{});
        try cli.run(context, &.{ "npm", "install" }, project);
    }

    std.debug.print(
        \\
        \\Done. Next:
        \\  cd {s}
        \\{s}  npm run dev      (plume dev: the app, live on Vite's dev server)
        \\  npm run build    (plume build: build/bin/{s})
        \\
    , .{ project, if (install) "" else "  npm install\n", cli.executableName(context, project) });
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or !std.ascii.isLower(name[0])) return false;
    for (name) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    }
    return name[name.len - 1] != '-';
}

/// "my-app" → "My App".
fn titleOf(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const title = try allocator.dupe(u8, name);
    var start = true;
    for (title) |*c| {
        if (c.* == '-') {
            c.* = ' ';
            start = true;
        } else {
            if (start) c.* = std.ascii.toUpper(c.*);
            start = false;
        }
    }
    return title;
}

fn substitute(allocator: std.mem.Allocator, text: []const u8, values: []const [2][]const u8) ![]const u8 {
    var result: []const u8 = text;
    for (values) |pair| {
        result = try std.mem.replaceOwned(u8, allocator, result, pair[0], pair[1]);
    }
    return result;
}

test "names and titles" {
    try std.testing.expect(validName("my-app"));
    try std.testing.expect(validName("notes2"));
    try std.testing.expect(!validName("My-App"));
    try std.testing.expect(!validName("2notes"));
    try std.testing.expect(!validName("app-"));
    try std.testing.expect(!validName("my_app"));
    const title = try titleOf(std.testing.allocator, "my-cool-app");
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("My Cool App", title);
}
