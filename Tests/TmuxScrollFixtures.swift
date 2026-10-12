// Generate reconnect output with the production tmux parser and resync code.
// The browser test feeds these bytes to the bundled terminal, without a server.
import Foundation

@main enum TmuxScrollFixtures {
  static func main() throws {
    var fixtures: [[String: Any]] = []
    let base = "%0|80|24|120|0|0|0|0|23|1|0|0|0|1|0|23|0|0|0|0|0|123|@0|1"
    // The server's explicit false must defeat stale archived true, while an unavailable format
    // must retain the compatibility fallback. Exercise both supported and old tmux replies.
    for (flag, cached, expected) in [("0", true, false), ("1", false, true), ("", true, true), ("", false, false)] {
      for path in ["full", "overlap", "alternate"] {
        var state = TmuxPaneState(line: base + "|" + flag)!
        state.alternateOn = path == "alternate"
        let snapshot = TmuxSnapshot(state: state,
          history: (0..<120).map { Array("HISTORY ROW \($0)".utf8) }, plainHistory: nil,
          screen: (0..<24).map { Array("SCREEN ROW \($0)".utf8) }, savedNormal: [], pendingEscape: [])
        let modes = TmuxTrackedModes(bracketedPaste: false, mouseAnyMotion: cached)
        let bytes: [UInt8]
        switch path {
        case "full": bytes = TmuxResync.fullRefill(snapshot, rows: 24, modes: modes, marker: nil)
        case "overlap": bytes = TmuxResync.overlapAppend(snapshot, newFrom: 0, rows: 24, modes: modes)
        default: bytes = TmuxResync.alternateRepaint(snapshot, rows: 24, modes: modes)
        }
        fixtures.append(["name": "\(path)-flag-\(flag.isEmpty ? "missing" : flag)-cached-\(cached)",
                         "path": path, "mouse": expected, "bytes": String(decoding: bytes, as: UTF8.self)])
      }
    }
    // Keep all advertised tracking modes and coordinate encodings functional after the reset.
    for mode in ["standard", "button", "any"] {
      for sgr in [false, true] {
        var state = TmuxPaneState(line: base + "|0")!
        state.mouseStandard = mode == "standard"
        state.mouseButton = mode == "button"
        state.mouseAny = mode == "any"
        state.mouseSGR = sgr
        let snapshot = TmuxSnapshot(state: state, history: [], plainHistory: nil,
                                    screen: [Array("TUI".utf8)], savedNormal: [], pendingEscape: [])
        let bytes = TmuxResync.fullRefill(snapshot, rows: 24, modes: TmuxTrackedModes(), marker: nil)
        fixtures.append(["name": "\(mode)-sgr-\(sgr)", "path": "full", "mouse": true,
                         "sgr": sgr, "bytes": String(decoding: bytes, as: UTF8.self)])
      }
    }
    let data = try JSONSerialization.data(withJSONObject: fixtures, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
  }
}
