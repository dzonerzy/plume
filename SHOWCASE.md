# Showcase

## What you could build

Four applications that could be built with Plume, each needing something only
a desktop application can do. They are mockups: static pages of
[`examples/showcase`](examples/showcase), with made-up data, but each
screenshot is a real Plume window showing it (`zig build showcase -- margin`).

### Margin: notes in Markdown files

Notes are plain Markdown files in a folder of the user's; Margin opens them
from Explorer (a file association made by the installer), keeps its pencil
notes in the margin beside the lines they are about, and lives in the tray for
a quick note. The menu bar is the system's, defined in Zig.

![Margin](docs/images/showcase-margin.png)

*Plume: `file_associations` and `plume package`, the native menu bar, the
tray, `single_instance` (opening a second note goes to the open window).*

### Spindle: an HTTP client

Requests in collections, the response with the time each phase took, tests
that run after each send. The requests leave from Zig, not from the page, so
no CORS and no browser limits; each request can open in a window of its own,
and a global shortcut brings Spindle forward from anywhere.

![Spindle](docs/images/showcase-spindle.png)

*Plume: async bindings (the request runs on a worker thread and settles a
Promise), `app.openWindow`, `app.registerShortcut`, a dark color scheme.*

### Kiln log: a pottery kiln on a serial port

Drives a kiln's controller over USB serial: the schedule's segments, the
temperature measured against the plan, drawn in the colors of the heat, and
the studio's notes beside it. A notification says when the firing reaches its
peak and when it is cool enough to open.

![Kiln log](docs/images/showcase-kiln.png)

*Plume: Zig reads the serial port on a thread and sends events
(`events.emit`) the page draws, notifications, start at login for unattended
firings, signed updates.*

### Gauge: the machine's load, from the tray

A tray icon whose click opens a small frameless window just above it: the
processor's load per core, memory, disk and network, and what uses them. (In
the screenshot the desktop and taskbar around the window are part of the
mockup.)

![Gauge](docs/images/showcase-gauge.png)

*Plume: `app.createTray` with `tray.attachWindow` (shown by the icon, hidden
on the next click), a frameless transparent window, Zig reading the system's
counters.*

## What `plume init` gives you

Every screenshot below is the React template
(`plume init starter --template react`) built with `plume build`: one
executable, the engine linked in, the frontend inside. The other templates
(vanilla, Svelte, Vue) look the same.

### Windows

The window after a greeting and a count. Zig answered the greeting in the same
process, under a millisecond; the twelve bars are twelve events a Zig worker
thread sent while it counted.

![The starter on Windows, dark](docs/images/windows-dark.png)

The same app, light, with a menu bar defined in Zig (below). On Windows the
menus are the system's own.

![The starter on Windows, light, with its menu bar](docs/images/windows-light.png)

### Linux

The same app on Linux (X11), dark. A window there has no menu bar of its own,
so Plume's page runtime draws the one defined in Zig, submenus and
accelerators included, in the page's light or dark.

![The starter on Linux, with the menu Plume draws](docs/images/linux-menus.png)

### The menu bar

The only change to the template for the screenshots with menus, in
`src/main.zig`:

```zig
const menu = plume.menu;
try window.setMenu(&.{
    menu.submenu("&File", &.{
        menu.item("new", "&New window", "Ctrl+N"),
        menu.item("open", "&Open…", "Ctrl+O"),
        menu.separator,
        menu.item("quit", "E&xit", null),
    }),
    menu.submenu("&View", &.{
        menu.checkbox("top", "Always on &top", false),
        menu.submenu("&Zoom", &.{ menu.item("zoom-in", "Zoom &in", "Ctrl+="), menu.item("zoom-out", "Zoom &out", "Ctrl+-") }),
    }),
});
```

A chosen item reaches `window.onMenu` in Zig and the page's `Plume.menu.on`.
