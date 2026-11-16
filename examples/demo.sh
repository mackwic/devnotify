#!/usr/bin/env bash
# Posts sample cards to a running `devnotify serve`. Most are fake; the first one is a real Herdr agent.
#   DEVNOTIFY=.build/release/devnotify examples/demo.sh
set -euo pipefail
N=${DEVNOTIFY:-devnotify}

# 1. A live Herdr agent other than the one running this script: its screen in the details, and a
#    reply pasted into it with `hc send` (careful: typing a reply really talks to that agent).
agent=$(hc ls --json 2>/dev/null | jq -c --arg me "${HC_TERMINAL_ID:-}" \
  '[.terminals[] | select(.state == "live" and .status != null and .address != $me)][0] // empty' || true)
if [ -n "$agent" ]; then
  jq -nc --argjson a "$agent" '{
    key: "herdr:\($a.address)", source: "Herdr", level: "success",
    title: "\($a.agent) a terminé", body: $a.where,
    detailsLabel: "Dernières lignes du terminal (hc read, en direct)",
    detailsCommand: ["hc", "read", $a.address, "--lines", "40"],
    reply: {placeholder: "Répondre à l’agent…", argv: ["hc", "send", $a.address, "{text}"]},
    actions: [
      {label: "Aller à l’agent", argv: ["herdr-app", "do", "pane.focus", ({terminal: $a.address} | tojson)], activate: "dev.herdr.app"},
      {label: "Peek", argv: ["herdr-app", "do", "terminal.peek", ({terminal: $a.address} | tojson)], activate: "dev.herdr.app"}
    ]}' | $N post -
  sleep 0.5
fi

# 2. A question asked with `ask`: the caller waits and reads the answer, a button or free text.
(
  answer=$(jq -nc '{
    key: "ask:migration", source: "Claude Code", level: "warning",
    title: "Claude attend ta réponse",
    body: "Appliquer la migration 0042_document_versions sur la base locale ?",
    actions: [{label: "Oui"}, {label: "Non"}, {label: "Plus tard"}]
  }' | $N ask -) || true
  say -v Thomas "$(jq -r '.label // .reply // "pas de réponse"' <<<"${answer:-{\}}")"
) &
sleep 0.5

# 3. Tests: the sender composes its own HTML (a bar, a table, a nested <details>).
tests_html=$(cat <<'HTML'
<div><b>3 échecs</b> <span class="muted">· 412 réussis · 415 au total · 48 s</span></div>
<div class="bar"><span class="ok" style="width:99.3%"></span><span class="ko" style="width:.7%"></span></div>
<table>
  <tr><th>Test</th><th>Fichier</th></tr>
  <tr><td class="ko">✕ refuses an unpublished template version</td><td class="mono muted">create-document.test.ts</td></tr>
  <tr><td class="ko">✕ lists report types by discipline</td><td class="mono muted">templates.query.test.ts</td></tr>
  <tr><td class="ko">✕ hides archived versions</td><td class="mono muted">templates.query.test.ts</td></tr>
</table>
<details><summary>Premier échec</summary>
<pre class="mono">Expected: DomainError(TemplateNotPublished)
Received: Ok({ id: "doc_42", version: 1 })</pre></details>
HTML
)
jq -nc --arg html "$tests_html" '{
  key: "tests:apw", source: "pnpm", level: "error",
  title: "pnpm test:all · @apw/backend", html: $html,
  actions: [{label: "Relancer", argv: ["say", "-v", "Thomas", "Je relance les tests"]}, {label: "Ignorer"}]
}' | $N post -
sleep 0.5

# 4. A long job re-posting the same key: the card updates in place, then turns green.
(
  steps=("Résolution des dépendances" "Compilation TypeScript" "Bundle" "Image Docker" "Scan de sécurité")
  for pct in 0 10 20 30 40 50 60 70 80 90; do
    html="<div><b>${steps[$((pct / 20))]}</b> <span class=\"muted\">· $pct %</span></div><div class=\"bar\"><span class=\"accent\" style=\"width:$pct%\"></span></div>"
    jq -nc --arg html "$html" '{key: "build:backend", source: "Build local", level: "info",
      title: "Build de l’image backend", html: $html}' | $N post -
    sleep 1.2
  done
  jq -nc '{key: "build:backend", source: "Build local", level: "success", title: "Image backend prête",
    html: "<div class=\"ok\"><b>✓ 5 étapes</b> <span class=\"muted\">· 13 s · 412 Mo</span></div>",
    actions: [{label: "Ouvrir la CI", url: "https://github.com/features/actions"}]}' | $N post -
) >/dev/null 2>&1 &
