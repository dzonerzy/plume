const std = @import("std");
const builtin = @import("builtin");

/// The engine's profile: what the web platform of the application has.
pub const Profile = enum {
    /// Application UI: no media, WebGL, WebAssembly or service workers.
    minimal,
    /// Everything: media, WebGL, WebAssembly, service workers, Web Audio.
    standard,
    /// Standard plus the Web Inspector, for developing applications.
    dev,
};

/// The target applications are built for by default: the engine uses the MSVC
/// ABI on Windows (static CRT) and glibc 2.28 on Linux.
pub const default_target: std.Target.Query = switch (builtin.os.tag) {
    .windows => .{ .abi = .msvc },
    .linux => .{ .abi = .gnu, .glibc_version = .{ .major = 2, .minor = 28, .patch = 0 } },
    else => .{},
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option(Profile, "profile", "The engine's profile (minimal, standard, dev); default minimal") orelse .minimal;

    // Fetched on first use; the build runs again once it is there.
    const engine = Engine.get(b, target, profile) orelse return;
    const plume = b.addModule("plume", .{
        .root_source_file = b.path("src/plume.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zerog", .module = engine.translateC(b, target, optimize) }},
    });

    // The rest is for working on Plume itself, not for applications using it.
    if (b.pkg_hash.len != 0)
        return;

    // examples/hello: a window, its page from the binary, every kind of binding.
    const hello = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "plume", .module = plume }},
        }),
    });
    engine.link(hello);
    hello.root_module.addAnonymousImport("frontend", .{ .root_source_file = addFrontend(b, b, b.path("examples/hello/web")) });
    b.installArtifact(hello);

    const run_hello = b.addRunArtifact(hello);
    run_hello.step.dependOn(b.getInstallStep());
    run_hello.addPassthruArgs();
    b.step("hello", "Run examples/hello").dependOn(&run_hello.step);

    // examples/showcase: mockups of applications one could build (SHOWCASE.md).
    const showcase = b.addExecutable(.{
        .name = "showcase",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/showcase/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "plume", .module = plume }},
        }),
    });
    engine.link(showcase);
    showcase.root_module.addAnonymousImport("frontend", .{ .root_source_file = addFrontend(b, b, b.path("examples/showcase/web")) });
    b.installArtifact(showcase);
    const run_showcase = b.addRunArtifact(showcase);
    run_showcase.step.dependOn(b.getInstallStep());
    run_showcase.addPassthruArgs();
    b.step("showcase", "Run a mockup of examples/showcase (margin, spindle, kiln, gauge)").dependOn(&run_showcase.step);

    // examples/layer: OpenGL drawn by Zig under the page (a native layer).
    const layer = b.addExecutable(.{
        .name = "layer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/layer/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "plume", .module = plume }},
        }),
    });
    engine.link(layer);
    layer.root_module.addAnonymousImport("frontend", .{ .root_source_file = addFrontend(b, b, b.path("examples/layer/web")) });
    b.installArtifact(layer);
    const run_layer = b.addRunArtifact(layer);
    run_layer.step.dependOn(b.getInstallStep());
    run_layer.addPassthruArgs();
    b.step("layer", "Run examples/layer (a native layer)").dependOn(&run_layer.step);

    // examples/margin: a real notes application, and its UI tests.
    const margin_frontend = addFrontend(b, b, b.path("examples/margin/web"));
    const margin = b.addExecutable(.{
        .name = "margin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/margin/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "plume", .module = plume }},
        }),
    });
    engine.link(margin);
    margin.root_module.addAnonymousImport("frontend", .{ .root_source_file = margin_frontend });
    b.installArtifact(margin);
    const run_margin = b.addRunArtifact(margin);
    run_margin.step.dependOn(b.getInstallStep());
    run_margin.addPassthruArgs();
    b.step("margin", "Run examples/margin (notes in Markdown files)").dependOn(&run_margin.step);
    const margin_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/margin/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "plume", .module = plume }},
    }) });
    engine.link(margin_tests);
    margin_tests.root_module.addAnonymousImport("frontend", .{ .root_source_file = margin_frontend });
    const run_margin_tests = b.addRunArtifact(margin_tests);
    run_margin_tests.setEnvironmentVariable("PLUME_PROJECT_DIR", b.root.toString(b.allocator) catch @panic("OOM"));
    run_margin_tests.has_side_effects = true;
    b.step("margin-test", "Run examples/margin's UI tests (headless)").dependOn(&run_margin_tests.step);
    b.step("margin-test-binary", "Install examples/margin's UI tests as bin/margin-test").dependOn(&b.addInstallArtifact(margin_tests, .{ .dest_sub_path = "margin-test" }).step);

    // tests/ui: plume.testing on a fixture page, headless.
    const ui_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/ui/ui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "plume", .module = plume }},
    }) });
    engine.link(ui_tests);
    ui_tests.root_module.addAnonymousImport("fixture", .{ .root_source_file = addFrontend(b, b, b.path("tests/ui/web")) });
    const run_ui_tests = b.addRunArtifact(ui_tests);
    run_ui_tests.setEnvironmentVariable("PLUME_PROJECT_DIR", b.root.toString(b.allocator) catch @panic("OOM"));
    // Snapshots are files the build does not track: always run.
    run_ui_tests.has_side_effects = true;
    b.step("ui-test", "Run tests/ui (plume.testing, headless)").dependOn(&run_ui_tests.step);
    // The same as an executable (bin/plume-ui-test), for another machine
    // (built with -Dtarget, run with PLUME_PROJECT_DIR set).
    b.step("ui-test-binary", "Install tests/ui as bin/plume-ui-test").dependOn(&b.addInstallArtifact(ui_tests, .{ .dest_sub_path = "plume-ui-test" }).step);

    b.step("bindings", "Write examples/hello/bindings.ts and bindings.d.ts")
        .dependOn(addBindings(b, b, b.path("examples/hello/app.zig"), "App", "examples/hello", engine));

    // The plume command line tool: for this machine, or -Dcli-target's (the
    // release's Linux and Windows binaries).
    const cli_target = if (b.option([]const u8, "cli-target", "The plume tool's target (default: this machine)")) |triple|
        b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple }) catch @panic("-Dcli-target: not a target triple"))
    else
        b.graph.host;
    const cli = b.addExecutable(.{
        .name = "plume",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = cli_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "assets", .module = b.createModule(.{ .root_source_file = b.path("src/assets.zig"), .target = cli_target }) },
                // Updates' gzip, as the applications read it.
                .{ .name = "update_core", .module = b.createModule(.{ .root_source_file = b.path("src/update.zig"), .target = cli_target }) },
            },
        }),
    });
    cli.root_module.addAnonymousImport("templates", .{ .root_source_file = addFrontend(b, b, b.path("templates")) });
    addUpx(b, cli) orelse return;
    const cli_options = b.addOptions();
    cli_options.addOption([]const u8, "version", "0.2.0");
    cli_options.addOption([]const u8, "commit", gitCommit(b));
    cli_options.addOption([]const u8, "upx_version", upx_version);
    cli.root_module.addOptions("build_options", cli_options);
    const install_cli = b.addInstallArtifact(cli, .{});
    b.step("cli", "Build the plume command line tool").dependOn(&install_cli.step);

    // The unit tests that need no engine (its API's types, for menu.zig).
    const host_engine = if (engine.os == b.graph.host.result.os.tag) engine else Engine.get(b, b.graph.host, .minimal) orelse return;
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "zerog", .module = host_engine.translateC(b, b.graph.host, optimize) }},
    }) });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}

