//! plume update keygen | sign <file>... [--key <file>]
//!
//! The keys of signed updates (plume.update): keygen writes update.key (the
//! secret: keep it out of the repository, in CI's secrets) and prints the
//! public key for plume.json's "update". sign writes <file>.sig for each
//! file, with update.key or the key in the PLUME_UPDATE_KEY environment
//! variable. plume package signs its update executable the same way.

const std = @import("std");
const cli = @import("main.zig");
const Ed25519 = std.crypto.sign.Ed25519;
const base64 = std.base64.standard;

pub const key_file = "update.key";

pub fn run(context: *cli.Context) !void {
    const command = if (context.args.len > 0) context.args[0] else "";
    if (cli.eql(command, "keygen")) return keygen(context);
    if (cli.eql(command, "sign")) {
        var key_path: []const u8 = key_file;
        var files: std.ArrayList([]const u8) = .empty;
        var i: usize = 1;
        while (i < context.args.len) : (i += 1) {
            if (cli.eql(context.args[i], "--key") and i + 1 < context.args.len) {
                i += 1;
                key_path = context.args[i];
            } else try files.append(context.arena, context.args[i]);
        }
        if (files.items.len == 0) {
            cli.fail("plume update sign <file>...: which files?", .{});
            return error.Reported;
        }
        const pair = try loadKey(context, key_path) orelse {
            cli.fail("no key: {s} (plume update keygen), or PLUME_UPDATE_KEY", .{key_path});
            return error.Reported;
        };
        for (files.items) |file| {
            const signature = try sign(context, pair, file);
            std.debug.print("{s}\n", .{signature});
        }
        return;
    }
    cli.fail("plume update keygen | sign <file>... [--key <file>]", .{});
    return error.Reported;
}

fn keygen(context: *cli.Context) !void {
    if (cli.exists(context, key_file)) {
        cli.fail("{s} exists: an application keeps its key (its users' copies trust it)", .{key_file});
        return error.Reported;
    }
    const pair = Ed25519.KeyPair.generate(context.io);
    var seed_text: [base64.Encoder.calcSize(Ed25519.KeyPair.seed_length)]u8 = undefined;
    _ = base64.Encoder.encode(&seed_text, &pair.secret_key.seed());
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = key_file, .data = &seed_text });
    var public_text: [base64.Encoder.calcSize(Ed25519.PublicKey.encoded_length)]u8 = undefined;
    _ = base64.Encoder.encode(&public_text, &pair.public_key.toBytes());
    std.debug.print(
        \\{s}: the secret key. Keep it out of the repository (.gitignore has it),
        \\and in CI give it as PLUME_UPDATE_KEY.
        \\
        \\plume.json:
        \\  "update": {{ "github": "<owner>/<repo>", "public_key": "{s}" }}
        \\
    , .{ key_file, &public_text });
}

/// The key pair from PLUME_UPDATE_KEY, else from `path`; null if neither.
pub fn loadKey(context: *cli.Context, path: []const u8) !?Ed25519.KeyPair {
    const text = context.environ.get("PLUME_UPDATE_KEY") orelse
        (std.Io.Dir.cwd().readFileAlloc(context.io, path, context.arena, .limited(4096)) catch return null);
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    if ((base64.Decoder.calcSizeForSlice(trimmed) catch 0) != seed.len) {
        cli.fail("the update key is not one (base64 of 32 bytes)", .{});
        return error.Reported;
    }
    try base64.Decoder.decode(&seed, trimmed);
    return try Ed25519.KeyPair.generateDeterministic(seed);
}

/// Writes `file`.sig; returns its path.
pub fn sign(context: *cli.Context, pair: Ed25519.KeyPair, file: []const u8) ![]const u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(context.io, file, context.arena, .limited(4 << 30)) catch |err| {
        cli.fail("{s}: {s}", .{ file, @errorName(err) });
        return error.Reported;
    };
    const signature = try pair.sign(data, null);
    var text: [base64.Encoder.calcSize(Ed25519.Signature.encoded_length)]u8 = undefined;
    _ = base64.Encoder.encode(&text, &signature.toBytes());
    const path = try std.fmt.allocPrint(context.arena, "{s}.sig", .{file});
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = path, .data = &text });
    return path;
}
