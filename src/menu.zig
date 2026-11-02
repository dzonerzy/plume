//! Menus, defined once in Zig: the window's menu bar and popup menus.
//!
//!     try app.setMenu(&.{
//!         menu.submenu("&File", &.{
//!             menu.item("open", "&Open…", "Ctrl+O"),
//!             menu.separator,
//!             menu.item("quit", "E&xit", "Alt+F4"),
//!         }),
//!         menu.submenu("&View", &.{menu.checkbox("dark", "&Dark mode", true)}),
//!     });
//!     try app.onMenu(&state, State.chosen); // chosen(state, "open")
//!
//! Items have string ids; a chosen one reaches app.onMenu's handlers and the
//! page's "menu" event. On Windows the menus are the system's; on Linux,
//! which has no menu bar of its own for a window, the page runtime draws
//! them (and takes their accelerators) at the top of the page.

const std = @import("std");
const zg = @import("zerog");

pub const Item = union(enum) {
    action: Action,
    checkbox: Checkbox,
    separator,
    submenu: Submenu,
};

pub const Action = struct {
    id: []const u8,
    /// '&' marks the access key ("&Open").
    label: []const u8,
    /// "Ctrl+S", "Ctrl+Shift+N", "F5": shown, and pressing it chooses the
    /// item (ahead of the page).
    accelerator: ?[]const u8 = null,
    enabled: bool = true,
};

pub const Checkbox = struct {
    id: []const u8,
    label: []const u8,
    accelerator: ?[]const u8 = null,
    checked: bool = false,
    enabled: bool = true,
};

pub const Submenu = struct {
    label: []const u8,
    items: []const Item,
};

pub fn item(id: []const u8, label: []const u8, accelerator: ?[]const u8) Item {
    return .{ .action = .{ .id = id, .label = label, .accelerator = accelerator } };
}

pub fn checkbox(id: []const u8, label: []const u8, checked: bool) Item {
    return .{ .checkbox = .{ .id = id, .label = label, .checked = checked } };
}

pub const separator: Item = .separator;

pub fn submenu(label: []const u8, items: []const Item) Item {
    return .{ .submenu = .{ .label = label, .items = items } };
}

/// Numbers from 60001 are the engine's context menu items.
pub const context_menu_base = 60000;

/// The application's menus: the ids' numbers, and a copy of the menu bar
/// (for the page runtime, and to change its items).
pub const Menus = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
    /// Number - 1 → id.
    names: std.ArrayList([]const u8) = .empty,
    numbers: std.StringHashMapUnmanaged(u16) = .empty,
    /// The menu bar's copy; null without one.
    bar: ?[]Item = null,

    pub fn deinit(menus: *Menus) void {
        menus.arena.deinit();
    }

    /// The number of `id` (the same for the same id, from 1).
    pub fn number(menus: *Menus, id: []const u8) error{ OutOfMemory, TooManyItems }!u16 {
        if (menus.numbers.get(id)) |n| return n;
        if (menus.names.items.len >= context_menu_base - 1) return error.TooManyItems;
        const a = menus.arena.allocator();
        const owned = try a.dupe(u8, id);
        try menus.names.append(a, owned);
        const n: u16 = @intCast(menus.names.items.len);
        try menus.numbers.put(a, owned, n);
        return n;
    }

    pub fn name(menus: *const Menus, n: u32) ?[]const u8 {
        if (n == 0 or n > menus.names.items.len) return null;
        return menus.names.items[n - 1];
    }

    /// Numbers every id of `items` (menus the page draws are chosen by id).
    pub fn numberAll(menus: *Menus, items: []const Item) error{ OutOfMemory, TooManyItems }!void {
        for (items) |entry| switch (entry) {
            .action => |action| _ = try menus.number(action.id),
            .checkbox => |box| _ = try menus.number(box.id),
            .separator => {},
            .submenu => |sub| try menus.numberAll(sub.items),
        };
    }

    /// Keeps a copy of `items` as the menu bar.
    pub fn setBar(menus: *Menus, items: ?[]const Item) error{OutOfMemory}!void {
        menus.bar = if (items) |list| try copy(menus.arena.allocator(), list) else null;
    }

    /// Changes the copy's item `id`; whether there was one.
    pub fn update(menus: *Menus, id: []const u8, checked: ?bool, enabled: ?bool) bool {
        return if (menus.bar) |bar| updateIn(bar, id, checked, enabled) else false;
    }

    /// A native menu of `items`, numbering their ids (zg_menu_destroy it).
    pub fn native(menus: *Menus, items: []const Item) error{ OutOfMemory, TooManyItems, EngineFailed }!*zg.zg_menu {
        var scratch: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
        defer scratch.deinit();
        return menus.build(scratch.allocator(), items);
    }

    fn build(menus: *Menus, a: std.mem.Allocator, items: []const Item) error{ OutOfMemory, TooManyItems, EngineFailed }!*zg.zg_menu {
        const result = zg.zg_menu_create() orelse return error.OutOfMemory;
        errdefer zg.zg_menu_destroy(result);
        for (items) |entry| {
            const status = switch (entry) {
                .action => |action| zg.zg_menu_add_item(result, try menus.number(action.id), try z(a, action.label), try optionalZ(a, action.accelerator), flags(false, false, action.enabled)),
                .checkbox => |box| zg.zg_menu_add_item(result, try menus.number(box.id), try z(a, box.label), try optionalZ(a, box.accelerator), flags(true, box.checked, box.enabled)),
                .separator => zg.zg_menu_add_separator(result),
                .submenu => |sub| blk: {
                    const child = try menus.build(a, sub.items);
                    defer zg.zg_menu_destroy(child);
                    break :blk zg.zg_menu_add_submenu(result, try z(a, sub.label), child);
                },
            };
            if (status != zg.ZG_OK) return error.EngineFailed;
        }
        return result;
    }
};

