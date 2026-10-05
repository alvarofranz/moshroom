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


// Pure parser for the tmux control-mode protocol (no I/O).
//
// What the wire looks like (measured against tmux 3.2a, `tmux -u -C` over an SSH exec channel, no PTY):
// - Every line ends in a bare \n. A pane's output is escaped (bytes below 0x20 and `\` as \ooo octal,
//   everything else raw, UTF-8 included), so a \n never appears inside it and splitting on \n is safe.
// - A command's reply is a block: `%begin <time> <num> <flags>`, the reply lines, then `%end` or
//   `%error` with the SAME three words. Reply lines are NOT escaped (a capture carries raw ESC), so a
//   block only closes on its own guard: a captured row may itself start with "%end".
// - Everything else that starts with `%` outside a block is a notification. One exception was seen:
//   `refresh-client -A '%p:continue'` prints `%continue %p` INSIDE its own block. It stays a reply line
//   here; the gateway knows what it asked for.
// - Lines outside the protocol (the remote shell talking before tmux starts) come out as `.text`.

import Foundation

/// One command's reply block.
struct TmuxReply {
  let isError: Bool
  let lines: [[UInt8]]
  /// The command never ran: an earlier command on its line failed and tmux skipped the rest, or the
  /// connection went away first.
  let skipped: Bool

  init(isError: Bool, lines: [[UInt8]], skipped: Bool = false) {
    self.isError = isError
    self.lines = lines
    self.skipped = skipped
  }

  static let skippedReply = TmuxReply(isError: true, lines: [], skipped: true)

  var text: String {
    lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
  }
}

enum TmuxEvent {
  case reply(TmuxReply)
  /// `%output` and `%extended-output`, already decoded to the pane's raw bytes.
  case output(pane: Int, bytes: [UInt8])
  case pause(pane: Int)
  case resume(pane: Int)
  /// `%exit [reason]`. tmux 3.2a sends it bare both when this client is detached and when the session
  /// ends, so the reason alone cannot tell the two apart.
  case exit(reason: String?)
  /// `%layout-change @w <layout> ...`: the layout's own width and height are what matter here.
  case layoutChange(window: String, width: Int, height: Int)
  case windowPaneChanged(window: String, pane: Int)
  case sessionWindowChanged(session: String, window: String)
  case sessionChanged(session: String, name: String)
  case windowAdd(window: String)
  case windowClose(window: String)
  case paneModeChanged(pane: Int)
  /// Every other notification (`%sessions-changed`, `%window-renamed`, `%message`, ...).
  case notification(name: String, rest: String)
  /// A line outside the protocol.
  case text(String)
}

final class TmuxControlParser {
  private var pending: [UInt8] = []
  private var blockGuard: [UInt8]? = nil
  private var blockLines: [[UInt8]] = []

  /// Bytes that are not a whole line yet.
  var hasPartialLine: Bool { !pending.isEmpty }

  func feed<C: Collection>(_ bytes: C, emit: (TmuxEvent) -> Void) where C.Element == UInt8 {
    pending.append(contentsOf: bytes)
    var start = 0
    let count = pending.count
    var i = 0
    pending.withUnsafeBufferPointer { buf in
      while i < count {
        if buf[i] == 0x0A {
          var end = i
          if end > start && buf[end - 1] == 0x0D {
            end -= 1
          }
          _line(buf[start..<end], emit: emit)
          start = i + 1
        }
        i += 1
      }
    }
    if start > 0 {
      pending.removeFirst(start)
    }
  }

  private func _line(_ line: Slice<UnsafeBufferPointer<UInt8>>, emit: (TmuxEvent) -> Void) {
    if let guardWords = blockGuard {
      if let (kind, rest) = Self._keyword(line), kind == "end" || kind == "error", Array(rest) == guardWords {
        let reply = TmuxReply(isError: kind == "error", lines: blockLines)
        blockGuard = nil
        blockLines = []
        emit(.reply(reply))
      } else {
        blockLines.append(Array(line))
      }
      return
    }

    guard let (name, rest) = Self._keyword(line) else {
      emit(.text(String(decoding: line, as: UTF8.self)))
      return
    }

    switch name {
    case "begin":
      blockGuard = Array(rest)
      blockLines = []
    case "output":
      // %output %<pane> <data>
      guard let (pane, data) = Self._paneAndRest(rest) else { return }
      emit(.output(pane: pane, bytes: Self.decodeOctal(data)))
    case "extended-output":
      // %extended-output %<pane> <age> ... : <data>
      guard let (pane, after) = Self._paneAndRest(rest) else { return }
      guard let colon = Self._find(" : ", in: after) else {
        // A notification with nothing after its arguments carries no data.
        return
      }
      emit(.output(pane: pane, bytes: Self.decodeOctal(after[(colon + 3)...])))
    case "pause":
      if let pane = Self._pane(rest) { emit(.pause(pane: pane)) }
    case "continue":
      if let pane = Self._pane(rest) { emit(.resume(pane: pane)) }
    case "exit":
      let reason = String(decoding: rest, as: UTF8.self).trimmingCharacters(in: .whitespaces)
      emit(.exit(reason: reason.isEmpty ? nil : reason))
    case "layout-change":
      let words = Self._words(rest)
      guard words.count >= 2 else { return }
      let (w, h) = Self._layoutSize(words[1])
      emit(.layoutChange(window: words[0], width: w, height: h))
    case "window-pane-changed":
      let words = Self._words(rest)
      if words.count >= 2, let pane = Self._paneNumber(words[1]) {
        emit(.windowPaneChanged(window: words[0], pane: pane))
      }
    case "session-window-changed":
      let words = Self._words(rest)
      if words.count >= 2 { emit(.sessionWindowChanged(session: words[0], window: words[1])) }
    case "session-changed":
      let words = Self._words(rest)
      if words.count >= 2 { emit(.sessionChanged(session: words[0], name: words[1...].joined(separator: " "))) }
    case "window-add":
      emit(.windowAdd(window: String(decoding: rest, as: UTF8.self)))
    case "window-close", "unlinked-window-close":
      emit(.windowClose(window: String(decoding: rest, as: UTF8.self)))
    case "pane-mode-changed":
      if let pane = Self._pane(rest) { emit(.paneModeChanged(pane: pane)) }
    default:
      emit(.notification(name: name, rest: String(decoding: rest, as: UTF8.self)))
    }
  }

