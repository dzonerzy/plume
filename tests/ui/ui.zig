//! plume.testing on a fixture page (web/index.html): input, clicks, keys,
//! scrolling, hover, bindings, events, captures and snapshots, headless.
//! `zig build ui-test` (PLUME_UPDATE_SNAPSHOTS=1 to rewrite the snapshots).

const std = @import("std");
const plume = @import("plume");

const Fixture = struct {
    greetings: u32 = 0,

    pub fn greet(self: *Fixture, allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        self.greetings += 1;
        return std.fmt.allocPrint(allocator, "Hello, {s}.", .{name});
    }
};

fn start(fixture: *Fixture) !*plume.testing.Harness {
    // The fixture brings its own font: one snapshot for every system.
    const h = try plume.testing.Harness.start(.{ .title = "fixture", .assets = @embedFile("fixture"), .io = std.testing.io }, .{ .width = 480, .height = 400, .snapshots = "tests/ui/snapshots", .per_os = false });
    errdefer h.stop();
    try h.app.bind("Fixture", Fixture, fixture);
    try h.open();
    return h;
}

/// An async method that runs until stop() tells it to end.
const Chores = struct {
    pub const async_methods = .{"work"};
    started: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    /// Whether shutdown ran with the work over.
    shut_down_after: bool = false,

    pub fn work(self: *Chores, io: std.Io) error{Canceled}!void {
        self.started.store(true, .release);
        while (!self.cancel.load(.acquire)) std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
        self.started.store(false, .release);
        return error.Canceled;
    }

    pub fn stop(self: *Chores) void {
        self.cancel.store(true, .release);
    }

    pub fn shutdown(self: *Chores) void {
        self.shut_down_after = !self.started.load(.acquire);
    }
};

test "stop ends async work before the app waits for it" {
    var chores: Chores = .{};
    const h = try plume.testing.Harness.start(.{ .title = "fixture", .assets = @embedFile("fixture"), .io = std.testing.io }, .{ .width = 320, .height = 240 });
    try h.app.bind("Chores", Chores, &chores);
    try h.open();
    try h.evaluate(void, "Chores.work().catch(() => {})");
    var steps: usize = 0;
    while (!chores.started.load(.acquire)) : (steps += 1) {
        if (steps > 600) return error.Timeout;
        h.step();
    }
    // Without stop, this waits for work() forever.
    h.stop();
    try std.testing.expect(chores.cancel.load(.acquire));
    try std.testing.expect(chores.shut_down_after);
}

test "typing, clicking and a binding" {
    var fixture: Fixture = .{};
    const h = try start(&fixture);
    defer h.stop();
    const greeted = try h.eventCount("greeted");
    try std.testing.expectEqual(@as(u32, 0), greeted);
    try h.typeText("#name", "Ada");
    try std.testing.expectEqualStrings("Ada", try h.value("#name"));
    try h.click("#greet");
    try h.expectText("#answer", "Hello, Ada.");
    try std.testing.expectEqual(@as(u32, 1), fixture.greetings);
    try std.testing.expectEqual(@as(u32, 1), try h.eventCount("greeted"));
}

test "Enter submits, clicks count, keys reach the page" {
    var fixture: Fixture = .{};
    const h = try start(&fixture);
    defer h.stop();
    try h.typeText("#name", "Bo");
    try h.press("Enter", .{});
    try h.expectText("#answer", "Hello, Bo.");
    try h.click("#count");
    try h.click("#count");
    try h.expectText("#clicks", "2 clicks");
    try h.press("Escape", .{});
    try h.expectText("#keys", "escaped");
}

test "scrolling and hover" {
    var fixture: Fixture = .{};
    const h = try start(&fixture);
    defer h.stop();
    try h.scroll("#list", 0, 120);
    try std.testing.expect(try h.evaluate(f64, "document.getElementById('list').scrollTop") > 0);
    try h.hover("#box");
    try std.testing.expectEqualStrings("rgb(255, 183, 77)", try h.evaluate([]const u8, "getComputedStyle(document.getElementById('box')).backgroundColor"));
}

test "captures and a snapshot" {
    var fixture: Fixture = .{};
    const h = try start(&fixture);
    defer h.stop();
    try h.typeText("#name", "Cy");
    try h.click("#greet");
    try h.expectText("#answer", "Hello, Cy.");
    const shot = try h.capture();
    try std.testing.expectEqual(@as(u32, 480), shot.width);
    try std.testing.expectEqual(@as(u32, 400), shot.height);
    // The page's background, top left.
    try std.testing.expectEqualSlices(u8, &.{ 0xf4, 0xf6, 0xfb, 0xff }, shot.rgba[0..4]);
    const png = try h.capturePng();
    try std.testing.expect(std.mem.startsWith(u8, png, "\x89PNG"));
    try h.snapshot("greeted");
}

test "a missing element times out" {
    var fixture: Fixture = .{};
    const h = try plume.testing.Harness.start(.{ .title = "fixture", .assets = @embedFile("fixture"), .io = std.testing.io }, .{ .width = 480, .height = 400, .timeout_ms = 300 });
    defer h.stop();
    try h.app.bind("Fixture", Fixture, &fixture);
    try h.open();
    try std.testing.expectError(error.Timeout, h.waitFor("#nothing-here"));
    try std.testing.expectError(error.TextMismatch, h.expectText("#answer", "never"));
}
