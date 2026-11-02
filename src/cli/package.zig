//! plume package [--format <f>]... [--skip-build]
//!
//! The release build (plume build), packaged for users into build/package/:
//!
//!   Windows  nsis      a per-user installer (makensis, from NSIS): Start menu
//!                      shortcut, uninstaller, file associations and URL
//!                      protocols in the user's registry
//!            zip       the executable alone
//!   Linux    deb       /usr/bin, a .desktop file with the MIME types and
//!                      URL schemes, the icon, MIME definitions for the
//!                      application's own file types
//!            tar       the same tree as a .tar.gz
//!            appimage  an AppImage (appimagetool, if installed)
//!
//! Default: nsis (zip when NSIS is not installed) on Windows; deb, tar and
//! appimage when appimagetool is there, on Linux. plume.json gives version,
//! publisher, description, file_associations and protocols. Opened with a
//! file or a URL, the application gets it as an argument of its launch (with
//! single_instance, in app.onSecondInstance when it already runs).

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("main.zig");
const project_module = @import("project.zig");
const Project = project_module.Project;

const Format = enum { nsis, zip, deb, tar, appimage };

const Package = struct {
    context: *cli.Context,
    project: Project,
    name: []const u8,
    title: []const u8,
    app_id: []const u8,
    version: []const u8,
    /// build/bin/<name>(.exe)
    executable: []const u8,
    /// build/share/icon.png, icon.ico (when the project has an icon).
    icon_png: ?[]const u8,
    icon_ico: ?[]const u8,
    out: []const u8,

    fn path(package: *const Package, parts: []const []const u8) []const u8 {
        return std.fs.path.join(package.context.arena, parts) catch @panic("OOM");
    }

    fn fmt(package: *const Package, comptime format: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(package.context.arena, format, args) catch @panic("OOM");
    }

    fn write(package: *const Package, sub_path: []const u8, data: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(sub_path)) |directory| try cwd.createDirPath(package.context.io, directory);
        try cwd.writeFile(package.context.io, .{ .sub_path = sub_path, .data = data });
    }

    fn copy(package: *const Package, from: []const u8, to: []const u8) !void {
        const data = try std.Io.Dir.cwd().readFileAlloc(package.context.io, from, package.context.arena, .limited(4 << 30));
        try package.write(to, data);
    }

    /// The MIME type of a file association.
    fn mime(package: *const Package, association: project_module.FileAssociation) []const u8 {
        return association.mime orelse package.fmt("application/x-{s}-{s}", .{ package.name, association.ext });
    }
};

