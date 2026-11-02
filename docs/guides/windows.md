# Windows

The application starts with a main window (`plume.json`'s `window`, or
`plume.App.init`'s options); `app.window()` returns it. Closing the main window
ends the application.

## Control

```zig
const window = app.window();
try window.setSize(.{ .width = 900, .height = 600 });
try window.setMinSize(.{ .width = 480, .height = 320 });
try window.center();
try window.setTitle("Notes — groceries.md");
try window.maximize();       // minimize, restore, toggleMaximize, show, hide, focus
window.setFullscreen(true);
try window.setAlwaysOnTop(true);
const state = window.state(); // .normal, .minimized, .maximized, .fullscreen, .hidden
```

Sizes are logical pixels; positions are desktop coordinates (not available on
Wayland, where compositors place windows). The page does the same with
`Plume.window` ([page runtime](../reference/page-runtime.md)).

## Events

```zig
try window.onWindow(&state, State.windowEvent);
fn windowEvent(state: *State, event: plume.WindowEvent) void {
    switch (event) {
        .resized => |size| ...,
        .moved => |position| ...,
        .focus => |focused| ...,
        .state => |s| ...,
        .screen => ...,                       // another screen, or its scale changed
        .files_dropped => |drop| ...,         // drop.paths, drop.x, drop.y
    }
}

window.onClose(&state, State.mayClose);       // return false to keep it open
```

The page gets the same as `window:*` events: `Plume.window.on("resized", ...)`.

## More windows

```zig
const settings = try app.openWindow(.{
    .title = "Settings",
    .width = 480,
    .height = 360,
    .url = "settings.html",     // a page of the frontend, or an absolute URL
});
```

From the page: `Plume.windows.open({ title: "Settings", url: "settings.html" })`.

A new window has the same bindings as the main one, and its own events and
menus. Closing it destroys it (`window.onClose` may refuse); `app.windows`
lists the open ones. With Vite, a second page is a second entry in
`vite.config.ts`'s `build.rollupOptions.input`.

## Frameless and transparent windows

`"frameless": true` removes the system's frame: the page draws its own and
marks the regions that move the window with the CSS property
`--zg-app-region: drag` (`no-drag` for buttons inside them). With
`"transparent": true`, what the page leaves transparent shows the desktop
behind the window.

## Look

`"color_scheme"` is `"system"` (follows the desktop as it changes), `"light"` or
`"dark"`: what `prefers-color-scheme` tells the pages, and the look of form
controls, the frame and native menus. `app.setColorScheme` changes it at run
time. The window's icon is the project's `icon.png`.
