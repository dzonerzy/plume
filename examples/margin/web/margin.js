// Margin's page: the notes list, the note as paper (or its Markdown in the
// editor), and its margin notes beside the words they are about. The files
// are Zig's (notes.zig, the Notes binding).
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const list = $("notes"), paper = $("paper"), editor = $("editor"), margin = $("margin");
  let notes = [];
  let current = null; // { name, text, margin }
  let editing = false;
  let saveTimer = 0;

  // ---- The list ----

  function showList() {
    const query = $("search").value.trim().toLowerCase();
    const shown = query ? notes.filter((n) => (n.title + " " + n.excerpt + " " + n.name).toLowerCase().includes(query)) : notes;
    list.replaceChildren(...shown.map((note) => {
      const item = document.createElement("li");
      item.tabIndex = 0;
      item.dataset.name = note.name;
      if (current && current.name === note.name) item.setAttribute("aria-current", "true");
      item.append(Object.assign(document.createElement("b"), { textContent: note.title }));
      item.append(Object.assign(document.createElement("span"), { textContent: note.excerpt || " " }));
      item.addEventListener("click", () => open(note.name));
      item.addEventListener("keydown", (e) => e.key === "Enter" && open(note.name));
      return item;
    }));
    $("count").textContent = notes.length === 1 ? "1 note" : notes.length + " notes";
  }

  function reloadList() {
    notes = Notes.list();
    showList();
  }

  // ---- A note ----

  function open(name) {
    if (editing) finishEditing();
    current = Notes.read(name);
    showNote();
    showList();
  }

  function showNote() {
    const has = current !== null;
    $("edit").disabled = !has;
    $("export").disabled = !has;
    if (!has) {
      paper.innerHTML = notes.length
        ? '<p class="empty">Choose a note, or make one: New note (Ctrl+N).</p>'
        : '<p class="empty">No notes here yet. Make one: New note (Ctrl+N).</p>';
      margin.replaceChildren();
      $("path").textContent = "";
      $("words").textContent = "";
      return;
    }
    const title = (notes.find((n) => n.name === current.name) || { title: current.name }).title;
    $("path").innerHTML = "";
    $("path").append(document.createTextNode("Notes / "), Object.assign(document.createElement("b"), { textContent: title }));
    const words = current.text.trim() ? current.text.trim().split(/\s+/).length : 0;
    $("words").textContent = words === 1 ? "1 word" : words + " words";
    paper.innerHTML = Markdown.render(current.text);
    anchorMarginNotes();
  }

  // The margin notes beside the first place their quoted words appear.
  function anchorMarginNotes() {
    margin.replaceChildren();
    current.margin.forEach((note, index) => {
      const anchor = wrapFirst(paper, note.quote, index);
      const element = document.createElement("p");
      element.className = "note";
      element.textContent = note.text;
      const meta = document.createElement("small");
      meta.append(document.createTextNode(new Date(note.added).toLocaleDateString(undefined, { month: "short", day: "numeric" })));
      const remove = Object.assign(document.createElement("button"), { textContent: "Remove", type: "button" });
      remove.setAttribute("aria-label", "Remove the margin note");
      remove.addEventListener("click", () => {
        current.margin = Notes.removeMarginNote(current.name, index);
        showNote();
      });
      meta.append(remove);
      element.append(meta);
      margin.append(element);
      element.style.top = (anchor ? anchor.offsetTop - 2 : 46 + index * 90) + "px";
    });
    // Notes that would overlap go below each other.
    let bottom = 0;
    for (const element of margin.children) {
      const top = Math.max(parseFloat(element.style.top), bottom);
      element.style.top = top + "px";
      bottom = top + element.offsetHeight + 12;
    }
  }

  function wrapFirst(root, quote, index) {
    if (!quote) return null;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const at = node.nodeValue.indexOf(quote);
      if (at < 0) continue;
      const range = document.createRange();
      range.setStart(node, at);
      range.setEnd(node, at + quote.length);
      const span = Object.assign(document.createElement("span"), { className: "anchor" });
      span.dataset.note = index;
      range.surroundContents(span);
      return span;
    }
    return null;
  }

  // ---- Editing ----

  function startEditing() {
    if (!current || editing) return;
    editing = true;
    editor.value = current.text;
    paper.hidden = true;
    editor.hidden = false;
    margin.hidden = true;
    $("edit").textContent = "Done";
    editor.focus();
  }

  function save() {
    clearTimeout(saveTimer);
    if (!current) return;
    current.text = editor.value;
    Notes.save(current.name, current.text);
    $("saved").textContent = "Saved";
  }

  function finishEditing() {
    if (!editing) return;
    save();
    editing = false;
    editor.hidden = true;
    paper.hidden = false;
    margin.hidden = false;
    $("edit").textContent = "Edit";
    reloadList();
    showNote();
  }

  editor.addEventListener("input", () => {
    $("saved").textContent = "Editing";
    clearTimeout(saveTimer);
    saveTimer = setTimeout(save, 800);
  });
  editor.addEventListener("keydown", (e) => {
    if (e.key === "Escape") finishEditing();
    if (e.key === "s" && e.ctrlKey) {
      e.preventDefault();
      save();
    }
  });
  $("edit").addEventListener("click", () => (editing ? finishEditing() : startEditing()));
  paper.addEventListener("dblclick", startEditing);

  // ---- New notes ----

  function newNote() {
    if (editing) finishEditing();
    const name = Notes.create("Untitled");
    reloadList();
    open(name);
    startEditing();
    // The title selected, to type over.
    editor.setSelectionRange(2, 2 + "Untitled".length);
  }
  $("new").addEventListener("click", newNote);

  // ---- Margin notes ----

  const addButton = $("add-margin");
  let selected = null; // { quote, top }

  document.addEventListener("selectionchange", () => {
    const selection = getSelection();
    const text = selection.toString().trim();
    if (editing || !current || !text || selection.rangeCount === 0 || !paper.contains(selection.anchorNode)) {
      addButton.hidden = true;
      return;
    }
    const rect = selection.getRangeAt(0).getBoundingClientRect();
    const desk = document.querySelector(".desk").getBoundingClientRect();
    selected = { quote: text, top: rect.top - paper.getBoundingClientRect().top };
    addButton.style.left = rect.right - desk.left + 8 + "px";
    addButton.style.top = rect.top - desk.top - 4 + "px";
    addButton.hidden = false;
  });

  function compose() {
    if (!selected || !current) return;
    addButton.hidden = true;
    const box = document.createElement("div");
    box.className = "composer";
    box.style.top = selected.top + "px";
    const input = Object.assign(document.createElement("textarea"), { placeholder: "A note in the margin" });
    input.setAttribute("aria-label", "The margin note");
    box.append(input, Object.assign(document.createElement("small"), { textContent: "Enter to keep it, Escape to drop it" }));
    margin.append(box);
    input.focus();
    const quote = selected.quote;
    input.addEventListener("keydown", (e) => {
      if (e.key === "Escape") box.remove();
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        if (input.value.trim()) current.margin = Notes.addMarginNote(current.name, quote, input.value.trim());
        showNote();
      }
    });
  }
  addButton.addEventListener("mousedown", (e) => e.preventDefault()); // keep the selection
  addButton.addEventListener("click", compose);

  // ---- Export ----

  async function exportNote() {
    if (!current) return;
    const title = (notes.find((n) => n.name === current.name) || { title: current.name }).title;
    const path = await Plume.dialog.save({ title: "Export as HTML", location: current.name + ".html", filters: [{ name: "Web pages", extensions: ["html"] }] });
    if (!path) return;
    const footnotes = current.margin.map((n) => `<li><q>${Markdown.escape(n.quote)}</q>: ${Markdown.escape(n.text)}</li>`).join("");
    const html = `<!doctype html><meta charset="utf-8"><title>${Markdown.escape(title)}</title>` +
      `<style>body{max-width:40em;margin:3em auto;font:17px/1.6 Georgia,serif;color:#1e2a2b}aside{color:#8a6a2f;font-style:italic}</style>` +
      Markdown.render(current.text) + (footnotes ? `<aside><h2>In the margin</h2><ul>${footnotes}</ul></aside>` : "");
    Notes.exportHtml(path, html);
  }
  $("export").addEventListener("click", exportNote);

  // ---- Menus, keys, events from Zig ----

  Plume.menu.on((id) => {
    if (id === "new") newNote();
    else if (id === "export") exportNote();
    else if (id === "edit") editing ? finishEditing() : startEditing();
    else if (id === "margin") compose();
    else if (id === "focus") document.body.classList.toggle("focus");
  });
  $("search").addEventListener("input", showList);
  addEventListener("keydown", (e) => {
    // The page draws the menus on Linux: the shortcuts work there too.
    if (e.ctrlKey && e.key === "n" && Plume.platform !== "windows") newNote();
  });

  Plume.on("changed", () => {
    reloadList();
    // The open note changed on disk: shown again, unless it is being edited.
    if (current && !editing) {
      try {
        current = Notes.read(current.name);
      } catch {
        current = null;
      }
      showNote();
    }
  });
  Plume.on("open", (name) => {
    reloadList();
    open(name);
  });
  Plume.on("folder", (path) => {
    $("folder").textContent = path;
    current = null;
    reloadList();
    showNote();
  });

  $("folder").textContent = Notes.folderPath();
  reloadList();
  if (notes.length) open(notes[0].name);
  else showNote();
  Plume.emit("ready");
})();