  // MARK: - Helpers

  /// `%name rest` -> ("name", rest). Nil for a line that does not start with `%<letter>`.
  private static func _keyword<C: Collection>(_ line: C) -> (String, C.SubSequence)? where C.Element == UInt8, C.Index == Int {
    guard let first = line.first, first == 0x25 else { return nil }
    let afterPercent = line.index(after: line.startIndex)
    guard afterPercent < line.endIndex, (0x61...0x7A).contains(line[afterPercent]) else { return nil }
    var end = afterPercent
    while end < line.endIndex && line[end] != 0x20 {
      end += 1
    }
    let name = String(decoding: line[afterPercent..<end], as: UTF8.self)
    let restStart = end < line.endIndex ? end + 1 : end
    return (name, line[restStart..<line.endIndex])
  }

  private static func _paneAndRest<C: Collection>(_ rest: C) -> (Int, C.SubSequence)? where C.Element == UInt8, C.Index == Int {
    guard let space = rest.firstIndex(of: 0x20) else {
      if let pane = _paneNumber(String(decoding: rest, as: UTF8.self)) {
        return (pane, rest[rest.endIndex..<rest.endIndex])
      }
      return nil
    }
    guard let pane = _paneNumber(String(decoding: rest[rest.startIndex..<space], as: UTF8.self)) else { return nil }
    return (pane, rest[(space + 1)..<rest.endIndex])
  }

  private static func _pane<C: Collection>(_ rest: C) -> Int? where C.Element == UInt8 {
    _paneNumber(String(decoding: rest, as: UTF8.self).trimmingCharacters(in: .whitespaces))
  }

  /// "%12" -> 12.
  static func _paneNumber(_ word: String) -> Int? {
    guard word.hasPrefix("%") else { return nil }
    return Int(word.dropFirst())
  }

  private static func _words<C: Collection>(_ rest: C) -> [String] where C.Element == UInt8 {
    String(decoding: rest, as: UTF8.self).split(separator: " ").map(String.init)
  }

  /// A layout string starts "csum,WxH,x,y...": its size is the whole window's.
  static func _layoutSize(_ layout: String) -> (Int, Int) {
    let parts = layout.split(separator: ",")
    guard parts.count >= 2 else { return (0, 0) }
    let wh = parts[1].split(separator: "x")
    guard wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]) else { return (0, 0) }
    return (w, h)
  }

  private static func _find<C: Collection>(_ needle: String, in hay: C) -> Int? where C.Element == UInt8, C.Index == Int {
    let n = Array(needle.utf8)
    guard hay.count >= n.count else { return nil }
    var i = hay.startIndex
    let last = hay.endIndex - n.count
    while i <= last {
      if hay[i] == n[0] && hay[i..<(i + n.count)].elementsEqual(n) {
        return i
      }
      i += 1
    }
    return nil
  }

  /// tmux escapes bytes below 0x20 and the backslash itself as \ooo (three octal digits). Anything
  /// that is not exactly that is kept as it came.
  static func decodeOctal<C: Collection>(_ data: C) -> [UInt8] where C.Element == UInt8, C.Index == Int {
    var out = [UInt8]()
    out.reserveCapacity(data.count)
    var i = data.startIndex
    let end = data.endIndex
    while i < end {
      let b = data[i]
      if b == 0x5C, i + 3 < end {
        let d1 = data[i + 1], d2 = data[i + 2], d3 = data[i + 3]
        if (0x30...0x37).contains(d1), (0x30...0x37).contains(d2), (0x30...0x37).contains(d3) {
          out.append(UInt8(truncatingIfNeeded: (Int(d1 - 0x30) << 6) | (Int(d2 - 0x30) << 3) | Int(d3 - 0x30)))
          i += 4
          continue
        }
      }
      out.append(b)
      i += 1
    }
    return out
  }
}
