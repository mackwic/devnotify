# devnotify

A notification center for developers on macOS: rich cards floating at the top right of the screen,
above every app and Space, without taking the focus. Cards fold and unfold, run commands, and take a
free-text reply. Any script, agent or CI hook posts one through a local socket.

One binary: `devnotify serve` is the menu bar app (a bell) and the cards; the other commands are its
clients.

## Build

Needs only the Command Line Tools (Swift 5.9+), macOS 13+.

```sh
make            # swift build -c release
make install    # into ~/.local/bin (PREFIX=… to change)
devnotify serve &
```

## Usage

```sh
devnotify post '{"title": "Build done", "body": "backend · 13 s", "level": "success"}'
echo '{…}' | devnotify post -
devnotify remove <key>

# Waits for the person and prints the answer:
devnotify ask '{"title": "Apply the migration?", "actions": [{"label": "Yes"}, {"label": "No"}]}'
# {"action":0,"label":"Yes"}   or   {"reply":"only on staging"}   or   {"closed":"dismissed"}
```

`ask` exits 0 with an answer, 3 when the card closed without one (dismissed, replaced, removed),
1 when nothing listens or the server went away. Killing the caller takes its card away.

## Card

| Field | |
|---|---|
| `key` | Identity; posting the same key again replaces the card in place. Generated if missing. |
| `title`, `body`, `source` | Text. |
| `level` | `info` (default), `success`, `warning` (pulsing dot), `error`. |
| `html` | The sender's own markup between the body and the buttons (see below). |
| `details` | Folded text, shown in monospace. |
| `detailsCommand` | argv run each time the details unfold; its output replaces `details`. |
| `detailsLabel` | The fold's label (default "Détails"). |
| `actions` | Buttons, see below. The first one is the primary button. |
| `reply` | A free-text reply right of the buttons: `{argv, placeholder, label, keep, open}`; `{text}` in `argv` is replaced by the reply. It folds behind a "Répondre…" button that slides open into a field; it starts open when the card has no button or says `"open": true`, and folds back on Esc or when left empty. An `ask` card always has one (`"reply": false` removes it); its reply is the answer. |
| `until` | argv started with the card; the card goes away when it exits (an `ask` answers `{"closed": "resolved"}`). |

An action is `{label, argv?, url?, activate?, keep?}`: it runs `argv`, opens `url`, then brings the
app with bundle id `activate` forward. The card goes away once the command succeeded, unless `keep`;
a failing command leaves the card with the command's message on it. On an `ask` card, an action
answers `{"action": index, "label": …}` (its own effects still run).

Commands run with `~/.local/bin` and `/opt/homebrew/bin` on the PATH.

### Custom HTML

`html` is drawn in a shadow root: its styles stay inside the card and no script runs (the page's
Content-Security-Policy only allows its own). It follows the theme through the page's CSS variables
(`--fg`, `--fg2`, `--fg3`, `--accent`, `--ok`, `--ko`, `--warn`, `--well`, `--line`) and gets ready
classes: `ok`, `ko`, `warn`, `accent`, `muted`, `mono`, and `bar` for a progress bar:

```html
<div class="bar"><span class="ok" style="width:80%"></span><span class="ko" style="width:20%"></span></div>
```

An element with `data-act="N"` in it runs the card's action N.

## Look

Light and dark palettes follow macOS, as do the accent colour (live) and Reduce Motion. Cards are
opaque, for contrast.

## Protocol

A Unix socket at `$TMPDIR/devnotify/sock` (`DEVNOTIFY_DIR` overrides the folder), in a `0700` folder;
the server also checks that the peer is the same user. One JSON object per line. A message with
`"wait": true` keeps its connection open and receives one JSON line, the answer.

## Herdr

`make herdr` installs `devnotify-herdr-until` and the `my-toast` mod (`~/.config/herdr-app/mods/my-toast`):
Herdr's notifications become cards that go to the agent or peek at it, unfold into its last terminal
lines, send a free reply with `hc send`, and go away once the agent is dealt with (looked at, new turn,
unblocked or ended). Without devnotify, the mod falls back to terminal-notifier, then to the in-window toast.
