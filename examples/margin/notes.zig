//! Margin's notes: Markdown files in a folder of the user's, and beside each
//! its margin notes (<note>.margin.json: the quoted words and the note). The
//! page calls Notes' methods; a thread watches the folder and says when
//! something changed on disk.

const std = @import("std");
const plume = @import("plume");

pub const NoteInfo = struct {
    /// The file's name, without ".md".
    name: []const u8,
    /// Its first heading, else its first line, else the name.
    title: []const u8,
    /// The first words after the title.
    excerpt: []const u8,
    /// Milliseconds since 1970.
    modified: i64,
};

pub const MarginNote = struct {
    /// The words of the note it is about.
    quote: []const u8,
    text: []const u8,
    added: i64,
};

pub const Note = struct {
    name: []const u8,
    text: []const u8,
    margin: []const MarginNote,
};

pub const Notes = struct {
    /// The folder, absolute: folder_buffer[0..folder_len] (a length, not a
    /// slice: Notes is moved around by value).
    folder_len: usize = 0,
    folder_buffer: [std.fs.max_path_bytes]u8 = undefined,
    io: std.Io,
    events: ?plume.Events(Events) = null,
    app: ?*plume.App = null,
    watching: std.atomic.Value(bool) = .init(false),
    watcher: ?std.Thread = null,

    pub const Events = struct {
        /// The folder's files changed (a note saved elsewhere, added, removed).
        changed: void,
        /// Open this note (a second launch with a file, the tray's "New note").
        open: []const u8,
        /// The folder is another one.
        folder: []const u8,
    };

    pub const hidden = .{ "setFolder", "importFile", "startWatching", "stopWatching" };

    pub const Error = error{ NotFound, InvalidName, AccessDenied, OutOfMemory };

    pub fn init(io: std.Io, folder: []const u8) Notes {
        var notes: Notes = .{ .io = io };
        notes.setFolder(folder) catch {};
        return notes;
    }

    /// Makes the folder (if needed) and uses it.
    pub fn setFolder(self: *Notes, folder: []const u8) Error!void {
        std.Io.Dir.cwd().createDirPath(self.io, folder) catch return error.AccessDenied;
        self.folder_len = std.Io.Dir.cwd().realPathFile(self.io, folder, &self.folder_buffer) catch return error.NotFound;
        if (self.events) |e| e.emit(.folder, self.folderPath());
    }

    /// The folder notes are in.
    pub fn folderPath(self: *const Notes) []const u8 {
        return self.folder_buffer[0..self.folder_len];
    }

    fn dir(self: *Notes) Error!std.Io.Dir {
        return std.Io.Dir.cwd().openDir(self.io, self.folderPath(), .{ .iterate = true }) catch error.NotFound;
    }

    /// A note's name must be a plain file name.
    fn check(name: []const u8) Error!void {
        if (name.len == 0 or name.len > 200) return error.InvalidName;
        for (name) |c| {
            if (c == '/' or c == '\\' or c == ':' or c < 32) return error.InvalidName;
        }
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;
    }

    /// The notes, the most recently changed first.
    pub fn list(self: *Notes, a: std.mem.Allocator) Error![]NoteInfo {
        var folder = try self.dir();
        defer folder.close(self.io);
        var notes: std.ArrayList(NoteInfo) = .empty;
        var it = folder.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
            const name = try a.dupe(u8, entry.name[0 .. entry.name.len - 3]);
            const stat = folder.statFile(self.io, entry.name, .{}) catch continue;
            const text = folder.readFileAlloc(self.io, entry.name, a, .limited(4 << 20)) catch "";
            const title, const excerpt = summary(text, name);
            try notes.append(a, .{ .name = name, .title = title, .excerpt = excerpt, .modified = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms)) });
        }
        std.mem.sort(NoteInfo, notes.items, {}, struct {
            fn newer(_: void, x: NoteInfo, y: NoteInfo) bool {
                return x.modified > y.modified;
            }
        }.newer);
        return notes.items;
    }

    fn summary(text: []const u8, name: []const u8) struct { []const u8, []const u8 } {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var title: ?[]const u8 = null;
        var excerpt: []const u8 = "";
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r#");
            if (line.len == 0) continue;
            if (title == null) {
                title = line;
            } else {
                excerpt = line[0..@min(line.len, 90)];
                break;
            }
        }
        return .{ title orelse name, excerpt };
    }

    pub fn read(self: *Notes, a: std.mem.Allocator, name: []const u8) Error!Note {
        try check(name);
        var folder = try self.dir();
        defer folder.close(self.io);
        const file = try std.fmt.allocPrint(a, "{s}.md", .{name});
        const text = folder.readFileAlloc(self.io, file, a, .limited(16 << 20)) catch return error.NotFound;
        return .{ .name = name, .text = text, .margin = try self.margin(a, folder, name) };
    }

    fn margin(self: *Notes, a: std.mem.Allocator, folder: std.Io.Dir, name: []const u8) Error![]const MarginNote {
        const file = try std.fmt.allocPrint(a, "{s}.margin.json", .{name});
        const json = folder.readFileAlloc(self.io, file, a, .limited(4 << 20)) catch return &.{};
        return std.json.parseFromSliceLeaky([]const MarginNote, a, json, .{ .ignore_unknown_fields = true }) catch &.{};
    }

    pub fn save(self: *Notes, a: std.mem.Allocator, name: []const u8, text: []const u8) Error!void {
        try check(name);
        var folder = try self.dir();
        defer folder.close(self.io);
        const file = try std.fmt.allocPrint(a, "{s}.md", .{name});
        folder.writeFile(self.io, .{ .sub_path = file, .data = text }) catch return error.AccessDenied;
    }

    /// A new note titled `title`: its name (the title, made a file name; a
    /// number added if taken).
    pub fn create(self: *Notes, a: std.mem.Allocator, title: []const u8) Error![]const u8 {
        var folder = try self.dir();
        defer folder.close(self.io);
        var base: std.ArrayList(u8) = .empty;
        for (std.mem.trim(u8, title, " ")) |c| {
            if (c == '/' or c == '\\' or c == ':' or c == '*' or c == '?' or c == '"' or c == '<' or c == '>' or c == '|' or c < 32) continue;
            try base.append(a, c);
        }
        if (base.items.len == 0) try base.appendSlice(a, "Untitled");
        var n: usize = 1;
        while (true) : (n += 1) {
            const name = if (n == 1) base.items else try std.fmt.allocPrint(a, "{s} {d}", .{ base.items, n });
            const file = try std.fmt.allocPrint(a, "{s}.md", .{name});
            _ = folder.statFile(self.io, file, .{}) catch {
                const text = try std.fmt.allocPrint(a, "# {s}\n\n", .{std.mem.trim(u8, title, " ")});
                folder.writeFile(self.io, .{ .sub_path = file, .data = text, .flags = .{ .exclusive = true } }) catch return error.AccessDenied;
                return name;
            };
        }
    }

    pub fn remove(self: *Notes, a: std.mem.Allocator, name: []const u8) Error!void {
        try check(name);
        var folder = try self.dir();
        defer folder.close(self.io);
        folder.deleteFile(self.io, try std.fmt.allocPrint(a, "{s}.md", .{name})) catch return error.NotFound;
        folder.deleteFile(self.io, try std.fmt.allocPrint(a, "{s}.margin.json", .{name})) catch {};
    }

    /// A margin note on `quote` (words of the note).
    pub fn addMarginNote(self: *Notes, a: std.mem.Allocator, name: []const u8, quote: []const u8, text: []const u8) Error![]const MarginNote {
        try check(name);
        var folder = try self.dir();
        defer folder.close(self.io);
        const existing = try self.margin(a, folder, name);
        const notes = try a.alloc(MarginNote, existing.len + 1);
        @memcpy(notes[0..existing.len], existing);
        notes[existing.len] = .{ .quote = quote, .text = text, .added = std.Io.Clock.real.now(self.io).toMilliseconds() };
        try self.writeMargin(a, folder, name, notes);
        return notes;
    }

    pub fn removeMarginNote(self: *Notes, a: std.mem.Allocator, name: []const u8, index: u32) Error![]const MarginNote {
        try check(name);
        var folder = try self.dir();
        defer folder.close(self.io);
        const existing = try self.margin(a, folder, name);
        if (index >= existing.len) return error.NotFound;
        const notes = try a.alloc(MarginNote, existing.len - 1);
        @memcpy(notes[0..index], existing[0..index]);
        @memcpy(notes[index..], existing[index + 1 ..]);
        try self.writeMargin(a, folder, name, notes);
        return notes;
    }

    fn writeMargin(self: *Notes, a: std.mem.Allocator, folder: std.Io.Dir, name: []const u8, notes: []const MarginNote) Error!void {
        const file = try std.fmt.allocPrint(a, "{s}.margin.json", .{name});
        if (notes.len == 0) {
            folder.deleteFile(self.io, file) catch {};
            return;
        }
        const json = plume.codec.encode(a, notes) catch return error.OutOfMemory;
        folder.writeFile(self.io, .{ .sub_path = file, .data = json }) catch return error.AccessDenied;
    }

    /// Writes an exported note (HTML the page rendered) to `path`, and says so.
    pub fn exportHtml(self: *Notes, path: []const u8, html: []const u8) Error!void {
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = html }) catch return error.AccessDenied;
        if (self.app) |app| app.notify(.{ .title = "Exported", .body = std.fs.path.basename(path), .tag = "export" }) catch {};
    }

    /// A Markdown file from elsewhere (opened with Margin): copied into the
    /// folder unless it is there; its name.
    pub fn importFile(self: *Notes, a: std.mem.Allocator, path: []const u8) Error![]const u8 {
        const absolute = std.Io.Dir.cwd().realPathFileAlloc(self.io, path, a) catch return error.NotFound;
        const base = std.fs.path.basename(absolute);
        if (!std.mem.endsWith(u8, base, ".md")) return error.InvalidName;
        const name = base[0 .. base.len - 3];
        const here = std.fs.path.dirname(absolute) orelse "";
        if (std.mem.eql(u8, here, self.folderPath())) return name;
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, absolute, a, .limited(16 << 20)) catch return error.NotFound;
        const created = try self.create(a, name);
        try self.save(a, created, text);
        return created;
    }

    // ---- The folder watched ----

    pub fn startWatching(self: *Notes) void {
        if (self.watching.swap(true, .acq_rel)) return;
        self.watcher = std.Thread.spawn(.{}, watch, .{self}) catch null;
    }

    pub fn stopWatching(self: *Notes) void {
        self.watching.store(false, .release);
        if (self.watcher) |thread| thread.join();
        self.watcher = null;
    }

    fn watch(self: *Notes) void {
        var last: u64 = 0;
        while (self.watching.load(.acquire)) {
            const now = self.stamp();
            if (last != 0 and now != last) {
                if (self.events) |e| e.emit(.changed, {});
            }
            last = now;
            std.Io.sleep(self.io, .fromMilliseconds(700), .awake) catch {};
        }
    }

    /// The folder's file names, sizes and times, hashed.
    fn stamp(self: *Notes) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        var folder = self.dir() catch return 0;
        defer folder.close(self.io);
        var it = folder.iterate();
        while (it.next(self.io) catch null) |entry| {
            const stat = folder.statFile(self.io, entry.name, .{}) catch continue;
            hasher.update(entry.name);
            hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
            hasher.update(std.mem.asBytes(&stat.size));
        }
        return hasher.final();
    }

    /// The app's lifecycle (plume.App.bind): the watcher stops before the app.
    pub fn shutdown(self: *Notes) void {
        self.stopWatching();
    }
};

/// Where notes go by default: Documents/Margin.
pub fn defaultFolder(a: std.mem.Allocator) ![]const u8 {
    const home = std.c.getenv(if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME") orelse return error.NoHome;
    return std.fs.path.join(a, &.{ std.mem.span(home), "Documents", "Margin" });
}
