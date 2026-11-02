//! Updates from GitHub releases, signed with Ed25519.
//!
//! plume.json names the repository and the public key:
//!
//!     "update": { "github": "owner/repo", "public_key": "<base64>" }
//!
//! (`plume update keygen` makes the key pair). A release of the repository
//! whose tag is a newer version ("v1.2.4" or "1.2.4") carries, for each
//! platform, the executable and its signature (`plume update sign`):
//!
//!     <name>-<version>-windows-x64.exe  and  .exe.sig
//!     <name>-<version>-linux-x64        and  .sig
//!
//! and the executable gzip-compressed as <asset>.gz, downloaded instead when
//! there (the signature is the uncompressed executable's; install's progress
//! reports the download).
//!
//! install() downloads the executable and its signature, checks the
//! signature, runs the new executable once with PLUME_VERIFY set (it must
//! start and say its version: App.init answers and exits), then swaps it for
//! the running one: the running one is renamed <exe>.old (Windows lets a
//! running executable be renamed, not replaced), the new one takes its name;
//! if that fails the old one gets its name back. The next start removes the
//! .old file. restart() starts the new one with the same arguments.
//!
//! Everything here blocks on the network or the disk: call it from a worker
//! thread (an async binding, or the pages' Plume.updates, which do).

const std = @import("std");
const builtin = @import("builtin");
const Ed25519 = std.crypto.sign.Ed25519;
const base64 = std.base64.standard;

pub const Config = struct {
    /// "owner/repo".
    github: []const u8,
    /// The Ed25519 public key, base64.
    public_key: []const u8,
    /// GitHub's API: another for GitHub Enterprise ("https://host/api/v3").
    api_url: []const u8 = "https://api.github.com",
};

pub const Release = struct {
    /// Without a leading "v".
    version: []const u8,
    /// The release's notes (Markdown, as on GitHub).
    notes: []const u8,
    url: []const u8,
    signature_url: []const u8,
    /// The download's size in bytes, as GitHub gives it (0: unknown).
    size: u64 = 0,
    /// The download is gzip-compressed (<asset>.gz); the signature is the
    /// executable's.
    compressed: bool = false,
};

/// install()'s progress: `report(context, received, total)` as the download
/// goes (total 0 when unknown), on install's thread.
pub const Progress = struct {
    context: ?*anyopaque,
    report: *const fn (?*anyopaque, u64, u64) void,
};

pub const Error = error{
    /// No "update" in plume.json, or a public key that is not one.
    NotConfigured,
    /// The server did not answer as expected.
    NetworkFailed,
    /// The release has no executable (or signature) for this platform.
    NoAsset,
    /// The signature does not match: the download is not the publisher's.
    BadSignature,
    /// The new executable did not start, or gave another version.
    VerifyFailed,
    /// The executable could not be swapped (it was put back).
    InstallFailed,
    OutOfMemory,
};

/// The asset's name for this platform: "<name>-<version>-windows-x64.exe".
pub fn assetName(a: std.mem.Allocator, name: []const u8, version: []const u8) error{OutOfMemory}![]u8 {
    return switch (builtin.os.tag) {
        .windows => std.fmt.allocPrint(a, "{s}-{s}-windows-x64.exe", .{ name, version }),
        else => std.fmt.allocPrint(a, "{s}-{s}-linux-x64", .{ name, version }),
    };
}

