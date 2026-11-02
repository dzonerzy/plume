//! Margin: notes in Markdown files, with notes in their margins. A real
//! application of examples/showcase's mockup: the notes are the .md files of
//! a folder (Documents/Margin, or `margin --notes <folder>`), opened from the
//! file manager too (`margin note.md`; a second launch hands it to the
//! running one); a menu bar, a tray icon with "New note", export to HTML with
//! a notification. `zig build margin`; its UI tests: `zig build margin-test`.

const std = @import("std");
const plume = @import("plume");
const menu = plume.menu;
const notes_module = @import("notes.zig");
const Notes = notes_module.Notes;

const State = struct {
    app: *plume.App,
    notes: *Notes,

    fn menuChosen(state: *State, id: []const u8) void {
        if (std.mem.eql(u8, id, "quit")) return state.app.quit();
        if (std.mem.eql(u8, id, "show")) {
            const w = state.app.window();
            w.show() catch {};
            w.restore() catch {};
            w.focus() catch {};
            return;
        }
        if (std.mem.eql(u8, id, "folder")) {
            state.app.fileDialog(.{ .kind = .open_folder, .title = "The folder of your notes" }, state, folderChosen) catch {};
        }
        // The rest (new, export, focus...) the page does: it has the "menu" event too.
    }

    fn folderChosen(state: *State, paths: []const []const u8) void {
        if (paths.len == 0) return;
        state.notes.setFolder(paths[0]) catch |err| std.log.err("margin: {s}: {s}", .{ paths[0], @errorName(err) });
    }

    /// `margin note.md` while Margin runs: the note opens in the running one.
    fn launched(state: *State, launch: plume.Launch) void {
        state.openFiles(launch.args[@min(1, launch.args.len)..]);
    }

    fn openFiles(state: *State, args: []const []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
        defer arena.deinit();
        for (args) |arg| {
            if (!std.mem.endsWith(u8, arg, ".md")) continue;
            const name = state.notes.importFile(arena.allocator(), arg) catch continue;
            if (state.notes.events) |e| e.emit(.open, name);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var folder: []const u8 = try notes_module.defaultFolder(a);
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--notes") and i + 1 < args.len) folder = args[i + 1];
    }

    const app = try plume.App.init(.{
        .title = "Margin",
        .name = "margin",
        .app_id = "dev.plume.margin",
        .width = 1180,
        .height = 760,
        .assets = @embedFile("frontend"),
        .io = init.io,
        .args = args,
        .color_scheme = .light,
        .single_instance = .{ .id = "dev.plume.margin", .args = args },
    });
    defer app.deinit();

    var notes = Notes.init(init.io, folder);
    notes.events = app.events(Notes.Events);
    notes.app = app;
    try app.bind("Notes", Notes, &notes);
    notes.startWatching();

    var state: State = .{ .app = app, .notes = &notes };
    app.onSecondInstance(&state, State.launched);
    try app.onMenu(&state, State.menuChosen);
    try app.setMenu(&.{
        menu.submenu("&File", &.{
            menu.item("new", "&New note", "Ctrl+N"),
            menu.item("folder", "Open &folder…", "Ctrl+O"),
            menu.separator,
            menu.item("export", "&Export as HTML…", "Ctrl+Shift+E"),
            menu.separator,
            menu.item("quit", "E&xit", null),
        }),
        menu.submenu("&Edit", &.{
            menu.item("edit", "&Edit the note", "Ctrl+E"),
            menu.item("margin", "Add a &margin note", "Ctrl+M"),
        }),
        menu.submenu("&View", &.{menu.checkbox("focus", "&Focus mode", false)}),
    });
    // The tray: where a note starts while Margin is in the background.
    if (app.createTray(.{
        .tooltip = "Margin",
        .icon = .{ .rgba = &tray_icon, .width = 16, .height = 16 },
        .menu = &.{ menu.item("new", "&New note", null), menu.item("show", "&Show Margin", null), menu.separator, menu.item("quit", "E&xit", null) },
    })) |tray| {
        tray.attachWindow(app.window());
    } else |err| std.log.info("margin: no tray: {s}", .{@errorName(err)});

    // Files Margin was opened with, once the page listens.
    const Opener = struct {
        fn ready(margin: *State, data: void) void {
            _ = data;
            margin.openFiles(margin.app.args[1..]);
        }
    };
    try app.on("ready", void, &state, Opener.ready);
    app.run();
}

/// A 16 × 16 icon: a page with a line in its margin.
const tray_icon = blk: {
    var pixels: [16 * 16 * 4]u8 = undefined;
    for (0..16) |y| for (0..16) |x| {
        const page = x >= 3 and x <= 12 and y >= 1 and y <= 14;
        const margin_line = page and x == 10 and y >= 3 and y <= 12;
        const text_line = page and x >= 5 and x <= 8 and (y == 4 or y == 7 or y == 10);
        const color: [4]u8 = if (margin_line) .{ 0x8a, 0x6a, 0x2f, 0xff } else if (text_line) .{ 0x1e, 0x2a, 0x2b, 0xff } else if (page) .{ 0xf8, 0xf9, 0xf6, 0xff } else .{ 0, 0, 0, 0 };
        @memcpy(pixels[(y * 16 + x) * 4 ..][0..4], &color);
    };
    break :blk pixels;
};