/// zg_menu_item_flags.
pub fn flags(is_checkbox: bool, checked: bool, enabled: bool) c_uint {
    var result: c_uint = 0;
    if (is_checkbox) result |= @intCast(zg.ZG_MENU_ITEM_CHECKBOX);
    if (checked) result |= @intCast(zg.ZG_MENU_ITEM_CHECKED);
    if (!enabled) result |= @intCast(zg.ZG_MENU_ITEM_DISABLED);
    return result;
}

fn optionalZ(a: std.mem.Allocator, text: ?[]const u8) error{OutOfMemory}![*c]const u8 {
    return if (text) |value| try z(a, value) else null;
}

fn z(a: std.mem.Allocator, text: []const u8) error{OutOfMemory}![*:0]const u8 {
    return (try a.dupeSentinel(u8, text, 0)).ptr;
}

/// A deep copy of `items` in `a`.
pub fn copy(a: std.mem.Allocator, items: []const Item) error{OutOfMemory}![]Item {
    const result = try a.alloc(Item, items.len);
    for (items, result) |entry, *out| out.* = switch (entry) {
        .action => |action| .{ .action = .{
            .id = try a.dupe(u8, action.id),
            .label = try a.dupe(u8, action.label),
            .accelerator = if (action.accelerator) |text| try a.dupe(u8, text) else null,
            .enabled = action.enabled,
        } },
        .checkbox => |box| .{ .checkbox = .{
            .id = try a.dupe(u8, box.id),
            .label = try a.dupe(u8, box.label),
            .accelerator = if (box.accelerator) |text| try a.dupe(u8, text) else null,
            .checked = box.checked,
            .enabled = box.enabled,
        } },
        .separator => .separator,
        .submenu => |sub| .{ .submenu = .{ .label = try a.dupe(u8, sub.label), .items = try copy(a, sub.items) } },
    };
    return result;
}

fn updateIn(items: []Item, id: []const u8, checked: ?bool, enabled: ?bool) bool {
    var found = false;
    for (items) |*entry| switch (entry.*) {
        .action => |*action| if (std.mem.eql(u8, action.id, id)) {
            if (enabled) |on| action.enabled = on;
            found = true;
        },
        .checkbox => |*box| if (std.mem.eql(u8, box.id, id)) {
            if (checked) |on| box.checked = on;
            if (enabled) |on| box.enabled = on;
            found = true;
        },
        .separator => {},
        // The copy's slices are its own.
        .submenu => |sub| found = updateIn(@constCast(sub.items), id, checked, enabled) or found,
    };
    return found;
}

test "menu ids and updates" {
    var menus: Menus = .{};
    defer menus.deinit();
    try std.testing.expectEqual(@as(u16, 1), try menus.number("open"));
    try std.testing.expectEqual(@as(u16, 2), try menus.number("save"));
    try std.testing.expectEqual(@as(u16, 1), try menus.number("open"));
    try std.testing.expectEqualStrings("save", menus.name(2).?);
    try std.testing.expect(menus.name(0) == null and menus.name(3) == null);

    try menus.setBar(&.{submenu("&View", &.{ checkbox("dark", "Dark", false), item("zoom", "Zoom", "Ctrl+=") })});
    try std.testing.expect(menus.update("dark", true, null));
    try std.testing.expect(menus.update("zoom", null, false));
    try std.testing.expect(!menus.update("missing", true, null));
    const view = menus.bar.?[0].submenu.items;
    try std.testing.expect(view[0].checkbox.checked and !view[1].action.enabled);
}
