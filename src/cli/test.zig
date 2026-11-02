//! plume test [--update-snapshots] [filter]
//!
//! The project's UI tests (src/tests.zig, plume.testing): the frontend built
//! (as plume build does), then `zig build test`. The app runs headless: no
//! window, no display, the same on a laptop and in CI. Snapshots go to
//! tests/snapshots/<os>/; --update-snapshots rewrites them.

const std = @import("std");
const cli = @import("main.zig");
const Project = @import("project.zig").Project;

pub fn run(context: *cli.Context) !void {
    var update = false;
    var filter: ?[]const u8 = null;
    for (context.args) |arg| {
        if (cli.eql(arg, "--update-snapshots")) {
            update = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            cli.fail("unknown option {s}", .{arg});
            return error.Reported;
        } else filter = arg;
    }

    const project = try Project.load(context);
    if (!cli.exists(context, "src/tests.zig")) {
        cli.fail("no src/tests.zig: the project's UI tests go there (plume init writes one)", .{});
        return error.Reported;
    }
    try project.ensureDependencies(context);
    cli.step("generating the bindings (frontend/src/bindings.ts)", .{});
    try cli.run(context, &.{ "zig", "build", "bindings" }, null);
    cli.step("building the frontend (npm run build)", .{});
    try cli.run(context, &.{ "npm", "run", "build" }, project.config.frontend.dir);

    if (update) try context.environ.put("PLUME_UPDATE_SNAPSHOTS", "1");
    cli.step("running the UI tests{s}", .{if (update) " (rewriting the snapshots)" else ""});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(context.arena, &.{ "zig", "build", "test", "--summary", "all" });
    if (filter) |f| try argv.append(context.arena, try std.fmt.allocPrint(context.arena, "-Dtest-filter={s}", .{f}));
    try cli.run(context, argv.items, null);
}
