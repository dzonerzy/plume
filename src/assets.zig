//! ZeroG asset archives: an application's frontend, embedded in its binary and
//! served from memory under app:// (zg_context_mount_assets). The format of
//! ZeroG's tools/assets.py, written in Zig so that building an application
//! needs no Python:
//!
//!   header, 16 bytes:  "ZGAR", u32 version (1), u32 file count, u32 flags (0)
//!   entries, 40 bytes each:
//!       u64 data offset, u64 stored size, u64 size,
//!       u32 path offset, u32 path length, u32 MIME offset, u16 MIME length,
//!       u8 compression (0 stored, 1 zlib), u8 reserved
//!   then the strings (UTF-8 paths, MIME types) and the data.
//!
//! All little-endian, offsets from the start of the archive, paths "/"-rooted.
//! A file is zlib-compressed when that makes it smaller, except formats that
//! are compressed already; the engine inflates an entry on its first request.

const std = @import("std");

pub const File = struct {
    /// "/"-rooted: "/index.html", "/assets/app.js".
    path: []const u8,
    data: []const u8,
    /// Empty: the engine derives it from the extension.
    mime: []const u8 = "",
};

const magic = "ZGAR";
const version = 1;
const header_size = 16;
const entry_size = 40;

/// Already compressed: zlib would only cost the first request some time.
const stored_extensions = [_][]const u8{
    ".png", ".jpg",  ".jpeg", ".gif", ".webp", ".avif", ".ico",
    ".woff", ".woff2", ".mp3", ".mp4", ".m4a", ".ogg", ".oga",
    ".ogv", ".opus", ".webm", ".flac", ".zip", ".gz", ".br",
    ".zst", ".xz",   ".7z",
};

fn isCompressedFormat(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    for (stored_extensions) |stored| {
        if (std.ascii.eqlIgnoreCase(extension, stored)) return true;
    }
    return false;
}

/// The archive of `files`, in the order given (sort them for reproducible
/// archives).
pub fn pack(allocator: std.mem.Allocator, files: []const File) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    // What each file stores: itself, or its zlib stream when smaller.
    const stored = try scratch.alloc([]const u8, files.len);
    const compression = try scratch.alloc(u8, files.len);
    for (files, stored, compression) |file, *data, *method| {
        data.* = file.data;
        method.* = 0;
        if (file.data.len > 0 and !isCompressedFormat(file.path)) {
            const deflated = try deflate(scratch, file.data);
            if (deflated.len < file.data.len) {
                data.* = deflated;
                method.* = 1;
            }
        }
    }

    var strings_size: usize = 0;
    var data_size: usize = 0;
    for (files, stored) |file, data| {
        strings_size += file.path.len + file.mime.len;
        data_size += data.len;
    }
    const strings_start = header_size + entry_size * files.len;
    const data_start = strings_start + strings_size;
    const archive = try allocator.alloc(u8, data_start + data_size);
    errdefer allocator.free(archive);

    @memcpy(archive[0..4], magic);
    std.mem.writeInt(u32, archive[4..8], version, .little);
    std.mem.writeInt(u32, archive[8..12], @intCast(files.len), .little);
    std.mem.writeInt(u32, archive[12..16], 0, .little);

    var string_offset = strings_start;
    var data_offset = data_start;
    for (files, stored, compression, 0..) |file, data, method, i| {
        const entry = archive[header_size + i * entry_size ..][0..entry_size];
        const path_offset = string_offset;
        @memcpy(archive[string_offset..][0..file.path.len], file.path);
        string_offset += file.path.len;
        const mime_offset = string_offset;
        @memcpy(archive[string_offset..][0..file.mime.len], file.mime);
        string_offset += file.mime.len;

        std.mem.writeInt(u64, entry[0..8], data_offset, .little);
        std.mem.writeInt(u64, entry[8..16], data.len, .little);
        std.mem.writeInt(u64, entry[16..24], file.data.len, .little);
        std.mem.writeInt(u32, entry[24..28], @intCast(path_offset), .little);
        std.mem.writeInt(u32, entry[28..32], @intCast(file.path.len), .little);
        std.mem.writeInt(u32, entry[32..36], @intCast(mime_offset), .little);
        std.mem.writeInt(u16, entry[36..38], @intCast(file.mime.len), .little);
        entry[38] = method;
        entry[39] = 0;

        @memcpy(archive[data_offset..][0..data.len], data);
        data_offset += data.len;
    }
    return archive;
}

