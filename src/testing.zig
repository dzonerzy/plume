//! UI tests of a Plume application, without a window or a display: its page
//! rendered into memory by the engine, driven with real input events, on a
//! clock the test controls. `plume test` runs them (a project's
//! src/tests.zig), or `zig build test`.
//!
//!     test "greets" {
//!         const h = try plume.testing.Harness.startProject(@import("plume_project"), .{});
//!         defer h.stop();
//!         var state: App = .{};
//!         try h.app.bind("App", App, &state);
//!         try h.open();
//!         try h.typeText("#name", "Ada");
//!         try h.click("button[type=submit]");
//!         try h.expectText("#answer", "Hello, Ada.");
//!         try h.snapshot("greeted");
//!     }
//!
//! Snapshots are PNG files under tests/snapshots/<os>/ (system fonts differ
//! between systems; `per_os = false` for apps that bundle their fonts). A
//! missing one is written; one that differs fails the test and leaves
//! <name>.actual.png and <name>.diff.png beside it. PLUME_UPDATE_SNAPSHOTS=1
//! rewrites them all.

const std = @import("std");
const builtin = @import("builtin");
const zg = @import("zerog");
const app_module = @import("app.zig");
const codec = @import("codec.zig");
const png = @import("png.zig");
const icon = @import("icon.zig");
const App = app_module.App;
const Window = @import("window.zig").Window;

pub const Options = struct {
    /// The page's size, logical pixels, and its device scale.
    width: u32 = 1024,
    height: u32 = 768,
    scale: f32 = 1,
    /// The page open() loads: a page of the frontend or an absolute URL.
    page: []const u8 = "index.html",
    /// How long waits (waitFor, expectText...) wait, real milliseconds.
    timeout_ms: u32 = 10_000,
    /// Where snapshots are, from the project's directory.
    snapshots: []const u8 = "tests/snapshots",
    /// One set of snapshots per system (windows/, linux/).
    per_os: bool = true,
    /// How much a channel may differ, and how many pixels may differ beyond it.
    tolerance: u8 = 8,
    max_different_pixels: usize = 0,
};

pub const Error = error{
    /// A wait ran out of time: the element, the text or the event never came.
    Timeout,
    /// No element matches the selector.
    NotFound,
    /// expectText's text is not there.
    TextMismatch,
    /// A snapshot differs from the stored one (see the .actual and .diff files).
    SnapshotMismatch,
    EngineFailed,
    OutOfMemory,
} || app_module.Error;

