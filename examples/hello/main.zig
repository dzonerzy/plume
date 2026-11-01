//! A window whose page calls Zig: the App type of app.zig, bound with
//! plume.bind (bindings generated at compile time). The page tries every kind
//! of binding and shows what came back; `hello --smoke` quits once it has, with
//! a failure status if anything was wrong (a test of the build).

const std = @import("std");
const plume = @import("plume");
const zg = plume.zerog;
const app = @import("app.zig");

/// The page reports its checks here.
const Smoke = struct {
    runtime: ?*zg.zg_runtime,
    enabled: bool,
    passed: ?bool = null,

    pub fn report(self: *Smoke, passed: bool, summary: []const u8) void {
        std.debug.print("{s}\n", .{summary});
        self.passed = passed;
        if (self.enabled)
            zg.zg_runtime_quit(self.runtime);
    }
};

const page =
    \\<!DOCTYPE html>
    \\<html><head><style>
    \\  :root { color-scheme: light dark; font: 15px system-ui, sans-serif; }
    \\  body { margin: 24px; }
    \\  li.ok::marker { content: "✓  "; color: #2a2; }
    \\  li.fail::marker { content: "✗  "; color: #d33; }
    \\  code { font-size: 13px; }
    \\</style></head><body>
    \\  <h1>Hello from Zig</h1>
    \\  <p>Every kind of binding, called from this page:</p>
    \\  <ul id="checks"></ul>
    \\<script>
    \\  const list = document.getElementById('checks');
    \\  const failed = [];
    \\  function check(what, actual, expected) {
    \\    const ok = JSON.stringify(actual) === JSON.stringify(expected);
    \\    if (!ok) failed.push(what + ' gave ' + JSON.stringify(actual, (k, v) => typeof v === 'bigint' ? v + 'n' : v));
    \\    const item = document.createElement('li');
    \\    item.className = ok ? 'ok' : 'fail';
    \\    item.innerHTML = '<code></code>';
    \\    item.firstChild.textContent = what + ' → ' + JSON.stringify(actual, (k, v) => typeof v === 'bigint' ? v + 'n' : v) + (ok ? '' : '  (expected ' + JSON.stringify(expected) + ')');
    \\    list.append(item);
    \\  }
    \\  function code(f) { try { f(); return 'no error'; } catch (e) { return e.message; } }
    \\  (async () => {
    \\    check('App.greet("Plume")', App.greet('Plume'), 'Hello, Plume, from Zig');
    \\    check('App.add(2, 40)', App.add(2, 40), 42);
    \\    check('App.describe({ name: "Ada", age: 36, mood: "happy", tags: ["math"] })',
    \\      App.describe({ name: 'Ada', age: 36, mood: 'happy', tags: ['math'] }),
    \\      { text: 'Ada (36) is happy, 1 tags', letters: 3, shout: true });
    \\    check('App.describe({ name: "Bo", age: 5 }) (defaults)', App.describe({ name: 'Bo', age: 5 }).text, 'Bo (5) is curious, 0 tags');
    \\    check('App.area({ tag: "rectangle", value: { width: 3, height: 4 } })', App.area({ tag: 'rectangle', value: { width: 3, height: 4 } }), 12);
    \\    check('App.area({ tag: "point" })', App.area({ tag: 'point' }), 0);
    \\    check('App.firstWord("zig is fun")', App.firstWord('zig is fun'), 'zig');
    \\    check('App.firstWord(null)', App.firstWord(null), null);
    \\    check('typeof App.double(2n ** 60n)', typeof App.double(2n ** 60n), 'bigint');
    \\    check('App.double(2n ** 60n) === 2n ** 61n', App.double(2n ** 60n) === 2n ** 61n, true);
    \\    check('App.divide(1, 0) throws', code(() => App.divide(1, 0)), 'plume:DivisionByZero');
    \\    check('App.add("2", 3) throws', code(() => App.add('2', 3)).startsWith('plume:InvalidArgument'), true);
    \\    check('App.describe({ age: 1 }) throws', code(() => App.describe({ age: 1 })).startsWith('plume:InvalidArgument'), true);
    \\    check('await App.slowSquare(9)', await App.slowSquare(9), 81);
    \\    check('await App.slowSquare(2000000) rejects', await App.slowSquare(2000000).then(() => 'resolved', e => e.message), 'plume:TooBig');
    \\    check('App.count() (the instance kept its state)', App.count(), 1);
    \\    Smoke.report(failed.length === 0, failed.length === 0 ? 'every binding check passed' : 'failed: ' + failed.join('; '));
    \\  })();
    \\</script></body></html>
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var smoke_mode = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke"))
            smoke_mode = true;
    }

    var runtime_config = std.mem.zeroes(zg.zg_runtime_config);
    runtime_config.size = @sizeOf(zg.zg_runtime_config);
    const runtime = zg.zg_runtime_create(&runtime_config) orelse return error.NoRuntime;
    defer zg.zg_runtime_destroy(runtime);

    var context_config = std.mem.zeroes(zg.zg_context_config);
    context_config.size = @sizeOf(zg.zg_context_config);
    context_config.app_id = "dev.plume.hello";
    context_config.ephemeral = 1;
    const context = zg.zg_context_create(runtime, &context_config) orelse return error.NoContext;

    var window_config = std.mem.zeroes(zg.zg_window_config);
    window_config.size = @sizeOf(zg.zg_window_config);
    window_config.title = "Hello, Plume";
    window_config.width = 760;
    window_config.height = 640;
    const window = zg.zg_window_create(context, &window_config) orelse {
        std.debug.print("zg_window_create: {s}\n", .{zg.zg_last_error()});
        return error.NoWindow;
    };
    defer zg.zg_window_destroy(window);
    const view = zg.zg_window_view(window).?;

    var instance: app.App = .{};
    var smoke: Smoke = .{ .runtime = runtime, .enabled = smoke_mode };
    try plume.bind(view, "App", app.App, &instance);
    try plume.bind(view, "Smoke", Smoke, &smoke);

    _ = zg.zg_view_load_html(view, page, page.len, null);
    _ = zg.zg_runtime_run(runtime);

    if (smoke_mode and smoke.passed != true)
        return error.SmokeFailed;
}
