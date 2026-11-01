//! A window showing a page whose button calls a Zig function: the engine
//! linked from its release package. `hello --smoke` quits once the page has
//! called the binding (a test of the build).

const std = @import("std");
const plume = @import("plume");
const zg = plume.zerog;

var runtime: ?*zg.zg_runtime = null;
var smoke = false;

const page =
    \\<!DOCTYPE html>
    \\<html><head><style>
    \\  :root { color-scheme: light dark; font: 16px system-ui, sans-serif; }
    \\  body { display: grid; place-items: center; height: 100vh; margin: 0; }
    \\  button { font: inherit; padding: 8px 16px; }
    \\</style></head><body><div>
    \\  <h1>Hello from Zig</h1>
    \\  <button id="greet">Greet</button>
    \\  <p id="answer"></p>
    \\</div><script>
    \\  const greet = () => { document.getElementById('answer').textContent = App.greet('Plume'); };
    \\  document.getElementById('greet').addEventListener('click', greet);
    \\  greet();
    \\</script></body></html>
;

// JS: App.greet(name) -> "Hello, <name>, from Zig"
fn greet(call: ?*zg.zg_call, user: ?*anyopaque) callconv(.c) ?*zg.zg_value {
    _ = user;
    var length: usize = 0;
    const name = zg.zg_call_arg_string(call, 0, &length);
    var buffer: [256]u8 = undefined;
    const reply = std.mem.printSentinel(&buffer, "Hello, {s}, from Zig", .{if (name) |n| n[0..length] else ""}, 0) catch "Hello from Zig";
    std.debug.print("App.greet called from the page\n", .{});
    if (smoke)
        zg.zg_runtime_quit(runtime);
    return zg.zg_value_string(call, reply.ptr);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke"))
            smoke = true;
    }

    var runtime_config = std.mem.zeroes(zg.zg_runtime_config);
    runtime_config.size = @sizeOf(zg.zg_runtime_config);
    runtime = zg.zg_runtime_create(&runtime_config) orelse return error.NoRuntime;
    defer zg.zg_runtime_destroy(runtime);

    var context_config = std.mem.zeroes(zg.zg_context_config);
    context_config.size = @sizeOf(zg.zg_context_config);
    context_config.app_id = "dev.plume.hello";
    context_config.ephemeral = 1;
    const context = zg.zg_context_create(runtime, &context_config) orelse return error.NoContext;

    var window_config = std.mem.zeroes(zg.zg_window_config);
    window_config.size = @sizeOf(zg.zg_window_config);
    window_config.title = "Hello, Plume";
    window_config.width = 640;
    window_config.height = 400;
    const window = zg.zg_window_create(context, &window_config) orelse {
        std.debug.print("zg_window_create: {s}\n", .{zg.zg_last_error()});
        return error.NoWindow;
    };
    const view = zg.zg_window_view(window);

    _ = zg.zg_view_bind(view, "App.greet", greet, null);
    _ = zg.zg_view_load_html(view, page, page.len, null);
    _ = zg.zg_runtime_run(runtime);
    zg.zg_window_destroy(window);
}
