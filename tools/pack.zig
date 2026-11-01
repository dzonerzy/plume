//! Packs a directory into a ZeroG asset archive (src/assets.zig), at build
//! time: `pack <directory> <archive>`. Files are sorted by path, so the same
//! directory gives the same archive. Source maps are left out.

const std = @import("std");
const assets = @import("assets");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) {
        std.debug.print("usage: pack <directory> <archive>\n", .{});
        return error.Usage;
    }

    var directory = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer directory.close(io);

    var files: std.ArrayList(assets.File) = .empty;
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or std.mem.endsWith(u8, entry.basename, ".map"))
            continue;
        // "/"-rooted, with forward slashes on every OS.
        const path = try std.mem.concat(allocator, u8, &.{ "/", entry.path });
        std.mem.replaceScalar(u8, path, '\\', '/');
        const data = try entry.dir.readFileAlloc(io, entry.basename, allocator, .unlimited);
        try files.append(allocator, .{ .path = path, .data = data });
    }
    std.mem.sort(assets.File, files.items, {}, struct {
        fn lessThan(_: void, a: assets.File, b: assets.File) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);

    const archive = try assets.pack(allocator, files.items);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = archive });
}