pub fn run(context: *cli.Context) !void {
    var formats: std.ArrayList(Format) = .empty;
    var skip_build = false;
    var i: usize = 0;
    while (i < context.args.len) : (i += 1) {
        const arg = context.args[i];
        if (cli.eql(arg, "--skip-build")) {
            skip_build = true;
        } else if (cli.eql(arg, "--format") and i + 1 < context.args.len) {
            i += 1;
            const format = std.meta.stringToEnum(Format, context.args[i]) orelse {
                cli.fail("unknown format {s} (nsis, zip, deb, tar, appimage)", .{context.args[i]});
                return error.Reported;
            };
            const for_windows = format == .nsis or format == .zip;
            if (for_windows != (builtin.os.tag == .windows)) {
                cli.fail("{s} packages are made on {s}", .{ context.args[i], if (for_windows) "Windows" else "Linux" });
                return error.Reported;
            }
            try formats.append(context.arena, format);
        } else {
            cli.fail("unknown option {s}", .{arg});
            return error.Reported;
        }
    }

    const project = try Project.load(context);
    if (!skip_build) {
        const saved = context.args;
        context.args = &.{};
        defer context.args = saved;
        try @import("build_app.zig").run(context);
    }

    var package: Package = .{
        .context = context,
        .project = project,
        .name = project.config.name,
        .title = project.title(),
        .app_id = project.appId(context),
        .version = project.config.version,
        .executable = try std.fs.path.join(context.arena, &.{ "build", "bin", cli.executableName(context, project.config.name) }),
        .icon_png = if (cli.exists(context, "build/share/icon.png")) "build/share/icon.png" else null,
        .icon_ico = if (cli.exists(context, "build/share/icon.ico")) "build/share/icon.ico" else null,
        .out = try std.fs.path.join(context.arena, &.{ "build", "package" }),
    };
    if (!cli.exists(context, package.executable)) {
        cli.fail("{s} is not built (plume build)", .{package.executable});
        return error.Reported;
    }
    try std.Io.Dir.cwd().createDirPath(context.io, package.out);

    if (formats.items.len == 0) switch (builtin.os.tag) {
        .windows => try formats.append(context.arena, if (makensis(context) != null) .nsis else .zip),
        else => {
            try formats.appendSlice(context.arena, &.{ .deb, .tar });
            if (cli.output(context, &.{ "appimagetool", "--version" }) != null) try formats.append(context.arena, .appimage);
        },
    };

    var made: std.ArrayList([]const u8) = .empty;
    for (formats.items) |format| {
        const file = switch (format) {
            .nsis => try nsis(&package),
            .zip => try zip(&package),
            .deb => try deb(&package),
            .tar => try tarball(&package),
            .appimage => try appImage(&package),
        };
        try made.append(context.arena, file);
    }
    if (project.config.update) |config| try made.appendSlice(context.arena, try updateAsset(&package, config.public_key));
    std.debug.print("\n", .{});
    for (made.items) |file| {
        const stat = try std.Io.Dir.cwd().statFile(context.io, file, .{});
        std.debug.print("{s}: {d:.1} MB\n", .{ file, @as(f64, @floatFromInt(stat.size)) / (1024 * 1024) });
    }
}

// ---- Updates ----

/// The executable as a release asset for updates, and its signature
/// (plume.update): to attach to the GitHub release tagged v<version>.
fn updateAsset(package: *Package, public_key: []const u8) ![]const []const u8 {
    const context = package.context;
    const signing = @import("update.zig");
    const asset = package.path(&.{ package.out, switch (builtin.os.tag) {
        .windows => package.fmt("{s}-{s}-windows-x64.exe", .{ package.name, package.version }),
        else => package.fmt("{s}-{s}-linux-x64", .{ package.name, package.version }),
    } });
    cli.step("signing the update ({s})", .{std.fs.path.basename(asset)});
    const pair = try signing.loadKey(context, signing.key_file) orelse {
        cli.fail("plume.json has \"update\" but there is no key to sign with: {s} (plume update keygen) or PLUME_UPDATE_KEY", .{signing.key_file});
        return error.Reported;
    };
    // The key must be the one the application trusts.
    var public_text: [std.base64.standard.Encoder.calcSize(32)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&public_text, &pair.public_key.toBytes());
    if (!std.mem.eql(u8, std.mem.trim(u8, public_key, " \r\n\t"), &public_text)) {
        cli.fail("the update key is not the one plume.json's public_key names ({s})", .{&public_text});
        return error.Reported;
    }
    try package.copy(package.executable, asset);
    if (builtin.os.tag != .windows) try cli.run(context, &.{ "chmod", "755", asset }, null);
    const signature = try signing.sign(context, pair, asset);
    return try context.arena.dupe([]const u8, &.{ asset, signature });
}

// ---- Windows ----

fn makensis(context: *cli.Context) ?[]const u8 {
    if (cli.output(context, &.{ "makensis", "/VERSION" }) != null) return "makensis";
    for ([_][]const u8{ "ProgramFiles(x86)", "ProgramFiles" }) |variable| {
        const base = context.environ.get(variable) orelse continue;
        const candidate = std.fs.path.join(context.arena, &.{ base, "NSIS", "makensis.exe" }) catch continue;
        if (cli.exists(context, candidate)) return candidate;
    }
    return null;
}

