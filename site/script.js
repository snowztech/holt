// The hero popup types a search, filters its rows like Holt does, then clears.
(() => {
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  const query = document.getElementById("demo-query");
  const placeholder = document.getElementById("demo-placeholder");
  const rows = [...document.querySelectorAll("#demo-list .row")];
  if (!query || !rows.length) return;

  const originals = new Map(rows.map((row) => [row, row.querySelector(".txt").innerHTML]));
  const searches = ["ssh", "friday", "holt"];
  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  // Same rule as the app: every word must appear, case-insensitively.
  function filter(text) {
    const words = text.toLowerCase().split(/\s+/).filter(Boolean);
    let first = true;
    for (const row of rows) {
      const match = words.every((w) => row.dataset.text.toLowerCase().includes(w));
      row.hidden = !match;
      row.classList.toggle("sel", match && first);
      if (match && first) preview(row);
      if (match) first = false;
      const label = row.querySelector(".txt");
      label.innerHTML = originals.get(row);
      if (match && words.length && !label.querySelector(".swatch")) {
        const pattern = new RegExp(`(${words.map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})`, "gi");
        label.innerHTML = label.textContent.replace(pattern, "<mark>$1</mark>");
      }
    }
  }

  const meta = document.getElementById("preview-meta");
  const body = document.getElementById("preview-body");

  function preview(row) {
    if (!row) return;
    meta.textContent = row.dataset.meta;
    const text = row.dataset.text;
    if (text.startsWith("https://")) {
      body.innerHTML = `<div class="preview-link"><strong>${new URL(text).host}</strong><span></span></div>`;
      body.querySelector("span").textContent = text;
    } else {
      body.innerHTML = `<p class="preview-text"></p>`;
      body.querySelector("p").textContent = text;
    }
  }

  function reset() {
    query.textContent = "";
    placeholder.hidden = false;
    filter("");
  }

  async function loop() {
    await wait(3200);
    for (;;) {
      for (const text of searches) {
        placeholder.hidden = true;
        for (let i = 1; i <= text.length; i++) {
          query.textContent = text.slice(0, i);
          filter(query.textContent);
          await wait(110 + Math.random() * 90);
        }
        await wait(2200);
        reset();
        await wait(1400);
      }
    }
  }

  loop();
})();
