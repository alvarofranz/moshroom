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
import UIKit

// MARK: - MoshLog: the on-device diagnostic log
//
// A small, always-on, privacy-safe log so that when something misbehaves on a real device we
// already have a trace — no rebuild, no attaching a debugger. Export it from
// Settings → About & Support → Export Logs (a share sheet on the file); on the Mac read it directly
// in the app container at Library/Application Support/Moshroom/moshroom.log.
//
// Where: the app's OWN Library/Application Support (never the user-visible Documents), excluded from
// iCloud backup. Bounded: once the file passes `maxBytes` it is trimmed back to the last
// `trimToBytes` (on a line boundary), so it keeps roughly the most recent activity and never grows
// without limit.
//
// PRIVACY CONTRACT — this ships to real users, so the log records DECISIONS and METADATA only, never
// secrets: no passwords, no key material, and never the text a user sends through the composer (it
// can contain secrets). Log lengths/counts/types/host aliases, not contents.

enum MoshLog {

  // Trim to the tail once the file grows past the cap. Trims happen rarely (only at the boundary),
  // so the amortized cost of logging stays near-zero.
  private static let maxBytes = 512 * 1024
  private static let trimToBytes = 256 * 1024

  // All file I/O is serialized here, off the caller's thread. `didBanner` and the formatter are only
  // ever touched on this queue, so they need no further locking.
  private static let queue = DispatchQueue(label: "com.alvarofranz.moshroom.moshlog", qos: .utility)
  private static var didBanner = false
  private static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
  }()

  // MARK: Public API

  /// Append one timestamped line under a short `tag` (e.g. "paste", "conn"). Thread-safe; returns
  /// immediately, the write runs on the log queue. The event time is captured now, not at write time.
  static func log(_ tag: String, _ message: String) {
    let now = Date()
    queue.async {
      _bannerIfNeeded()
      _write(formatter.string(from: now) + " [" + tag + "] " + message + "\n")
    }
  }

  /// The log file's location (its directory is created on demand, and marked excluded from backup).
  static var fileURL: URL {
    var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Moshroom", isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path) {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      var rv = URLResourceValues()
      rv.isExcludedFromBackup = true
      try? dir.setResourceValues(rv)
    }
    return dir.appendingPathComponent("moshroom.log")
  }

  /// Guarantee the file exists before it is handed to a share sheet, so exporting on a fresh install
  /// (nothing logged yet) still produces a real, openable file rather than a dead link.
  static func ensureFileExists() {
    let url = fileURL
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    queue.sync {
      _bannerIfNeeded()
      _write("(no events logged yet)\n")
    }
  }

  /// Empty the log (Settings action / before reproducing a bug). The next line re-prints the banner.
  static func clear() {
    queue.async {
      try? Data().write(to: fileURL)
      didBanner = false
    }
  }

  // MARK: Internals (log queue only)

  private static func _bannerIfNeeded() {
    guard !didBanner else { return }
    didBanner = true
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    let device = UIDevice.current
    let kind = ProcessInfo().isMacCatalystApp ? "Catalyst" : "iOS"
    _write("\n=== Moshroom \(version) (\(build)) · \(kind) · \(device.systemName) \(device.systemVersion) · session start ===\n")
  }

  private static func _write(_ line: String) {
    guard let data = line.data(using: .utf8) else { return }
    let url = fileURL
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url)
    }
    _trimIfNeeded(url)
  }

  private static func _trimIfNeeded(_ url: URL) {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? Int, size > maxBytes,
          let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }
    try? handle.seek(toOffset: UInt64(size - trimToBytes))
    guard var tail = try? handle.readToEnd() else { return }
    // Start on a clean line boundary so the first retained line isn't a fragment.
    if let nl = tail.firstIndex(of: 0x0A), tail.index(after: nl) < tail.endIndex {
      tail = tail.subdata(in: tail.index(after: nl)..<tail.endIndex)
    }
    var out = Data("…(older log lines trimmed)\n".utf8)
    out.append(tail)
    try? out.write(to: url)
  }
}
