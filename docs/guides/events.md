# Events

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

const events = app.events(App.Events);
events.emit(.progress, .{ .done = 3, .total = 10 });   // any thread
try events.on(.cancel, &job, Job.cancel);              // runs on the runtime thread
```

```ts
import { Events } from "./bindings";
const stop = Events.on("progress", (p) => (bar.value = p.done / p.total)); // p: Progress
Events.emit("cancel");
```

`bindings.ts` types `Events.on`, `once`, `off` and `emit` from the
declaration: a `void` event takes no data.

## Delivery

- Zig's `emit` reaches every window's pages; `window.emit(name, value)` one
  window's.
- From the runtime thread an event is delivered at once; from another thread it
  is posted to the runtime thread, and the events of one thread arrive in the
  order they were sent.
- The page's `emit` reaches Zig's handlers and the page's own listeners.
- Data that does not match the handler's type is logged and dropped.

## Without a declaration

`app.emit(name, value)`, `app.on(name, T, context, handler)` and the page's
`Plume.on` / `Plume.emit` take any name and data.

## Work for the runtime thread

The engine (pages, windows, menus) is used from the runtime thread only. From a
worker thread, hand work over:

```zig
try app.dispatch(task, Task.run);   // Task.run(task) on the runtime thread, soon
```

When called on the runtime thread, the function runs at once.

## Events Plume sends

| Name | Data | When |
| --- | --- | --- |
| `window:resized`, `window:moved`, `window:focus`, `window:state`, `window:screen`, `window:files-dropped` | see [Windows](windows.md) | to the window's page |
| `menu` | the item's id | a menu item was chosen |
| `menu:context` | `{ menu, id, data }` | an item of a declarative context menu |
| `tray:activated` | `{ x, y }` | the tray icon was clicked |
| `notification` | `{ tag, action }` | a notification or its button was clicked |
| `shortcut` | its name | a global shortcut was pressed |
| `instance:launched` | `{ args, cwd }` | the application was launched again (single instance) |
