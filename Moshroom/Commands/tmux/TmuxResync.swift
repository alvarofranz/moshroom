////////////////////////////////////////////////////////////////////////////////
//
// M O S H R O O M
//
// Copyright (C) 2026 Moshroom
//
// This file is part of Moshroom.
//
// Moshroom is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Moshroom is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Moshroom. If not, see <http://www.gnu.org/licenses/>.
//
////////////////////////////////////////////////////////////////////////////////


// Bringing the terminal back in step with a tmux pane: what to ask tmux (one command line, so nothing
// changes in between) and the bytes that paint its answer. Pure: no I/O, testable on its own.
//
// tmux sends nothing about a pane's past when a client attaches, so every (re)attach asks for it:
// - FULL refill, for a terminal that shows nothing (a relaunched tab, a rebuilt page): the last K lines
//   of history, then the screen, the cursor and the modes.
// - OVERLAP append, for a terminal that still shows what it showed when the connection went away: only
//   the history it has not seen yet, found by matching its own last scrolled-off lines in tmux's.

import Foundation

struct TmuxVersion: Comparable {
  let major: Int
  let minor: Int

  /// "tmux 3.2a", "tmux next-3.4", "tmux 3.5": the first "<n>.<n>" in the text.
  init?(_ text: String) {
    let scalars = Array(text.unicodeScalars)
    var i = 0
    while i < scalars.count {
      if CharacterSet.decimalDigits.contains(scalars[i]) {
        var j = i
        var major = 0
        while j < scalars.count, let d = Int(String(scalars[j])) { major = major * 10 + d; j += 1 }
        if j < scalars.count, scalars[j] == ".", j + 1 < scalars.count, let first = Int(String(scalars[j + 1])) {
          var minor = first
          var k = j + 2
          while k < scalars.count, let d = Int(String(scalars[k])) { minor = minor * 10 + d; k += 1 }
          self.major = major
          self.minor = minor
          return
        }
        i = j
      }
      i += 1
    }
    return nil
  }

  init(_ major: Int, _ minor: Int) {
    self.major = major
    self.minor = minor
  }

  static func < (a: TmuxVersion, b: TmuxVersion) -> Bool {
    (a.major, a.minor) < (b.major, b.minor)
  }

  /// `capture-pane -N` (keep trailing spaces) and the mouse_sgr_flag format.
  var hasCaptureN: Bool { self >= TmuxVersion(3, 1) }
  /// `refresh-client -f pause-after` and `refresh-client -A` (flow control, pane on/off).
  var hasFlowControl: Bool { self >= TmuxVersion(3, 2) }
}

/// Modes tmux has no format for (bracketed paste; any-motion mouse on 3.2), followed in the pane's own
/// output as it streams by.
struct TmuxTrackedModes: Equatable {
  var bracketedPaste = false
  var mouseAnyMotion = false
}

/// One pane, as `display -p` reports it.
struct TmuxPaneState {
  var paneId = 0
  var width = 80
  var height = 24
  var historySize = 0
  var alternateOn = false
  var alternateSavedX = 0
  var alternateSavedY = 0
  var cursorX = 0
  var cursorY = 0
  var cursorVisible = true
  var insertMode = false
  var appCursorKeys = false
  var appKeypad = false
  var wrap = true
  var scrollUpper = 0
  var scrollLower = 23
  var mouseStandard = false
  var mouseButton = false
  var mouseUTF8 = false
  var mouseSGR = false
  var inMode = false
  var sessionCreated = ""
  var windowId = ""
  var windowPanes = 1

  static let format = [
    "#{pane_id}", "#{pane_width}", "#{pane_height}", "#{history_size}", "#{alternate_on}",
    "#{alternate_saved_x}", "#{alternate_saved_y}", "#{cursor_x}", "#{cursor_y}", "#{cursor_flag}",
    "#{insert_flag}", "#{keypad_cursor_flag}", "#{keypad_flag}", "#{wrap_flag}",
    "#{scroll_region_upper}", "#{scroll_region_lower}", "#{mouse_standard_flag}",
    "#{mouse_button_flag}", "#{mouse_utf8_flag}", "#{mouse_sgr_flag}", "#{pane_in_mode}",
    "#{session_created}", "#{window_id}", "#{window_panes}",
  ].joined(separator: "|")

