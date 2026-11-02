//! Margin's UI tests, headless: notes made, written and saved as files,
//! margin notes added on selected words and kept beside the note, changes on
//! disk shown. `zig build margin-test`.

const std = @import("std");
const plume = @import("plume");
const Notes = @import("notes.zig").Notes;

const io = std.testing.io;

/// Margin over the folder `path`, its page open.
fn start(notes: *Notes, path: []const u8) !*plume.testing.Harness {
    const h = try plume.testing.Harness.start(.{ .title = "Margin", .assets = @embedFile("frontend"), .io = io }, .{
        .width = 1180,
        .height = 760,
        .snapshots = "examples/margin/tests/snapshots",
        // Margin brings its fonts: one snapshot for every system.
        .per_os = false,
    });
    errdefer h.stop();
    notes.* = Notes.init(io, path);
    notes.events = h.app.events(Notes.Events);
    try h.app.bind("Notes", Notes, notes);
    notes.startWatching();
    try h.open();
    return h;
}

/// A new empty folder of notes.
fn folder(tmp: *std.testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
}

fn readFile(path: []const u8, name: []const u8) ![]u8 {
    const file = try std.fs.path.join(std.testing.allocator, &.{ path, name });
    defer std.testing.allocator.free(file);
    return std.Io.Dir.cwd().readFileAlloc(io, file, std.testing.allocator, .limited(1 << 20));
}

test "a new note, written and saved as a Markdown file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try folder(&tmp);
    defer std.testing.allocator.free(path);
    var notes: Notes = undefined;
    const h = try start(&notes, path);
    defer h.stop();

    try h.expectText(".paper .empty", "No notes here yet. Make one: New note (Ctrl+N).");
    try h.click("#new");
    // The editor has the title selected: typing replaces it.
    try h.typeKeys("Groceries\n\n- [ ] Bread\n- [x] Coffee");
    try h.press("Escape", .{});
    try h.expectText(".notes li[aria-current=true] b", "Groceries");
    try h.expectText(".paper h1", "Groceries");
    try h.expectText(".paper li.done", "Coffee");

    const saved = try readFile(path, "Untitled.md");
    defer std.testing.allocator.free(saved);
    // The new note's "# Untitled\n\n", its title typed over.
    try std.testing.expectEqualStrings("# Groceries\n\n- [ ] Bread\n- [x] Coffee\n\n", saved);
}

test "a margin note on selected words, kept beside the note" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try folder(&tmp);
    defer std.testing.allocator.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "Lisbon.md", .data = "# Lisbon by tram\n\nGet on at the second stop instead, where locals board.\n\nSit on the left side going west." });

    {
        var notes: Notes = undefined;
        const h = try start(&notes, path);
        defer h.stop();
        try h.expectText(".paper h1", "Lisbon by tram");
        // The words selected as the mouse would.
        _ = try h.evaluate(bool,
            \\(() => {
            \\  const p = document.querySelector(".paper p");
            \\  const text = p.firstChild, at = text.nodeValue.indexOf("second stop instead");
            \\  const range = document.createRange();
            \\  range.setStart(text, at);
            \\  range.setEnd(text, at + "second stop instead".length);
            \\  getSelection().removeAllRanges();
            \\  getSelection().addRange(range);
            \\  return true;
            \\})()
        );
        try h.settle();
        try h.click("#add-margin");
        try h.typeKeys("Miguel says the stop is Sapadores.\n");
        try h.waitUntil("document.querySelector('.margin .note')?.firstChild?.nodeValue === 'Miguel says the stop is Sapadores.'");
        try h.expectText(".paper .anchor", "second stop instead");
    }

    // Kept beside the note: in the sidecar file, and shown again on reopening.
    const sidecar = try readFile(path, "Lisbon.margin.json");
    defer std.testing.allocator.free(sidecar);
    try std.testing.expect(std.mem.indexOf(u8, sidecar, "\"quote\":\"second stop instead\"") != null);
    {
        var notes: Notes = undefined;
        const h = try start(&notes, path);
        defer h.stop();
        try h.expectText(".paper .anchor", "second stop instead");
        try h.waitUntil("document.querySelector('.margin .note')?.firstChild?.nodeValue === 'Miguel says the stop is Sapadores.'");
        // The note beside its words: at the anchor's height.
        try std.testing.expect(try h.evaluate(bool, "Math.abs(document.querySelector('.margin .note').offsetTop - document.querySelector('.paper .anchor').offsetTop) < 8"));
        try h.snapshotElement("lisbon", ".paper");
    }
}

test "a note changed on disk is shown again" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try folder(&tmp);
    defer std.testing.allocator.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "Plans.md", .data = "# Plans\n\nNothing yet." });
    var notes: Notes = undefined;
    const h = try start(&notes, path);
    defer h.stop();
    try h.expectText(".paper p", "Nothing yet.");
    // Another program writes the file, and adds one.
    try tmp.dir.writeFile(io, .{ .sub_path = "Plans.md", .data = "# Plans\n\nA trip to Porto." });
    try tmp.dir.writeFile(io, .{ .sub_path = "Porto.md", .data = "# Porto\n\nThe bookshops." });
    try h.expectText(".paper p", "A trip to Porto.");
    try h.expectText("#count", "2 notes");
}

test "searching the notes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try folder(&tmp);
    defer std.testing.allocator.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "Porto.md", .data = "# Porto\n\nThe bookshops." });
    try tmp.dir.writeFile(io, .{ .sub_path = "Sintra.md", .data = "# Sintra\n\nPena in the fog." });
    var notes: Notes = undefined;
    const h = try start(&notes, path);
    defer h.stop();
    try std.testing.expectEqual(@as(u32, 2), try h.evaluate(u32, "document.querySelectorAll('.notes li').length"));
    try h.typeText("#search", "fog");
    try std.testing.expectEqual(@as(u32, 1), try h.evaluate(u32, "document.querySelectorAll('.notes li').length"));
    try h.expectText(".notes li b", "Sintra");
}
