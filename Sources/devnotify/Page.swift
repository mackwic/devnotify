// The page follows the system: light/dark palettes (opaque cards, high contrast), the person's accent
// colour (--accent, pushed from macOS) and Reduce Motion. A card's `html` is the sender's own markup,
// drawn in a shadow root (its styles stay inside) under a CSP that runs no script but ours.
let pageHTML = #"""
<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-dn'; style-src 'unsafe-inline'; img-src data: https:">
<style>
:root { color-scheme: light dark; --accent: #0a84ff;
  --card: rgba(255,255,255,.985); --line: rgba(0,0,0,.14); --fg: #111114; --fg2: #3a3a3f; --fg3: #5f5f66;
  --well: #f1f1f4; --btn: #ececf0; --btn-line: rgba(0,0,0,.16); --shadow: 0 4px 16px rgba(0,0,0,.18);
  --ok: #1f8a3b; --ko: #d1242f; --warn: #b25e00; --info: #0b62d6; --err-bg: #fdecec }
@media (prefers-color-scheme: dark) { :root {
  --card: rgba(28,28,32,.975); --line: rgba(255,255,255,.14); --fg: #f5f5f7; --fg2: #d4d4da; --fg3: #a8a8b0;
  --well: rgba(0,0,0,.42); --btn: rgba(255,255,255,.10); --btn-line: rgba(255,255,255,.18); --shadow: 0 4px 16px rgba(0,0,0,.45);
  --ok: #3fd16b; --ko: #ff6b6b; --warn: #ffb340; --info: #5aa9ff; --err-bg: rgba(255,90,90,.14) } }
html, body { margin: 0; background: transparent; font: 13px -apple-system, system-ui; color: var(--fg);
  -webkit-user-select: none; overflow: hidden }
#stack { display: flex; flex-direction: column; gap: 8px; padding: 6px 6px 12px }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 10px 12px; box-shadow: var(--shadow) }
.card.new { animation: in .28s cubic-bezier(.2,.9,.3,1.2) }
@keyframes in { from { opacity: 0; transform: translateX(30px) } to { opacity: 1; transform: none } }
@keyframes fade { from { opacity: 0 } }
.head { display: flex; align-items: center; gap: 8px }
.dot { width: 8px; height: 8px; border-radius: 4px; flex: none }
.dot.pulse { animation: pulse 1.4s ease-in-out infinite }
@keyframes pulse { 50% { opacity: .35 } }
@media (prefers-reduced-motion: reduce) { .card.new { animation: fade .15s } .dot.pulse { animation: none } }
.title { font-weight: 600; flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis }
.src { color: var(--fg3); font-size: 11px; white-space: nowrap }
.x { color: var(--fg3); cursor: pointer; padding: 0 2px }
.x:hover { color: var(--fg) }
.body { color: var(--fg2); margin: 4px 0 0 16px }
.custom { display: block; margin: 6px 0 0 16px }
details { margin: 6px 0 0 16px }
summary { cursor: pointer; color: var(--accent); font-size: 12px; font-weight: 500; list-style: none }
summary::-webkit-details-marker { display: none }
summary::before { content: "▸ " }
details[open] summary::before { content: "▾ " }
pre { max-height: 240px; overflow: auto; background: var(--well); color: var(--fg); border-radius: 8px; padding: 8px;
  font: 11px ui-monospace, Menlo; white-space: pre-wrap; margin: 6px 0 0; -webkit-user-select: text }
/* Buttons on the left, the free reply takes the rest of the row (and its own row when too narrow). */
.respond { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; margin: 8px 0 0 16px }
button { background: var(--btn); color: var(--fg); border: 1px solid var(--btn-line); border-radius: 7px;
  padding: 4px 10px; font: 500 12px -apple-system; cursor: pointer }
button.primary { background: var(--accent); border-color: transparent; color: #fff }
button:hover { filter: brightness(1.08) }
button.busy { opacity: .55; cursor: progress }
.reply { flex: 1 1 120px; min-width: 120px; position: relative; display: flex }
.reply input { flex: 1; width: 0; background: var(--well); border: 1px solid var(--btn-line); border-radius: 7px;
  color: var(--fg); padding: 4px 30px 4px 8px; font: 12px -apple-system; outline: none }
.reply input:focus { border-color: var(--accent); box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 30%, transparent) }
.reply .send { position: absolute; right: 3px; top: 50%; transform: translateY(-50%); padding: 1px 7px; border: none;
  border-radius: 5px; background: var(--accent); color: #fff; font-size: 11px }
.reply input:placeholder-shown + .send { opacity: .35; pointer-events: none }
.error { margin: 8px 0 0 16px; padding: 6px 8px; border-radius: 7px; background: var(--err-bg); color: var(--ko);
  font-size: 12px; -webkit-user-select: text }
</style></head><body><div id="stack"></div><script nonce="dn">
// Base styles inside a card's own HTML: the page's variables cross the shadow boundary.
const CUSTOM_CSS = `:host { color: var(--fg2) } * { box-sizing: border-box }
  table { border-collapse: collapse; width: 100%; font-size: 12px } td, th { padding: 3px 6px 3px 0; text-align: left; vertical-align: top }
  th { color: var(--fg3); font-weight: 500 } tr + tr td { border-top: 1px solid var(--line) }
  code, .mono { font: 11px ui-monospace, Menlo } .muted { color: var(--fg3) } .ok { color: var(--ok) } .ko { color: var(--ko) }
  .warn { color: var(--warn) } .accent { color: var(--accent) } b, strong { color: var(--fg) }
  .bar { display: flex; height: 6px; border-radius: 3px; overflow: hidden; background: var(--well); margin: 6px 0 }
  .bar > * { height: 100% } .bar .ok { background: var(--ok) } .bar .ko { background: var(--ko) } .bar .accent { background: var(--accent) }
  details summary { cursor: pointer; color: var(--accent); font-size: 12px }
  button { background: var(--btn); color: var(--fg); border: 1px solid var(--btn-line); border-radius: 7px; padding: 2px 8px; font: 500 11px -apple-system; cursor: pointer }`;
const opened = new Set(), loaded = {}, seen = new Set(), errors = {}, drafts = {};
const post = m => webkit.messageHandlers.dn.postMessage(m);
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const isObj = v => v !== null && typeof v === "object";
const DOT = { success: "var(--ok)", error: "var(--ko)", warning: "var(--warn)", info: "var(--info)" };
const ago = t => { const s = Math.round(Date.now() / 1000 - t);
  return s < 60 ? "à l'instant" : s < 3600 ? Math.floor(s / 60) + " min" : Math.floor(s / 3600) + " h" };
const srcLine = c => (c.source ? esc(c.source) + " · " : "") + ago(c.time);
// A card version is its key and its post time: a re-post (same key) starts clean.
const version = c => c.key + "@" + c.time;
let last = [];
function render(cards) {
  last = cards;
  const keys = new Set(cards.map(c => c.key));
  for (const k of Object.keys(drafts)) if (!keys.has(k)) delete drafts[k];
  // Re-rendering replaces the inputs: keep the one being typed in focused, caret included.
  const f = document.activeElement, typing = f?.matches?.(".reply input") ? f.closest(".card").dataset.key : null;
  const caret = typing ? [f.selectionStart, f.selectionEnd] : null;
  const stack = document.getElementById("stack");
  stack.innerHTML = cards.map(c => {
    const isNew = !seen.has(c.key); seen.add(c.key);
    const hasDetails = c.details != null || c.detailsCommand;
    const actions = c.actions || [], reply = isObj(c.reply) ? c.reply : null;
    const err = errors[version(c)];
    return `<div class="card ${isNew ? "new" : ""}" data-key="${esc(c.key)}">
      <div class="head"><span class="dot ${c.level === "warning" ? "pulse" : ""}" style="background:${DOT[c.level] || DOT.info}"></span>
        <span class="title">${esc(c.title)}</span><span class="src">${srcLine(c)}</span>
        <span class="x" data-dismiss title="Ignorer">✕</span></div>
      ${c.body ? `<div class="body">${esc(c.body)}</div>` : ""}
      ${c.html ? `<div class="custom"></div>` : ""}
      ${hasDetails ? `<details ${opened.has(c.key) ? "open" : ""}><summary>${esc(c.detailsLabel || "Détails")}</summary>
        <pre>${esc(loaded[c.key] ?? c.details ?? "chargement…")}</pre></details>` : ""}
      ${actions.length || reply ? `<div class="respond">
        ${actions.map((a, i) => `<button class="${i === 0 ? "primary" : ""}" data-act="${i}">${esc(a.label)}</button>`).join("")}
        ${reply ? `<div class="reply"><input placeholder="${esc(reply.placeholder || "Répondre…")}" value="${esc(drafts[c.key] ?? "")}">
          <button class="send" data-reply title="${esc(reply.label || "Envoyer")}">↵</button></div>` : ""}
      </div>` : ""}
      ${err ? `<div class="error">${esc(err)}</div>` : ""}
    </div>`; }).join("");
  const withHTML = cards.filter(c => c.html);
  stack.querySelectorAll(".custom").forEach((el, i) => {
    el.attachShadow({ mode: "open" }).innerHTML = `<style>${CUSTOM_CSS}</style>${withHTML[i].html}`;
  });
  const input = typing && cardEl(typing)?.querySelector(".reply input");
  if (input) { input.focus(); input.setSelectionRange(...caret); }
}
function cardEl(key) { return [...document.querySelectorAll(".card")].find(c => c.dataset.key === key); }
function setDetails(key, text) {
  loaded[key] = text;
  const pre = cardEl(key)?.querySelector("pre");
  if (pre) { pre.textContent = text; pre.scrollTop = pre.scrollHeight; }
}
// The command behind a button finished. A failure stays on the card, in the command's own words
// (`herdr-app do` answers {"error": "..."}); a sent reply clears its draft.
function actionDone(key, ok, text, isReply) {
  const c = last.find(c => c.key === key); if (!c) return;
  let msg = null;
  if (!ok) { msg = text.trim() || "La commande a échoué.";
    try { msg = JSON.parse(msg).error ?? msg } catch {}
    msg = "Échec : " + msg.slice(0, 300); }
  else if (isReply) delete drafts[key];
  errors[version(c)] = msg;
  render(last);
}
function sendReply(card) {
  const input = card.querySelector(".reply input"), text = input.value.trim();
  if (!text || input.disabled) return;
  input.disabled = true;
  post({ type: "reply", key: card.dataset.key, text });
}
new ResizeObserver(() => post({ type: "size", h: document.getElementById("stack").scrollHeight }))
  .observe(document.getElementById("stack"));
// Clicks inside a card's own HTML come through its shadow root: read the composed path.
document.addEventListener("click", e => {
  const path = e.composedPath(), find = sel => path.find(n => n.matches?.(sel));
  const card = find(".card"); if (!card) return; const key = card.dataset.key;
  if (find("[data-dismiss]")) post({ type: "dismiss", key });
  const a = find("[data-act]");
  if (a && !a.classList.contains("busy")) { a.classList.add("busy"); post({ type: "action", key, index: +a.dataset.act }); }
  if (find("[data-reply]")) sendReply(card);
});
document.addEventListener("input", e => {
  if (e.target.matches(".reply input")) drafts[e.target.closest(".card").dataset.key] = e.target.value;
});
document.addEventListener("keydown", e => {
  if (e.key === "Enter" && e.target.matches(".reply input")) sendReply(e.target.closest(".card"));
});
document.addEventListener("toggle", e => {
  if (e.target.tagName !== "DETAILS" || !e.target.closest(".card")) return;
  const key = e.target.closest(".card").dataset.key;
  if (e.target.open) { opened.add(key); post({ type: "expand", key }); } else opened.delete(key);
}, true);
setInterval(() => document.querySelectorAll(".card").forEach((el, i) => {
  const c = last[i]; const src = el.querySelector(".src"); if (c && src) src.innerHTML = srcLine(c);
}), 30000);
</script></body></html>
"""#
