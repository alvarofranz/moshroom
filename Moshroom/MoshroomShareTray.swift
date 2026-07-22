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
//
// The Share tray: a small persistent inbox living in the shared App Group container.
//
// The Moshroom share extension (a SEPARATE process, no terminal / no connection required) drops
// images shared to Moshroom here. Later — whenever you want, on any tab — the Moshkitor composer
// surfaces the tray as a grid and lets you drop one inline exactly like a paste, deleting it from
// the tray as it goes (a shared screenshot is a one-shot; there's no point keeping it around).
//
// This file compiles into BOTH the app and the extension. It resolves the shared container from the
// `MOSHROOM_GROUP_ID` Info.plist key, which is present in both bundles (the app's Info.plist and the
// extension's), so there is ONE code path and no framework dependency the extension would have to
// drag in. Every operation degrades gracefully to a no-op if the container can't be resolved.
//
////////////////////////////////////////////////////////////////////////////////

import Foundation

enum MoshroomShareTray {

  private static let folderName = "share-inbox"

  /// `group.<GROUP_ID>` read from THIS bundle's Info.plist — the app bundle in the app process, the
  /// extension bundle in the extension process. Both carry `MOSHROOM_GROUP_ID = $(GROUP_ID)`.
  private static func fullGroupID() -> String? {
    guard let gid = Bundle.main.object(forInfoDictionaryKey: "MOSHROOM_GROUP_ID") as? String,
          !gid.isEmpty else { return nil }
    return "group.\(gid)"
  }

  /// The tray directory inside the shared App Group container (created on demand). `nil` when the
  /// container can't be resolved (a misconfigured entitlement) — callers treat that as an empty tray.
  static func directory() -> URL? {
    guard let group = fullGroupID(),
          let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    else { return nil }
    let dir = container.appendingPathComponent(folderName, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Every tray item, newest first (the most recent share leads). Regular files only.
  static func items() -> [URL] {
    guard let dir = directory() else { return [] }
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
    guard let urls = try? FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
    return urls
      .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
      .sorted { a, b in
        let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return da > db
      }
  }

  static func count() -> Int { items().count }
  static func isEmpty() -> Bool { count() == 0 }

  /// Copy a file into the tray under a fresh unique name, keeping a clean extension. Used by the
  /// share extension when iOS hands it a file URL. Returns the new tray URL, or `nil` on failure.
  @discardableResult
  static func add(fileAt source: URL, preferredExtension ext: String? = nil) -> URL? {
    guard let dir = directory() else { return nil }
    let dest = dir.appendingPathComponent(_uniqueName(ext: ext ?? source.pathExtension))
    // Copy to a hidden temp name, then atomically rename into place — the app (a separate process)
    // must never list a half-written tray file. The temp is hidden so a mid-copy listing skips it.
    let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
    do {
      try FileManager.default.copyItem(at: source, to: tmp)
      try FileManager.default.moveItem(at: tmp, to: dest)
      return dest
    } catch {
      try? FileManager.default.removeItem(at: tmp)
      return nil
    }
  }

  /// Write raw bytes into the tray. Used by the share extension when it only has in-memory data.
  @discardableResult
  static func add(data: Data, preferredExtension ext: String) -> URL? {
    guard let dir = directory() else { return nil }
    let dest = dir.appendingPathComponent(_uniqueName(ext: ext))
    do { try data.write(to: dest, options: .atomic); return dest }
    catch { return nil }
  }

  /// Remove one item. Scoped hard to the tray dir so a stray URL can never walk a delete elsewhere.
  static func remove(_ url: URL) {
    guard let dir = directory(),
          url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL else { return }
    try? FileManager.default.removeItem(at: url)
  }

  private static func _uniqueName(ext: String) -> String {
    let e = _cleanExt(ext)
    let id = UUID().uuidString
    return e.isEmpty ? id : "\(id).\(e)"
  }

  private static func _cleanExt(_ raw: String) -> String {
    let cleaned = raw.lowercased().filter { ($0.isLetter || $0.isNumber) && $0.isASCII }
    return String(cleaned.prefix(8))
  }
}