  init() {}

  init?(line: String) {
    let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard f.count >= 24, let pane = TmuxControlParser._paneNumber(f[0]) else { return nil }
    func n(_ i: Int, _ d: Int = 0) -> Int { Int(f[i]) ?? d }
    func b(_ i: Int) -> Bool { f[i] == "1" }
    paneId = pane
    width = n(1, 80)
    height = n(2, 24)
    historySize = n(3)
    alternateOn = b(4)
    alternateSavedX = n(5)
    alternateSavedY = n(6)
    cursorX = n(7)
    cursorY = n(8)
    cursorVisible = f[9] != "0"
    insertMode = b(10)
    appCursorKeys = b(11)
    appKeypad = b(12)
    wrap = f[13] != "0"
    scrollUpper = n(14)
    scrollLower = n(15, height - 1)
    mouseStandard = b(16)
    mouseButton = b(17)
    mouseUTF8 = b(18)
    mouseSGR = b(19)
    inMode = b(20)
    sessionCreated = f[21]
    windowId = f[22]
    windowPanes = n(23, 1)
  }
}

/// What one resync fence answered.
struct TmuxSnapshot {
  var state: TmuxPaneState
  /// History with escapes (-e), wrapped lines joined: what gets painted.
  var history: [[UInt8]]
  /// The same history without escapes: what the overlap match compares (nil for a full refill).
  var plainHistory: [[UInt8]]?
  /// The screen (the alternate one while alternate_on).
  var screen: [[UInt8]]
  /// The normal screen saved under the alternate one (empty unless alternate_on).
  var savedNormal: [[UInt8]]
  /// An escape sequence tmux has started receiving but not finished (decoded).
  var pendingEscape: [UInt8]
}

enum TmuxResync {
  /// One command line: the state, then every capture, all of the active pane at the same instant.
  /// Five or six commands, five or six replies, in this order (see `snapshot(from:)`).
  static func fence(historyLines: Int, overlap: Bool, version: TmuxVersion) -> [String] {
    let n = version.hasCaptureN ? " -N" : ""
    var commands = [
      "display -p '\(TmuxPaneState.format)'",
      "capture-pane -p -e -J -q -S -\(historyLines) -E -1",
    ]
    if overlap {
      commands.append("capture-pane -p -J -q -S -\(historyLines) -E -1")
    }
    commands.append("capture-pane -p -e\(n) -q")
    // With -q a pane that is not on its alternate screen answers empty instead of failing (a failure
    // would make tmux skip whatever followed it on the line).
    commands.append("capture-pane -p -a -e\(n) -q")
    commands.append("capture-pane -p -P -C -q")
    return commands
  }

  /// Assemble the replies of `fence` (same order). Nil when the state line cannot be read.
  static func snapshot(from replies: [TmuxReply], overlap: Bool) -> TmuxSnapshot? {
    let expected = overlap ? 6 : 5
    guard replies.count == expected, !replies.contains(where: { $0.skipped || $0.isError }),
          let state = TmuxPaneState(line: replies[0].text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return nil
    }
    var i = 1
    // An empty history still answers one line (the screen's first row): only history_size says.
    let history = state.historySize > 0 ? replies[i].lines : []
    i += 1
    var plain: [[UInt8]]? = nil
    if overlap {
      plain = state.historySize > 0 ? replies[i].lines : []
      i += 1
    }
    let screen = replies[i].lines
    i += 1
    let saved = state.alternateOn ? replies[i].lines : []
    i += 1
    let pendingLine = replies[i].lines.first ?? []
    return TmuxSnapshot(state: state,
                        history: history,
                        plainHistory: plain,
                        screen: screen,
                        savedNormal: saved,
                        pendingEscape: TmuxControlParser.decodeOctal(pendingLine))
  }

  // MARK: - Painting

