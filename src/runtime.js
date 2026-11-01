// Plume's page runtime: window.Plume. The engine runs it in every page that
// gets the bindings, after them and before the page's own scripts. The Zig
// side is events.zig (events) and shell.zig (the window, dialogs, clipboard,
// screens and menus).
(() => {
  "use strict";
  const native = globalThis.__plume;
  if (!native || globalThis.Plume) return;

  // ---- Events ----

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

  // ---- The window ----

  const control = (op, value) => native.window(op, value === undefined ? "null" : JSON.stringify(value));

  const window_ = Object.freeze({
    minimize: () => control("minimize"),
    maximize: () => control("maximize"),
    restore: () => control("restore"),
    toggleMaximize: () => control("toggleMaximize"),
    /** As the user closing it: Zig's onClose handler may keep it open. */
    close: () => control("close"),
    center: () => control("center"),
    show: () => control("show"),
    hide: () => control("hide"),
    focus: () => control("focus"),
    setTitle: (title) => control("setTitle", String(title)),
    setSize: (width, height) => control("setSize", { width, height }),
    setMinSize: (width, height) => control("setMinSize", { width, height }),
    setMaxSize: (width, height) => control("setMaxSize", { width, height }),
    setPosition: (x, y) => control("setPosition", { x, y }),
    setResizable: (resizable) => control("setResizable", !!resizable),
    setAlwaysOnTop: (onTop) => control("setAlwaysOnTop", !!onTop),
    setFullscreen: (fullscreen) => control("setFullscreen", !!fullscreen),
    size: () => control("size"),
    position: () => control("position"),
    state: () => control("state"),
    screen: () => control("screen"),
    /** "resized", "moved", "focus", "state", "screen", "files-dropped". */
    on: (name, listener) => on("window:" + name, listener),
  });

  // ---- Dialogs ----

  function fileDialog(kind, options = {}) {
    return {
      kind,
      title: options.title ?? null,
      accept_label: options.acceptLabel ?? null,
      location: options.location ?? null,
      filters: (options.filters ?? []).map((filter) => ({
        name: String(filter.name),
        pattern: (filter.extensions ?? ["*"]).join(";"),
      })),
      multiple: !!options.multiple,
    };
  }

  const dialog = Object.freeze({
    /** Existing files: their paths, empty if cancelled. */
    open: (options) => native.dialog("file", JSON.stringify(fileDialog("open", options))),
    /** Folders: their paths, empty if cancelled. */
    folder: (options) => native.dialog("file", JSON.stringify(fileDialog("open_folder", options))),
    /** A path to save to, or null if cancelled. */
    save: async (options) => (await native.dialog("file", JSON.stringify(fileDialog("save", options))))[0] ?? null,
    /** The chosen button's id. */
    message: (options) =>
      native.dialog("message", JSON.stringify({
        kind: options.kind ?? "info",
        title: options.title ?? "",
        message: String(options.message ?? ""),
        buttons: (options.buttons ?? []).map((button) => ({
          id: button.id,
          label: String(button.label),
          default: !!button.default,
          cancel: !!button.cancel,
        })),
      })),
  });

  const clipboard = Object.freeze({
    readText: () => native.clipboard("readText"),
    writeText: (text) => native.clipboard("writeText", String(text)),
  });

  // ---- Menus ----

  const platform = native.platform();

  // The page's form of an item to Zig's (menu.Item): { tag, value }.
  function toItem(item) {
    if (item === "separator" || item.type === "separator") return { tag: "separator" };
    if (item.items) return { tag: "submenu", value: { label: String(item.label), items: item.items.map(toItem) } };
    const base = { id: String(item.id), label: String(item.label), accelerator: item.accelerator ?? null, enabled: item.enabled ?? true };
    if (item.type === "checkbox") return { tag: "checkbox", value: { ...base, checked: !!item.checked } };
    return { tag: "action", value: base };
  }

  /** A popup menu at (x, y), CSS pixels: the chosen item's id, or null. */
  function popup(items, x, y) {
    const zigItems = items.map(toItem);
    if (platform === "windows") return native.popup(JSON.stringify(zigItems), x, y);
    return new Promise((resolve) => drawn.popup(zigItems, x, y, resolve));
  }

  const menu = Object.freeze({
    popup,
    /** `listener(id)` for the menu bar's items and Zig's popup menus. */
    on: (listener) => on("menu", listener),
  });

  // Linux: the window has no menu bar of its own; Zig's is drawn here.
  const drawn = (() => {
    if (platform === "windows") return null;
    let host = null;
    let root = null;
    let bar = null;
    let open = null; // { panel, close }
    let accelerators = new Map();

    const style = `
      :host { all: initial; }
      * { box-sizing: border-box; }
      .bar, .panel { font: 13px system-ui, sans-serif; color: var(--fg); }
      .bar { position: fixed; inset: 0 0 auto 0; height: 28px; display: flex; align-items: stretch;
        padding: 0 4px; background: var(--bg); border-bottom: 1px solid var(--line); z-index: 2147483646; }
      .top { padding: 0 10px; border: 0; background: none; color: inherit; font: inherit; border-radius: 4px; margin: 3px 0; }
      .top:hover, .top[aria-expanded="true"] { background: var(--hover); }
      .panel { position: fixed; min-width: 200px; padding: 4px; background: var(--bg); border: 1px solid var(--line);
        border-radius: 6px; box-shadow: 0 6px 24px rgb(0 0 0 / 0.2); z-index: 2147483647; }
      .item { display: grid; grid-template-columns: 18px 1fr auto; gap: 6px; align-items: center; width: 100%;
        padding: 5px 8px; border: 0; background: none; color: inherit; font: inherit; text-align: left; border-radius: 4px; }
      .item:hover:not(:disabled), .item:focus-visible { background: var(--accent); color: var(--on-accent); outline: none; }
      .item:disabled { opacity: 0.45; }
      .key { opacity: 0.65; font-size: 12px; }
      .sep { height: 1px; margin: 4px 6px; background: var(--line); }
      .light { --bg: #f6f6f6; --fg: #1d1d1d; --line: #d4d4d4; --hover: #e4e4e4; --accent: #2f6fd6; --on-accent: #fff; }
      .dark { --bg: #2a2a2a; --fg: #ececec; --line: #3d3d3d; --hover: #3a3a3a; --accent: #3d7be0; --on-accent: #fff; }
    `;

    const scheme = () => (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
    const plain = (label) => label.replace(/&(.)/g, "$1");

    function ensureHost() {
      if (host) return;
      host = document.createElement("plume-menus");
      root = host.attachShadow({ mode: "closed" });
      root.innerHTML = `<style>${style}</style>`;
      document.documentElement.append(host);
      document.addEventListener("pointerdown", (event) => {
        if (open && !event.composedPath().includes(host)) closeOpen();
      }, true);
      addEventListener("keydown", onKey, true);
      addEventListener("blur", closeOpen);
    }

    function closeOpen() {
      if (!open) return;
      const current = open;
      open = null;
      current.close();
    }

    // A panel of `items` at (x, y); `choose(id)` for an item, `done()` when it closes.
    function panel(items, x, y, choose, done) {
      const element = document.createElement("div");
      element.className = "panel " + scheme();
      element.setAttribute("role", "menu");
      let child = null;
      for (const item of items) {
        if (item.tag === "separator") {
          element.append(Object.assign(document.createElement("div"), { className: "sep" }));
          continue;
        }
        const value = item.value;
        const button = document.createElement("button");
        button.className = "item";
        button.setAttribute("role", item.tag === "checkbox" ? "menuitemcheckbox" : "menuitem");
        const mark = item.tag === "checkbox" && value.checked ? "✓" : "";
        const key = item.tag === "submenu" ? "›" : value.accelerator ?? "";
        button.innerHTML = "<span></span><span></span><span class=key></span>";
        button.children[0].textContent = mark;
        button.children[1].textContent = plain(value.label);
        button.children[2].textContent = key;
        if (item.tag !== "submenu" && value.enabled === false) button.disabled = true;
        if (item.tag === "submenu") {
          button.addEventListener("pointerenter", () => {
            child?.remove();
            const box = button.getBoundingClientRect();
            child = panel(value.items, box.right - 2, box.top - 4, choose, () => {});
          });
        } else {
          button.addEventListener("pointerenter", () => {
            child?.remove();
            child = null;
          });
          button.addEventListener("click", () => choose(value.id));
        }
        element.append(button);
      }
      root.append(element);
      // Kept inside the viewport.
      const box = element.getBoundingClientRect();
      element.style.left = Math.max(0, Math.min(x, innerWidth - box.width)) + "px";
      element.style.top = Math.max(0, Math.min(y, innerHeight - box.height)) + "px";
      const remove = element.remove.bind(element);
      element.remove = () => {
        child?.remove();
        remove();
      };
      return element;
    }

    function drawBar(items) {
      ensureHost();
      closeOpen();
      bar?.remove();
      bar = null;
      accelerators = new Map();
      document.documentElement.style.removeProperty("--plume-menu-height");
      document.documentElement.style.removeProperty("padding-top");
      if (!items || items.length === 0) return;
      collect(items);
      bar = document.createElement("div");
      bar.className = "bar " + scheme();
      bar.setAttribute("role", "menubar");
      for (const item of items) {
        if (item.tag !== "submenu") continue;
        const top = document.createElement("button");
        top.className = "top";
        top.textContent = plain(item.value.label);
        top.setAttribute("aria-haspopup", "menu");
        const show = () => {
          closeOpen();
          const box = top.getBoundingClientRect();
          const element = panel(item.value.items, box.left, box.bottom + 2, (id) => {
            closeOpen();
            native.menuChosen(id);
          });
          top.setAttribute("aria-expanded", "true");
          open = { panel: element, top, close: () => { element.remove(); top.setAttribute("aria-expanded", "false"); } };
        };
        top.addEventListener("click", () => (open?.top === top ? closeOpen() : show()));
        top.addEventListener("pointerenter", () => open && open.top !== top && show());
        bar.append(top);
      }
      root.append(bar);
      // Room for it at the top of the page; pages can use the variable.
      document.documentElement.style.setProperty("--plume-menu-height", "28px");
      document.documentElement.style.setProperty("padding-top", "28px");
    }

    function collect(items) {
      for (const item of items) {
        if (item.tag === "submenu") collect(item.value.items);
        else if (item.tag !== "separator" && item.value.accelerator && item.value.enabled !== false)
          accelerators.set(normalize(item.value.accelerator), item.value.id);
      }
    }

    // "ctrl+shift+n": modifiers in a fixed order, then the key.
    function normalize(accelerator) {
      const parts = accelerator.toLowerCase().split("+").map((part) => part.trim());
      const key = parts.pop();
      const order = ["ctrl", "alt", "shift", "meta"];
      const mods = order.filter((mod) => parts.includes(mod) || (mod === "meta" && parts.includes("super")));
      return [...mods, key].join("+");
    }

    function eventAccelerator(event) {
      const mods = [];
      if (event.ctrlKey) mods.push("ctrl");
      if (event.altKey) mods.push("alt");
      if (event.shiftKey) mods.push("shift");
      if (event.metaKey) mods.push("meta");
      let key = event.key.length === 1 ? event.key.toLowerCase() : event.key.toLowerCase().replace(/^arrow/, "");
      if (event.shiftKey && /^[!@#$%^&*()_+{}|:"<>?~]$/.test(event.key)) key = event.code.replace(/^(Key|Digit)/, "").toLowerCase();
      return [...mods, key].join("+");
    }

    function onKey(event) {
      if (event.key === "Escape" && open) {
        closeOpen();
        event.preventDefault();
        return;
      }
      const id = accelerators.get(eventAccelerator(event));
      if (id !== undefined) {
        event.preventDefault();
        event.stopPropagation();
        native.menuChosen(id);
      }
    }

    function popupAt(items, x, y, resolve) {
      ensureHost();
      closeOpen();
      let settled = false;
      const element = panel(items, x, y, (id) => {
        settled = true;
        closeOpen();
        resolve(id);
      });
      open = { panel: element, close: () => { element.remove(); if (!settled) resolve(null); } };
    }

    return { drawBar, popup: popupAt };
  })();

  if (drawn) {
    const start = () => drawn.drawBar(native.menu());
    if (document.documentElement) start();
    else addEventListener("DOMContentLoaded", start);
    on("plume:menu", (items) => drawn.drawBar(items));
    // Zig's popup menus: the chosen item goes back to Zig.
    on("plume:popup", ({ items, x, y }) => drawn.popup(items, x, y, (id) => id !== null && native.menuChosen(id)));
  }

  Object.defineProperty(globalThis, "Plume", {
    value: Object.freeze({
      on,
      once,
      off,
      emit,
      platform,
      window: window_,
      dialog,
      clipboard,
      screens: () => native.screens(),
      menu,
    }),
    enumerable: false,
  });
})();
