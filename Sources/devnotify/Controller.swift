import AppKit
import WebKit

/// A borderless panel that can take the keyboard (to type a reply) without activating the app.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Takes the first click, so a card's button works without clicking the panel first.
final class CardsWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The floating stack of cards (top right of the screen under the pointer) and the bell in the menu bar.
final class Controller: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var cards: [[String: Any]] = []  // newest first
    /// `ask` callers, by card key: answered when the person acts on their card.
    private var waiters: [String: Client] = [:]
    /// `until` commands, by card key: the card goes away when its command exits.
    private var watchers: [String: Process] = [:]
    private var hidden = false
    private var pageReady = false
    private let width: CGFloat = 400
    private var contentHeight: CGFloat = 0
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private lazy var panel: Panel = {
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = web
        return p
    }()

    private lazy var web: CardsWebView = {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "dn")
        let w = CardsWebView(frame: NSRect(x: 0, y: 0, width: width, height: 100), configuration: config)
        w.setValue(false, forKey: "drawsBackground")
        w.navigationDelegate = self
        w.loadHTMLString(pageHTML, baseURL: nil)
        return w
    }()

    /// False when another server already runs.
    func start() -> Bool {
        guard serve(onMessage: { [weak self] in self?.receive($0, waiting: $1) }) else { return false }
        _ = panel
        refreshMenu()
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.pushAccent() }
        return true
    }

    // MARK: Messages from the socket

    func receive(_ msg: [String: Any], waiting client: Client?) {
        guard let key = msg["key"] as? String else {
            client?.answer(["error": "a message needs a key"])
            return
        }
        let removing = msg["remove"] as? Bool == true
        settle(key, ["closed": removing ? "removed" : "replaced"])
        unwatch(key)
        cards.removeAll { $0["key"] as? String == key }
        if !removing {
            var card = msg
            card["time"] = Date().timeIntervalSince1970
            if let client {
                // Whoever asks reads the answer: the card always takes a free reply, unless it says no.
                if card["reply"] == nil { card["reply"] = [String: Any]() }
                waiters[key] = client
                client.onHangup { [weak self, weak client] in
                    guard let self, let client, self.waiters[key] === client else { return }
                    self.waiters[key] = nil
                    self.drop(key)
                }
            }
            cards.insert(card, at: 0)
            if let argv = card["until"] as? [String], !argv.isEmpty {
                var watcher: Process?
                watcher = run(argv) { [weak self] _, _ in
                    guard let self, let watcher, self.watchers[key] === watcher else { return }
                    self.watchers[key] = nil
                    self.settle(key, ["closed": "resolved"])
                    self.drop(key)
                }
                watchers[key] = watcher
            }
            hidden = false
        }
        render()
    }

    /// Answers the card's waiting caller, if any. Whether the card goes away is the caller's business.
    private func settle(_ key: String, _ answer: [String: Any]) {
        waiters.removeValue(forKey: key)?.answer(answer)
    }

    private func drop(_ key: String) {
        unwatch(key)
        cards.removeAll { $0["key"] as? String == key }
        render()
    }

    /// Stops the card's `until` command, if it still runs.
    private func unwatch(_ key: String) {
        watchers.removeValue(forKey: key)?.terminate()
    }

    private func render() {
        refreshMenu()
        guard pageReady,
              let data = try? JSONSerialization.data(withJSONObject: cards),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("render(\(json))")
        layoutPanel()
    }

    private func layoutPanel() {
        guard !cards.isEmpty, !hidden else { panel.orderOut(nil); return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let h = min(max(contentHeight, 60), vf.height - 16)
        panel.setFrame(NSRect(x: vf.maxX - width - 10, y: vf.maxY - h - 6, width: width, height: h), display: true)
        panel.orderFrontRegardless()
    }

    private func pushAccent() {
        web.evaluateJavaScript("document.documentElement.style.setProperty('--accent', \(js(accentCSS())))")
    }

    // MARK: Messages from the page

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        pushAccent()
        render()
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        if type == "focus" {
            panel.makeKey()
            return
        }
        if type == "size", let h = m["h"] as? Double {
            contentHeight = CGFloat(h)
            layoutPanel()
            return
        }
        guard let key = m["key"] as? String,
              let card = cards.first(where: { $0["key"] as? String == key }) else { return }
        switch type {
        case "dismiss":
            settle(key, ["closed": "dismissed"])
            drop(key)
        case "expand":
            if let argv = card["detailsCommand"] as? [String] {
                run(argv) { [weak self] _, text in self?.web.evaluateJavaScript("setDetails(\(js(key)), \(js(text)))") }
            }
        case "action":
            guard let actions = card["actions"] as? [[String: Any]],
                  let i = m["index"] as? Int, actions.indices.contains(i) else { return }
            let action = actions[i]
            if let waiter = waiters.removeValue(forKey: key) {
                // The caller decides what the choice does; the action's own effects still run.
                open(action)
                run(action["argv"] as? [String] ?? [])
                waiter.answer(["action": i, "label": action["label"] as? String ?? ""])
                drop(key)
            } else {
                open(action)
                finish(key: key, keep: action["keep"] as? Bool == true, argv: action["argv"] as? [String] ?? [], isReply: false) {
                    self.activate(action)
                }
            }
        case "reply":
            guard let text = m["text"] as? String else { return }
            if let waiter = waiters.removeValue(forKey: key) {
                waiter.answer(["reply": text])
                drop(key)
            } else if let reply = card["reply"] as? [String: Any], let argv = reply["argv"] as? [String] {
                finish(key: key, keep: reply["keep"] as? Bool == true,
                       argv: argv.map { $0.replacingOccurrences(of: "{text}", with: text) }, isReply: true)
            }
        default:
            break
        }
    }

    private func open(_ action: [String: Any]) {
        if let url = (action["url"] as? String).flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
    }

    private func activate(_ action: [String: Any]) {
        if let bundle = action["activate"] as? String {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate()
        }
    }

    /// Runs a button's command. The card goes away only once it succeeded (and isn't kept);
    /// a failure stays on the card in the command's own words.
    private func finish(key: String, keep: Bool, argv: [String], isReply: Bool, onSuccess: (() -> Void)? = nil) {
        run(argv) { [weak self] status, text in
            guard let self else { return }
            if status == 0 { onSuccess?() }
            if status == 0 && !keep { self.drop(key); return }
            self.web.evaluateJavaScript("actionDone(\(js(key)), \(status == 0), \(js(text)), \(isReply))")
        }
    }

    // MARK: Menu bar

    private func refreshMenu() {
        statusItem.button?.title = cards.isEmpty ? "" : " \(cards.count)"
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.image = NSImage(systemSymbolName: cards.isEmpty ? "bell" : "bell.badge",
                                           accessibilityDescription: "devnotify")
        let menu = NSMenu()
        if cards.isEmpty {
            menu.addItem(NSMenuItem(title: "Aucune notification", action: nil, keyEquivalent: ""))
        }
        for card in cards {
            let item = NSMenuItem(title: card["title"] as? String ?? "?", action: #selector(showCards), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: hidden ? "Afficher les cartes" : "Masquer les cartes",
                                action: #selector(toggleCards), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let clear = NSMenuItem(title: "Tout effacer", action: #selector(clearAll), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(NSMenuItem(title: "Quitter devnotify", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func showCards() { hidden = false; render() }
    @objc private func toggleCards() { hidden.toggle(); render() }
    @objc private func clearAll() {
        for key in Array(waiters.keys) { settle(key, ["closed": "dismissed"]) }
        for key in Array(watchers.keys) { unwatch(key) }
        cards.removeAll()
        render()
    }
}
