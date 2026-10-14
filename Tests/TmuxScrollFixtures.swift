// Generate reconnect output with the production tmux parser and resync code.
// The browser test feeds these bytes to the bundled terminal, without a server.
import Foundation

@main enum TmuxScrollFixtures {
  static func main() throws {
    var tracker = TmuxModeTracker(TmuxTrackedModes(bracketedPaste: false, mouseAnyMotion: true))
    tracker.scan(Array("\u{1b}[?2004".utf8))
    tracker.restoreSnapshot(mouseAny: false, pendingEscape: [])
    tracker.scan(Array("h".utf8))
    precondition(!tracker.modes.bracketedPaste, "Reconnect must discard an obsolete partial mode sequence")
    precondition(!tracker.modes.mouseAnyMotion, "Snapshot false must replace archived true")
    tracker.restoreSnapshot(mouseAny: true, pendingEscape: Array("\u{1b}[?2004".utf8))
    tracker.scan(Array("h".utf8))
    precondition(tracker.modes.bracketedPaste, "Continue the snapshot's pending sequence")
    tracker.restoreSnapshot(mouseAny: nil, pendingEscape: [])
    precondition(tracker.modes.mouseAnyMotion, "Old tmux keeps tracked mouse mode")
    tracker.scan(Array("\u{1b}[?2004l\u{1b}[?1003l".utf8))
    precondition(tracker.modes == TmuxTrackedModes(), "Live output still disables both modes")
    tracker.scan(Array("\u{1b}[?2004h\u{1b}[?1003h".utf8))
    tracker.scan(Array("text\u{1b}".utf8))
    tracker.scan(Array("c".utf8))
    precondition(tracker.modes == TmuxTrackedModes(), "RIS resets the tracked modes, also split across chunks")
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
    // Joined history can be wider than the terminal even if the old TUI disabled wrapping.
    for path in ["full", "overlap", "retained", "leave-alternate"] {
      let state = TmuxPaneState(line: base + "|0")!
      let longLine = String(repeating: "W", count: 160) + "END OF LONG HISTORY"
      let snapshot = TmuxSnapshot(state: state, history: [Array(longLine.utf8)], plainHistory: nil,
        screen: (0..<24).map { Array("SCREEN ROW \($0)".utf8) }, savedNormal: [], pendingEscape: [])
      let bytes = path == "overlap"
        ? TmuxResync.overlapAppend(snapshot, newFrom: 0, rows: 24, modes: TmuxTrackedModes())
        : TmuxResync.fullRefill(snapshot, rows: 24, modes: TmuxTrackedModes(),
            marker: path == "full" ? nil : "")
      fixtures.append(["name": "\(path)-long-history", "path": path, "mouse": false,
        "longHistory": longLine, "bytes": String(decoding: bytes, as: UTF8.self)])
    }
    // A short shell screen in a pane taller than the terminal: the blank rows under the cursor give
    // way, the written rows keep their places (tmux drops blank rows itself when the pane shrinks).
    for path in ["full", "overlap"] {
      var state = TmuxPaneState(line: base + "|0")!
      state.height = 30
      state.scrollLower = 29
      state.cursorY = 3
      state.cursorX = 2
      let screen = (0..<30).map { $0 < 4 ? Array("TOP ROW \($0)".utf8) : [UInt8]() }
      let snapshot = TmuxSnapshot(state: state, history: [], plainHistory: nil,
                                  screen: screen, savedNormal: [], pendingEscape: [])
      let bytes = path == "overlap"
        ? TmuxResync.overlapAppend(snapshot, newFrom: 0, rows: 24, modes: TmuxTrackedModes())
        : TmuxResync.fullRefill(snapshot, rows: 24, modes: TmuxTrackedModes(), marker: nil)
      fixtures.append(["name": "\(path)-tall-pane-short-screen", "path": path, "mouse": false,
        "screenTop": "TOP ROW 0", "cursorRow": 3, "bytes": String(decoding: bytes, as: UTF8.self)])
    }
    let data = try JSONSerialization.data(withJSONObject: fixtures, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
  }
}
