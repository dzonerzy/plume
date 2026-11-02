# Your first app

```sh
plume init notes --template react    # or vanilla, svelte, vue
cd notes
plume dev
```

`plume init` writes the project and installs the frontend's dependencies.
`plume dev` builds the application with the engine's dev profile, starts
Vite, and runs the app on Vite's dev server:

- edit `frontend/src/`: the page reloads at once;
- edit `src/*.zig`, `build.zig` or `plume.json`: the app is rebuilt while it
  keeps running, then restarted; if the build fails, the errors stay in the
  terminal and the app runs on;
- press F12 for the Web Inspector;
- the page's `console.log` and errors print in the terminal;
- close the window to stop.

## A binding

`src/app.zig` has the `App` type the page calls. Add a method:

```zig
pub fn shout(self: *App, allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    _ = self;
    return std.ascii.allocUpperString(allocator, text);
}
```

Save: `frontend/src/bindings.ts` is regenerated with it, typed, and the page
can call it:

```ts
import { App } from "./bindings";
console.log(App.shout("hello"));   // "HELLO"
```

## The release build

```sh
plume build               # build/bin/notes(.exe), the frontend inside
plume build --compress    # the same, compressed with UPX
plume package             # an installer (Windows) or .deb/.tar.gz (Linux)
```

`plume build` runs the frontend's type check and build, packs `frontend/dist`
into the executable and links the engine (the profile in `plume.json`,
`minimal` by default). On Windows the result is a GUI application with the
project's icon and version information.

Set `PLUME_SMOKE=1` to make an application quit once its page has loaded, with
exit status 1 if the load failed: a check that a build starts, for CI.

Next: [what is in a project](project.md).