// ---- For applications: their build.zig calls addApp ----

pub const AppOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// The executable's name; default the project directory's.
    name: ?[]const u8 = null,
    root_source_file: ?std.Build.LazyPath = null,
    /// The binding type the frontend's bindings.ts is generated from.
    bindings_source: []const u8 = "src/app.zig",
    bindings_type: []const u8 = "App",
    bindings_output: []const u8 = "frontend/src",
    /// The application's icon, a square PNG of 256 pixels or more; default
    /// the project's icon.png, if there is one.
    icon: ?std.Build.LazyPath = null,
};

pub const AppResult = struct {
    executable: *std.Build.Step.Compile,
    /// Writes frontend/src/bindings.ts; the executable depends on it.
    bindings: *std.Build.Step,
};

/// The application of a Plume project (`plume init` writes its build.zig):
/// src/main.zig linked with the engine, plume.json and the built frontend
/// embedded, bindings.ts generated. Options from the command line (plume dev
/// and plume build pass them): -Dprofile, -Ddev-url (the frontend's dev
/// server: nothing embedded), -Dconsole. Null while the engine is being
/// fetched.
pub fn addApp(b: *std.Build, options: AppOptions) ?AppResult {
    const profile = b.option(Profile, "profile", "The engine's profile (minimal, standard, dev)") orelse .minimal;
    const dev_url = b.option([]const u8, "dev-url", "Load the frontend from this dev server instead of embedding it");
    const console = b.option(bool, "console", "Windows: a console for the output (default: in debug builds)") orelse (options.optimize == .debug);

    const dependency = b.dependency("plume", .{ .target = options.target, .optimize = options.optimize, .profile = profile });
    const plume_b = dependency.builder;
    const engine = Engine.get(plume_b, options.target, profile) orelse return null;

    // The icon: the executable's on Windows (a resource), the windows'
    // elsewhere and the tray's everywhere (RGBA the application sets), and
    // the PNG notifications show.
    const windows = options.target.result.os.tag == .windows;
    const icon_png = options.icon orelse if (projectHas(b, "icon.png")) b.path("icon.png") else null;
    const icon_dir = if (icon_png) |png| addIcon(b, plume_b, png) else null;

    // What the application knows of its project: plume.json, the frontend.
    const project = b.addWriteFiles();
    _ = project.addCopyFile(b.path("plume.json"), "plume.json");
    if (dev_url == null)
        _ = project.addCopyFile(addFrontend(b, plume_b, b.path("frontend/dist")), "frontend.zga");
    if (icon_dir) |dir| _ = project.addCopyFile(dir.path(b, "icon.rgba"), "icon.rgba");
    if (icon_png) |png| _ = project.addCopyFile(png, "icon.png");
    const project_source = project.add("plume_project.zig", b.fmt(
        \\//! Generated by plume's addApp: the project, as the application sees it.
        \\pub const config = @embedFile("plume.json");
        \\pub const assets: ?[]const u8 = {s};
        \\pub const dev_url: ?[:0]const u8 = {s};
        \\/// icon_size × icon_size RGBA, for the windows and the tray (on
        \\/// Windows the executable has its own for the windows).
        \\pub const icon: ?[]const u8 = {s};
        \\pub const icon_size = 128;
        \\/// The icon.png, for notifications.
        \\pub const icon_png: ?[]const u8 = {s};
        \\
    , .{
        if (dev_url == null) "@embedFile(\"frontend.zga\")" else "null",
        if (dev_url) |url| b.fmt("\"{s}\"", .{url}) else "null",
        if (icon_dir != null) "@embedFile(\"icon.rgba\")" else "null",
        if (icon_png != null) "@embedFile(\"icon.png\")" else "null",
    }));

    const name = options.name orelse std.fs.path.basename(b.root.toString(b.allocator) catch @panic("OOM"));
    const executable = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = options.root_source_file orelse b.path("src/main.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{
                .{ .name = "plume", .module = dependency.module("plume") },
                .{ .name = "plume_project", .module = b.createModule(.{ .root_source_file = project_source }) },
            },
        }),
    });
    engine.link(executable);
    // The icon beside the executable (share/), for plume package.
    if (icon_dir) |dir| b.getInstallStep().dependOn(&b.addInstallFileWithDir(dir.path(b, "icon.ico"), .prefix, "share/icon.ico").step);
    if (icon_png) |png| b.getInstallStep().dependOn(&b.addInstallFileWithDir(png, .prefix, "share/icon.png").step);
    if (windows) {
        if (icon_dir) |dir| executable.root_module.addWin32ResourceFile(.{ .file = dir.path(b, "app.rc") });
        // Version information (Explorer's Details, installers) and a manifest,
        // from plume.json (Plume's tools/resources.zig).
        const resources = addResources(b, plume_b, b.path("plume.json"), name);
        executable.root_module.addWin32ResourceFile(.{ .file = resources.path(b, "version.rc") });
        executable.win32_manifest = resources.path(b, "app.manifest");
    }
    if (windows and !console) {
        // No console window; the C runtime still starts at main (its
        // WinMain-based startup is for programs that define WinMain).
        executable.subsystem = .windows;
        executable.entry = .{ .symbol_name = "mainCRTStartup" };
    }

    const bindings = addBindings(b, plume_b, b.path(options.bindings_source), options.bindings_type, options.bindings_output, engine);
    executable.step.dependOn(bindings);

    // The project's UI tests (src/tests.zig, plume.testing): `zig build test`,
    // or plume test (which builds the frontend first).
    if (projectHas(b, "src/tests.zig") and !b.top_level_steps.contains("test")) {
        const filter = b.option([]const u8, "test-filter", "Run only the tests whose names contain this");
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tests.zig"),
                .target = options.target,
                .optimize = options.optimize,
                .imports = &.{
                    .{ .name = "plume", .module = dependency.module("plume") },
                    .{ .name = "plume_project", .module = b.createModule(.{ .root_source_file = project_source }) },
                },
            }),
            .filters = if (filter) |f| b.dupeStrings(&.{f}) else &.{},
        });
        engine.link(tests);
        const run_tests = b.addRunArtifact(tests);
        run_tests.setEnvironmentVariable("PLUME_PROJECT_DIR", b.root.toString(b.allocator) catch @panic("OOM"));
        // Snapshots are files the build does not track: always run.
        run_tests.has_side_effects = true;
        run_tests.step.dependOn(bindings);
        b.step("test", "Run the UI tests (src/tests.zig)").dependOn(&run_tests.step);
    }
    return .{ .executable = executable, .bindings = bindings };
}

