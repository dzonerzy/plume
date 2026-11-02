# A project

| Path | |
| --- | --- |
| `plume.json` | the application: name, title, `app_id`, version, window, engine profile, packaging, updates ([reference](../reference/plume-json.md)) |
| `src/main.zig` | creates the app, binds `App`, runs |
| `src/app.zig` | `App`: its `pub fn`s are the page's bindings, its `Events` the events |
| `frontend/` | the Vite project; `frontend/src/bindings.ts` is generated at every build |
| `icon.png` | the application's icon (square, 256 pixels or more) |
| `package.json` | npm workspaces and the scripts `npm run dev`, `npm run build` |
| `build.zig`, `build.zig.zon` | `plume.addApp`, with Plume as a Zig dependency |

## main.zig

```zig
const std = @import("std");
const plume = @import("plume");
const App = @import("app.zig").App;

pub fn main(init: std.process.Init) !void {
    // The window of plume.json, showing the frontend (built into the binary,
    // or Vite's dev server under plume dev).
    const app = try plume.App.initProject(@import("plume_project"), init);
    defer app.deinit();

    var state: App = .{ .events = app.events(App.Events) };
    try app.bind("App", App, &state);

    app.run();
}
```

`plume_project` is a module `addApp` generates: `plume.json`, the built
frontend (or the dev server's address under `plume dev`) and the icon.
`initProject` makes the application from it; `plume.App.init` takes the same
settings directly, for programs without a project.

`app.run()` loads the main window's page and runs until the main window is
closed or `app.quit()` is called. Everything on `app` and its windows runs on
that thread, except `emit`, `events().emit`, `dispatch` and `quit`, which any
thread may call.

## build.zig

```zig
const app = plume.addApp(b, .{ .name = "notes", .target = target, .optimize = optimize }) orelse return;
b.installArtifact(app.executable);
```

`addApp` links the engine, embeds the frontend and the icon, generates the
bindings and, on Windows, the executable's resources. It takes `-Dprofile`
(`minimal`, `standard`, `dev`), `-Ddev-url` and `-Dconsole` from the command
line; `plume dev` and `plume build` pass them.

## Engine profiles

| Profile | The web platform |
| --- | --- |
| `minimal` (default) | application UI: no media, WebGL, WebAssembly or service workers |
| `standard` | everything: media, WebGL, WebAssembly, service workers, Web Audio |
| `dev` | standard plus the Web Inspector |

To build with an engine of your own (a ZeroG build being worked on), set
`PLUME_ZEROG_DIR` to a directory of unpacked packages named
`<os>-<profile>` (`windows-minimal`, `linux-dev`...).