/// An NSIS string's content: $ and " escaped.
fn nsisText(package: *const Package, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = package.context.arena;
    for (text) |c| switch (c) {
        '$' => out.appendSlice(a, "$$") catch @panic("OOM"),
        '"' => out.appendSlice(a, "$\\\"") catch @panic("OOM"),
        '\r', '\n' => out.append(a, ' ') catch @panic("OOM"),
        else => out.append(a, c) catch @panic("OOM"),
    };
    return out.items;
}

/// A name for a file (the Start menu shortcut): no characters Windows refuses.
fn fileName(package: *const Package, text: []const u8) []const u8 {
    const out = package.context.arena.dupe(u8, text) catch @panic("OOM");
    for (out) |*c| {
        if (std.mem.indexOfScalar(u8, "\\/:*?\"<>|", c.*) != null) c.* = '-';
    }
    return out;
}

fn absolute(package: *const Package, sub_path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(package.context.io, sub_path, package.context.arena);
}

fn nsis(package: *Package) ![]const u8 {
    const context = package.context;
    const tool = makensis(context) orelse {
        cli.fail("NSIS's makensis is not installed (nsis.sourceforge.io); plume package --format zip makes a zip", .{});
        return error.Reported;
    };
    const exe_name = cli.executableName(context, package.name);
    const out_file = package.path(&.{ package.out, package.fmt("{s}-{s}-windows-x64-setup.exe", .{ package.name, package.version }) });
    const stat = try std.Io.Dir.cwd().statFile(context.io, package.executable, .{});
    const n = versionNumbers(package.version);
    const t = struct {
        fn s(p: *const Package, text: []const u8) []const u8 {
            return nsisText(p, text);
        }
    }.s;

    var script: std.ArrayList(u8) = .empty;
    const a = context.arena;
    const w = struct {
        fn line(list: *std.ArrayList(u8), arena: std.mem.Allocator, comptime format: []const u8, args: anytype) void {
            list.print(arena, format ++ "\n", args) catch @panic("OOM");
        }
    }.line;
    const uninstall_key = package.fmt("Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{s}", .{package.app_id});
    const shortcut = package.fmt("$SMPROGRAMS\\{s}.lnk", .{t(package, fileName(package, package.title))});
    const target = package.fmt("$INSTDIR\\{s}", .{exe_name});

    w(&script, a, "; Generated by plume package from plume.json.", .{});
    w(&script, a, "Unicode true", .{});
    w(&script, a, "!include \"MUI2.nsh\"", .{});
    w(&script, a, "Name \"{s}\"", .{t(package, package.title)});
    w(&script, a, "OutFile \"{s}\"", .{t(package, try absoluteOut(package, out_file))});
    w(&script, a, "InstallDir \"$LOCALAPPDATA\\Programs\\{s}\"", .{t(package, package.name)});
    w(&script, a, "InstallDirRegKey HKCU \"{s}\" \"InstallLocation\"", .{t(package, uninstall_key)});
    w(&script, a, "RequestExecutionLevel user", .{});
    w(&script, a, "SetCompressor /SOLID lzma", .{});
    if (package.icon_ico) |ico| {
        const ico_path = t(package, try absolute(package, ico));
        w(&script, a, "!define MUI_ICON \"{s}\"", .{ico_path});
        w(&script, a, "!define MUI_UNICON \"{s}\"", .{ico_path});
    }
    w(&script, a, "!define MUI_FINISHPAGE_RUN \"{s}\"", .{target});
    w(&script, a, "!insertmacro MUI_PAGE_DIRECTORY", .{});
    w(&script, a, "!insertmacro MUI_PAGE_INSTFILES", .{});
    w(&script, a, "!insertmacro MUI_PAGE_FINISH", .{});
    w(&script, a, "!insertmacro MUI_UNPAGE_CONFIRM", .{});
    w(&script, a, "!insertmacro MUI_UNPAGE_INSTFILES", .{});
    w(&script, a, "!insertmacro MUI_LANGUAGE \"English\"", .{});
    w(&script, a, "VIProductVersion \"{d}.{d}.{d}.{d}\"", .{ n[0], n[1], n[2], n[3] });
    w(&script, a, "VIAddVersionKey \"ProductName\" \"{s}\"", .{t(package, package.title)});
    w(&script, a, "VIAddVersionKey \"CompanyName\" \"{s}\"", .{t(package, package.project.publisher())});
    w(&script, a, "VIAddVersionKey \"FileDescription\" \"{s} setup\"", .{t(package, package.title)});
    w(&script, a, "VIAddVersionKey \"LegalCopyright\" \"{s}\"", .{t(package, package.project.copyright(context))});
    w(&script, a, "VIAddVersionKey \"FileVersion\" \"{s}\"", .{t(package, package.version)});
    w(&script, a, "VIAddVersionKey \"ProductVersion\" \"{s}\"", .{t(package, package.version)});
    w(&script, a, "", .{});
    w(&script, a, "Section", .{});
    w(&script, a, "  SetOutPath \"$INSTDIR\"", .{});
    w(&script, a, "  File \"{s}\"", .{t(package, try absolute(package, package.executable))});
    w(&script, a, "  WriteUninstaller \"$INSTDIR\\uninstall.exe\"", .{});
    w(&script, a, "  CreateShortcut \"{s}\" \"{s}\"", .{ shortcut, target });
    const values = [_][2][]const u8{
        .{ "DisplayName", t(package, package.title) },
        .{ "DisplayVersion", t(package, package.version) },
        .{ "Publisher", t(package, package.project.publisher()) },
        .{ "DisplayIcon", target },
        .{ "InstallLocation", "$INSTDIR" },
        .{ "UninstallString", "$\\\"$INSTDIR\\uninstall.exe$\\\"" },
        .{ "QuietUninstallString", "$\\\"$INSTDIR\\uninstall.exe$\\\" /S" },
    };
    for (values) |value| w(&script, a, "  WriteRegStr HKCU \"{s}\" \"{s}\" \"{s}\"", .{ t(package, uninstall_key), value[0], value[1] });
    w(&script, a, "  WriteRegDWORD HKCU \"{s}\" \"NoModify\" 1", .{t(package, uninstall_key)});
    w(&script, a, "  WriteRegDWORD HKCU \"{s}\" \"NoRepair\" 1", .{t(package, uninstall_key)});
    w(&script, a, "  WriteRegDWORD HKCU \"{s}\" \"EstimatedSize\" {d}", .{ t(package, uninstall_key), stat.size / 1024 });
    const open_command = package.fmt("$\\\"{s}$\\\" $\\\"%1$\\\"", .{target});
    for (package.project.config.file_associations) |association| {
        const prog_id = t(package, package.fmt("{s}.{s}", .{ package.app_id, association.ext }));
        const ext = t(package, association.ext);
        w(&script, a, "  WriteRegStr HKCU \"Software\\Classes\\.{s}\\OpenWithProgids\" \"{s}\" \"\"", .{ ext, prog_id });
        w(&script, a, "  WriteRegStr HKCU \"Software\\Classes\\{s}\" \"\" \"{s}\"", .{ prog_id, t(package, association.name) });
        w(&script, a, "  WriteRegStr HKCU \"Software\\Classes\\{s}\\DefaultIcon\" \"\" \"{s},0\"", .{ prog_id, target });
        w(&script, a, "  WriteRegStr HKCU \"Software\\Classes\\{s}\\shell\\open\\command\" \"\" \"{s}\"", .{ prog_id, open_command });
    }
    for (package.project.config.protocols) |protocol| {
        const scheme = t(package, protocol);
        w(&script, a, "  WriteRegStr HKCU \"Software\\Classes\\{s}\" \"\" \"URL:{s}\"", .{ scheme, t(package, package.title) });
        w(&script, a, "  WriteRegStr HKCU \"Software\\Classes\\{s}\" \"URL Protocol\" \"\"", .{scheme});
        w(&script, a, "  WriteRegStr HKCU \"Software\\Classes\\{s}\\DefaultIcon\" \"\" \"{s},0\"", .{ scheme, target });
        w(&script, a, "  WriteRegStr HKCU \"Software\\Classes\\{s}\\shell\\open\\command\" \"\" \"{s}\"", .{ scheme, open_command });
    }
    // SHCNE_ASSOCCHANGED: Explorer reads the associations again.
    w(&script, a, "  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'", .{});
    w(&script, a, "SectionEnd", .{});
    w(&script, a, "", .{});
    w(&script, a, "Section \"Uninstall\"", .{});
    w(&script, a, "  Delete \"{s}\"", .{target});
    w(&script, a, "  Delete \"{s}.old\"", .{target});
    w(&script, a, "  Delete \"$INSTDIR\\uninstall.exe\"", .{});
    w(&script, a, "  RMDir \"$INSTDIR\"", .{});
    w(&script, a, "  Delete \"{s}\"", .{shortcut});
    w(&script, a, "  DeleteRegKey HKCU \"{s}\"", .{t(package, uninstall_key)});
    for (package.project.config.file_associations) |association| {
        const prog_id = t(package, package.fmt("{s}.{s}", .{ package.app_id, association.ext }));
        w(&script, a, "  DeleteRegValue HKCU \"Software\\Classes\\.{s}\\OpenWithProgids\" \"{s}\"", .{ t(package, association.ext), prog_id });
        // The extension's keys, unless other applications are in them.
        w(&script, a, "  DeleteRegKey /ifempty HKCU \"Software\\Classes\\.{s}\\OpenWithProgids\"", .{t(package, association.ext)});
        w(&script, a, "  DeleteRegKey /ifempty HKCU \"Software\\Classes\\.{s}\"", .{t(package, association.ext)});
        w(&script, a, "  DeleteRegKey HKCU \"Software\\Classes\\{s}\"", .{prog_id});
    }
    for (package.project.config.protocols) |protocol| w(&script, a, "  DeleteRegKey HKCU \"Software\\Classes\\{s}\"", .{t(package, protocol)});
    w(&script, a, "  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'", .{});
    w(&script, a, "SectionEnd", .{});

    const script_path = package.path(&.{ package.out, "installer.nsi" });
    try package.write(script_path, script.items);
    cli.step("making the installer (NSIS)", .{});
    try cli.run(context, &.{ tool, "/V2", script_path }, null);
    return out_file;
}

