//! PNG files of pages: what `plume.testing` snapshots and `window.capture`
//! give. 8-bit RGBA, not interlaced, zlib-compressed scanlines (filter none);
//! icon.zig reads them back.

const std = @import("std");
const flate = std.compress.flate;

pub const Error = error{OutOfMemory};

/// A PNG of `rgba` (`width` × `height`, rows top to bottom, 4 bytes a pixel).
pub fn encode(a: std.mem.Allocator, rgba: []const u8, width: u32, height: u32) Error![]u8 {
    std.debug.assert(rgba.len == @as(usize, width) * height * 4);

    // The scanlines, each after its filter byte, deflated in a zlib stream.
    var compressed: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(a, 64 * 1024) catch return error.OutOfMemory;
    defer compressed.deinit();
    const window = try a.alloc(u8, flate.max_window_len);
    defer a.free(window);
    const compressor = try a.create(flate.Compress);
    defer a.destroy(compressor);
    compressor.* = flate.Compress.init(&compressed.writer, window, .zlib, .default) catch return error.OutOfMemory;
    const row_len = @as(usize, width) * 4;
    for (0..height) |y| {
        compressor.writer.writeByte(0) catch return error.OutOfMemory;
        compressor.writer.writeAll(rgba[y * row_len ..][0..row_len]) catch return error.OutOfMemory;
    }
    compressor.finish() catch return error.OutOfMemory;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "\x89PNG\r\n\x1a\n");
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8 bits, RGBA, deflate, filter set 0, not interlaced
    try chunk(a, &out, "IHDR", &header);
    try chunk(a, &out, "IDAT", compressed.written());
    try chunk(a, &out, "IEND", "");
    return out.toOwnedSlice(a);
}

fn chunk(a: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) Error!void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    try out.appendSlice(a, &length);
    try out.appendSlice(a, kind);
    try out.appendSlice(a, data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try out.appendSlice(a, &sum);
}

/// BGRA rows with a stride (the engine's CPU frames) as packed RGBA rows.
pub fn fromBgra(a: std.mem.Allocator, bgra: [*]const u8, stride: usize, width: u32, height: u32) Error![]u8 {
    const out = try a.alloc(u8, @as(usize, width) * height * 4);
    for (0..height) |y| {
        const row = bgra[y * stride ..];
        for (0..width) |x| {
            const o = out[(y * width + x) * 4 ..][0..4];
            o.* = .{ row[x * 4 + 2], row[x * 4 + 1], row[x * 4], row[x * 4 + 3] };
        }
    }
    return out;
}

/// How two images of the same size differ: the pixels where a channel differs
/// by more than `tolerance`, and the image showing them (red on a faded copy
/// of `actual`).
pub const Difference = struct {
    pixels: usize,
    image: []u8,
};

pub fn difference(a: std.mem.Allocator, expected: []const u8, actual: []const u8, tolerance: u8) Error!Difference {
    std.debug.assert(expected.len == actual.len);
    const image = try a.alloc(u8, actual.len);
    var pixels: usize = 0;
    var i: usize = 0;
    while (i < actual.len) : (i += 4) {
        var differs = false;
        for (0..4) |c| {
            const d = @as(i16, expected[i + c]) - @as(i16, actual[i + c]);
            if (@abs(d) > tolerance) differs = true;
        }
        if (differs) {
            pixels += 1;
            image[i..][0..4].* = .{ 255, 0, 64, 255 };
        } else {
            for (0..3) |c| image[i + c] = 192 + actual[i + c] / 4;
            image[i + 3] = 255;
        }
    }
    return .{ .pixels = pixels, .image = image };
}

test "encode and decode" {
    const icon = @import("icon.zig");
    const a = std.testing.allocator;
    var rgba: [5 * 3 * 4]u8 = undefined;
    for (&rgba, 0..) |*byte, i| byte.* = @intCast((i * 37) % 256);
    const png = try encode(a, &rgba, 5, 3);
    defer a.free(png);
    const image = try icon.decode(a, png);
    defer image.deinit(a);
    try std.testing.expectEqual(@as(u32, 5), image.width);
    try std.testing.expectEqual(@as(u32, 3), image.height);
    try std.testing.expectEqualSlices(u8, &rgba, image.pixels);
}

test "difference" {
    const a = std.testing.allocator;
    const one = [_]u8{ 10, 10, 10, 255, 200, 200, 200, 255 };
    const two = [_]u8{ 12, 10, 10, 255, 100, 200, 200, 255 };
    const d = try difference(a, &one, &two, 4);
    defer a.free(d.image);
    try std.testing.expectEqual(@as(usize, 1), d.pixels);
}
