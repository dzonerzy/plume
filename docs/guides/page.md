# The page from Zig

`plume.Page` reads and changes the page's objects as JavaScript would. A sync
binding gets the calling page by declaring a parameter of that type;
elsewhere on the runtime thread, `app.page()` (the main window's) or
`window.page()` opens one.

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

- `page.byId`, `query`, `queryAll`, `document`, `window`: references
  (`plume.Ref`).
- `ref.get`, `getString`, `getNumber`, `getBool`, `getAs(T, ...)`, `set`:
  properties, by dotted path.
- `ref.call(path, args)` (its result as a `Ref`) and `ref.invoke(path, args)`
  (none): functions, with Zig values as arguments.
- `ref.as(T)`: the value as a Zig type, as bindings decode them; `ref.items()`
  an array's or a NodeList's elements.
- `page.evaluate(T, script)`: a script's result as a `T`.

References and strings live until the page is closed: after the call for a
binding's page, at `page.close()` for one opened with `app.page()`.

From a worker thread, `app.dispatch` to the runtime thread first:

```zig
fn run(task: *Task) void {
    const page = task.app.page() catch return;
    defer page.close();
    (page.byId("status") catch return).set("textContent", task.text) catch {};
}
```
