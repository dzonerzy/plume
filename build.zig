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

    b.step("bindings", "Write examples/hello/bindings.ts and bindings.d.ts")
        .dependOn(addBindings(b, b, b.path("examples/hello/app.zig"), "App", "examples/hello"));

    // The plume command line tool.
    const cli = b.addExecutable(.{
        .name = "plume",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "assets", .module = b.createModule(.{ .root_source_file = b.path("src/assets.zig"), .target = b.graph.host }) },
            },
        }),
    });
    cli.root_module.addAnonymousImport("templates", .{ .root_source_file = addFrontend(b, b, b.path("templates")) });
    addUpx(b, cli) orelse return;
    const cli_options = b.addOptions();
    cli_options.addOption([]const u8, "version", "0.1.0");
    cli_options.addOption([]const u8, "commit", gitCommit(b));
    cli_options.addOption([]const u8, "upx_version", upx_version);
    cli.root_module.addOptions("build_options", cli_options);
    const install_cli = b.addInstallArtifact(cli, .{});
    b.step("cli", "Build the plume command line tool").dependOn(&install_cli.step);

    // The unit tests that need no engine.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
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

    // What the application knows of its project: plume.json, the frontend.
    const project = b.addWriteFiles();
    _ = project.addCopyFile(b.path("plume.json"), "plume.json");
    if (dev_url == null)
        _ = project.addCopyFile(addFrontend(b, plume_b, b.path("frontend/dist")), "frontend.zga");
    const project_source = project.add("plume_project.zig", b.fmt(
        \\//! Generated by plume's addApp: the project, as the application sees it.
        \\pub const config = @embedFile("plume.json");
        \\pub const assets: ?[]const u8 = {s};
        \\pub const dev_url: ?[:0]const u8 = {s};
        \\
    , .{
        if (dev_url == null) "@embedFile(\"frontend.zga\")" else "null",
        if (dev_url) |url| b.fmt("\"{s}\"", .{url}) else "null",
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
    if (options.target.result.os.tag == .windows and !console) {
        // No console window; the C runtime still starts at main (its
        // WinMain-based startup is for programs that define WinMain).
        executable.subsystem = .windows;
        executable.entry = .{ .symbol_name = "mainCRTStartup" };
    }

    const bindings = addBindings(b, plume_b, b.path(options.bindings_source), options.bindings_type, options.bindings_output);
    executable.step.dependOn(bindings);
    return .{ .executable = executable, .bindings = bindings };
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
/// built for the host from the same Zig type writes them.
pub fn addBindings(b: *std.Build, plume_b: *std.Build, source: std.Build.LazyPath, type_name: []const u8, directory: []const u8) *std.Build.Step {
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
    // translated for the host (only types are used: nothing is linked).
    const host_engine = Engine.get(plume_b, host, .minimal);
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
pub const Engine = struct {
    dependency: *std.Build.Dependency,
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
        const name = b.fmt("zerog_{s}_{s}", .{ os_name, @tagName(profile) });
        const dependency = b.lazyDependency(name, .{}) orelse return null;
        return .{ .dependency = dependency, .os = os, .abi = target.result.abi };
    }

    pub fn path(engine: Engine, sub_path: []const u8) std.Build.LazyPath {
        return engine.dependency.path(sub_path);
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
        const full = engine.dependency.builder.root.joinString(b.allocator, sub_path) catch @panic("OOM");
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
