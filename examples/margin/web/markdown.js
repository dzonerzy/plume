// The Markdown Margin's notes use, as HTML: headings, paragraphs, lists and
// task lists, quotes, **bold**, *italic*, `code`, ==marks==, [links](url).
// Text is escaped first: a note's HTML is shown as text.
(() => {
  "use strict";
  const escape = (text) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

  function inline(text) {
    return escape(text)
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>")
      .replace(/==([^=]+)==/g, "<mark>$1</mark>")
      .replace(/\[([^\]]+)\]\((https?:[^)\s]+|mailto:[^)\s]+)\)/g, '<a href="$2">$1</a>');
  }

  function render(markdown) {
    const out = [];
    let list = null; // "ul" or "tasks"
    let paragraph = [];
    const flushParagraph = () => {
      if (paragraph.length) out.push("<p>" + inline(paragraph.join(" ")) + "</p>");
      paragraph = [];
    };
    const closeList = () => {
      if (list) out.push("</ul>");
      list = null;
    };
    for (const raw of markdown.replace(/\r/g, "").split("\n")) {
      const line = raw.trimEnd();
      let m;
      if (!line.trim()) {
        flushParagraph();
        closeList();
      } else if ((m = /^(#{1,3})\s+(.*)$/.exec(line))) {
        flushParagraph();
        closeList();
        out.push(`<h${m[1].length}>${inline(m[2])}</h${m[1].length}>`);
      } else if ((m = /^\s*[-*]\s+\[([ xX])\]\s+(.*)$/.exec(line))) {
        flushParagraph();
        if (list !== "tasks") {
          closeList();
          out.push('<ul class="tasks">');
          list = "tasks";
        }
        out.push(`<li${m[1] === " " ? "" : ' class="done"'}>${inline(m[2])}</li>`);
      } else if ((m = /^\s*[-*]\s+(.*)$/.exec(line))) {
        flushParagraph();
        if (list !== "ul") {
          closeList();
          out.push("<ul>");
          list = "ul";
        }
        out.push(`<li>${inline(m[1])}</li>`);
      } else if ((m = /^>\s?(.*)$/.exec(line))) {
        flushParagraph();
        closeList();
        out.push(`<blockquote>${inline(m[1])}</blockquote>`);
      } else {
        closeList();
        paragraph.push(line.trim());
      }
    }
    flushParagraph();
    closeList();
    return out.join("\n");
  }

  window.Markdown = { render, escape };
})();
