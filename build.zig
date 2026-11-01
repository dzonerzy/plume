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

pub fn build(b: *std.Build) void {
    // The engine is built with the MSVC ABI on Windows (static CRT) and for
    // glibc on Linux: applications link it with the same.
    const target = b.standardTargetOptions(.{ .default_target = if (builtin.os.tag == .windows) .{ .abi = .msvc } else .{} });
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option(Profile, "profile", "The engine's profile (minimal, standard, dev); default minimal") orelse .minimal;

    // Fetched on first use; the build runs again once it is there.
    const engine = Engine.get(b, target, profile) orelse return;

    const zerog = b.addTranslateC(.{
        .root_source_file = engine.path("include/zerog.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();

    const plume = b.addModule("plume", .{
        .root_source_file = b.path("src/plume.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zerog", .module = zerog }},
    });

    // examples/hello: a window, a page, a binding.
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
    b.installArtifact(hello);

    const run_hello = b.addRunArtifact(hello);
    run_hello.step.dependOn(b.getInstallStep());
    run_hello.addPassthruArgs();
    b.step("hello", "Run examples/hello").dependOn(&run_hello.step);

    // The TypeScript of examples/hello's App, next to it.
    b.step("bindings", "Write examples/hello/bindings.ts and bindings.d.ts")
        .dependOn(addBindings(b, b.path("examples/hello/app.zig"), "App", "examples/hello"));

    // The unit tests that need no engine.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}

/// A step writing bindings.ts and bindings.d.ts for the binding type
/// `type_name` of `source` into `directory` (in the source tree). A generator
/// built for the host from the same Zig type writes them.
pub fn addBindings(b: *std.Build, source: std.Build.LazyPath, comptime type_name: []const u8, directory: []const u8) *std.Build.Step {
    const generator_source = b.addWriteFiles().add("generate_bindings.zig",
        \\const std = @import("std");
        \\const typescript = @import("plume_typescript");
        \\const app = @import("app");
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const args = try init.minimal.args.toSlice(init.arena.allocator());
        \\    const kind: typescript.Kind = if (std.mem.eql(u8, args[1], "declarations")) .declarations else .module;
        \\    var buffer: [8192]u8 = undefined;
        \\    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
        \\    try typescript.write(app.
    ++ type_name ++ ", \"" ++ type_name ++ "\", kind, &stdout.interface);\n" ++
        \\    try stdout.interface.flush();
        \\}
        \\
    );
    const host = b.graph.host;
    const generator = b.addExecutable(.{
        .name = "generate-bindings",
        .root_module = b.createModule(.{
            .root_source_file = generator_source,
            .target = host,
            .imports = &.{
                .{ .name = "plume_typescript", .module = b.createModule(.{ .root_source_file = b.path("src/typescript.zig"), .target = host }) },
                .{ .name = "app", .module = b.createModule(.{ .root_source_file = source, .target = host }) },
            },
        }),
    });
    const update = b.addUpdateSourceFiles();
    for ([_][]const u8{ "module", "declarations" }) |kind| {
        const run = b.addRunArtifact(generator);
        run.addArg(kind);
        const name = if (std.mem.eql(u8, kind, "module")) "bindings.ts" else "bindings.d.ts";
        update.addCopyFileToSource(run.captureStdOut(.{}), b.pathJoin(&.{ directory, name }));
    }
    return &update.step;
}

/// A ZeroG release package for the target and profile (unpacked without its
/// top-level directory, as Zig does with an archive holding only one).
pub const Engine = struct {
    dependency: *std.Build.Dependency,
    os: std.Target.Os.Tag,

    pub fn get(b: *std.Build, target: std.Build.ResolvedTarget, profile: Profile) ?Engine {
        const os = target.result.os.tag;
        const os_name = switch (os) {
            .windows => "windows",
            .linux => "linux",
            else => std.debug.panic("Plume runs on Windows and Linux, not {s}", .{@tagName(os)}),
        };
        if (target.result.cpu.arch != .x86_64)
            std.debug.panic("the engine is built for x86_64, not {s}", .{@tagName(target.result.cpu.arch)});
        if (os == .windows and target.result.abi != .msvc)
            std.debug.panic("the engine uses the MSVC ABI on Windows: build with -Dtarget=x86_64-windows-msvc", .{});
        const name = b.fmt("zerog_{s}_{s}", .{ os_name, @tagName(profile) });
        const dependency = b.lazyDependency(name, .{}) orelse return null;
        return .{ .dependency = dependency, .os = os };
    }

    pub fn path(engine: Engine, sub_path: []const u8) std.Build.LazyPath {
        return engine.dependency.path(sub_path);
    }

    /// Links the engine into an executable: the bundle and the system
    /// libraries its package lists (lib/zerog-engine.libs.txt).
    pub fn link(engine: Engine, executable: *std.Build.Step.Compile) void {
        const module = executable.root_module;
        module.link_libc = true;
        // The bundle is one large relocatable object in an archive, which
        // LLD links and Zig's own ELF linker does not (yet); LLD takes the
        // LLVM backend's objects only.
        executable.use_llvm = true;
        executable.use_lld = true;
        switch (engine.os) {
            .windows => {
                module.addObjectFile(engine.path("lib/zerog-engine.lib"));
                for (windows_libraries) |library|
                    module.linkSystemLibrary(library, .{});
            },
            else => {
                module.addObjectFile(engine.path("lib/libzerog-engine.a"));
                for (linux_libraries) |library|
                    module.linkSystemLibrary(library, .{});
            },
        }
    }

    // As lib/zerog-engine.libs.txt in the packages.
    const windows_libraries = [_][]const u8{
        "kernel32",  "user32",  "gdi32",   "imm32",      "version",   "uuid",     "setupapi",
        "d3d11",     "dwmapi",  "ole32",   "oleaut32",   "shell32",   "uiautomationcore",
        "dbghelp",   "shlwapi", "winmm",   "dxguid",     "dxgi",      "d3d9",     "synchronization",
        "advapi32",  "bcrypt",  "crypt32", "secur32",    "ws2_32",    "iphlpapi", "winspool",
        "comdlg32",
    };
    const linux_libraries = [_][]const u8{ "dl", "m" };
};
