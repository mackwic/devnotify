import AppKit

/// Runs `argv` and reports its exit status and combined output on the main queue.
/// The PATH also holds ~/.local/bin and Homebrew: a server started at login has a bare one.
@discardableResult
func run(_ argv: [String], completion: ((Int32, String) -> Void)? = nil) -> Process? {
    guard !argv.isEmpty else { completion?(0, ""); return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = argv
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    p.terminationHandler = { proc in
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        DispatchQueue.main.async { completion?(proc.terminationStatus, text) }
    }
    do { try p.run() } catch { completion?(127, "devnotify: \(error.localizedDescription)"); return nil }
    return p
}

/// A JS literal for any JSON value, strings included.
func js(_ value: Any) -> String {
    (try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]))
        .flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "null"
}

/// The person's accent colour, as CSS.
func accentCSS() -> String {
    guard let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return "#0a84ff" }
    return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}
