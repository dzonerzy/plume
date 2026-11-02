//! An application's icon from one PNG: the sizes Windows wants, packed as
//! an .ico (PNG entries, as Windows Vista and later read them), and raw RGBA
//! for a window's icon on Linux (zg_window_set_icon).
//!
//! Reads 8-bit PNGs (gray, gray and alpha, RGB, RGBA, palette), not
//! interlaced; square, 256 pixels or more.

const std = @import("std");
const flate = std.compress.flate;

pub const Error = error{ NotPng, UnsupportedPng, InvalidPng, NotSquare, TooSmall, OutOfMemory };

/// The sizes of the .ico: Explorer's views, the taskbar, title bars, at
/// 100% to 200% scale.
pub const ico_sizes = [_]u32{ 16, 20, 24, 32, 40, 48, 64, 96, 128, 256 };

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGBA8, rows top to bottom.
    pixels: []u8,

    pub fn deinit(image: Image, allocator: std.mem.Allocator) void {
        allocator.free(image.pixels);
    }
};

// ---- Reading ----

pub fn decode(allocator: std.mem.Allocator, png: []const u8) Error!Image {
    const signature = "\x89PNG\r\n\x1a\n";
    if (png.len < signature.len or !std.mem.eql(u8, png[0..signature.len], signature)) return error.NotPng;
    var width: u32 = 0;
    var height: u32 = 0;
    var color_type: u8 = 0;
    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);

    var at: usize = signature.len;
    while (at + 12 <= png.len) {
        const length = std.mem.readInt(u32, png[at..][0..4], .big);
        const kind = png[at + 4 ..][0..4];
        if (at + 12 + length > png.len) return error.InvalidPng;
        const data = png[at + 8 ..][0..length];
        at += 12 + length;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (length != 13) return error.InvalidPng;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            const depth = data[8];
            color_type = data[9];
            if (depth != 8 or data[12] != 0) return error.UnsupportedPng; // 8 bits, not interlaced
            switch (color_type) {
                0, 2, 3, 4, 6 => {},
                else => return error.UnsupportedPng,
            }
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            for (0..@min(length / 3, 256)) |i| palette[i] = .{ data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS") and color_type == 3) {
            for (0..@min(length, 256)) |i| palette[i][3] = data[i];
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try compressed.appendSlice(allocator, data);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    if (width == 0 or height == 0) return error.InvalidPng;

    const channels: usize = switch (color_type) {
        0, 3 => 1,
        4 => 2,
        2 => 3,
        else => 4,
    };
    const stride = width * channels;
    var input: std.Io.Reader = .fixed(compressed.items);
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    var decompressor: flate.Decompress = .init(&input, .zlib, window);
    const raw = decompressor.reader.allocRemaining(allocator, .limited((stride + 1) * height + 1)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPng,
    };
    defer allocator.free(raw);
    if (raw.len != (stride + 1) * height) return error.InvalidPng;

    // Undo each row's filter, in place.
    var previous: ?[]const u8 = null;
    for (0..height) |y| {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        try unfilter(raw[y * (stride + 1)], row, previous, channels);
        previous = row;
    }

    const pixels = try allocator.alloc(u8, @as(usize, width) * height * 4);
    for (0..height) |y| {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        for (0..width) |x| {
            const out = pixels[(y * width + x) * 4 ..][0..4];
            const in = row[x * channels ..][0..channels];
            out.* = switch (color_type) {
                0 => .{ in[0], in[0], in[0], 255 },
                4 => .{ in[0], in[0], in[0], in[1] },
                2 => .{ in[0], in[1], in[2], 255 },
                3 => palette[in[0]],
                else => in[0..4].*,
            };
        }
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

fn unfilter(filter: u8, row: []u8, previous: ?[]const u8, bpp: usize) Error!void {
    for (row, 0..) |*byte, i| {
        const left: u8 = if (i >= bpp) row[i - bpp] else 0;
        const up: u8 = if (previous) |p| p[i] else 0;
        const up_left: u8 = if (previous != null and i >= bpp) previous.?[i - bpp] else 0;
        byte.* +%= switch (filter) {
            0 => 0,
            1 => left,
            2 => up,
            3 => @intCast((@as(u16, left) + up) / 2),
            4 => paeth(left, up, up_left),
            else => return error.InvalidPng,
        };
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}

// ---- Resizing ----

/// `image` made `size` × `size` by averaging the pixels each one covers
/// (premultiplied, so transparent edges keep their color).
pub fn downscale(allocator: std.mem.Allocator, image: Image, size: u32) Error!Image {
    const pixels = try allocator.alloc(u8, @as(usize, size) * size * 4);
    const scale = @as(f64, @floatFromInt(image.width)) / @as(f64, @floatFromInt(size));
    for (0..size) |y| {
        const y0 = @as(f64, @floatFromInt(y)) * scale;
        const y1 = y0 + scale;
        for (0..size) |x| {
            const x0 = @as(f64, @floatFromInt(x)) * scale;
            const x1 = x0 + scale;
            var sum: [4]f64 = @splat(0);
            var area: f64 = 0;
            var sy: usize = @intFromFloat(@floor(y0));
            while (@as(f64, @floatFromInt(sy)) < y1 and sy < image.height) : (sy += 1) {
                const wy = @min(y1, @as(f64, @floatFromInt(sy + 1))) - @max(y0, @as(f64, @floatFromInt(sy)));
                var sx: usize = @intFromFloat(@floor(x0));
                while (@as(f64, @floatFromInt(sx)) < x1 and sx < image.width) : (sx += 1) {
                    const wx = @min(x1, @as(f64, @floatFromInt(sx + 1))) - @max(x0, @as(f64, @floatFromInt(sx)));
                    const weight = wx * wy;
                    const p = image.pixels[(sy * image.width + sx) * 4 ..][0..4];
                    const alpha = @as(f64, @floatFromInt(p[3])) / 255.0;
                    for (0..3) |c| sum[c] += @as(f64, @floatFromInt(p[c])) * alpha * weight;
                    sum[3] += alpha * weight;
                    area += weight;
                }
            }
            const out = pixels[(y * size + x) * 4 ..][0..4];
            const alpha = if (area > 0) sum[3] / area else 0;
            for (0..3) |c| out[c] = if (sum[3] > 0) channel(sum[c] / sum[3]) else 0;
            out[3] = channel(alpha * 255.0);
        }
    }
    return .{ .width = size, .height = size, .pixels = pixels };
}

fn channel(value: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 255)));
}

// ---- Writing ----

/// An RGBA8 PNG of `image`.
pub fn encode(allocator: std.mem.Allocator, image: Image) Error![]u8 {
    const stride = @as(usize, image.width) * 4;
    const raw = try allocator.alloc(u8, (stride + 1) * image.height);
    defer allocator.free(raw);
    for (0..image.height) |y| {
        raw[y * (stride + 1)] = 0; // no filter
        @memcpy(raw[y * (stride + 1) + 1 ..][0..stride], image.pixels[y * stride ..][0..stride]);
    }
    // The compressor needs room in its output from the start.
    var deflated: std.Io.Writer.Allocating = try .initCapacity(allocator, @max(1024, raw.len / 4));
    defer deflated.deinit();
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    var compressor = flate.Compress.init(&deflated.writer, window, .zlib, .best) catch return error.OutOfMemory;
    compressor.writer.writeAll(raw) catch return error.OutOfMemory;
    compressor.finish() catch return error.OutOfMemory;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeAll("\x89PNG\r\n\x1a\n") catch return error.OutOfMemory;
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], image.width, .big);
    std.mem.writeInt(u32, header[4..8], image.height, .big);
    header[8..13].* = .{ 8, 6, 0, 0, 0 };
    chunk(w, "IHDR", &header) catch return error.OutOfMemory;
    chunk(w, "IDAT", deflated.written()) catch return error.OutOfMemory;
    chunk(w, "IEND", "") catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) std.Io.Writer.Error!void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

