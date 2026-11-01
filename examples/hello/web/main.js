// Calls every kind of binding of App (app.zig) and shows what came back; the
// result goes to Smoke.report (main.zig), which `hello --smoke` exits with.

const list = document.getElementById("checks");
const failed = [];
const show = (value) => JSON.stringify(value, (k, v) => (typeof v === "bigint" ? v + "n" : v));

function check(what, actual, expected) {
  const ok = show(actual) === show(expected);
  if (!ok) failed.push(what + " gave " + show(actual));
  console.log((ok ? "ok   " : "FAIL ") + what);
  const item = document.createElement("li");
  item.className = ok ? "ok" : "fail";
  item.innerHTML = "<code></code>";
  item.firstChild.textContent = what + " → " + show(actual) + (ok ? "" : "  (expected " + show(expected) + ")");
  list.append(item);
}

function thrown(f) {
  try {
    f();
    return "no error";
  } catch (e) {
    return e.message;
  }
}

(async () => {
  check('App.greet("Plume")', App.greet("Plume"), "Hello, Plume, from Zig");
  check("App.add(2, 40)", App.add(2, 40), 42);
  check('App.describe({ name: "Ada", age: 36, mood: "happy", tags: ["math"] })',
    App.describe({ name: "Ada", age: 36, mood: "happy", tags: ["math"] }),
    { text: "Ada (36) is happy, 1 tags", letters: 3, shout: true });
  check('App.describe({ name: "Bo", age: 5 }) (defaults)', App.describe({ name: "Bo", age: 5 }).text, "Bo (5) is curious, 0 tags");
  check('App.area({ tag: "rectangle", value: { width: 3, height: 4 } })', App.area({ tag: "rectangle", value: { width: 3, height: 4 } }), 12);
  check('App.area({ tag: "point" })', App.area({ tag: "point" }), 0);
  check('App.firstWord("zig is fun")', App.firstWord("zig is fun"), "zig");
  check("App.firstWord(null)", App.firstWord(null), null);
  check("typeof App.double(2n ** 60n)", typeof App.double(2n ** 60n), "bigint");
  check("App.double(2n ** 60n) === 2n ** 61n", App.double(2n ** 60n) === 2n ** 61n, true);
  check("App.divide(1, 0) throws", thrown(() => App.divide(1, 0)), "plume:DivisionByZero");
  check('App.add("2", 3) throws', thrown(() => App.add("2", 3)).startsWith("plume:InvalidArgument"), true);
  check("App.describe({ age: 1 }) throws", thrown(() => App.describe({ age: 1 })).startsWith("plume:InvalidArgument"), true);
  check("await App.slowSquare(9)", await App.slowSquare(9), 81);
  check("await App.slowSquare(2000000) rejects", await App.slowSquare(2000000).then(() => "resolved", (e) => e.message), "plume:TooBig");
  check("App.count() (the instance kept its state)", App.count(), 1);

  // Events: the page to Zig and back, on the runtime thread.
  const pong = new Promise((resolve) => Plume.once("pong", resolve));
  const local = new Promise((resolve) => Plume.once("ping", resolve));
  Plume.emit("ping", { text: "hi", times: 3 });
  check('Plume.emit("ping") → Zig → "pong"', await pong, { text: "hihihi" });
  check('Plume.emit("ping") reaches the page\'s listeners too', await local, { text: "hi", times: 3 });

  // Events from a worker thread, through the pump, in order.
  const ticks = [];
  const stopTicks = Plume.on("tick", (n) => ticks.push(n));
  const done = new Promise((resolve) => Plume.once("done", resolve));
  check("await App.countdown(3)", await App.countdown(3), 3);
  check('"done" from the worker (null data)', await done, null);
  stopTicks();
  check('"tick" events from a worker thread', ticks, [3, 2, 1]);

  // Many threads at once: nothing lost, each thread's events in order.
  const received = [];
  const stopBurst = Plume.on("burst", (e) => received.push(e));
  const sent = await App.burst(8, 2000);
  for (let waited = 0; received.length < sent && waited < 5000; waited += 20)
    await new Promise((resolve) => setTimeout(resolve, 20));
  stopBurst();
  const next = new Array(8).fill(0);
  let inOrder = true;
  for (const e of received) inOrder &&= e.index === next[e.thread]++;
  check("App.burst(8, 2000): events received", received.length, 16000);
  check("App.burst: each thread's events in order", inOrder, true);

  // A worker hands work to the runtime thread, which writes into the page.
  const stamped = new Promise((resolve) => Plume.once("stamped", resolve));
  await App.stampLater("from a worker");
  check('"stamped" from the dispatched task', await stamped, "from a worker");
  check("the task's plume.Page wrote #stamp", document.getElementById("stamp").textContent, "from a worker");

  // plume.Page in sync bindings.
  App.setText("stamp", "set by Zig");
  check('App.setText("stamp", ...) (plume.Page)', document.getElementById("stamp").textContent, "set by Zig");
  check("App.pageTitle() reads document.title", App.pageTitle(), document.title);
  check('App.setText("missing", ...) throws NotFound', thrown(() => App.setText("missing", "x")), "plume:NotFound");
  check('App.words("zig is fun")', App.words("zig is fun"), { count: 3, words: ["zig", "is", "fun"] });

  // The desktop: the window, screens, clipboard, dialogs, menus.
  const windows = Plume.platform === "windows";
  check("Plume.platform", ["windows", "linux"].includes(Plume.platform), true);
  check("Plume.window.size() (the window's 760x640)", Plume.window.size(), { width: 760, height: 640 });
  check("Plume.window.state()", Plume.window.state(), "normal");
  const resized = new Promise((resolve) => Plume.window.on("resized", resolve));
  Plume.window.setSize(800, 600);
  check('Plume.window.setSize(800, 600): "resized"', await resized, { width: 800, height: 600 });
  check("Zig's onWindow saw it", Smoke.seen().resizes >= 1, true);
  Plume.window.setTitle("Hello, Plume!");
  check("Plume.window.setTitle (document.title is the page's)", document.title, "Hello, Plume");
  const screens = Plume.screens();
  check("Plume.screens(): one primary at least", screens.length >= 1 && screens.some((s) => s.primary), true);
  check("Plume.window.screen() has a scale", Plume.window.screen().scale > 0, true);
  Plume.window.close();
  check("Plume.window.close() asks Zig's onClose, which kept it open", Smoke.seen().close_requests, 1);
  Plume.clipboard.writeText("from the page ✓");
  check("Plume.clipboard: written and read back", Plume.clipboard.readText(), "from the page ✓");
  check('Plume.window.setSize("x") throws', thrown(() => Plume.window.setSize("x", 1)).startsWith("plume:"), true);

  if (windows) {
    Smoke.pressEnterIn("Plume smoke");
    const button = await Plume.dialog.message({ title: "Plume smoke", message: "Enter chooses the default.", buttons: [{ id: 3, label: "No" }, { id: 7, label: "Yes", default: true }] });
    check("Plume.dialog.message: Enter chose the default button", button, 7);
  }

  // Menus: Zig's menu bar (main.zig), chosen natively or from the drawn one.
  const chosen = new Promise((resolve) => Plume.menu.on(resolve));
  if (windows) Smoke.chooseMenu("open");
  else dispatchEvent(new KeyboardEvent("keydown", { key: "o", code: "KeyO", ctrlKey: true, bubbles: true }));
  check(windows ? 'the menu bar\'s "open" (WM_COMMAND): "menu" event' : 'Ctrl+O, the drawn menu\'s accelerator: "menu" event', await chosen, "open");
  check("Zig's onMenu saw it", Smoke.seen().last_menu, "open");
  if (!windows) {
    check("the drawn menu bar is there", document.querySelector("plume-menus") !== null, true);
    check("--plume-menu-height", document.documentElement.style.getPropertyValue("--plume-menu-height"), "28px");
    const dismissed = Plume.menu.popup([{ id: "a", label: "A" }, "separator", { id: "b", label: "B" }], 20, 20);
    document.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }));
    check("a drawn popup dismissed by a click elsewhere: null", await dismissed, null);
  }
  Smoke.report(failed.length === 0, failed.length === 0 ? "every binding check passed" : "failed: " + failed.join("; "));
})();
