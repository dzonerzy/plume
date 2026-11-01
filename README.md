# Plume

Desktop applications in Zig with a web frontend, on the
[ZeroG](https://github.com/dzonerzy/ZeroG) engine: one process, one executable,
the engine linked in statically. Windows and Linux.

> Early work. This repository holds the build integration with the engine and a
> first example; the framework (bindings generated at compile time, events,
> windows, dialogs, menus, the `plume` CLI and templates) comes next.

## Requirements

- Zig 0.17
- Windows 10 1809 or later (x64; Visual Studio's C++ build tools for the
  system libraries), or Linux x86_64 with glibc 2.28 or later

The engine comes from ZeroG's release packages, fetched by `zig build` for the
target and profile you build (`build.zig.zon`).

## Try it

```sh
zig build hello                     # a window whose page calls a Zig function
zig build hello -Dprofile=dev       # with the Web Inspector (F12)
zig build -Doptimize=ReleaseSmall   # the release build
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
freeing. `zig build bindings` writes `bindings.ts` (and `bindings.d.ts` for pages
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