/// A directory with version.rc and app.manifest made from `config`
/// (plume.json) by Plume's tools/resources.zig: a step, so plume.json's
/// changes reach the executable.
pub fn addResources(b: *std.Build, plume_b: *std.Build, config: std.Build.LazyPath, executable_name: []const u8) std.Build.LazyPath {
    const tool = b.addExecutable(.{
        .name = "plume-resources",
        .root_module = b.createModule(.{
            .root_source_file = plume_b.path("tools/resources.zig"),
            .target = b.graph.host,
            .optimize = .fast,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addFileArg(config);
    run.addArg(executable_name);
    return run.addOutputDirectoryArg("resources");
}

fn projectHas(b: *std.Build, sub_path: []const u8) bool {
    const full = b.root.joinString(b.allocator, sub_path) catch @panic("OOM");
    _ = std.Io.Dir.cwd().statFile(b.graph.io, full, .{}) catch return false;
    return true;
}

/// A directory with the application's icon made from `png` (Plume's
/// tools/icon.zig): icon.ico and app.rc for Windows, icon.rgba for a window.
pub fn addIcon(b: *std.Build, plume_b: *std.Build, png: std.Build.LazyPath) std.Build.LazyPath {
    const host = b.graph.host;
    const tool = b.addExecutable(.{
        .name = "plume-icon",
        .root_module = b.createModule(.{
            .root_source_file = plume_b.path("tools/icon.zig"),
            .target = host,
            .optimize = .fast,
            .imports = &.{.{ .name = "icon", .module = b.createModule(.{ .root_source_file = plume_b.path("src/icon.zig"), .target = host }) }},
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addFileArg(png);
    return run.addOutputDirectoryArg("icon");
}

/// The frontend in `directory` (a built one: Vite's dist/) as a ZeroG asset
/// archive, for `module.addAnonymousImport("frontend", ...)` and
/// `@embedFile("frontend")`. `plume_b`: Plume's build (its packer).
pub fn addFrontend(b: *std.Build, plume_b: *std.Build, directory: std.Build.LazyPath) std.Build.LazyPath {
    const host = b.graph.host;
    const pack = b.addExecutable(.{
        .name = "plume-pack",
        .root_module = b.createModule(.{
            .root_source_file = plume_b.path("tools/pack.zig"),
            .target = host,
            .optimize = .fast,
            .imports = &.{.{ .name = "assets", .module = b.createModule(.{ .root_source_file = plume_b.path("src/assets.zig"), .target = host }) }},
        }),
    });
    const run = b.addRunArtifact(pack);
    run.addDirectoryArg(directory);
    // The build cache knows the directory, not the files in it: packed on
    // every build (milliseconds); an unchanged archive rebuilds nothing.
    run.has_side_effects = true;
    return run.addOutputFileArg("frontend.zga");
}

/// A step writing bindings.ts and bindings.d.ts for the binding type
/// `type_name` of `source` into `directory` (in the source tree). A generator
/// built for the host from the same Zig type writes them. `app_engine`: the one
/// the application links, if any; its zerog.h serves when it is for this OS
/// (every profile has the same), else the host's minimal package is fetched.
pub fn addBindings(b: *std.Build, plume_b: *std.Build, source: std.Build.LazyPath, type_name: []const u8, directory: []const u8, app_engine: ?Engine) *std.Build.Step {
    const generator_source = b.addWriteFiles().add("generate_bindings.zig", b.fmt(
        \\const std = @import("std");
        \\const typescript = @import("plume").typescript;
        \\const app = @import("app");
        \\
        \\pub fn main(init: std.process.Init) !void {{
        \\    const args = try init.minimal.args.toSlice(init.arena.allocator());
        \\    const kind: typescript.Kind = if (std.mem.eql(u8, args[1], "declarations")) .declarations else .module;
        \\    var buffer: [8192]u8 = undefined;
        \\    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
        \\    try typescript.write(app.{s}, "{s}", kind, &stdout.interface);
        \\    try stdout.interface.flush();
        \\}}
        \\
    , .{ type_name, type_name }));
    const host = b.graph.host;
    // The binding type may import plume: a host build of it, its engine API
    // translated for the host (only types are used: nothing is linked). One
    // package fewer to fetch: Zig's HTTP client fails two at once from GitHub.
    const host_engine = if (app_engine != null and app_engine.?.os == host.result.os.tag) app_engine else Engine.get(plume_b, host, .minimal);
    const plume_host = b.createModule(.{
        .root_source_file = plume_b.path("src/plume.zig"),
        .target = host,
        .imports = if (host_engine) |engine| &.{.{ .name = "zerog", .module = engine.translateC(b, host, .debug) }} else &.{},
    });
    const generator = b.addExecutable(.{
        .name = "generate-bindings",
        .root_module = b.createModule(.{
            .root_source_file = generator_source,
            .target = host,
            .imports = &.{
                .{ .name = "plume", .module = plume_host },
                .{ .name = "app", .module = b.createModule(.{ .root_source_file = source, .target = host, .imports = &.{.{ .name = "plume", .module = plume_host }} }) },
            },
        }),
    });
    // Listing a method's inferred error set compiles its body, which may call
    // the engine; the generator never runs one, so stand-ins satisfy the
    // linker instead of the engine itself.
    if (host_engine) |engine| generator.root_module.addCSourceFile(.{ .file = engineStubs(b, engine) });
    const update = b.addUpdateSourceFiles();
    for ([_][]const u8{ "module", "declarations" }) |kind| {
        const run = b.addRunArtifact(generator);
        run.addArg(kind);
        const file = if (std.mem.eql(u8, kind, "module")) "bindings.ts" else "bindings.d.ts";
        update.addCopyFileToSource(run.captureStdOut(.{}), b.pathJoin(&.{ directory, file }));
    }
    return &update.step;
}

/// A C file defining every function of zerog.h (the names after ZG_API) as
/// an empty one: for programs that reference the engine without calling it.
fn engineStubs(b: *std.Build, engine: Engine) std.Build.LazyPath {
    const header = engine.read(b, "include/zerog.h");
    var source: std.ArrayList(u8) = .empty;
    source.appendSlice(b.allocator, "/* Generated by Plume's build: stand-ins, never called. */\n") catch @panic("OOM");
    var rest = header;
    while (std.mem.indexOf(u8, rest, "ZG_API ")) |start| {
        rest = rest[start + "ZG_API ".len ..];
        const paren = std.mem.indexOfScalar(u8, rest, '(') orelse break;
        const before = std.mem.trimEnd(u8, rest[0..paren], " \t");
        var name_start = before.len;
        while (name_start > 0 and (std.ascii.isAlphanumeric(before[name_start - 1]) or before[name_start - 1] == '_')) name_start -= 1;
        const name = before[name_start..];
        // "#define ZG_API ..." and the like are not functions.
        if (!std.mem.startsWith(u8, name, "zg_")) continue;
        source.print(b.allocator, "void {s}(void) {{}}\n", .{name}) catch @panic("OOM");
    }
    return b.addWriteFiles().add("zerog_stubs.c", source.items);
}

/// A ZeroG release package for the target and profile (unpacked without its
/// top-level directory, as Zig does with an archive holding only one).
///
/// The environment variable PLUME_ZEROG_DIR names a directory of unpacked
/// packages, one per "<os>-<profile>" ("windows-minimal/include/zerog.h"...):
/// they are used instead of the released ones (an engine being worked on).
pub const Engine = struct {
    owner: *std.Build,
    root: std.Build.LazyPath,
    /// The same, as a path to read files from while configuring.
    root_path: []const u8,
    os: std.Target.Os.Tag,
    abi: std.Target.Abi,

    /// `b` is Plume's build (the packages are its dependencies).
    pub fn get(b: *std.Build, target: std.Build.ResolvedTarget, profile: Profile) ?Engine {
        const os = target.result.os.tag;
        const os_name = switch (os) {
            .windows => "windows",
            .linux => "linux",
            else => std.debug.panic("Plume runs on Windows and Linux, not {s}", .{@tagName(os)}),
        };
        if (target.result.cpu.arch != .x86_64)
            std.debug.panic("the engine is built for x86_64, not {s}", .{@tagName(target.result.cpu.arch)});
        if (b.graph.environ_map.get("PLUME_ZEROG_DIR")) |dir| {
            const local = b.pathJoin(&.{ dir, b.fmt("{s}-{s}", .{ os_name, @tagName(profile) }) });
            const header = b.pathJoin(&.{ local, "include", "zerog.h" });
            if (std.Io.Dir.cwd().statFile(b.graph.io, header, .{})) |_| {
                return .{ .owner = b, .root = .{ .cwd_relative = local }, .root_path = local, .os = os, .abi = target.result.abi };
            } else |_| {}
        }
        const name = b.fmt("zerog_{s}_{s}", .{ os_name, @tagName(profile) });
        const dependency = b.lazyDependency(name, .{}) orelse return null;
        return .{
            .owner = b,
            .root = dependency.path(""),
            .root_path = dependency.builder.root.toString(b.allocator) catch @panic("OOM"),
            .os = os,
            .abi = target.result.abi,
        };
    }

    pub fn path(engine: Engine, sub_path: []const u8) std.Build.LazyPath {
        return engine.root.path(engine.owner, sub_path);
    }

    /// include/zerog.h as a Zig module.
    pub fn translateC(engine: Engine, b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
        return b.addTranslateC(.{
            .root_source_file = engine.path("include/zerog.h"),
            .target = target,
            .optimize = optimize,
        }).createModule();
    }

    /// Links the engine into an executable: the bundle and the system
    /// libraries its package lists (lib/zerog-engine.libs.txt).
    pub fn link(engine: Engine, executable: *std.Build.Step.Compile) void {
        if (engine.os == .windows and engine.abi != .msvc)
            std.debug.panic("the engine uses the MSVC ABI on Windows: build with -Dtarget=x86_64-windows-msvc", .{});
        const module = executable.root_module;
        module.link_libc = true;
        // The bundle is one large relocatable object in an archive, which
        // LLD links and Zig's own ELF linker does not (yet); LLD takes the
        // LLVM backend's objects only.
        executable.use_llvm = true;
        executable.use_lld = true;
        module.addObjectFile(engine.path(switch (engine.os) {
            .windows => "lib/zerog-engine.lib",
            else => "lib/libzerog-engine.a",
        }));
        // The list depends on the profile (standard adds Media Foundation on
        // Windows): one name per line, "name.lib" on Windows, "-lname" on Linux.
        const b = executable.step.owner;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var lines = std.mem.tokenizeAny(u8, engine.read(b, "lib/zerog-engine.libs.txt"), "\r\n");
        while (lines.next()) |line| {
            var name = std.mem.trim(u8, line, " \t");
            if (std.mem.startsWith(u8, name, "-l")) name = name[2..];
            if (std.ascii.endsWithIgnoreCase(name, ".lib")) name = name[0 .. name.len - 4];
            if (name.len == 0) continue;
            const key = std.ascii.allocLowerString(b.allocator, name) catch @panic("OOM");
            if ((seen.getOrPut(b.allocator, key) catch @panic("OOM")).found_existing) continue;
            module.linkSystemLibrary(key, .{});
        }
    }

    /// A file of the package, read while configuring the build.
    fn read(engine: Engine, b: *std.Build, sub_path: []const u8) []const u8 {
        const full = b.pathJoin(&.{ engine.root_path, sub_path });
        return std.Io.Dir.cwd().readFileAlloc(b.graph.io, full, b.allocator, .limited(1 << 20)) catch |err|
            std.debug.panic("the engine package: {s}: {s}", .{ full, @errorName(err) });
    }
};

// ---- The plume tool's own dependencies ----

/// UPX, compiled from its sources into the plume tool (plume build --compress):
/// a library there, called in-process. The plume executable is therefore a
/// GPLv2+ work (UPX's license); Plume's sources stay BSD, and the
/// applications it builds are not affected.
const upx_version = "5.3.0";

/// UPX's C++ (in library mode: WITH_GUI throws where the command would exit,
/// and has no main) with UCL, zlib and the LZMA SDK, linked into `executable`
/// with the shim plume calls (src/cli/upx.cpp). Null while being fetched.
fn addUpx(b: *std.Build, executable: *std.Build.Step.Compile) ?void {
    const upx = b.lazyDependency("upx", .{}) orelse return null;
    const module = executable.root_module;
    module.link_libcpp = true;
    const flags = [_][]const u8{
        // As UPX's CMakeLists for clang.
        "-std=c++17",              "-fno-delete-null-pointer-checks",
        "-fno-strict-aliasing",    "-fno-strict-overflow",            "-funsigned-char",
        "-DWITH_GUI=1",            "-DWITH_THREADS=1",                "-DUPX_CONFIG_DISABLE_WERROR=1",
        "-DUPX_CONFIG_DISABLE_WSTRICT=1",
    };
    module.addIncludePath(upx.path("vendor"));
    module.addIncludePath(upx.path("src"));
    // As UPX's CMakeLists: src/*.cpp and src/[cfu]*/*.cpp.
    for ([_][]const u8{ "src", "src/check", "src/compress", "src/console", "src/filter", "src/util" }) |directory| {
        module.addCSourceFiles(.{ .root = upx.path(directory), .files = upxSources(b, upx, directory), .flags = &flags });
    }
    const c_flags = [_][]const u8{ "-std=c11", "-fno-strict-aliasing", "-DHAVE_VSNPRINTF=1" };
    module.addIncludePath(upx.path("vendor/ucl/include"));
    module.addIncludePath(upx.path("vendor/ucl"));
    module.addCSourceFiles(.{ .root = upx.path("vendor/ucl/src"), .files = upxSources(b, upx, "vendor/ucl/src"), .flags = &c_flags });
    // zlib's gz* files take read/lseek/close from unistd.h where there is one.
    const zlib_flags: []const []const u8 = if (executable.rootModuleTarget().os.tag == .windows)
        &c_flags
    else
        &(c_flags ++ [_][]const u8{"-DHAVE_UNISTD_H=1"});
    module.addCSourceFiles(.{ .root = upx.path("vendor/zlib"), .files = upxSources(b, upx, "vendor/zlib"), .flags = zlib_flags });
    module.addCSourceFile(.{ .file = b.path("src/cli/upx.cpp"), .flags = &flags });
}

/// The C and C++ files of a UPX source directory (not its subdirectories).
fn upxSources(b: *std.Build, upx: *std.Build.Dependency, directory: []const u8) []const []const u8 {
    const io = b.graph.io;
    const full = upx.builder.root.joinString(b.allocator, directory) catch @panic("OOM");
    var dir = std.Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch |err|
        std.debug.panic("UPX sources: {s}: {s}", .{ full, @errorName(err) });
    defer dir.close(io);
    var files: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        // The full-screen console (s_*.cpp, c_screen.cpp): not in library mode.
        if (std.mem.endsWith(u8, directory, "console") and
            (std.mem.startsWith(u8, entry.name, "s_") or std.mem.eql(u8, entry.name, "c_screen.cpp"))) continue;
        if (std.mem.endsWith(u8, entry.name, ".cpp") or std.mem.endsWith(u8, entry.name, ".c"))
            files.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lessThan);
    return files.items;
}

fn gitCommit(b: *std.Build) []const u8 {
    var code: u8 = 0;
    const root = b.root.toString(b.allocator) catch return "unknown";
    const out = b.runAllowFail(&.{ "git", "-C", if (root.len == 0) "." else root, "rev-parse", "HEAD" }, &code, .ignore) catch return "unknown";
    return std.mem.trim(u8, out, " \r\n");
}
