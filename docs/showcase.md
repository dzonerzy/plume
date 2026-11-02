# Showcase

## What you could build

Four applications that could be built with Plume, each needing something only
a desktop application can do. They are mockups, static pages of
[`examples/showcase`](https://github.com/dzonerzy/plume/tree/main/examples/showcase)
with made-up data, but each screenshot is a real Plume window showing it:
`zig build showcase -- margin` in a clone of Plume.

### Margin: notes in Markdown files

Notes are Markdown files in a folder of the user's; Margin opens them from the
file manager (a [file association](guides/packaging.md)), keeps pencil notes in
the margin beside the lines they are about, and lives in the
[tray](guides/desktop.md#the-tray) for a quick note.

![Margin](images/showcase-margin.png)

### Spindle: an HTTP client

Requests leave from Zig, on a worker thread ([async
bindings](guides/bindings.md#async-bindings)), so without the browser's CORS
limits; each request can open in a [window](guides/windows.md) of its own, and a
[global shortcut](guides/desktop.md#global-shortcuts) brings Spindle forward.

![Spindle](images/showcase-spindle.png)

### Kiln log: a pottery kiln on a serial port

Zig reads the kiln controller over USB serial on a thread and sends
[events](guides/events.md) the page draws: the temperature against the
schedule, in the colors of the heat.
[Notifications](guides/desktop.md#notifications) say when the firing peaks.

![Kiln log](images/showcase-kiln.png)

### Gauge: the machine's load, from the tray

A tray icon whose click shows a small frameless window above it
(`tray.attachWindow`): load per core, memory, disk, network. In the screenshot
the desktop around the window is part of the mockup.

![Gauge](images/showcase-gauge.png)

## What plume init gives you

The React template (`plume init starter --template react`) built with
`plume build`, on Windows dark, Windows light with a menu bar defined in Zig,
and Linux, where Plume's page runtime draws the menu bar.

![The starter on Windows, dark](images/windows-dark.png)

![The starter on Windows, light, with its menu bar](images/windows-light.png)

![The starter on Linux, with the menu Plume draws](images/linux-menus.png)