/// The latest release if its version is newer than `current`, else null.
pub fn check(a: std.mem.Allocator, io: std.Io, config: Config, name: []const u8, current: []const u8) Error!?Release {
    const url = std.fmt.allocPrint(a, "{s}/repos/{s}/releases/latest", .{ std.mem.trimEnd(u8, config.api_url, "/"), config.github }) catch return error.OutOfMemory;
    const body = try get(a, io, url, 1 << 20, null, 0);
    const Latest = struct {
        tag_name: []const u8,
        body: ?[]const u8 = null,
        draft: bool = false,
        prerelease: bool = false,
        assets: []const struct { name: []const u8, browser_download_url: []const u8, size: u64 = 0 } = &.{},
    };
    const latest = std.json.parseFromSliceLeaky(Latest, a, body, .{ .ignore_unknown_fields = true }) catch return error.NetworkFailed;
    if (latest.draft or latest.prerelease) return null;
    const version = std.mem.trimStart(u8, latest.tag_name, "vV");
    if (!newer(version, current)) return null;
    const asset = try assetName(a, name, version);
    const compressed_asset = std.fmt.allocPrint(a, "{s}.gz", .{asset}) catch return error.OutOfMemory;
    const signature = std.fmt.allocPrint(a, "{s}.sig", .{asset}) catch return error.OutOfMemory;
    var release: Release = .{ .version = version, .notes = latest.body orelse "", .url = "", .signature_url = "" };
    // The compressed one when there is one.
    for (latest.assets) |item| {
        if (std.mem.eql(u8, item.name, asset) and !release.compressed) {
            release.url = item.browser_download_url;
            release.size = item.size;
        }
        if (std.mem.eql(u8, item.name, compressed_asset)) {
            release.url = item.browser_download_url;
            release.size = item.size;
            release.compressed = true;
        }
        if (std.mem.eql(u8, item.name, signature)) release.signature_url = item.browser_download_url;
    }
    if (release.url.len == 0 or release.signature_url.len == 0) return error.NoAsset;
    return release;
}

/// `data` gzip-compressed (plume package's update assets).
pub fn gzip(a: std.mem.Allocator, data: []const u8) error{OutOfMemory}![]u8 {
    const flate = std.compress.flate;
    var out: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(a, @max(64 * 1024, data.len / 2)) catch return error.OutOfMemory;
    errdefer out.deinit();
    const window = try a.alloc(u8, flate.max_window_len);
    defer a.free(window);
    const compressor = try a.create(flate.Compress);
    defer a.destroy(compressor);
    compressor.* = flate.Compress.init(&out.writer, window, .gzip, .default) catch return error.OutOfMemory;
    compressor.writer.writeAll(data) catch return error.OutOfMemory;
    compressor.finish() catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn gunzip(a: std.mem.Allocator, data: []const u8, limit: usize) Error![]u8 {
    const flate = std.compress.flate;
    var input: std.Io.Reader = .fixed(data);
    const window = try a.alloc(u8, flate.max_window_len);
    defer a.free(window);
    var decompressor: flate.Decompress = .init(&input, .gzip, window);
    return decompressor.reader.allocRemaining(a, .limited(limit)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadSignature, // not what was signed
    };
}

/// Downloads, checks and swaps in `release` (see the top of this file).
pub fn install(a: std.mem.Allocator, io: std.Io, config: Config, release: Release, progress: ?Progress) Error!void {
    const key = try publicKey(config);
    const signature_text = try get(a, io, release.signature_url, 4096, null, 0);
    const downloaded = try get(a, io, release.url, 2 << 30, progress, release.size);
    const data = if (release.compressed) try gunzip(a, downloaded, 2 << 30) else downloaded;
    try verifySignature(key, data, signature_text);

    const exe = std.process.executablePathAlloc(io, a) catch |err| return installFailed("the executable's path", err);
    const new_path = std.fmt.allocPrint(a, "{s}.new", .{exe}) catch return error.OutOfMemory;
    const old_path = std.fmt.allocPrint(a, "{s}.old", .{exe}) catch return error.OutOfMemory;
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = new_path, .data = data, .flags = .{ .permissions = .executable_file } }) catch |err| return installFailed(new_path, err);
    errdefer cwd.deleteFile(io, new_path) catch {};
    try verifyRun(a, io, new_path, release.version);

    cwd.deleteFile(io, old_path) catch {};
    move(a, io, exe, old_path) catch |err| return installFailed(exe, err);
    move(a, io, new_path, exe) catch |err| {
        // Put back.
        move(a, io, old_path, exe) catch {};
        return installFailed(exe, err);
    };
}

