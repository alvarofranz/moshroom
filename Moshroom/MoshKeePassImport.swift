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

import Foundation

// Parses a KeePass 2 XML export (File → Export → KeePass XML) into MoshVaultEntry records.
//
// The KeePass schema nests <Group>s, each holding <Entry>s; every entry carries a flat list of
// <String><Key>…</Key><Value>…</Value></String> pairs. The standard keys are Title / UserName /
// Password / URL / Notes (plugins add their own, e.g. "KPRPC JSON", which we ignore). Entries in
// the Recycle Bin group (identified by the Meta/RecycleBinUUID) are skipped — those are deletions.
//
// Streaming XMLParser on purpose: an export can be many MB / thousands of entries, and the secret
// values must never be materialised beyond the record they belong to. Nothing here logs or returns
// field VALUES anywhere except inside the produced MoshVaultEntry array.
enum MoshKeePassImport {

  enum ImportError: Error, LocalizedError {
    case unreadable
    case notKeePass
    var errorDescription: String? {
      switch self {
      case .unreadable: return "Could not read the file."
      case .notKeePass: return "This does not look like a KeePass XML export."
      }
    }
  }

  static func parse(data: Data) throws -> [MoshVaultEntry] {
    let delegate = _Delegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else { throw ImportError.unreadable }
    guard delegate.sawKeePassRoot else { throw ImportError.notKeePass }
    // Drop entries that live under the Recycle Bin group UUID (deleted items).
    let bin = delegate.recycleBinUUID
    return delegate.entries
      .filter { bin == nil || $0.groupUUID != bin }
      .map { $0.entry }
  }

  // MARK: - Streaming delegate

  private final class _Delegate: NSObject, XMLParserDelegate {
    private(set) var entries: [(entry: MoshVaultEntry, groupUUID: String?)] = []
    private(set) var recycleBinUUID: String?
    private(set) var sawKeePassRoot = false

    // Path of element names, so we know whether text belongs to Meta, a Group UUID, an Entry
    // String Key/Value, etc.
    private var stack: [String] = []
    private var text = ""

    // The stack of enclosing group UUIDs (KeePass nests groups); the innermost is the entry's group.
    private var groupUUIDStack: [String?] = []

    // Current entry being assembled.
    private var inEntry = false
    private var entrySkipDepth = 0        // >0 while inside <History> (past versions — not imported)
    private var curFields: [String: String] = [:]
    private var curKey: String?
    private var curValue: String?
    private var inString = false

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
      stack.append(name)
      text = ""

      switch name {
      case "KeePassFile":
        sawKeePassRoot = true
      case "Group":
        groupUUIDStack.append(nil)   // filled when the group's own <UUID> text arrives
      case "History":
        // Entries carry a <History> of past versions, each a full <Entry>. Skip that subtree.
        if inEntry { entrySkipDepth += 1 }
      case "Entry":
        if entrySkipDepth == 0 {
          inEntry = true
          curFields = [:]
        }
      case "String":
        if inEntry && entrySkipDepth == 0 { inString = true; curKey = nil; curValue = nil }
      default:
        break
      }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
      if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
      let value = text
      defer { stack.removeLast(); text = "" }

      switch name {
      case "UUID":
        // A group's UUID: the parent element is Group and we're not inside an Entry.
        if stack.count >= 2, stack[stack.count - 2] == "Group", !groupUUIDStack.isEmpty {
          groupUUIDStack[groupUUIDStack.count - 1] = value
        }
      case "RecycleBinUUID":
        // Lives under Meta; marks which group is the trash.
        if recycleBinUUID == nil { recycleBinUUID = value.isEmpty ? nil : value }
      case "Key":
        if inString { curKey = value }
      case "Value":
        if inString { curValue = value }
      case "String":
        if inString, let k = curKey { curFields[k] = curValue ?? "" }
        inString = false
      case "Entry":
        if inEntry && entrySkipDepth == 0 {
          let group = groupUUIDStack.last ?? nil
          entries.append((_entry(from: curFields), group))
          inEntry = false
        }
      case "History":
        if entrySkipDepth > 0 { entrySkipDepth -= 1 }
      case "Group":
        if !groupUUIDStack.isEmpty { groupUUIDStack.removeLast() }
      default:
        break
      }
    }

    private func _entry(from f: [String: String]) -> MoshVaultEntry {
      // KeePass has no dedicated email field — leave email empty and keep the username as-is.
      MoshVaultEntry(
        service: (f["Title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
        username: f["UserName"] ?? "",
        email: "",
        password: f["Password"] ?? "",
        notes: f["Notes"] ?? "",
        url: f["URL"] ?? ""
      )
    }
  }
}