/// The path of a file not made yet: its directory's real path, joined.
fn absoluteOut(package: *const Package, sub_path: []const u8) ![]const u8 {
    const directory = try absolute(package, std.fs.path.dirname(sub_path) orelse ".");
    return package.path(&.{ directory, std.fs.path.basename(sub_path) });
}

fn zip(package: *Package) ![]const u8 {
    const context = package.context;
    const out_file = package.path(&.{ package.out, package.fmt("{s}-{s}-windows-x64.zip", .{ package.name, package.version }) });
    cli.step("making the zip", .{});
    // Windows' own tar (bsdtar) writes zips; another tar on the PATH may not.
    const system_root = context.environ.get("SystemRoot") orelse "C:\\Windows";
    const tar = package.path(&.{ system_root, "System32", "tar.exe" });
    std.Io.Dir.cwd().deleteFile(context.io, out_file) catch {};
    try cli.run(context, &.{ tar, "-a", "-c", "-f", try absoluteOut(package, out_file), "-C", "build/bin", cli.executableName(context, package.name) }, null);
    return out_file;
}

// ---- Linux ----

/// The tree the deb and the tarball hold: usr/bin, usr/share/... In
/// build/package/root.
fn linuxTree(package: *Package) ![]const u8 {
    const context = package.context;
    const root = package.path(&.{ package.out, "root" });
    std.Io.Dir.cwd().deleteTree(context.io, root) catch {};
    const binary = package.path(&.{ root, "usr", "bin", package.name });
    try package.copy(package.executable, binary);
    try cli.run(context, &.{ "chmod", "755", binary }, null);
    try package.write(package.path(&.{ root, "usr", "share", "applications", package.fmt("{s}.desktop", .{package.app_id}) }), desktopEntry(package, package.fmt("/usr/bin/{s}", .{package.name})));
    if (package.icon_png) |png| try package.copy(png, package.path(&.{ root, "usr", "share", "pixmaps", package.fmt("{s}.png", .{package.app_id}) }));
    if (mimeDefinitions(package)) |xml| try package.write(package.path(&.{ root, "usr", "share", "mime", "packages", package.fmt("{s}.xml", .{package.app_id}) }), xml);
    return root;
}

