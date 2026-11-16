import Darwin
import Foundation

/// The server's private folder (`DEVNOTIFY_DIR` overrides it) and its socket.
let stateDir = ProcessInfo.processInfo.environment["DEVNOTIFY_DIR"] ?? (NSTemporaryDirectory() + "devnotify")
let sockPath = stateDir + "/sock"

// Protocol: one JSON object per line. A message with `"wait": true` keeps its connection open
// and gets one answer line back; the connection then belongs to that card.

private func unixAddress(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    precondition(bytes.count < MemoryLayout.size(ofValue: addr.sun_path), "socket path too long: \(path)")
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
    return addr
}

private func connectToServer() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = unixAddress(sockPath)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { close(fd); return nil }
    return fd
}

private func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        var off = 0
        while off < buf.count {
            let n = write(fd, buf.baseAddress! + off, buf.count - off)
            if n <= 0 { return }
            off += n
        }
    }
}

private func jsonLine(_ obj: [String: Any]) -> Data {
    var data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    data.append(0x0A)
    return data
}

// MARK: - Client

/// Sends one message. Returns nil when no server listens; for a waiting message, the answer line
/// ("" if the server went away without answering), else "".
func send(_ message: [String: Any]) -> String? {
    guard let fd = connectToServer() else { return nil }
    defer { close(fd) }
    writeAll(fd, jsonLine(message))
    guard message["wait"] as? Bool == true else { return "" }
    var answer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while !answer.contains(0x0A) {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        answer.append(chunk, count: n)
    }
    return String(decoding: answer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Server

/// A caller waiting for the person's answer (`devnotify ask`).
final class Client {
    private let fd: Int32
    private var source: DispatchSourceRead?
    private var done = false

    init(fd: Int32) { self.fd = fd }

    /// Calls `handler` (main queue) when the caller goes away without an answer: killed, timed out.
    func onHangup(_ handler: @escaping () -> Void) {
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            var byte: UInt8 = 0
            if read(self.fd, &byte, 1) <= 0 {
                self.finish()
                handler()
            }
        }
        source = s
        s.resume()
    }

    func answer(_ obj: [String: Any]) {
        guard !done else { return }
        writeAll(fd, jsonLine(obj))
        finish()
    }

    private func finish() {
        guard !done else { return }
        done = true
        if let source {
            source.setCancelHandler { [fd] in close(fd) }
            source.cancel()
        } else {
            close(fd)
        }
    }
}

/// Listens on the socket; messages reach `onMessage` on the main queue, with the caller's
/// connection when it waits for an answer. False when another server already listens.
func serve(onMessage: @escaping ([String: Any], Client?) -> Void) -> Bool {
    if let other = connectToServer() { close(other); return false }
    mkdir(stateDir, 0o700)
    unlink(sockPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = unixAddress(sockPath)
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, Darwin.listen(fd, 16) == 0 else { perror("devnotify: bind/listen"); exit(1) }
    chmod(sockPath, 0o600)
    Thread.detachNewThread {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            // Only this user's processes may post: a card can run commands.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            Thread.detachNewThread { readMessages(client, onMessage) }
        }
    }
    return true
}

private func readMessages(_ fd: Int32, _ onMessage: @escaping ([String: Any], Client?) -> Void) {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        buffer.append(chunk, count: n)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if msg["wait"] as? Bool == true {
                let client = Client(fd: fd)
                DispatchQueue.main.async { onMessage(msg, client) }
                return
            }
            DispatchQueue.main.async { onMessage(msg, nil) }
        }
    }
    close(fd)
}
