# Plume

Desktop applications in Zig with a web frontend, on the
[ZeroG](https://github.com/dzonerzy/ZeroG) engine: one process, one executable,
the engine linked in statically. Windows and Linux.

[![The starter app on Windows](docs/images/windows-dark.png)](SHOWCASE.md)

What a new project looks like on Windows and Linux: [SHOWCASE.md](SHOWCASE.md).

> Early work: the `plume` tool, the templates, the build integration, the
> bindings, events, the page's objects from Zig, and the desktop (window,
> dialogs, menus, clipboard, screens, single instance) are here. Packaging
> (icons, installers) comes next.

## Requirements

- Zig 0.17
- Node.js 20 or later, with npm
- Windows 10 1809 or later (x64; Visual Studio's C++ build tools for the
  system libraries), or Linux x86_64 with glibc 2.28 or later

The engine comes from ZeroG's release packages, fetched by `zig build` for the
target and profile you build (`build.zig.zon`). To build with an engine of your
own (a ZeroG build being worked on), set `PLUME_ZEROG_DIR` to a directory of
unpacked packages named `<os>-<profile>` (`windows-minimal`, `linux-dev`...).

## The plume tool

```sh
zig build cli -Doptimize=small      # zig-out/bin/plume: put that folder on PATH
```

A project's `npm run dev` and `npm run build` call `plume` by name; `plume
doctor` says whether it is on PATH.

```sh
plume init notes --template react   # or vanilla, svelte, vue (alias: plume new)
cd notes
plume dev                           # the app on Vite's dev server: live reload,
                                    # Zig changes rebuild and restart it
plume build                         # build/bin/notes(.exe), the frontend inside
plume build --compress              # the same, compressed with UPX (--compress=best: smaller, minutes)
plume doctor                        # checks Zig, Node.js, npm and git
```

Every template uses Vite, TypeScript and Tailwind CSS. A project looks like
this:

| Path | |
| --- | --- |
| `plume.json` | name, title, `app_id`, window size and flags, engine profile, `compress` |
| `src/main.zig`, `src/app.zig` | the application; `App`'s `pub fn`s are the bindings |
| `frontend/` | the Vite project; `frontend/src/bindings.ts` is generated at every build |
| `package.json` | npm workspaces and scripts: `npm run dev`, `npm run build` call plume |
| `build.zig`, `build.zig.zon` | `plume.addApp`, with Plume as a Zig dependency |

`plume build` runs the frontend's build (and type check), packs `frontend/dist`
into the executable, and links the engine. On Windows the result is a GUI
application without a console. Set `PLUME_SMOKE=1` to make an app quit once its
page has loaded, exiting with status 1 if it failed: useful in CI.

## Try the example

```sh
zig build hello                     # a window whose page calls a Zig function
zig build hello -Dprofile=dev       # with the Web Inspector (F12)
zig build -Doptimize=small          # the release build
```

On Linux you can also cross-compile from Windows:
`zig build -Dtarget=x86_64-linux-gnu.2.28`.

## Bindings

A Zig type's `pub fn`s become JavaScript functions, generated at compile time,
with exact TypeScript types:

```zig
pub const App = struct {
    pub const async_methods = .{"listFiles"}; // on a worker thread, a Promise

    pub fn greet(self: *App, allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "Hello, {s}", .{name});
    }
    pub fn listFiles(self: *App, dir: []const u8) ![]FileEntry { ... }
};

try plume.bind(view, "App", App, &app);
```

```ts
import { App, PlumeError } from "./bindings";
const message: string = App.greet("Plume");            // synchronous
const files: FileEntry[] = await App.listFiles("/tmp"); // a Promise
```

| Zig | TypeScript |
| --- | --- |
| `bool` | `boolean` |
| integers, floats | `number` (`bigint` past 53 bits, passed directly) |
| `[]const u8` | `string` |
| slices, arrays | `T[]` |
| structs | `interface` |
| enums | `"a" \| "b"` |
| `union(enum)` | `{ tag: "a"; value: T } \| ...` |
| `?T` | `T \| null` |
| errors | `PlumeError` with the error's name as `code` |

A parameter of type `std.mem.Allocator` gets the call's arena: results need no
freeing. A parameter of type `plume.Page` gets the calling page (see below).

## Events

Events go both ways, with their names and data declared once, in the binding
type:

```zig
pub const App = struct {
    pub const Events = struct {
        progress: Progress,   // Zig → page
        cancel: void,         // page → Zig
    };
    ...
};

