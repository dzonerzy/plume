# Bindings

`app.bind("App", App, &state)` makes the `pub fn`s of `App` callable from every
window's pages as `App.method(...)`. The dispatcher is generated at compile
time from the Zig types, and so is `bindings.ts`, the page's typed view of
them.

```zig
pub const App = struct {
    pub const async_methods = .{"listFiles"};   // on a worker thread: a Promise

    files_opened: u32 = 0,

    pub fn greet(self: *App, allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "Hello, {s}", .{name});
    }

    pub fn listFiles(self: *App, allocator: std.mem.Allocator, dir: []const u8) ![]FileEntry { ... }
};
```

```ts
import { App, PlumeError } from "./bindings";
const message: string = App.greet("Plume");
const files: FileEntry[] = await App.listFiles("/tmp");
```

## Which functions

A binding is a `pub fn` whose first parameter is the instance (`*T`,
`*const T` or `T`), except:

- `deinit`;
- the lifecycle hooks `startup` and `shutdown` (below);
- the names listed in `pub const hidden = .{ ... }`.

## Types

| Zig | TypeScript |
| --- | --- |
| `bool` | `boolean` |
| integers, floats | `number`; `bigint` for integers past 53 bits passed directly |
| `[]const u8` | `string` |
| slices, arrays | `T[]` |
| structs | `interface` (an inline object type when anonymous) |
| enums | `"a" \| "b"` |
| `union(enum)` | `{ tag: "a"; value: T } \| ...` |
| `?T` | `T \| null` |
| `plume.Bytes` | `Uint8Array` (inside objects: `number[]`) |
| error sets | `PlumeError` with the error's name as `code` |

Arguments of the wrong type throw `plume:InvalidArgument` with what was wrong.
Struct fields with default values may be left out by the page.

## What else a binding can take

Parameters of these types are not passed by the page:

- `std.mem.Allocator`: the call's arena, freed after the call (sync) or once
  the Promise settled (async). Results allocated there need no freeing.
- `std.Io`: the application's (`init.io` from `main`).
- `plume.Page`: the calling page's objects, in sync bindings
  ([The page from Zig](page.md)).

## Errors

A Zig error becomes a JavaScript exception (sync) or a rejected Promise
(async) whose message is `plume:<ErrorName>`; `bindings.ts` turns it into a
`PlumeError`, with `code` typed as the method's error names:

```ts
try {
  App.divide(1, 0);
} catch (error) {
  if (error instanceof PlumeError && error.code === "DivisionByZero") { ... }
}
```

## Async bindings

The methods named in `async_methods` run on a thread of their own and return a
Promise. Their arguments are copied first; the result is sent as JSON, or as a
`Uint8Array` for `plume.Bytes`. They may emit events and hand work to the
runtime thread with `app.dispatch`. The app waits for running ones before it
ends.

## Binary data

`plume.Bytes` is `struct { data: []const u8 }`. As a binding's argument the
page passes any `ArrayBuffer` view, read in place during a sync call; as a
result the page gets a `Uint8Array`.

```zig
pub fn thumbnail(self: *App, allocator: std.mem.Allocator, image: plume.Bytes) !plume.Bytes { ... }
```

## Lifecycle

```zig
pub fn startup(self: *App, app: *plume.App) void { ... }   // when app.run() starts, before the page loads
pub fn shutdown(self: *App) void { ... }                    // in app.deinit(), before the engine goes
```

Either may return an error, which is logged. `startup` may also take only
`self`.

## Bound in every window

The types bound with `app.bind` are bound in every window, including windows
opened later. A bound instance must outlive the app.
