//! plume-icon <icon.png> <out-dir>: an application's icon for its build
//! (plume's addApp). Writes icon.ico and app.rc (the executable's icon on
//! Windows) and icon.rgba (128 × 128 RGBA, the window's icon on Linux).

const std = @import("std");
const icon = @import("icon");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) {
        std.debug.print("usage: plume-icon <icon.png> <out-dir>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const png = cwd.readFileAlloc(io, args[1], allocator, .limited(64 << 20)) catch |err| fail("{s}: {s}", .{ args[1], @errorName(err) });
    const image = icon.decode(allocator, png) catch |err| fail("{s}: {s}", .{ args[1], switch (err) {
        error.NotPng => "not a PNG image",
        error.UnsupportedPng => "an 8-bit PNG is needed (gray, RGB, RGBA or palette), not interlaced",
        else => "a damaged PNG image",
    } });
    if (image.width != image.height or image.width < 256)
        fail("{s} is {d}x{d}: an icon is square, 256x256 or more (1024x1024 is best)", .{ args[1], image.width, image.height });

    var out = try cwd.createDirPathOpen(io, args[2], .{});
    defer out.close(io);
    try out.writeFile(io, .{ .sub_path = "icon.ico", .data = try icon.ico(allocator, image) });
    try out.writeFile(io, .{ .sub_path = "app.rc", .data = "1 ICON \"icon.ico\"\n" });
    const small = try icon.downscale(allocator, image, 128);
    try out.writeFile(io, .{ .sub_path = "icon.rgba", .data = small.pixels });
}

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("plume: the icon: " ++ format ++ "\n", args);
    std.process.exit(1);
}
