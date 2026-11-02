# The page runtime

Every page of a Plume application has `window.Plume`, before its own scripts
run. `bindings.ts` exports it typed (`import { Plume } from "./bindings"`), and
`bindings.d.ts` declares it for pages that do not import modules.

## Events

| | |
| --- | --- |
| `Plume.on(name, listener)` | returns a function that stops listening |
| `Plume.once(name, listener)` | |
| `Plume.off(name, listener?)` | without a listener: all of `name`'s |
| `Plume.emit(name, data)` | to Zig's handlers and this page's listeners |

`Events` in `bindings.ts` is the same, typed from the binding type's `Events`.

## Plume.window

The page's window: `minimize()`, `maximize()`, `restore()`,
`toggleMaximize()`, `close()` (Zig's `onClose` may keep it open), `center()`,
`show()`, `hide()`, `focus()`, `setTitle(title)`, `setSize(w, h)`,
`setMinSize(w, h)`, `setMaxSize(w, h)`, `setPosition(x, y)`,
`setResizable(bool)`, `setAlwaysOnTop(bool)`, `setFullscreen(bool)`, `size()`,
`position()`, `state()`, `screen()`, `capture()` (a Promise of the window as
the user sees it, a PNG file's bytes), and `on(name, listener)` for `resized`,
`moved`, `focus`, `state`, `screen`, `files-dropped`.

## Plume.windows

`open({ title, width, height, resizable, frameless, transparent, url, hidden })`:
another window of the application.

## Plume.dialog

| | |
| --- | --- |
| `open(options?)` | existing files: their paths, empty if cancelled |
| `folder(options?)` | folders |
| `save(options?)` | a path, or null |
| `message({ kind, title, message, buttons })` | the chosen button's id |

Options: `title`, `acceptLabel`, `location`, `filters: [{ name, extensions }]`,
`multiple`.

## Plume.menu

| | |
| --- | --- |
| `popup(items, x, y)` | a popup menu at CSS pixels; the chosen id, or null |
| `on(listener)` | items of the menu bar, Zig's popups and the tray's menu, by id |
| `onContext(listener)` | `{ menu, id, data }` of a declarative context menu (`data-plume-menu`) |

Items: `"separator"`, `{ id, label, accelerator?, enabled? }`,
`{ type: "checkbox", id, label, checked? }`, `{ label, items }`.

## Plume.app and Plume.openURL

`args()`, `quit()`, `openURL(url)`, `openPath(path)`, `startsAtLogin()`,
`setStartAtLogin(bool)`. `Plume.openURL` is `Plume.app.openURL`.

## Plume.notifications

`show({ title, body?, tag?, actions? })`, `remove(tag)`,
`on(({ tag, action }) => ...)`.

## Plume.shortcuts

`register(name, accelerator)`, `unregister(name)`, `on((name) => ...)`.

## Plume.tray

`on(({ x, y }) => ...)`: a click on the application's tray icon.

## Plume.updates

`check()` (a release or null), `install(release)`, `restart()`,
`on("progress", ({ received, total }) => ...)`.

## Plume.clipboard, Plume.screens, Plume.platform

`clipboard.readText()`, `clipboard.writeText(text)`; `screens()`;
`platform` is `"windows"` or `"linux"`.

## Errors

Calls that fail throw (or reject with) an `Error` whose message is
`plume:<Name>`, as bindings do: `plume:Unsupported`, `plume:AlreadyExists`,
`plume:NotFound`, `plume:InvalidArgument`...
