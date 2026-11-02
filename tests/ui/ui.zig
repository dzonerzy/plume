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