  private static let esc: UInt8 = 0x1B
  private static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

  /// A full refill. `rows` is the terminal's own height. A `marker` means the terminal still shows
  /// something: that is pushed up into its scrollback first, so nothing on it is painted over, and a
  /// non-empty marker goes above the refill as a short dim line.
  ///
  /// With a marker the refill simply continues below the cursor: every line it writes scrolls what
  /// was there up into the scrollback, and since it writes at least a screenful, the screen ends up
  /// holding exactly the pane's. No blank rows are pushed into the scrollback on the way.
  static func fullRefill(_ snap: TmuxSnapshot, rows: Int, modes: TmuxTrackedModes, marker: String?, leaveAlternate: Bool = false) -> [UInt8] {
    var lines: [[UInt8]] = []
    var out: [UInt8]
    if let marker {
      out = bytes("\u{1b}[0m")
      if leaveAlternate {
        out += bytes("\u{1b}[?1049l")
      }
      // Reset the scroll region without losing the cursor (DECSTBM homes it), then a fresh row.
      out += bytes("\u{1b}7\u{1b}[r\u{1b}8\r\n")
      if !marker.isEmpty {
        lines.append(bytes("\u{1b}[2m\(marker)\u{1b}[0m"))
      }
    } else {
      out = bytes("\u{1b}[0m\u{1b}[r\u{1b}[H\u{1b}[2J")
    }
    lines += snap.history.map(trimTrailingSpaces)
    out += _primary(snap, lines: lines, rows: rows, eraseRows: marker != nil)
    out += _tail(snap, rows: rows, modes: modes)
    return out
  }

  /// An overlap append: the terminal still holds everything up to `newFrom` (an index into the
  /// snapshot's history), so only what comes after it is written, from the top of a cleared screen.
  static func overlapAppend(_ snap: TmuxSnapshot, newFrom: Int, rows: Int, modes: TmuxTrackedModes) -> [UInt8] {
    var out = bytes("\u{1b}[0m\u{1b}[r\u{1b}[H\u{1b}[J")
    let fresh = newFrom < snap.history.count ? Array(snap.history[newFrom...]) : []
    out += _primary(snap, lines: fresh.map(trimTrailingSpaces), rows: rows)
    out += _tail(snap, rows: rows, modes: modes)
    return out
  }

  /// The alternate screen only, for a terminal that is on its alternate screen and missed nothing
  /// else (the program was full screen the whole time).
  static func alternateRepaint(_ snap: TmuxSnapshot, rows: Int, modes: TmuxTrackedModes) -> [UInt8] {
    var out = bytes("\u{1b}[0m\u{1b}[r\u{1b}[H\u{1b}[2J")
    out += _alternateRows(snap.screen, rows: rows)
    out += _tail(snap, rows: rows, modes: modes)
    return out
  }

  // The primary screen's part: `lines` then the screen rows (the saved normal screen while the pane is
  // on its alternate one), starting at the home position of an empty screen. The first `rows` lines
  // fill it, every later one scrolls the top into the scrollback, so the screen ends up holding exactly
  // the last `rows` lines written: the pane's own screen.
  // `eraseRows`: the rows written over may still hold something (a refill that continues below the
  // cursor), so each is erased before it is written.
  private static func _primary(_ snap: TmuxSnapshot, lines: [[UInt8]], rows: Int, eraseRows: Bool = false) -> [UInt8] {
    var all = lines
    var screen = (snap.state.alternateOn ? snap.savedNormal : snap.screen).map(trimTrailingSpaces)
    // A pane taller than this terminal: its top rows belong to the scrollback here.
    if rows > 0, screen.count > rows {
      all += screen.prefix(screen.count - rows)
      screen = Array(screen.suffix(rows))
    }
    all += screen
    var out = [UInt8]()
    for (i, line) in all.enumerated() {
      if i > 0 { out += bytes("\r\n") }
      out += bytes(eraseRows ? "\u{1b}[0m\u{1b}[2K" : "\u{1b}[0m")
      out += line
    }
    out += bytes("\u{1b}[0m")
    if snap.state.alternateOn {
      let shift = max(0, snap.state.height - rows)
      let y = max(0, snap.state.alternateSavedY - shift)
      out += bytes("\u{1b}[\(y + 1);\(snap.state.alternateSavedX + 1)H\u{1b}[?1049h")
      out += _alternateRows(snap.screen, rows: rows)
    }
    return out
  }

