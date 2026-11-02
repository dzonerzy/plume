# UI tests

`plume test` runs a project's UI tests with the application headless: its page
rendered into memory by the same engine the app ships with, no window and no
display. They run the same on a laptop and in CI, Windows or Linux, and need
no browser, no WebDriver and no Xvfb.

```zig
// src/tests.zig (plume init writes one)
const std = @import("std");
const plume = @import("plume");
const App = @import("app.zig").App;

test "greeting someone" {
    const h = try plume.testing.Harness.startProject(@import("plume_project"), .{});
    defer h.stop();
    var state: App = .{ .events = h.app.events(App.Events) };
    try h.app.bind("App", App, &state);     // as main.zig does
    try h.open();

    try h.typeText("#name", "Ada");
    try h.click(".ask .action");
    try h.expectText(".answer", "Hello, Ada.");
    try std.testing.expectEqual(@as(u32, 1), state.greetings);   // the Zig side, directly

    h.advance(1500);                          // the page's clock: animations finish
    try h.snapshotElement("answer", ".answer");
}
```

```sh
plume test                       # builds the frontend, runs src/tests.zig
plume test greeting              # only tests whose names contain "greeting"
plume test --update-snapshots    # rewrites the snapshots
```

## Driving the page

Input goes into the engine as a user's would: mouse events at the element's
middle, keys one by one, so the page's handlers, focus, forms and `:hover`
behave as in the app.

| | |
| --- | --- |
| `open()` | loads the page (options.page, `index.html`) and waits for it |
| `click(selector)`, `clickAt(x, y)` | a left click |
| `typeText(selector, text)` | clicks the element, types the text |
| `typeKeys(text)` | types into what has the focus (`\n` is Enter) |
| `press(key, .{ .ctrl = true })` | a key by its DOM name: `"Enter"`, `"Escape"`, `"ArrowDown"`, `"a"` |
| `hover(selector)`, `scroll(selector, dx, dy)` | the mouse over it, the wheel |
| `text(selector)`, `value(selector)` | what an element shows, an input's value |
| `evaluate(T, script)` | a script's result as a Zig type |
| `waitFor(selector)`, `waitUntil(script)` | until it is there or true (options.timeout_ms) |
| `expectText(selector, text)` | waits for the text; says what was there if it never came |
| `eventCount(name)` | how many times an event reached the app's bus |

The test has the app (`h.app`) and its bound instances: assert on Zig state
directly, emit events, call bindings.

## Time

The page's clock is the test's: `step()` advances one frame (1/60 s),
`advance(ms)` many. CSS animations, transitions and `requestAnimationFrame` move
only with it, so what a snapshot shows does not depend on how fast the machine
is. Timers (`setTimeout`) and the engine's loading run in real time.

## Snapshots

`snapshot(name)` compares the whole page, `snapshotElement(name, selector)` one
element, with a PNG under `tests/snapshots/`. A missing one is written (commit
it); one that differs fails the test and leaves `<name>.actual.png` and
`<name>.diff.png`, the differing pixels in red, beside it.

By default there is one set per system (`tests/snapshots/windows/`, `linux/`):
system fonts differ. An application that bundles its fonts can share one set
(`.per_os = false`): the engine renders the same pixels on Windows and Linux
(Plume's own UI tests and Margin's do: their snapshots are bit-identical on
both). `tolerance` (per channel, default 8) and `max_different_pixels`
(default 0) set how strict a comparison is.

Snapshot what the test is about: an element rather than the page when other
parts change on their own (times, counters, data from elsewhere).

## Captures

`capture()` (RGBA pixels) and `capturePng()` give the page as drawn, for
assertions of your own. In a running app, `window.capture(context, done)` and
the page's `Plume.window.capture()` give the window as the user sees it
(native layer included), as a PNG.

## In CI

`plume test` needs nothing besides what `plume build` needs: no display server
on Linux. Plume's own CI runs the template's test on Windows and Linux on every
push.