fn desktopEntry(package: *const Package, exec: []const u8) []const u8 {
    var types: std.ArrayList(u8) = .empty;
    const a = package.context.arena;
    for (package.project.config.file_associations) |association| types.print(a, "{s};", .{package.mime(association)}) catch @panic("OOM");
    for (package.project.config.protocols) |protocol| types.print(a, "x-scheme-handler/{s};", .{protocol}) catch @panic("OOM");
    const takes_argument = types.items.len > 0;
    return package.fmt(
        \\[Desktop Entry]
        \\Type=Application
        \\Name={s}
        \\Comment={s}
        \\Exec="{s}"{s}
        \\Icon={s}
        \\Terminal=false
        \\Categories={s}
        \\StartupWMClass={s}
        \\{s}{s}{s}
    , .{
        package.title,
        package.project.description(),
        exec,
        if (takes_argument) " %U" else "",
        package.app_id,
        package.project.config.categories,
        package.app_id,
        if (takes_argument) "MimeType=" else "",
        types.items,
        if (takes_argument) "\n" else "",
    });
}

/// shared-mime-info definitions of the application's own types (those
/// without a "mime" in plume.json).
fn mimeDefinitions(package: *const Package) ?[]const u8 {
    var xml: std.ArrayList(u8) = .empty;
    const a = package.context.arena;
    for (package.project.config.file_associations) |association| {
        if (association.mime != null) continue;
        xml.print(a,
            \\  <mime-type type="{s}">
            \\    <comment>{s}</comment>
            \\    <glob pattern="*.{s}"/>
            \\  </mime-type>
            \\
        , .{ package.mime(association), association.name, association.ext }) catch @panic("OOM");
    }
    if (xml.items.len == 0) return null;
    return package.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
        \\{s}</mime-info>
        \\
    , .{xml.items});
}