  private static func _alternateRows(_ screen: [[UInt8]], rows: Int) -> [UInt8] {
    var out = [UInt8]()
    let shown = rows > 0 && screen.count > rows ? Array(screen.suffix(rows)) : screen
    for (i, row) in shown.enumerated() {
      out += bytes("\u{1b}[\(i + 1);1H\u{1b}[0m")
      out += row
    }
    out += bytes("\u{1b}[0m")
    return out
  }

  // Cursor, then every mode a program may have set that the terminal would otherwise not know about.
  private static func _tail(_ snap: TmuxSnapshot, rows: Int, modes: TmuxTrackedModes) -> [UInt8] {
    let s = snap.state
    let shift = max(0, s.height - rows)
    let cup = "\u{1b}[\(max(0, s.cursorY - shift) + 1);\(s.cursorX + 1)H"
    var out = [UInt8]()
    if s.scrollUpper != 0 || s.scrollLower != s.height - 1 {
      out += bytes("\u{1b}[\(max(0, s.scrollUpper - shift) + 1);\(max(0, s.scrollLower - shift) + 1)r")
    }
    out += bytes(cup)
    out += bytes(s.appCursorKeys ? "\u{1b}[?1h" : "\u{1b}[?1l")
    out += bytes(s.appKeypad ? "\u{1b}=" : "\u{1b}>")
    if !s.cursorVisible { out += bytes("\u{1b}[?25l") }
    if !s.wrap { out += bytes("\u{1b}[?7l") }
    if s.insertMode { out += bytes("\u{1b}[4h") }
    if s.mouseStandard { out += bytes("\u{1b}[?1000h") }
    if s.mouseButton { out += bytes("\u{1b}[?1002h") }
    if modes.mouseAnyMotion { out += bytes("\u{1b}[?1003h") }
    if s.mouseUTF8 { out += bytes("\u{1b}[?1005h") }
    if s.mouseSGR { out += bytes("\u{1b}[?1006h") }
    if modes.bracketedPaste { out += bytes("\u{1b}[?2004h") }
    out += snap.pendingEscape
    return out
  }

  /// Trailing blanks are padding (tmux keeps them for joined lines and with -N); painted, they could
  /// make hterm wrap a line the pane did not wrap and they end up in every copy. Only plain spaces at
  /// the very end, and only while the pen is the default one: blanks after a background colour are a
  /// painted bar, not padding.
  static func trimTrailingSpaces(_ line: [UInt8]) -> [UInt8] {
    var end = line.count
    while end > 0 && line[end - 1] == 0x20 { end -= 1 }
    guard end < line.count else { return line }
    if let escape = line[0..<end].lastIndex(of: 0x1B) {
      // The last escape before the blanks must be an SGR that leaves the background default.
      guard escape + 1 < end, line[escape + 1] == 0x5B,
            let final = line[(escape + 2)..<end].firstIndex(where: { $0 >= 0x40 && $0 <= 0x7E }),
            line[final] == 0x6D else { return line }
      let params = String(decoding: line[(escape + 2)..<final], as: UTF8.self)
      guard ["", "0", "39", "49", "39;49", "49;39", "0;39;49"].contains(params) else { return line }
    }
    return Array(line[0..<end])
  }

  // MARK: - Overlap

