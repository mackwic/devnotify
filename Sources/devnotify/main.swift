import AppKit

let usage = """
usage: devnotify serve              run the menu bar app and the floating cards
       devnotify post '<json>'|-    show a card (JSON on stdin with -)
       devnotify ask '<json>'|-     show a card and print the person's answer as JSON
       devnotify remove <key>       take a card away
"""

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("devnotify: \(message)\n".utf8))
    exit(code)
}

func readMessage(_ arg: String?) -> [String: Any] {
    let text = arg ?? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
        fail("expected a JSON object", 2)
    }
    return obj
}

// A caller that went away mid-write must not kill the server (nor a reply to it).
signal(SIGPIPE, SIG_IGN)

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "serve":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = Controller()
    guard controller.start() else { fail("already running on \(sockPath)", 1) }
    app.run()

case "post", "ask":
    let asking = args[0] == "ask"
    var msg = readMessage(args.dropFirst().first.flatMap { $0 == "-" ? nil : $0 })
    if msg["key"] == nil { msg["key"] = UUID().uuidString }
    msg["wait"] = asking
    guard let answer = send(msg) else { fail("nothing listens on \(sockPath) (run `devnotify serve`)", 1) }
    guard asking else { exit(0) }
    // 0: the person chose or replied; 3: the card closed without an answer; 1: no answer at all.
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [String: Any] else {
        fail("the server closed without answering", 1)
    }
    print(answer)
    exit(obj["closed"] != nil || obj["error"] != nil ? 3 : 0)

case "remove":
    guard args.count == 2 else { fail(usage, 2) }
    guard send(["key": args[1], "remove": true]) != nil else { fail("nothing listens on \(sockPath)", 1) }

default:
    print(usage)
    exit(args.isEmpty ? 0 : 2)
}
