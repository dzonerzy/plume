//! What an application asks of the system besides its windows: starting at
//! login (Windows: the user's Run key; Linux: an XDG autostart entry), where
//! its executable is, and a per-user cache folder (the icon file
//! notifications show).

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ OutOfMemory, AccessDenied, Unexpected };

const allocator = std.heap.smp_allocator;

/// The running executable's path, in `a`.
pub fn executablePath(a: std.mem.Allocator, io: std.Io) Error![]u8 {
    return std.process.executablePathAlloc(io, a) catch error.Unexpected;
}

/// Whether the application starts when the user logs in. `name` identifies
/// its entry (the app id).
pub fn startsAtLogin(io: std.Io, name: []const u8) bool {
    switch (builtin.os.tag) {
        .windows => {
            const value = std.unicode.utf8ToUtf16LeAllocZ(allocator, name) catch return false;
            defer allocator.free(value);
            var key: ?windows.HKEY = null;
            if (windows.RegOpenKeyExW(windows.HKEY_CURRENT_USER, windows.run_key, 0, windows.KEY_READ, &key) != 0) return false;
            defer _ = windows.RegCloseKey(key.?);
            return windows.RegQueryValueExW(key.?, value.ptr, null, null, null, null) == 0;
        },
        else => {
            const path = autostartPath(allocator, name) catch return false;
            defer allocator.free(path);
            _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
            return true;
        },
    }
}

/// Starts the application at login (with `args` after the executable), or
/// no more.
pub fn setStartAtLogin(io: std.Io, name: []const u8, display_name: []const u8, enabled: bool) Error!void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exe = try executablePath(a, io);
    switch (builtin.os.tag) {
        .windows => {
            const value = std.unicode.utf8ToUtf16LeAllocZ(a, name) catch return error.OutOfMemory;
            var key: ?windows.HKEY = null;
            if (windows.RegCreateKeyExW(windows.HKEY_CURRENT_USER, windows.run_key, 0, null, 0, windows.KEY_SET_VALUE, null, &key, null) != 0) return error.AccessDenied;
            defer _ = windows.RegCloseKey(key.?);
            if (!enabled) {
                _ = windows.RegDeleteValueW(key.?, value.ptr);
                return;
            }
            const command = std.fmt.allocPrint(a, "\"{s}\"", .{exe}) catch return error.OutOfMemory;
            const data = std.unicode.utf8ToUtf16LeAllocZ(a, command) catch return error.OutOfMemory;
            const bytes: u32 = @intCast((data.len + 1) * 2);
            if (windows.RegSetValueExW(key.?, value.ptr, 0, windows.REG_SZ, @ptrCast(data.ptr), bytes) != 0) return error.AccessDenied;
        },
        else => {
            const path = try autostartPath(a, name);
            const cwd = std.Io.Dir.cwd();
            if (!enabled) {
                cwd.deleteFile(io, path) catch {};
                return;
            }
            if (std.fs.path.dirname(path)) |directory| cwd.createDirPath(io, directory) catch return error.AccessDenied;
            const entry = std.fmt.allocPrint(a,
                \\[Desktop Entry]
                \\Type=Application
                \\Name={s}
                \\Exec="{s}"
                \\X-GNOME-Autostart-enabled=true
                \\
            , .{ display_name, exe }) catch return error.OutOfMemory;
            cwd.writeFile(io, .{ .sub_path = path, .data = entry }) catch return error.AccessDenied;
        },
    }
}

fn autostartPath(a: std.mem.Allocator, name: []const u8) Error![]u8 {
    const config = configHome(a) catch return error.Unexpected;
    return std.fmt.allocPrint(a, "{s}/autostart/{s}.desktop", .{ config, name }) catch error.OutOfMemory;
}

fn configHome(a: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |value| {
        if (value[0] != 0) return a.dupe(u8, std.mem.span(value));
    }
    const home = std.c.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(a, "{s}/.config", .{std.mem.span(home)});
}

/// The user's cache folder for the application (created): LOCALAPPDATA's on
/// Windows, XDG_CACHE_HOME's on Linux.
pub fn cacheDirectory(a: std.mem.Allocator, io: std.Io, name: []const u8) Error![]u8 {
    const base = switch (builtin.os.tag) {
        .windows => if (std.c.getenv("LOCALAPPDATA")) |value| std.mem.span(value) else return error.Unexpected,
        else => blk: {
            if (std.c.getenv("XDG_CACHE_HOME")) |value| {
                if (value[0] != 0) break :blk std.mem.span(value);
            }
            const home = std.c.getenv("HOME") orelse return error.Unexpected;
            break :blk std.fmt.allocPrint(a, "{s}/.cache", .{std.mem.span(home)}) catch return error.OutOfMemory;
        },
    };
    const path = std.fs.path.join(a, &.{ base, name }) catch return error.OutOfMemory;
    std.Io.Dir.cwd().createDirPath(io, path) catch return error.AccessDenied;
    return path;
}

const windows = struct {
    const HKEY = *opaque {};
    const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
    const KEY_READ: u32 = 0x20019;
    const KEY_SET_VALUE: u32 = 0x0002;
    const REG_SZ: u32 = 1;
    const run_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");

    extern "advapi32" fn RegOpenKeyExW(key: HKEY, sub_key: [*:0]const u16, options: u32, sam: u32, result: *?HKEY) callconv(.winapi) i32;
    extern "advapi32" fn RegCreateKeyExW(key: HKEY, sub_key: [*:0]const u16, reserved: u32, class: ?[*:0]u16, options: u32, sam: u32, security: ?*anyopaque, result: *?HKEY, disposition: ?*u32) callconv(.winapi) i32;
    extern "advapi32" fn RegCloseKey(key: HKEY) callconv(.winapi) i32;
    extern "advapi32" fn RegQueryValueExW(key: HKEY, name: [*:0]const u16, reserved: ?*u32, kind: ?*u32, data: ?[*]u8, size: ?*u32) callconv(.winapi) i32;
    extern "advapi32" fn RegSetValueExW(key: HKEY, name: [*:0]const u16, reserved: u32, kind: u32, data: [*]const u8, size: u32) callconv(.winapi) i32;
    extern "advapi32" fn RegDeleteValueW(key: HKEY, name: [*:0]const u16) callconv(.winapi) i32;
};