fn tarGz(package: *const Package, out_file: []const u8, directory: []const u8) !void {
    try cli.run(package.context, &.{ "tar", "--owner=0", "--group=0", "--numeric-owner", "-czf", out_file, "-C", directory, "." }, null);
}

fn tarball(package: *Package) ![]const u8 {
    cli.step("making the tarball", .{});
    const root = try linuxTree(package);
    const out_file = package.path(&.{ package.out, package.fmt("{s}-{s}-linux-x64.tar.gz", .{ package.name, package.version }) });
    try tarGz(package, out_file, package.path(&.{ root, "usr" }));
    return out_file;
}

/// A Debian package name: lowercase letters, digits, + - .
fn debianName(package: *const Package) []const u8 {
    const out = package.context.arena.dupe(u8, package.name) catch @panic("OOM");
    for (out) |*c| {
        c.* = std.ascii.toLower(c.*);
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '+' and c.* != '-' and c.* != '.') c.* = '-';
    }
    return out;
}

fn deb(package: *Package) ![]const u8 {
    const context = package.context;
    cli.step("making the Debian package", .{});
    const root = try linuxTree(package);
    const control_dir = package.path(&.{ package.out, "control" });
    std.Io.Dir.cwd().deleteTree(context.io, control_dir) catch {};
    const stat = try std.Io.Dir.cwd().statFile(context.io, package.executable, .{});
    try package.write(package.path(&.{ control_dir, "control" }), package.fmt(
        \\Package: {s}
        \\Version: {s}
        \\Architecture: amd64
        \\Maintainer: {s}
        \\Installed-Size: {d}
        \\Depends: libc6 (>= 2.28)
        \\Section: misc
        \\Priority: optional
        \\Description: {s}
        \\
    , .{ debianName(package), package.version, package.project.publisher(), stat.size / 1024 + 64, package.project.description() }));
    const refresh =
        \\#!/bin/sh
        \\set -e
        \\if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database -q /usr/share/applications || true; fi
        \\if command -v update-mime-database >/dev/null 2>&1; then update-mime-database /usr/share/mime || true; fi
        \\
    ;
    for ([_][]const u8{ "postinst", "postrm" }) |script| {
        const script_path = package.path(&.{ control_dir, script });
        try package.write(script_path, refresh);
        try cli.run(context, &.{ "chmod", "755", script_path }, null);
    }
    const control_tar = package.path(&.{ package.out, "control.tar.gz" });
    const data_tar = package.path(&.{ package.out, "data.tar.gz" });
    try tarGz(package, control_tar, control_dir);
    try tarGz(package, data_tar, root);

    // An ar archive: debian-binary, control.tar.gz, data.tar.gz.
    var archive: std.ArrayList(u8) = .empty;
    const a = context.arena;
    try archive.appendSlice(a, "!<arch>\n");
    const members = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "debian-binary", .data = "2.0\n" },
        .{ .name = "control.tar.gz", .data = try std.Io.Dir.cwd().readFileAlloc(context.io, control_tar, a, .limited(1 << 30)) },
        .{ .name = "data.tar.gz", .data = try std.Io.Dir.cwd().readFileAlloc(context.io, data_tar, a, .limited(4 << 30)) },
    };
    for (members) |member| {
        try archive.print(a, "{s: <16}{d: <12}{d: <6}{d: <6}{s: <8}{d: <10}`\n", .{ member.name, 0, 0, 0, "100644", member.data.len });
        try archive.appendSlice(a, member.data);
        if (member.data.len % 2 == 1) try archive.append(a, '\n');
    }
    const out_file = package.path(&.{ package.out, package.fmt("{s}_{s}_amd64.deb", .{ debianName(package), package.version }) });
    try package.write(out_file, archive.items);
    std.Io.Dir.cwd().deleteFile(context.io, control_tar) catch {};
    std.Io.Dir.cwd().deleteFile(context.io, data_tar) catch {};
    return out_file;
}

