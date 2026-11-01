// Calls every kind of binding of App (app.zig) and shows what came back; the
// result goes to Smoke.report (main.zig), which `hello --smoke` exits with.

const list = document.getElementById("checks");
const failed = [];
const show = (value) => JSON.stringify(value, (k, v) => (typeof v === "bigint" ? v + "n" : v));

function check(what, actual, expected) {
  const ok = show(actual) === show(expected);
  if (!ok) failed.push(what + " gave " + show(actual));
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
  Smoke.report(failed.length === 0, failed.length === 0 ? "every binding check passed" : "failed: " + failed.join("; "));
})();