const events = window.events(App.Events);
events.emit(.progress, .{ .done = 3, .total = 10 });   // from any thread
try events.on(.cancel, &job, Job.cancel);              // runs on the runtime thread
```

```ts
import { Events } from "./bindings";
const stop = Events.on("progress", (p) => bar.value = p.done / p.total); // p: Progress
Events.emit("cancel");
```

`Events.emit` reaches Zig's handlers and the page's own listeners. Without an
`Events` declaration, `app.emit(name, value)`, `app.on(name, T, ...)` and the
page's `Plume.on`/`Plume.emit` take any name. Events from worker threads keep
their order. `app.dispatch(context, function)` runs Zig code on the runtime
thread, from a worker thread for instance.

## The page from Zig

`plume.Page` reads and changes the page's objects as JavaScript would. A sync
binding gets the calling page by declaring a parameter of that type, and
`app.page()` opens it elsewhere on the runtime thread:

```zig
pub fn rename(self: *App, page: plume.Page, title: []const u8) !void {
    const heading = try page.byId("title");      // error.NotFound if missing
    try heading.set("textContent", title);
    try heading.set("style.color", "tomato");
    const items = try page.queryAll("li.done");  // []plume.Ref
    const width = try (try page.window()).getNumber("innerWidth");
    const words = try (try page.window()).call("String.prototype.split.call", .{ title, " " });
    const list = try words.as([]const []const u8);
    ...
}
```

References and strings live until the page is closed: after the call for a
binding's page, at `page.close()` for one from `app.page()`.

## The desktop

From Zig, on the runtime thread (from a worker thread, through
`app.dispatch`):

```zig
const window = app.window();
try window.setSize(.{ .width = 900, .height = 600 });
try window.center();
try app.onWindow(&state, State.windowEvent);   // resized, moved, focus, state, screen, files_dropped
app.onClose(&state, State.mayClose);            // return false to keep the window open

try app.setMenu(&.{
    plume.menu.submenu("&File", &.{
        plume.menu.item("open", "&Open…", "Ctrl+O"),
        plume.menu.separator,
        plume.menu.item("quit", "E&xit", null),
    }),
    plume.menu.submenu("&View", &.{plume.menu.checkbox("dark", "&Dark mode", false)}),
});
try app.onMenu(&state, State.menuChosen);       // menuChosen(state, "open")

try app.fileDialog(.{ .kind = .open, .filters = &.{.{ .name = "Images", .pattern = "png;jpg" }} }, &state, State.opened);
try app.clipboard().writeText("copied");
const screens = try app.screens(allocator);
```

From the page, the same through `Plume` (typed in `bindings.ts`):

```ts
import { Plume } from "./bindings";
Plume.window.toggleMaximize();
Plume.window.on("files-dropped", ({ paths }) => open(paths));
const [file] = await Plume.dialog.open({ filters: [{ name: "Images", extensions: ["png", "jpg"] }] });
const answer = await Plume.dialog.message({ kind: "warning", message: "Discard?", buttons: [{ id: 1, label: "Discard" }, { id: 0, label: "Cancel", cancel: true }] });
const choice = await Plume.menu.popup([{ id: "copy", label: "Copy" }, "separator", { id: "delete", label: "Delete" }], event.clientX, event.clientY);
Plume.clipboard.writeText("copied");
```

Menus are the system's on Windows. On Linux, where a window has no menu bar
of its own, the page runtime draws the same menus at the top of the page,
with their accelerators (`--plume-menu-height` gives pages the room it takes).
In text fields and on selected text, the engine's context menu (cut, copy,
paste) shows as a native popup on Windows.

`"single_instance": true` in `plume.json` keeps one instance per user: a second
launch hands its arguments to the first (`app.onSecondInstance`, the page's
`instance:launched` event), which comes to the front. `"color_scheme"` is
`"system"`, `"light"` or `"dark"`. The page's console messages and errors go
to the terminal. `zig build bindings` writes `bindings.ts` (and `bindings.d.ts` for pages
that do not import modules) for `examples/hello`.

## Profiles

| Profile | The web platform |
| --- | --- |
| `minimal` (default) | application UI: no media, WebGL, WebAssembly or service workers |
| `standard` | everything: media, WebGL, WebAssembly, service workers, Web Audio |
| `dev` | standard plus the Web Inspector |

## License

BSD 2-Clause. Applications link the ZeroG engine, whose WebCore and
JavaScriptCore are LGPL: see [LICENSE](LICENSE).

The `plume` executable itself contains [UPX](https://upx.github.io) 5.3.0,
compiled from its sources and called as a library. That makes the executable a
GPLv2+ work. Plume's sources stay BSD, and the applications it builds and
compresses are not affected (UPX's license makes an exception for compressed
programs).