fn appImage(package: *Package) ![]const u8 {
    const context = package.context;
    cli.step("making the AppImage (appimagetool)", .{});
    const app_dir = package.path(&.{ package.out, package.fmt("{s}.AppDir", .{package.name}) });
    std.Io.Dir.cwd().deleteTree(context.io, app_dir) catch {};
    const binary = package.path(&.{ app_dir, "usr", "bin", package.name });
    try package.copy(package.executable, binary);
    const app_run = package.path(&.{ app_dir, "AppRun" });
    try package.write(app_run, package.fmt(
        \\#!/bin/sh
        \\here="$(dirname "$(readlink -f "$0")")"
        \\exec "$here/usr/bin/{s}" "$@"
        \\
    , .{package.name}));
    try cli.run(context, &.{ "chmod", "755", binary, app_run }, null);
    try package.write(package.path(&.{ app_dir, package.fmt("{s}.desktop", .{package.app_id}) }), desktopEntry(package, package.name));
    if (package.icon_png) |png| {
        try package.copy(png, package.path(&.{ app_dir, package.fmt("{s}.png", .{package.app_id}) }));
    } else {
        cli.fail("an AppImage needs an icon: icon.png in the project", .{});
        return error.Reported;
    }
    const out_file = package.path(&.{ package.out, package.fmt("{s}-{s}-x86_64.AppImage", .{ package.name, package.version }) });
    try context.environ.put("ARCH", "x86_64");
    try cli.run(context, &.{ "appimagetool", "--no-appstream", app_dir, out_file }, null);
    return out_file;
}

/// "1.2.3" → { 1, 2, 3, 0 }.
pub fn versionNumbers(version: []const u8) [4]u16 {
    var numbers: [4]u16 = .{ 0, 0, 0, 0 };
    var parts = std.mem.tokenizeAny(u8, version, ".-+");
    for (&numbers) |*number| {
        const part = parts.next() orelse break;
        number.* = std.fmt.parseInt(u16, part, 10) catch break;
    }
    return numbers;
}