/// An .ico of `image` at every size of ico_sizes, as PNG entries.
pub fn ico(allocator: std.mem.Allocator, image: Image) Error![]u8 {
    if (image.width != image.height) return error.NotSquare;
    if (image.width < 256) return error.TooSmall;
    var entries: [ico_sizes.len][]u8 = undefined;
    var made: usize = 0;
    defer for (entries[0..made]) |entry| allocator.free(entry);
    for (ico_sizes, 0..) |size, i| {
        const small = try downscale(allocator, image, size);
        defer small.deinit(allocator);
        entries[i] = try encode(allocator, small);
        made += 1;
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const header_len = 6 + 16 * ico_sizes.len;
    (struct {
        fn write(writer: *std.Io.Writer, list: [][]u8, offset_start: usize) std.Io.Writer.Error!void {
            try writer.writeInt(u16, 0, .little);
            try writer.writeInt(u16, 1, .little); // an icon
            try writer.writeInt(u16, @intCast(list.len), .little);
            var offset = offset_start;
            for (list, ico_sizes) |entry, size| {
                const side: u8 = if (size >= 256) 0 else @intCast(size); // 0 is 256
                try writer.writeAll(&.{ side, side, 0, 0 });
                try writer.writeInt(u16, 1, .little); // planes
                try writer.writeInt(u16, 32, .little); // bits per pixel
                try writer.writeInt(u32, @intCast(entry.len), .little);
                try writer.writeInt(u32, @intCast(offset), .little);
                offset += entry.len;
            }
            for (list) |entry| try writer.writeAll(entry);
        }
    }).write(w, entries[0..made], header_len) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

test "a PNG written, read back, made smaller and packed" {
    const allocator = std.testing.allocator;
    const size = 256;
    const pixels = try allocator.alloc(u8, size * size * 4);
    defer allocator.free(pixels);
    for (0..size) |y| for (0..size) |x| {
        // Left half opaque blue, right half transparent.
        pixels[(y * size + x) * 4 ..][0..4].* = if (x < size / 2) .{ 0x2b, 0x59, 0xd9, 255 } else .{ 0, 0, 0, 0 };
    };
    const image: Image = .{ .width = size, .height = size, .pixels = pixels };
    const png = try encode(allocator, image);
    defer allocator.free(png);
    const back = try decode(allocator, png);
    defer back.deinit(allocator);
    try std.testing.expectEqualSlices(u8, pixels, back.pixels);

    const small = try downscale(allocator, back, 16);
    defer small.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &.{ 0x2b, 0x59, 0xd9, 255 }, small.pixels[0..4]);
    try std.testing.expectEqual(@as(u8, 0), small.pixels[(16 - 1) * 4 + 3]);

    const icon = try ico(allocator, back);
    defer allocator.free(icon);
    try std.testing.expectEqual(@as(u16, ico_sizes.len), std.mem.readInt(u16, icon[4..6], .little));
    const last_offset = std.mem.readInt(u32, icon[6 + 16 * (ico_sizes.len - 1) + 12 ..][0..4], .little);
    try std.testing.expectEqualStrings("\x89PNG", icon[last_offset..][0..4]);
    try std.testing.expectError(error.TooSmall, ico(allocator, small));
}
