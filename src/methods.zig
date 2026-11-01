//! Which functions of a type are bindings, and what JavaScript passes them:
//! shared by the dispatcher (bindings.zig) and the TypeScript generator.
//!
//! A binding is a `pub fn` whose first parameter is the instance (`*T`,
//! `*const T` or `T`), except `deinit` and the names in `pub const hidden`.
//! Its other parameters come from JavaScript in order, except those of type
//! `std.mem.Allocator`: they get the call's arena, freed after the call (sync)
//! or once the Promise settled (async), and those of type plume.Page: the
//! calling page's objects (sync bindings only). The names in
//! `pub const async_methods` run on a worker thread and return a Promise.
//! `pub const Events`, a struct, declares the events (names and data types)
//! the type's frontend gets typed in bindings.ts.

const std = @import("std");

pub const Method = struct {
    name: [:0]const u8,
    is_async: bool,
};

/// The bindings of `T`, in declaration order.
pub fn of(comptime T: type) []const Method {
    comptime {
        const decls = @typeInfo(T).@"struct".decl_names;
        var result: [decls.len]Method = undefined;
        var count = 0;
        for (decls) |name| {
            if (!isBinding(T, name))
                continue;
            result[count] = .{ .name = name, .is_async = listed(T, "async_methods", name) };
            if (result[count].is_async) {
                for (@typeInfo(@TypeOf(@field(T, name))).@"fn".param_types) |P| {
                    if (P != null and isInjected(P.?))
                        @compileError(@typeName(T) ++ "." ++ name ++ " is async: the page (" ++ @typeName(P.?) ++ ") is for the runtime thread, in sync bindings");
                }
            }
            count += 1;
        }
        // Every name listed must be a binding.
        for (.{ "async_methods", "hidden" }) |list| {
            if (@hasDecl(T, list)) {
                for (@field(T, list)) |listed_name| {
                    if (!@hasDecl(T, listed_name) or @typeInfo(@TypeOf(@field(T, listed_name))) != .@"fn")
                        @compileError(@typeName(T) ++ "." ++ list ++ " names \"" ++ listed_name ++ "\", which is not a pub fn of it");
                }
            }
        }
        const final = result[0..count].*;
        return &final;
    }
}

fn listed(comptime T: type, comptime list: []const u8, comptime name: []const u8) bool {
    if (!@hasDecl(T, list))
        return false;
    for (@field(T, list)) |listed_name| {
        if (std.mem.eql(u8, listed_name, name))
            return true;
    }
    return false;
}

fn isBinding(comptime T: type, comptime name: []const u8) bool {
    const F = @TypeOf(@field(T, name));
    if (@typeInfo(F) != .@"fn")
        return false;
    if (std.mem.eql(u8, name, "deinit") or listed(T, "hidden", name))
        return false;
    const params = @typeInfo(F).@"fn".param_types;
    if (params.len == 0)
        return false;
    const First = params[0] orelse return false;
    return First == *T or First == *const T or First == T;
}

/// The types JavaScript passes, in order (the instance and allocators left out).
pub fn jsParams(comptime T: type, comptime name: []const u8) []const type {
    comptime {
        const params = @typeInfo(@TypeOf(@field(T, name))).@"fn".param_types;
        var result: [params.len]type = undefined;
        var count = 0;
        for (params[1..]) |Param| {
            const P = Param orelse @compileError(@typeName(T) ++ "." ++ name ++ ": bindings take no anytype parameters");
            if (P == std.mem.Allocator or isInjected(P))
                continue;
            result[count] = P;
            count += 1;
        }
        const final = result[0..count].*;
        return &final;
    }
}

/// A parameter the dispatcher provides from the call (plume.Page, which
/// declares `plume_injected`), not JavaScript.
pub fn isInjected(comptime P: type) bool {
    return @typeInfo(P) == .@"struct" and @hasDecl(P, "plume_injected");
}

/// What the method returns, without its error set.
pub fn Result(comptime T: type, comptime name: []const u8) type {
    const R = @typeInfo(@TypeOf(@field(T, name))).@"fn".return_type orelse
        @compileError(@typeName(T) ++ "." ++ name ++ ": bindings have a known return type");
    return switch (@typeInfo(R)) {
        .error_union => |info| info.payload,
        else => R,
    };
}

/// The error names the method may fail with: null if it cannot fail, empty
/// if its error set is inferred as anyerror.
pub fn errorNames(comptime T: type, comptime name: []const u8) ?[]const [:0]const u8 {
    const R = @typeInfo(@TypeOf(@field(T, name))).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |info| @typeInfo(info.error_set).error_set.error_names orelse &.{},
        else => null,
    };
}

test "which functions are bindings" {
    const FakePage = struct {
        pub const plume_injected = {};
    };
    const Example = struct {
        pub const async_methods = .{"slow"};
        pub const hidden = .{"internal"};
        pub fn init() @This() {
            return .{};
        }
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
        pub fn greet(self: *@This(), allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
            _ = self;
            return allocator.dupe(u8, name);
        }
        pub fn slow(self: *const @This(), n: u32) error{TooSlow}!u32 {
            _ = self;
            return n;
        }
        pub fn internal(self: *@This()) void {
            _ = self;
        }
        pub fn rename(self: *@This(), page: FakePage, title: []const u8) void {
            _ = self;
            _ = page;
            _ = title;
        }
    };
    const found = comptime of(Example);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expect(comptime jsParams(Example, "rename").len == 1);
    try std.testing.expectEqualStrings("greet", found[0].name);
    try std.testing.expect(!found[0].is_async);
    try std.testing.expectEqualStrings("slow", found[1].name);
    try std.testing.expect(found[1].is_async);
    try std.testing.expectEqual(@as(usize, 1), comptime jsParams(Example, "greet").len);
    try std.testing.expect(comptime jsParams(Example, "greet")[0] == []const u8);
    try std.testing.expect(Result(Example, "slow") == u32);
    try std.testing.expectEqualStrings("TooSlow", comptime errorNames(Example, "slow").?[0]);
    try std.testing.expect(comptime errorNames(Example, "internal") == null);
}