/// A rename that works on the running executable: on Windows MoveFileExW
/// (std's rename opens the file in a way a running image refuses).
fn move(a: std.mem.Allocator, io: std.Io, from: []const u8, to: []const u8) !void {
    if (builtin.os.tag != .windows) return std.Io.Dir.cwd().rename(from, std.Io.Dir.cwd(), to, io);
    const from_w = try std.unicode.wtf8ToWtf16LeAllocZ(a, from);
    const to_w = try std.unicode.wtf8ToWtf16LeAllocZ(a, to);
    const MOVEFILE_REPLACE_EXISTING = 0x1;
    if (MoveFileExW(from_w.ptr, to_w.ptr, MOVEFILE_REPLACE_EXISTING) == 0) return error.AccessDenied;
}

extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: u32) callconv(.winapi) i32;

fn installFailed(what: []const u8, err: anyerror) Error {
    std.log.err("plume: update: {s}: {s}", .{ what, @errorName(err) });
    return error.InstallFailed;
}

/// Starts the executable again with `args` (the program's, its name first);
/// the caller then quits.
pub fn restart(a: std.mem.Allocator, io: std.Io, args: []const []const u8) Error!void {
    const exe = std.process.executablePathAlloc(io, a) catch return error.InstallFailed;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(a, exe) catch return error.OutOfMemory;
    if (args.len > 1) argv.appendSlice(a, args[1..]) catch return error.OutOfMemory;
    _ = std.process.spawn(io, .{ .argv = argv.items }) catch return error.InstallFailed;
}

/// The .old executable an update left: removed (a few tries, while the
/// process that was updated ends). Any thread.
pub fn cleanup(io: std.Io) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const exe = std.process.executablePathAlloc(io, fixed.allocator()) catch return;
    var old_buffer: [std.fs.max_path_bytes + 4]u8 = undefined;
    const old_path = std.fmt.bufPrint(&old_buffer, "{s}.old", .{exe}) catch return;
    for (0..20) |_| {
        std.Io.Dir.cwd().deleteFile(io, old_path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => {
                std.Io.sleep(io, .fromMilliseconds(250), .awake) catch return;
                continue;
            },
        };
        return;
    }
}

fn publicKey(config: Config) Error!Ed25519.PublicKey {
    var bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    const trimmed = std.mem.trim(u8, config.public_key, " \r\n\t");
    if ((base64.Decoder.calcSizeForSlice(trimmed) catch return error.NotConfigured) != bytes.len) return error.NotConfigured;
    base64.Decoder.decode(&bytes, trimmed) catch return error.NotConfigured;
    return Ed25519.PublicKey.fromBytes(bytes) catch error.NotConfigured;
}

/// `signature_text`: the .sig file, the signature in base64.
pub fn verifySignature(key: Ed25519.PublicKey, data: []const u8, signature_text: []const u8) Error!void {
    var bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    const trimmed = std.mem.trim(u8, signature_text, " \r\n\t");
    if ((base64.Decoder.calcSizeForSlice(trimmed) catch return error.BadSignature) != bytes.len) return error.BadSignature;
    base64.Decoder.decode(&bytes, trimmed) catch return error.BadSignature;
    Ed25519.Signature.fromBytes(bytes).verify(data, key) catch return error.BadSignature;
}

/// Runs `path` with PLUME_VERIFY=1: it must exit 0 saying "plume-verify <version>".
fn verifyRun(a: std.mem.Allocator, io: std.Io, path: []const u8, version: []const u8) Error!void {
    // This process's environment, as far as starting a program needs it.
    var environ: std.process.Environ.Map = .init(a);
    for ([_][:0]const u8{ "PATH", "SystemRoot", "SYSTEMROOT", "TEMP", "TMP", "HOME", "LOCALAPPDATA", "APPDATA", "USERPROFILE", "XDG_RUNTIME_DIR", "LANG" }) |variable| {
        if (std.c.getenv(variable)) |value| environ.put(variable, std.mem.span(value)) catch return error.OutOfMemory;
    }
    environ.put("PLUME_VERIFY", "1") catch return error.OutOfMemory;
    const result = std.process.run(a, io, .{ .argv = &.{path}, .environ_map = &environ }) catch |err| {
        std.log.err("plume: update: the new executable did not start: {s}", .{@errorName(err)});
        return error.VerifyFailed;
    };
    const expected = std.fmt.allocPrint(a, "plume-verify {s}", .{version}) catch return error.OutOfMemory;
    if (!result.term.success() or std.mem.indexOf(u8, result.stdout, expected) == null) {
        std.log.err("plume: update: the new executable answered \"{s}\", not \"{s}\"", .{ std.mem.trim(u8, result.stdout, " \r\n"), expected });
        return error.VerifyFailed;
    }
}