pub const Harness = struct {
    app: *App,
    window: *Window,
    options: Options,
    /// Strings handed to the test live here until stop().
    arena: std.heap.ArenaAllocator,
    /// The page's clock, monotonic milliseconds: 60 frames a second,
    /// advanced by step().
    time_ms: f64,
    events: std.StringHashMapUnmanaged(*Counter) = .empty,
    /// The last frame captured (a page that drew nothing since looks so).
    last_shot: ?Shot = null,

    const allocator = std.heap.smp_allocator;
    const frame_ms = 1000.0 / 60.0;

    const Counter = struct {
        count: u32 = 0,
        fn hit(counter: *Counter, data: void) void {
            _ = data;
            counter.count += 1;
        }
    };

    /// The application, headless, with `app_options` (plume.App.init's; its
    /// size and headless fields come from `options`). Bind the app's types on
    /// `h.app`, then open().
    pub fn start(app_options: app_module.Options, options: Options) Error!*Harness {
        var settings = app_options;
        settings.width = options.width;
        settings.height = options.height;
        settings.headless = .{ .scale = options.scale };
        settings.single_instance = null;
        const app = try App.init(settings);
        errdefer app.deinit();
        const h = try allocator.create(Harness);
        // The page's clock starts at the engine's monotonic now (its
        // timelines do), then moves only as the test steps it.
        h.* = .{ .app = app, .window = app.window(), .options = options, .arena = .init(allocator), .time_ms = zg.zg_runtime_now_ms() };
        return h;
    }

    /// The application of a Plume project (`@import("plume_project")`, as
    /// main.zig's initProject), headless.
    pub fn startProject(comptime project: type, options: Options) Error!*Harness {
        // The project's strings live as long as the process.
        const settings = try App.projectOptions(project, std.heap.page_allocator, null, &.{});
        return start(settings, options);
    }

    pub fn stop(h: *Harness) void {
        h.app.deinit();
        var it = h.events.iterator();
        while (it.next()) |entry| allocator.destroy(entry.value_ptr.*);
        h.events.deinit(allocator);
        h.arena.deinit();
        allocator.destroy(h);
    }

    /// Loads the page (options.page) and waits until it has loaded.
    pub fn open(h: *Harness) Error!void {
        h.window.load(h.options.page) catch return error.EngineFailed;
        zg.zg_view_set_focus(h.window.view, 1);
        try h.waitUntil("document.readyState === 'complete'");
        try h.settle();
    }

    // ---- Time ----

    /// One frame: the engine's pending work, then the page's rendering at the
    /// next frame time.
    pub fn step(h: *Harness) void {
        zg.zg_runtime_update(h.app.runtime);
        h.time_ms += frame_ms;
        _ = zg.zg_view_render(h.window.view, h.time_ms);
    }

    /// A few frames, for what was just done to show (layout, transitions'
    /// first frames, events handled).
    pub fn settle(h: *Harness) Error!void {
        for (0..6) |_| {
            h.step();
            h.pause();
        }
    }

    /// `ms` of the page's time, frame by frame: timers and animations advance.
    pub fn advance(h: *Harness, ms: f64) void {
        const end = h.time_ms + ms;
        while (h.time_ms < end) h.step();
    }

    /// Real time for the engine's other threads (loading, decoding).
    fn pause(h: *Harness) void {
        const io = h.app.programIo();
        std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
    }

    /// Steps until the script is true, or options.timeout_ms passed.
    pub fn waitUntil(h: *Harness, script: []const u8) Error!void {
        const io = h.app.programIo();
        const start_time = std.Io.Clock.awake.now(io);
        while (true) {
            h.step();
            if (h.evaluate(bool, script) catch false) return;
            const elapsed = start_time.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
            if (elapsed > h.options.timeout_ms) {
                std.debug.print("plume.testing: timed out waiting for: {s}\n", .{script});
                return error.Timeout;
            }
            h.pause();
        }
    }

    // ---- The page ----

    /// A script's result as a `T` (as bindings decode JSON); strings in the
    /// harness's arena.
    pub fn evaluate(h: *Harness, comptime T: type, script: []const u8) Error!T {
        var result: ?*zg.zg_value = null;
        if (zg.zg_view_evaluate(h.window.view, script.ptr, script.len, if (T == void) null else &result) != zg.ZG_OK)
            return error.EngineFailed;
        if (T == void) return;
        defer zg.zg_value_release(result);
        var length: usize = 0;
        const json = zg.zg_value_to_json(result, &length) orelse return error.EngineFailed;
        return codec.decode(T, h.arena.allocator(), json[0..length]) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidArgument => error.EngineFailed,
        };
    }

    /// The selector as a JavaScript string literal.
    fn quote(h: *Harness, selector: []const u8) Error![]const u8 {
        return codec.encode(h.arena.allocator(), selector) catch error.OutOfMemory;
    }

    fn js(h: *Harness, comptime format: []const u8, args: anytype) Error![]const u8 {
        return std.fmt.allocPrint(h.arena.allocator(), format, args) catch error.OutOfMemory;
    }

    /// Waits until an element matches `selector`.
    pub fn waitFor(h: *Harness, selector: []const u8) Error!void {
        try h.waitUntil(try h.js("document.querySelector({s}) !== null", .{try h.quote(selector)}));
    }

    /// The element's text (textContent, trimmed).
    pub fn text(h: *Harness, selector: []const u8) Error![]const u8 {
        try h.waitFor(selector);
        return h.evaluate([]const u8, try h.js("document.querySelector({s}).textContent.trim()", .{try h.quote(selector)}));
    }

    /// An input's value.
    pub fn value(h: *Harness, selector: []const u8) Error![]const u8 {
        try h.waitFor(selector);
        return h.evaluate([]const u8, try h.js("String(document.querySelector({s}).value)", .{try h.quote(selector)}));
    }

    /// Waits until the element's text is `expected` (trimmed).
    pub fn expectText(h: *Harness, selector: []const u8, expected: []const u8) Error!void {
        const quoted = try h.quote(selector);
        const wanted = codec.encode(h.arena.allocator(), expected) catch return error.OutOfMemory;
        h.waitUntil(try h.js("(document.querySelector({s})?.textContent ?? '').trim() === {s}", .{ quoted, wanted })) catch |err| {
            if (err != error.Timeout) return err;
            const actual = h.evaluate(?[]const u8, try h.js("document.querySelector({s})?.textContent?.trim() ?? null", .{quoted})) catch null;
            std.debug.print("plume.testing: {s}: expected \"{s}\", found {s}{s}{s}\n", .{ selector, expected, if (actual != null) "\"" else "", actual orelse "no element", if (actual != null) "\"" else "" });
            return error.TextMismatch;
        };
    }

    // ---- Input ----

    const Point = struct { x: f32, y: f32 };

    /// The middle of the element, scrolled into view, logical pixels.
    fn center(h: *Harness, selector: []const u8) Error!Point {
        try h.waitFor(selector);
        const point = try h.evaluate(?Point, try h.js(
            "(() => {{ const e = document.querySelector({s}); if (!e) return null; e.scrollIntoView({{ block: 'center', inline: 'center' }}); const r = e.getBoundingClientRect(); return {{ x: r.left + r.width / 2, y: r.top + r.height / 2 }}; }})()",
            .{try h.quote(selector)},
        ));
        return point orelse error.NotFound;
    }

    /// A left click in the middle of the element, as the mouse would.
    pub fn click(h: *Harness, selector: []const u8) Error!void {
        const at = try h.center(selector);
        try h.clickAt(at.x, at.y);
    }

    /// A left click at (x, y), logical pixels.
    pub fn clickAt(h: *Harness, x: f32, y: f32) Error!void {
        const view = h.window.view;
        zg.zg_view_mouse_event(view, zg.ZG_MOUSE_MOVE, x, y, zg.ZG_MOUSE_NONE, 0, 0);
        zg.zg_view_mouse_event(view, zg.ZG_MOUSE_DOWN, x, y, zg.ZG_MOUSE_LEFT, 1, 0);
        zg.zg_view_mouse_event(view, zg.ZG_MOUSE_UP, x, y, zg.ZG_MOUSE_LEFT, 1, 0);
        try h.settle();
    }

    /// The mouse over the element (hover styles, mouseover).
    pub fn hover(h: *Harness, selector: []const u8) Error!void {
        const at = try h.center(selector);
        zg.zg_view_mouse_event(h.window.view, zg.ZG_MOUSE_MOVE, at.x, at.y, zg.ZG_MOUSE_NONE, 0, 0);
        try h.settle();
    }

    /// The wheel over the element: positive `dy` scrolls down, logical pixels.
    pub fn scroll(h: *Harness, selector: []const u8, dx: f32, dy: f32) Error!void {
        const at = try h.center(selector);
        zg.zg_view_scroll_event(h.window.view, at.x, at.y, dx, dy, 1, 0);
        try h.settle();
    }

    /// Clicks the element (focusing it) and types `characters`, key by key.
    pub fn typeText(h: *Harness, selector: []const u8, characters: []const u8) Error!void {
        try h.click(selector);
        var it = (std.unicode.Utf8View.init(characters) catch return error.EngineFailed).iterator();
        while (it.nextCodepointSlice()) |character| {
            var buffer: [8]u8 = undefined;
            @memcpy(buffer[0..character.len], character);
            buffer[character.len] = 0;
            const z: [*:0]const u8 = @ptrCast(&buffer);
            zg.zg_view_key_event(h.window.view, zg.ZG_KEY_DOWN, z, null, null, 0, 0);
            zg.zg_view_key_event(h.window.view, zg.ZG_KEY_CHAR, null, null, z, 0, 0);
            zg.zg_view_key_event(h.window.view, zg.ZG_KEY_UP, z, null, null, 0, 0);
            h.step();
        }
        try h.settle();
    }

    pub const Modifiers = struct { shift: bool = false, ctrl: bool = false, alt: bool = false, meta: bool = false };

    /// A key by its DOM name ("Enter", "Tab", "Escape", "ArrowDown", "a"),
    /// with modifiers.
    pub fn press(h: *Harness, key: [:0]const u8, modifiers: Modifiers) Error!void {
        var mods: c_uint = 0;
        if (modifiers.shift) mods |= zg.ZG_MOD_SHIFT;
        if (modifiers.ctrl) mods |= zg.ZG_MOD_CTRL;
        if (modifiers.alt) mods |= zg.ZG_MOD_ALT;
        if (modifiers.meta) mods |= zg.ZG_MOD_META;
        const view = h.window.view;
        zg.zg_view_key_event(view, zg.ZG_KEY_DOWN, key.ptr, key.ptr, null, mods, 0);
        // The text keys produce, as WM_CHAR would.
        const produced: ?[*:0]const u8 = if (std.mem.eql(u8, key, "Enter")) "\r" else if (std.mem.eql(u8, key, "Tab")) "\t" else if (key.len == 1 and !modifiers.ctrl and !modifiers.alt and !modifiers.meta) key.ptr else null;
        if (produced) |t| zg.zg_view_key_event(view, zg.ZG_KEY_CHAR, null, null, t, mods, 0);
        zg.zg_view_key_event(view, zg.ZG_KEY_UP, key.ptr, key.ptr, null, mods, 0);
        try h.settle();
    }

    // ---- Events ----

    /// How many times the event `name` reached the app's bus so far (Zig's
    /// emits and the page's Plume.emit), counting from the first call.
    pub fn eventCount(h: *Harness, name: []const u8) Error!u32 {
        if (h.events.get(name)) |counter| return counter.count;
        const counter = try allocator.create(Counter);
        counter.* = .{};
        const owned = try h.arena.allocator().dupe(u8, name);
        try h.events.put(allocator, owned, counter);
        h.app.bus.on(owned, void, counter, Counter.hit) catch return error.OutOfMemory;
        return 0;
    }

    // ---- Pixels ----

    /// The page as it is drawn now: RGBA rows, `width` × `height` physical
    /// pixels, in the harness's arena.
    pub fn capture(h: *Harness) Error!Shot {
        try h.settle();
        const surface = zg.zg_view_surface(h.window.view) orelse return error.EngineFailed;
        var frame = std.mem.zeroes(zg.zg_frame);
        // A new frame if the page drew one; else the page looks as it did
        // at the last one.
        var tries: usize = 0;
        while (zg.zg_surface_acquire(surface, &frame) != zg.ZG_OK) : (tries += 1) {
            if (tries > (if (h.last_shot != null) @as(usize, 8) else 120)) {
                if (h.last_shot) |shot| return shot;
                return error.EngineFailed;
            }
            h.step();
            h.pause();
        }
        defer zg.zg_surface_release(surface, &frame);
        const pixels: [*]const u8 = @ptrCast(frame.pixels orelse return error.EngineFailed);
        const rgba = try png.fromBgra(h.arena.allocator(), pixels, frame.stride, frame.width, frame.height);
        h.last_shot = .{ .rgba = rgba, .width = frame.width, .height = frame.height };
        return h.last_shot.?;
    }

    pub const Shot = struct { rgba: []u8, width: u32, height: u32 };

    /// The page as a PNG file's bytes (exports, thumbnails), in the arena.
    pub fn capturePng(h: *Harness) Error![]u8 {
        const shot = try h.capture();
        return png.encode(h.arena.allocator(), shot.rgba, shot.width, shot.height);
    }

    /// Compares the page with the snapshot `name` (see the top of the file).
    pub fn snapshot(h: *Harness, name: []const u8) Error!void {
        return h.compare(name, try h.capture());
    }

    /// Compares one element (its border box, as drawn now) with the snapshot
    /// `name`: what a test checks, without the rest of the page (clocks,
    /// timings, other people's changes).
    pub fn snapshotElement(h: *Harness, name: []const u8, selector: []const u8) Error!void {
        return h.compare(name, try h.captureElement(selector));
    }

    /// One element of the page as drawn now (see capture).
    pub fn captureElement(h: *Harness, selector: []const u8) Error!Shot {
        const Rect = struct { x: f64, y: f64, w: f64, h: f64 };
        try h.waitFor(selector);
        const rect = (try h.evaluate(?Rect, try h.js(
            "(() => {{ const e = document.querySelector({s}); if (!e) return null; e.scrollIntoView({{ block: 'nearest' }}); const r = e.getBoundingClientRect(); return {{ x: r.left, y: r.top, w: r.width, h: r.height }}; }})()",
            .{try h.quote(selector)},
        ))) orelse return error.NotFound;
        const page = try h.capture();
        const scale: f64 = h.options.scale;
        const x0: u32 = @intFromFloat(std.math.clamp(@floor(rect.x * scale), 0, @as(f64, @floatFromInt(page.width))));
        const y0: u32 = @intFromFloat(std.math.clamp(@floor(rect.y * scale), 0, @as(f64, @floatFromInt(page.height))));
        const x1: u32 = @intFromFloat(std.math.clamp(@ceil((rect.x + rect.w) * scale), 0, @as(f64, @floatFromInt(page.width))));
        const y1: u32 = @intFromFloat(std.math.clamp(@ceil((rect.y + rect.h) * scale), 0, @as(f64, @floatFromInt(page.height))));
        if (x1 <= x0 or y1 <= y0) return error.NotFound;
        const width = x1 - x0;
        const height = y1 - y0;
        const rgba = try h.arena.allocator().alloc(u8, @as(usize, width) * height * 4);
        for (0..height) |row| {
            const from = ((y0 + row) * page.width + x0) * 4;
            @memcpy(rgba[row * width * 4 ..][0 .. width * 4], page.rgba[from..][0 .. width * 4]);
        }
        return .{ .rgba = rgba, .width = width, .height = height };
    }

    fn compare(h: *Harness, name: []const u8, shot: Shot) Error!void {
        const a = h.arena.allocator();
        const io = h.app.programIo();
        const os_name = if (builtin.os.tag == .windows) "windows" else "linux";
        const root = if (std.c.getenv("PLUME_PROJECT_DIR")) |dir| std.mem.span(dir) else ".";
        const directory = if (h.options.per_os)
            try std.fs.path.join(a, &.{ root, h.options.snapshots, os_name })
        else
            try std.fs.path.join(a, &.{ root, h.options.snapshots });
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, directory) catch return error.EngineFailed;
        const path = try std.fmt.allocPrint(a, "{s}{c}{s}.png", .{ directory, std.fs.path.sep, name });
        const encoded = try png.encode(a, shot.rgba, shot.width, shot.height);

        const update = std.c.getenv("PLUME_UPDATE_SNAPSHOTS") != null;
        const stored = if (update) null else cwd.readFileAlloc(io, path, a, .limited(256 << 20)) catch null;
        const expected_png = stored orelse {
            cwd.writeFile(io, .{ .sub_path = path, .data = encoded }) catch return error.EngineFailed;
            std.debug.print("plume.testing: wrote the snapshot {s}\n", .{path});
            return;
        };
        const expected = icon.decode(a, expected_png) catch {
            std.debug.print("plume.testing: {s} is not a PNG this can read\n", .{path});
            return error.SnapshotMismatch;
        };
        const actual_path = try std.fmt.allocPrint(a, "{s}{c}{s}.actual.png", .{ directory, std.fs.path.sep, name });
        const diff_path = try std.fmt.allocPrint(a, "{s}{c}{s}.diff.png", .{ directory, std.fs.path.sep, name });
        if (expected.width != shot.width or expected.height != shot.height) {
            cwd.writeFile(io, .{ .sub_path = actual_path, .data = encoded }) catch {};
            std.debug.print("plume.testing: {s}: {d}x{d}, the snapshot is {d}x{d} (see {s})\n", .{ name, shot.width, shot.height, expected.width, expected.height, actual_path });
            return error.SnapshotMismatch;
        }
        const diff = try png.difference(a, expected.pixels, shot.rgba, h.options.tolerance);
        if (diff.pixels > h.options.max_different_pixels) {
            cwd.writeFile(io, .{ .sub_path = actual_path, .data = encoded }) catch {};
            cwd.writeFile(io, .{ .sub_path = diff_path, .data = try png.encode(a, diff.image, shot.width, shot.height) }) catch {};
            std.debug.print("plume.testing: {s}: {d} pixels differ (see {s} and {s})\n", .{ name, diff.pixels, actual_path, diff_path });
            return error.SnapshotMismatch;
        }
        // A pass clears what a failure left.
        cwd.deleteFile(io, actual_path) catch {};
        cwd.deleteFile(io, diff_path) catch {};
    }
};
