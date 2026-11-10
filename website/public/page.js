// Shows the Markdown file named by data-content in <main>. The files live in content/,
// so they can be swapped in the container without building a new image.
//
// Understood: # headings, paragraphs (a single line break stays a line break),
// lists with "- ", **bold**, *italic* and [links](https://...).

const escape = (text) =>
  text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// Only these link targets, so a file can never smuggle in javascript: URLs.
const SAFE_URL = /^(https?:|mailto:|tel:|[./#]|[\w-]+\.html)/i;

function inline(text) {
  return escape(text)
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (all, label, url) => (SAFE_URL.test(url) ? `<a href="${url}">${label}</a>` : label))
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/\*(.+?)\*/g, "<em>$1</em>");
}

function render(markdown) {
  const html = [];
  for (const block of markdown.replace(/\r\n?/g, "\n").split(/\n\s*\n/)) {
    const lines = block.split("\n").map((line) => line.trim()).filter(Boolean);
    if (lines.length === 0) continue;
    const heading = /^(#{1,3})\s+(.*)$/.exec(lines[0]);
    if (heading && lines.length === 1) {
      const level = heading[1].length;
      html.push(`<h${level}>${inline(heading[2])}</h${level}>`);
    } else if (lines.every((line) => /^[-*]\s+/.test(line))) {
      html.push(`<ul>${lines.map((line) => `<li>${inline(line.replace(/^[-*]\s+/, ""))}</li>`).join("")}</ul>`);
    } else {
      html.push(`<p>${lines.map(inline).join("<br>")}</p>`);
    }
  }
  return html.join("\n");
}

async function show() {
  const main = document.querySelector("main[data-content]");
  try {
    const response = await fetch(main.dataset.content, { cache: "no-cache" });
    if (!response.ok) throw new Error(response.statusText);
    main.innerHTML = render(await response.text());
    const title = main.querySelector("h1");
    if (title) document.title = `${title.textContent} – Kintura`;
  } catch {
    main.querySelector("[data-status]").textContent = "Der Inhalt konnte nicht geladen werden.";
  }
}

show();