/// The body written to `inner`, its progress reported as it comes.
const Counting = struct {
    inner: *std.Io.Writer,
    progress: Progress,
    total: u64,
    received: u64 = 0,
    interface: std.Io.Writer,

    fn init(inner: *std.Io.Writer, progress: Progress, total: u64, buffer: []u8) Counting {
        return .{ .inner = inner, .progress = progress, .total = total, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    /// The buffer's bytes first, then `data` (the last slice `splat` times).
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Counting = @fieldParentPtr("interface", w);
        const buffered = w.buffered();
        if (buffered.len > 0) {
            try self.inner.writeAll(buffered);
            self.received += buffered.len;
            w.end = 0;
        }
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.inner.writeAll(bytes);
            n += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try self.inner.writeAll(last);
            n += last.len;
        }
        self.received += n;
        self.progress.report(self.progress.context, self.received, self.total);
        return n;
    }
};

fn get(a: std.mem.Allocator, io: std.Io, url: []const u8, limit: usize, progress: ?Progress, total: u64) Error![]u8 {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(a);
    var counting_buffer: [64 * 1024]u8 = undefined;
    var counting: Counting = .init(&body.writer, progress orelse undefined, total, &counting_buffer);
    const status = request(&client, a, url, if (progress != null) &counting.interface else &body.writer) catch |err| {
        std.log.warn("plume: update: {s}: {s}", .{ url, @errorName(err) });
        return error.NetworkFailed;
    };
    // What the counting writer still holds.
    if (progress != null) counting.interface.flush() catch return error.OutOfMemory;
    if (status != .ok) {
        std.log.warn("plume: update: {s}: HTTP {d}", .{ url, @intFromEnum(status) });
        return error.NetworkFailed;
    }
    if (body.written().len > limit) return error.NetworkFailed;
    return body.written();
}

/// A GET of `url`, its body to `out`, following redirects as they are given:
/// GitHub's assets redirect to signed CDN URLs whose query std's own
/// redirects would re-encode (and the CDN refuse).
fn request(client: *std.http.Client, a: std.mem.Allocator, url: []const u8, out: *std.Io.Writer) !std.http.Status {
    var location: []const u8 = url;
    for (0..8) |_| {
        const uri = try std.Uri.parse(location);
        var req = try client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            // One User-Agent (GitHub's API wants one): std's, replaced.
            .headers = .{ .user_agent = .{ .override = "plume-updater" } },
            .extra_headers = &.{
                .{ .name = "Accept", .value = "application/vnd.github+json, application/octet-stream" },
            },
        });
        defer req.deinit();
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        if (response.head.status.class() == .redirect) {
            const next = response.head.location orelse return error.HttpRedirectLocationMissing;
            location = try a.dupe(u8, next);
            continue;
        }
        if (response.head.status != .ok) return response.head.status;
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .deflate, .gzip => try a.alloc(u8, std.compress.flate.max_window_len),
            else => return error.UnsupportedCompressionMethod,
        };
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = reader.streamRemaining(out) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
        return .ok;
    }
    return error.TooManyHttpRedirects;
}

/// Whether `candidate` is a newer version than `current` ("1.10.0" > "1.9.2";
/// a pre-release "1.2.0-beta" is older than "1.2.0").
pub fn newer(candidate: []const u8, current: []const u8) bool {
    return order(candidate, current) == .gt;
}