pub const UnpackError = error{ InvalidArchive, OutOfMemory };

/// The files of an archive, inflated (the plume tool's templates). Paths and
/// data are allocated with `allocator`.
pub fn unpack(allocator: std.mem.Allocator, archive: []const u8) UnpackError![]File {
    if (archive.len < header_size or !std.mem.eql(u8, archive[0..4], magic))
        return error.InvalidArchive;
    const count = std.mem.readInt(u32, archive[8..12], .little);
    if (archive.len < header_size + @as(usize, count) * entry_size)
        return error.InvalidArchive;
    const files = try allocator.alloc(File, count);
    for (files, 0..) |*file, i| {
        const entry = archive[header_size + i * entry_size ..][0..entry_size];
        const data_offset = std.mem.readInt(u64, entry[0..8], .little);
        const stored_size = std.mem.readInt(u64, entry[8..16], .little);
        const size = std.mem.readInt(u64, entry[16..24], .little);
        const path_offset = std.mem.readInt(u32, entry[24..28], .little);
        const path_length = std.mem.readInt(u32, entry[28..32], .little);
        if (data_offset + stored_size > archive.len or path_offset + path_length > archive.len)
            return error.InvalidArchive;
        const stored = archive[data_offset..][0..stored_size];
        file.path = try allocator.dupe(u8, archive[path_offset..][0..path_length]);
        file.data = switch (entry[38]) {
            0 => try allocator.dupe(u8, stored),
            1 => inflate(allocator, stored, size) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidArchive,
            },
            else => return error.InvalidArchive,
        };
    }
    return files;
}

fn inflate(allocator: std.mem.Allocator, stored: []const u8, size: u64) ![]u8 {
    var input: std.Io.Reader = .fixed(stored);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var decompressor: std.compress.flate.Decompress = .init(&input, .zlib, window);
    const data = try decompressor.reader.allocRemaining(allocator, .limited(size + 1));
    if (data.len != size) return error.InvalidArchive;
    return data;
}

fn deflate(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, @max(64, data.len / 2));
    defer out.deinit();
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var compressor: std.compress.flate.Compress = try .init(&out.writer, window, .zlib, .best);
    try compressor.writer.writeAll(data);
    try compressor.finish();
    return out.toOwnedSlice();
}

test "an archive the engine reads" {
    const allocator = std.testing.allocator;
    // Repetitive, so that compressing it pays.
    const page = try allocator.alloc(u8, 1200);
    defer allocator.free(page);
    for (page, 0..) |*c, i| c.* = "hello "[i % 6];
    const archive = try pack(allocator, &.{
        .{ .path = "/index.html", .data = page },
        .{ .path = "/logo.png", .data = "\x89PNG not compressed" },
        .{ .path = "/data.bin", .data = "x", .mime = "application/octet-stream" },
    });
    defer allocator.free(archive);

    try std.testing.expectEqualStrings("ZGAR", archive[0..4]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, archive[4..8], .little));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, archive[8..12], .little));

    // The page: compressed, and inflating gives it back.
    const entry = archive[16..56];
    const offset = std.mem.readInt(u64, entry[0..8], .little);
    const stored_size = std.mem.readInt(u64, entry[8..16], .little);
    try std.testing.expectEqual(@as(u64, page.len), std.mem.readInt(u64, entry[16..24], .little));
    try std.testing.expectEqual(@as(u8, 1), entry[38]);
    try std.testing.expect(stored_size < page.len);
    const path_offset = std.mem.readInt(u32, entry[24..28], .little);
    try std.testing.expectEqualStrings("/index.html", archive[path_offset..][0..11]);
    var input: std.Io.Reader = .fixed(archive[offset..][0..stored_size]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    const inflated = try decompressor.reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(inflated);
    try std.testing.expectEqualStrings(page, inflated);

    // The PNG: stored. The binary: its MIME type kept.
    try std.testing.expectEqual(@as(u8, 0), archive[56 + 38]);
    const mime_offset = std.mem.readInt(u32, archive[96 + 32 ..][0..4], .little);
    try std.testing.expectEqualStrings("application/octet-stream", archive[mime_offset..][0..24]);

    // And back.
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const files = try unpack(arena.allocator(), archive);
    try std.testing.expectEqual(@as(usize, 3), files.len);
    try std.testing.expectEqualStrings("/index.html", files[0].path);
    try std.testing.expectEqualStrings(page, files[0].data);
    try std.testing.expectEqualStrings("\x89PNG not compressed", files[1].data);
}
