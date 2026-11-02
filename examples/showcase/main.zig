//! Mockups of applications one could build with Plume, each a real Plume
//! window showing a static page of web/ (SHOWCASE.md has their screenshots):
//!
//!   zig build showcase -- margin    Markdown notes
//!   zig build showcase -- spindle   an HTTP client
//!   zig build showcase -- kiln      a kiln controller on a serial port
//!   zig build showcase -- gauge     a tray popover with the machine's load

const std = @import("std");
const plume = @import("plume");
const menu = plume.menu;

const Mockup = struct {
    name: []const u8,
    title: [:0]const u8,
    width: u32,
    height: u32,
    frameless: bool = false,
    color_scheme: @FieldType(plume.Options, "color_scheme") = .system,
    menus: bool = false,
};

const mockups = [_]Mockup{
    .{ .name = "margin", .title = "Margin", .width = 1180, .height = 760, .color_scheme = .light, .menus = true },
    .{ .name = "spindle", .title = "Spindle", .width = 1240, .height = 640, .color_scheme = .dark },
    .{ .name = "kiln", .title = "Kiln log", .width = 1200, .height = 760, .color_scheme = .light },
    .{ .name = "gauge", .title = "Gauge", .width = 760, .height = 560, .frameless = true, .color_scheme = .dark },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const wanted = if (args.len > 1) args[1] else "margin";
    const mockup = for (mockups) |m| {
        if (std.mem.eql(u8, m.name, wanted)) break m;
    } else {
        std.debug.print("showcase: margin, spindle, kiln or gauge\n", .{});
        return error.UnknownMockup;
    };

    const app = try plume.App.init(.{
        .title = mockup.title,
        .name = "showcase",
        .width = mockup.width,
        .height = mockup.height,
        .frameless = mockup.frameless,
        .resizable = !mockup.frameless,
        .color_scheme = mockup.color_scheme,
        .assets = @embedFile("frontend"),
        .url = try std.fmt.allocPrint(init.arena.allocator(), "{s}.html", .{mockup.name}),
        .io = init.io,
        .args = args,
    });
    defer app.deinit();

    if (mockup.menus) {
        try app.setMenu(&.{
            menu.submenu("&File", &.{
                menu.item("new", "&New note", "Ctrl+N"),
                menu.item("open", "&Open folder…", "Ctrl+O"),
                menu.separator,
                menu.item("export", "&Export as PDF…", "Ctrl+Shift+E"),
                menu.separator,
                menu.item("quit", "E&xit", null),
            }),
            menu.submenu("&Edit", &.{
                menu.item("find", "&Find in notes", "Ctrl+Shift+F"),
                menu.item("link", "Insert &link", "Ctrl+K"),
            }),
            menu.submenu("&View", &.{
                menu.checkbox("focus", "&Focus mode", false),
                menu.checkbox("outline", "Show &outline", true),
            }),
        });
    }
    app.run();
}
