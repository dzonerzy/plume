# Menus

Menus are defined once, in Zig, with string ids:

```zig
const menu = plume.menu;
try app.setMenu(&.{
    menu.submenu("&File", &.{
        menu.item("open", "&Open…", "Ctrl+O"),
        menu.separator,
        menu.item("quit", "E&xit", null),
    }),
    menu.submenu("&View", &.{menu.checkbox("dark", "&Dark mode", false)}),
});
try app.onMenu(&state, State.menuChosen);       // menuChosen(state, "open")
try app.setMenuChecked("dark", true);
try app.setMenuEnabled("open", false);
```

`&` marks an item's access key; the accelerator (`"Ctrl+Shift+N"`, `"F5"`) is
shown and chooses the item ahead of the page. A chosen item reaches
`app.onMenu`'s handlers and the window's page as a `menu` event
(`Plume.menu.on((id) => ...)`).

On Windows the menu bar is the system's, dark with a dark color scheme. On
Linux, where a window has no menu bar of its own, the page runtime draws the
same menu at the top of the page, with its accelerators, light or dark as the
page; `--plume-menu-height` gives the page the room it takes.

Each window has its own menu bar: `window.setMenu`, or `app.setMenu` for the
main window.

## Popup menus

```zig
try app.popupMenu(&.{ menu.item("copy", "Copy", null), menu.item("delete", "Delete", null) }, x, y);
```

```ts
const choice = await Plume.menu.popup([{ id: "copy", label: "Copy" }, "separator", { id: "delete", label: "Delete" }], event.clientX, event.clientY);
```

The page's popup resolves with the chosen id, or null.

## Context menus declared in HTML

A context menu defined in Zig, shown on a right click on any element marked
with its name:

```zig
try app.setContextMenu("note", &.{ menu.item("rename", "&Rename", null), menu.item("delete", "&Delete", null) });
try app.onContextMenu(&state, State.contextChosen);   // a plume.ContextMenuChoice
```

```html
<li data-plume-menu="note" data-plume-menu-data="42">Groceries</li>
```

```ts
Plume.menu.onContext(({ menu, id, data }) => act(id, data));   // "note", "delete", "42"
```

The choice comes with the element's `data-plume-menu-data`. Elsewhere on the
page, a right click shows the engine's own menu in text fields and on selected
text (cut, copy, paste), and in the dev profile Inspect Element.

## The tray's menu

A [tray icon](desktop.md#the-tray) takes the same items; its choices reach
`app.onMenu` and every page's `menu` event.
