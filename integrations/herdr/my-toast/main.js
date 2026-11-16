// Herdr's notifications as devnotify cards. An agent's card unfolds into its last terminal lines, goes
// to it or peeks at it, takes a free reply (`hc send`), and goes away once the agent is dealt with
// (devnotify-herdr-until). Without devnotify, a macOS notification (terminal-notifier); failing that,
// the toast shows in the window as before. Installed by `make herdr` from the devnotify repository.

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { props, closeOverlay, run, theme, exec, home, checking } from "herdr";

const NOTIFIER = "/opt/homebrew/bin/terminal-notifier";
const HERDR_BUNDLE = "dev.herdr.app";
const DOT = { error: "blocked", warning: "working", success: "done", info: "accent" };

const quote = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

/** The devnotify card for a Herdr notification. */
function card(p) {
  const bin = `${home()}/.local/bin`;
  const herdr = `${bin}/herdr-app`;
  const terminal = p.action?.args?.terminal;
  const c = {
    key: `herdr:${terminal ?? p.title}`,
    source: "Herdr",
    level: p.level ?? "info",
    title: p.title ?? "",
    body: p.body || undefined,
    actions: [],
  };
  if (p.action?.name) {
    c.actions.push({ label: "Aller à l'agent", argv: [herdr, "do", p.action.name, JSON.stringify(p.action.args ?? {})], activate: HERDR_BUNDLE });
  }
  if (terminal) {
    c.actions.push({ label: "Peek", argv: [herdr, "do", "terminal.peek", JSON.stringify({ terminal })], activate: HERDR_BUNDLE });
    c.detailsLabel = "Dernières lignes du terminal";
    c.detailsCommand = [`${bin}/hc`, "read", terminal, "--lines", "40"];
    c.reply = { argv: [`${bin}/hc`, "send", terminal, "{text}"], placeholder: "Répondre à l'agent…" };
    c.until = [`${bin}/devnotify-herdr-until`, terminal];
  }
  return c;
}

export default class MyToast extends View {
  init(_props, cx) {
    const p = props();
    if (!p || checking()) return;
    cx.spawn(async (cx) => {
      try {
        const r = await exec(`${home()}/.local/bin/devnotify`, ["post", JSON.stringify(card(p))]);
        if (r.code !== 0) throw new Error(r.stderr);
        closeOverlay(p.overlay);
        return;
      } catch (e) {
        console.log(`my-toast: devnotify failed: ${e}`);
      }
      try {
        const args = ["-title", "Herdr", "-subtitle", p.title ?? "", "-message", p.body || p.title || " ", "-activate", HERDR_BUNDLE];
        if (p.action?.name) {
          args.push("-execute", `${quote(`${home()}/.local/bin/herdr-app`)} do ${quote(p.action.name)} ${quote(JSON.stringify(p.action.args ?? {}))}`);
        }
        const r = await exec(NOTIFIER, args);
        if (r.code !== 0) throw new Error(r.stderr);
        closeOverlay(p.overlay);
      } catch (e) {
        console.log(`my-toast: terminal-notifier failed: ${e}`);
        this.failed = true;
        cx.notify();
      }
    });
  }

  render() {
    const t = theme();
    const p = props() ?? {};
    if (!this.failed) return div();
    return h_flex().id("toast").size_full().px(18).gap(12).items_center().bg(t.popover).cursor_pointer()
      .hover((s) => s.bg(t.hover))
      .on_click(() => {
        if (p.action?.name) run(p.action.name, p.action.args ?? {});
        closeOverlay(p.overlay);
      })
      .child(div().size(8).rounded(4).flex_none().bg(t[DOT[p.level] ?? "accent"]))
      .child(v_flex().flex_1().overflow_hidden()
        .child(div().truncate().font_semibold().text_size(13).text_color(t.foreground).child(p.title ?? ""))
        .when(Boolean(p.body), (el) => el.child(div().truncate().text_size(12).text_color(t.muted).child(p.body))));
  }
}