fn order(a: []const u8, b: []const u8) std.math.Order {
    const a_core, const a_pre = split(a);
    const b_core, const b_pre = split(b);
    var a_parts = std.mem.tokenizeScalar(u8, a_core, '.');
    var b_parts = std.mem.tokenizeScalar(u8, b_core, '.');
    for (0..4) |_| {
        const x = std.fmt.parseInt(u32, a_parts.next() orelse "0", 10) catch 0;
        const y = std.fmt.parseInt(u32, b_parts.next() orelse "0", 10) catch 0;
        if (x != y) return std.math.order(x, y);
    }
    // A pre-release comes before the release.
    if (a_pre.len == 0 and b_pre.len == 0) return .eq;
    if (a_pre.len == 0) return .gt;
    if (b_pre.len == 0) return .lt;
    return std.mem.order(u8, a_pre, b_pre);
}

fn split(version: []const u8) struct { []const u8, []const u8 } {
    const trimmed = std.mem.trimStart(u8, version, "vV");
    const plus = std.mem.indexOfScalar(u8, trimmed, '+') orelse trimmed.len;
    const core = trimmed[0..plus];
    const dash = std.mem.indexOfScalar(u8, core, '-') orelse return .{ core, "" };
    return .{ core[0..dash], core[dash + 1 ..] };
}

test "versions" {
    try std.testing.expect(newer("1.10.0", "1.9.2"));
    try std.testing.expect(newer("v2.0.0", "1.99.99"));
    try std.testing.expect(!newer("1.2.0", "1.2.0"));
    try std.testing.expect(newer("1.2.0", "1.2.0-beta"));
    try std.testing.expect(!newer("1.2.0-beta", "1.2.0"));
    try std.testing.expect(newer("1.2.0-rc.2", "1.2.0-rc.1"));
    try std.testing.expect(!newer("1.2", "1.2.0"));
}

test "the counting writer passes everything through and counts it" {
    const a = std.testing.allocator;
    var inner: std.Io.Writer.Allocating = .init(a);
    defer inner.deinit();
    const Seen = struct {
        reports: usize = 0,
        last: u64 = 0,
        fn report(context: ?*anyopaque, received: u64, total: u64) void {
            _ = total;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.reports += 1;
            self.last = received;
        }
    };
    var seen: Seen = .{};
    var buffer: [16]u8 = undefined;
    var counting: Counting = .init(&inner.writer, .{ .context = &seen, .report = Seen.report }, 0, &buffer);
    var data: [1000]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @intCast(i % 256);
    try counting.interface.writeAll(data[0..10]);
    try counting.interface.writeAll(data[10..]);
    try counting.interface.splatByteAll('z', 40);
    try counting.interface.flush();
    try std.testing.expectEqual(@as(usize, 1040), inner.written().len);
    try std.testing.expectEqualSlices(u8, &data, inner.written()[0..1000]);
    try std.testing.expectEqual(@as(u64, 1040), counting.received);
    try std.testing.expect(seen.reports > 0);
}

test "gzip round trip" {
    const a = std.testing.allocator;
    var data: [100_000]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @intCast((i * 7 + i / 300) % 251);
    const packed_data = try gzip(a, &data);
    defer a.free(packed_data);
    try std.testing.expect(packed_data.len < data.len);
    const unpacked = try gunzip(a, packed_data, 1 << 20);
    defer a.free(unpacked);
    try std.testing.expectEqualSlices(u8, &data, unpacked);
}

test "signatures" {
    const pair = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const data = "the new executable";
    const signature = try pair.sign(data, null);
    var text: [base64.Encoder.calcSize(Ed25519.Signature.encoded_length)]u8 = undefined;
    _ = base64.Encoder.encode(&text, &signature.toBytes());
    try verifySignature(pair.public_key, data, &text);
    try std.testing.expectError(error.BadSignature, verifySignature(pair.public_key, "something else", &text));
    try std.testing.expectError(error.BadSignature, verifySignature(pair.public_key, data, "not base64!"));
    var key_text: [base64.Encoder.calcSize(32)]u8 = undefined;
    _ = base64.Encoder.encode(&key_text, &pair.public_key.toBytes());
    _ = try publicKey(.{ .github = "o/r", .public_key = &key_text });
    try std.testing.expectError(error.NotConfigured, publicKey(.{ .github = "o/r", .public_key = "short" }));
}
