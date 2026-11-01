// Plume's page runtime: window.Plume. The engine runs it in every page that
// gets the bindings, after them and before the page's own scripts. The Zig
// side is events.zig.
(() => {
  "use strict";
  const native = globalThis.__plume;
  if (!native || globalThis.Plume) return;

  const listeners = new Map();

  function deliver(name, data) {
    const set = listeners.get(name);
    if (!set) return;
    for (const listener of [...set]) {
      try {
        listener(data);
      } catch (error) {
        console.error(error);
      }
    }
  }

  /** Calls `listener(data)` for each event `name`; returns what stops it. */
  function on(name, listener) {
    let set = listeners.get(name);
    if (!set) listeners.set(name, (set = new Set()));
    set.add(listener);
    return () => off(name, listener);
  }

  function once(name, listener) {
    const stop = on(name, (data) => {
      stop();
      listener(data);
    });
    return stop;
  }

  /** Without a listener: every listener of `name`. */
  function off(name, listener) {
    const set = listeners.get(name);
    if (!set) return;
    if (listener) set.delete(listener);
    else set.clear();
  }

  /** To Zig's handlers (app.on) and to this page's listeners. */
  function emit(name, data) {
    const json = JSON.stringify(data === undefined ? null : data);
    native.emit(String(name), json);
    deliver(String(name), JSON.parse(json));
  }

  // Events emitted on the runtime thread.
  addEventListener("plume:event", (event) => deliver(event.detail.name, event.detail.data));

  // Events emitted from other threads, and work for the runtime thread.
  (async () => {
    for (;;) {
      let batch;
      try {
        batch = await native.pump();
      } catch {
        return;
      }
      if (!batch) return; // another page took over, or the app is closing
      for (const event of batch.events) deliver(event.name, event.data);
      if (batch.tasks) native.drain();
    }
  })();

  Object.defineProperty(globalThis, "Plume", {
    value: Object.freeze({ on, once, off, emit }),
    enumerable: false,
  });
})();
