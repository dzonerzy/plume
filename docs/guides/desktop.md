# The desktop

Everything here is on the runtime thread; from a worker thread, go through
`app.dispatch`. The page has the same through `Plume`
([page runtime](../reference/page-runtime.md)).

## Dialogs

```zig
try app.fileDialog(.{ .kind = .open, .multiple = true, .filters = &.{.{ .name = "Images", .pattern = "png;jpg" }} }, &state, State.opened);
fn opened(state: *State, paths: []const []const u8) void { ... }   // empty if cancelled

try app.messageBox(.{ .kind = .warning, .title = "Notes", .message = "Discard the changes?",
    .buttons = &.{ .{ .id = 1, .label = "Discard" }, .{ .id = 0, .label = "Cancel", .cancel = true } } }, &state, State.answered);
```

```ts
const [file] = await Plume.dialog.open({ filters: [{ name: "Images", extensions: ["png", "jpg"] }] });
const where = await Plume.dialog.save({ title: "Export" });
const answer = await Plume.dialog.message({ kind: "warning", message: "Discard?", buttons: [{ id: 1, label: "Discard" }, { id: 0, label: "Cancel", cancel: true }] });
```

They are the system's: Windows' own, the desktop portal on Linux (zenity
without it).

## Clipboard and screens

```zig
try app.clipboard().writeText("copied");
const text = try app.clipboard().readText(allocator);       // ?[]u8
try app.clipboard().writeHtml("<b>bold</b>", "bold");
const screens = try app.screens(allocator);                 // bounds, work area, scale, refresh, primary, name
```

## The tray

```zig
const tray = try app.createTray(.{
    .tooltip = "Notes",
    .menu = &.{ menu.item("show", "&Show", null), menu.separator, menu.item("quit", "E&xit", null) },
});
tray.attachWindow(app.window());           // a click shows it by the icon, the next (or a click elsewhere) hides it
try tray.onActivated(&state, State.clicked);
try tray.setTooltip("Notes: 3 unsaved");
try tray.setMenuChecked("mute", true);
```

The icon is the application's unless `.icon` gives another (RGBA). Its menu's
choices reach `app.onMenu`; clicks reach `onActivated` and the pages'
`tray:activated` event. Windows: the notification area. Linux: a
StatusNotifierItem, which KDE, GNOME with the AppIndicator extension and most
other desktops show.

A tray application often starts hidden (`"window": { "hidden": true }`) and
keeps running when its window is closed: `window.onClose` returns false and
hides the window instead.

The attached window is a popover: a page of its own is the tray's interface,
next to the native menu (right click). Open it hidden and frameless, attach it,
and it shows by the icon on a click, hides on the next one and when another
window takes the focus. On Windows it stays on top, without a taskbar button or
a place in Alt+Tab.

```zig
const popover = try app.openWindow(.{ .url = "tray.html", .width = 340, .height = 420, .frameless = true, .transparent = true, .resizable = false, .hidden = true });
tray.attachWindow(popover);
```

## Notifications

```zig
try app.notify(.{ .title = "Exported", .body = "groceries.pdf", .tag = "export", .actions = &.{"Open", "Show in folder"} });
try app.onNotification(&state, State.notificationClicked);   // .{ .tag, .action }: -1 for the notification itself
try app.removeNotification("export");
```

```ts
Plume.notifications.show({ title: "Exported", body: "groceries.pdf", tag: "export", actions: ["Open"] });
Plume.notifications.on(({ tag, action }) => ...);
```

A notification with the tag of one still shown replaces it. They come from the
application: its `app_id`, title and icon. Windows: toasts. Linux: the
desktop's notification service. `error.Unsupported` where there is none.

## Global shortcuts

```zig
try app.registerShortcut("capture", "Ctrl+Shift+K");
try app.onShortcut(&state, State.shortcut);   // shortcut(state, "capture")
try app.unregisterShortcut("capture");
```

```ts
Plume.shortcuts.register("capture", "Ctrl+Shift+K");
Plume.shortcuts.on((name) => capture());
```

Pressed anywhere, whichever application has the keyboard. A shortcut needs a
modifier. `error.AlreadyExists` if another application holds the keys.
Windows: `RegisterHotKey`. X11: a key grab. Wayland: the GlobalShortcuts
portal, where the desktop asks the user to confirm the keys
(`error.Unsupported` without it). The Wayland path is tested against a
portal of Plume's tests, not a real desktop's: the real one needs a person to
confirm.

## Single instance

`"single_instance": true` keeps one instance per user. A second launch hands
its arguments and working directory to the first and exits; the first comes to
the front:

```zig
app.onSecondInstance(&state, State.launched);   // a plume.Launch: .args, .cwd
```

The pages get `instance:launched`. That is how a file opened from the file
manager reaches a running application ([Packages](packaging.md)).

## Start at login

```zig
try app.setStartAtLogin(true);
const on = app.startsAtLogin();
```

Windows: the user's Run key. Linux: an XDG autostart entry. It starts this
executable, where it is now.

## Links and files

Links to other sites, and `window.open` of one, open in the default browser.
To decide otherwise:

```zig
app.onExternalLink(&state, State.link);   // return true if handled
```

`app.openURL("https://ziglang.org")` opens a URL with the system (`mailto:`
in the mail program), `app.openPath("report.pdf")` a file or folder with its
program; the page has `Plume.openURL` and `Plume.app.openPath`.

## The program's arguments

`app.args` (the program's name first), `Plume.app.args()` in the page.
