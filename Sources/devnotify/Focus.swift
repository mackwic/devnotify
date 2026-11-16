import Foundation

/// Whether a Focus (Do Not Disturb, Work...) is on. macOS has no public API for it outside a signed app
/// with the Focus Status entitlement, so this reads the file where macOS records the active Focus: its
/// format is undocumented, and an unreadable file counts as no Focus.
func focusActive() -> Bool {
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let stores = json["data"] as? [[String: Any]] else { return false }
    return stores.contains { ($0["storeAssertionRecords"] as? [Any])?.isEmpty == false }
}