  /// Where the history the terminal has not seen starts: right after the LAST place the terminal's own
  /// final scrolled-off lines (`localTail`, oldest first) appear in tmux's plain history. Nil when they
  /// do not appear (too much happened, a different session, a reflow): the caller falls back to a full
  /// refill. An empty tail means the terminal banked nothing yet, so all of tmux's history is new.
  static func newHistoryStart(localTail: [String], remotePlain: [[UInt8]]) -> Int? {
    let tail = localTail.map(_normalized)
    guard !tail.isEmpty else { return 0 }
    let remote = remotePlain.map { _normalized(String(decoding: $0, as: UTF8.self)) }
    guard remote.count >= tail.count else { return nil }
    // A tail of only blank lines matches anywhere: not evidence of anything.
    guard tail.contains(where: { !$0.isEmpty }) else { return nil }
    var start = remote.count - tail.count
    while start >= 0 {
      if Array(remote[start..<(start + tail.count)]) == tail {
        return start + tail.count
      }
      start -= 1
    }
    return nil
  }

  private static func _normalized(_ s: String) -> String {
    var t = s
    while let last = t.last, last == " " || last == "\t" { t.removeLast() }
    return t
  }
}

/// Drops the screen-style title sequence (ESC k <name> ESC \\) from a pane's output. Shells set it
/// whenever TERM says screen or tmux, and a tmux client turns it into the window's name; a terminal
/// that does not know it prints the name as text, which also throws readline's idea of the cursor
/// column off. A sequence split between chunks is carried over.
struct TmuxTitleFilter {
  private enum State { case normal, escape, title, titleEscape }
  private var state = State.normal
  private var titleLength = 0

  mutating func filter(_ bytes: [UInt8]) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(bytes.count + 1)
    for b in bytes {
      switch state {
      case .normal:
        if b == 0x1B { state = .escape } else { out.append(b) }
      case .escape:
        if b == 0x6B {
          state = .title
          titleLength = 0
        } else if b == 0x1B {
          out.append(0x1B)
        } else {
          out.append(0x1B)
          out.append(b)
          state = .normal
        }
      case .title, .titleEscape:
        titleLength += 1
        if state == .titleEscape {
          state = b == 0x5C ? .normal : (b == 0x1B ? .titleEscape : .title)
        } else if b == 0x1B {
          state = .titleEscape
        } else if b == 0x07 {
          state = .normal
        } else if titleLength > 512 {
          // Never a title that long: stop swallowing output.
          state = .normal
        }
      }
    }
    return out
  }
}

/// Follows the DEC private modes tmux has no format for, as the pane's output streams by. A sequence
/// split between two chunks is carried over.
struct TmuxModeTracker {
  private(set) var modes = TmuxTrackedModes()
  private var carry: [UInt8] = []

  init(_ modes: TmuxTrackedModes = TmuxTrackedModes()) {
    self.modes = modes
  }

  mutating func scan(_ bytes: [UInt8]) {
    let data = carry.isEmpty ? bytes : carry + bytes
    carry = []
    var i = 0
    let n = data.count
    while i < n {
      guard data[i] == 0x1B else { i += 1; continue }
      // ESC [ ? <digits;digits> h|l
      if i + 2 >= n {
        carry = Array(data[i...])
        return
      }
      guard data[i + 1] == 0x5B, data[i + 2] == 0x3F else { i += 1; continue }
      var j = i + 3
      var params: [Int] = []
      var current = 0
      var hasDigit = false
      while j < n, (data[j] >= 0x30 && data[j] <= 0x39) || data[j] == 0x3B {
        if data[j] == 0x3B {
          params.append(current); current = 0; hasDigit = false
        } else {
          current = current * 10 + Int(data[j] - 0x30); hasDigit = true
          if current > 100000 { break }
        }
        j += 1
      }
      if j >= n {
        // Cut short by the end of the chunk; keep it unless it is absurdly long.
        if n - i < 32 { carry = Array(data[i...]) }
        return
      }
      if hasDigit { params.append(current) }
      let final = data[j]
      if final == 0x68 || final == 0x6C {
        let on = final == 0x68
        for p in params {
          switch p {
          case 2004: modes.bracketedPaste = on
          case 1003: modes.mouseAnyMotion = on
          default: break
          }
        }
      }
      i = j + 1
    }
  }

  /// A full reset of the terminal (RIS) or the pane being replaced: start over.
  mutating func reset(_ modes: TmuxTrackedModes) {
    self.modes = modes
    carry = []
  }
}
