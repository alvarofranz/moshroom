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
import MoshroomConfig

// Mirrors the local SSH-hosts blob (`~/.moshroom/hosts`) to and from iCloud Drive while
// "Sync with iCloud" is on. The local file stays the synchronous, authoritative source the
// connect path reads — iCloud Drive is a background mirror.
//
// Sync model — safe by construction, a conflict can never lose data:
// - Normal case: whole-file newest-wins by modification date. Edits AND deletions propagate,
//   because only one side changed since this device last synced.
// - True conflict (BOTH the local file and the cloud copy changed since this device's last
//   sync, or iCloud itself forked the file into unresolved versions): the host lists are
//   MERGED — union by alias; where the same alias was edited on both sides, the entry with
//   the newer per-host `lastModified` wins. Worst case a host deleted on one device while
//   edited on another comes back — never the other way around.
// - iCloud's own NSFileVersion conflicts are folded into the same merge, then marked resolved.
//
// Self-installs once (`install()` from AppDelegate): reconciles when hosts are saved
// (`MoshroomHostsDidSave`), on every foreground and at launch, and on demand via `syncNow()`.
// `isSyncing` + `lastSyncDate` + `syncStateNotification` drive the Settings row. All file work
// runs off the main thread with NSFileCoordinator; the only main-thread step is reloading
// `MoshHosts` after the local file changed.
@objc final class HostsCloudMirror: NSObject {

  // Posted by MoshHosts after the local hosts file is written (kept in sync with MoshHosts.m).
  static let didSaveNotification = Notification.Name("MoshroomHostsDidSave")
  // Posted (main thread) after a reconcile replaced the local hosts — open UI can refresh off it.
  static let didChangeNotification = Notification.Name("MoshroomHostsDidChangeFromICloud")
  // Posted (main thread) whenever `isSyncing` flips or a sync finishes — the Settings row observes.
  static let syncStateNotification = Notification.Name("MoshroomCloudSyncStateChanged")

  private static let queue = DispatchQueue(label: "moshroom.hosts.cloudmirror", qos: .utility)
  private static var installed = false

  // MARK: - Sync status (read by Settings)

  private static let lastSyncKey = "MoshroomCloudLastSyncDate"
  private static let markerLocalKey = "MoshroomCloudLastSyncedLocalDate"
  private static let markerCloudKey = "MoshroomCloudLastSyncedCloudDate"

  // When this device last completed a successful reconcile (any direction, including no-op).
  @objc static var lastSyncDate: Date? {
    UserDefaults.standard.object(forKey: lastSyncKey) as? Date
  }

  private static let lastSummaryKey = "MoshroomCloudLastSyncSummary"

  // One honest line about the last pass — "2 hosts · 14 snips · sent to iCloud", or the problem
  // that stopped it. The Settings row shows it so you can SEE what sync saw.
  @objc static var lastSyncSummary: String? {
    UserDefaults.standard.string(forKey: lastSummaryKey)
  }

  private static func _setSummary(_ text: String) {
    UserDefaults.standard.set(text, forKey: lastSummaryKey)
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: syncStateNotification, object: nil)
    }
  }

  @objc private(set) static var isSyncing = false   // main-thread value, drives "Syncing…"

  private static func _setSyncing(_ on: Bool) {
    DispatchQueue.main.async {
      guard isSyncing != on else { return }
      isSyncing = on
      NotificationCenter.default.post(name: syncStateNotification, object: nil)
    }
  }

  private static func _markSynced(localDate: Date?, cloudDate: Date?) {
    let d = UserDefaults.standard
    d.set(Date(), forKey: lastSyncKey)
    d.set(localDate, forKey: markerLocalKey)
    d.set(cloudDate, forKey: markerCloudKey)
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: syncStateNotification, object: nil)
    }
  }

  // MARK: - Lifecycle

  @objc static func install() {
    guard !installed else { return }
    installed = true
    // The connect path reads the generated ssh_config, not the hosts blob. Regenerate it once at
    // launch so it always matches the persisted hosts — this covers a host that arrived via an
    // iCloud pull (or state restoration) on a device that never saved one locally, whose
    // ssh_config would otherwise be stale/empty and make the connection die with
    // "Socket error: No such file or directory" (hostName falls back to the alias).
    MoshHosts.saveAllToSSHConfig()
    let nc = NotificationCenter.default
    nc.addObserver(forName: didSaveNotification, object: nil, queue: nil) { _ in reconcile() }
    nc.addObserver(forName: UIScene.willEnterForegroundNotification, object: nil, queue: nil) { _ in
      reconcile()
    }
    reconcile()   // launch pass
  }

  // The Settings "Sync Now": a full reconcile, plus a download nudge for the snips folder
  // (snips are a plain iCloud Drive folder — iOS syncs it; we can only ask it to hurry).
  @objc static func syncNow() {
    if let snips = MoshroomPaths.iCloudSnippetsLocationURL() {
      try? FileManager.default.startDownloadingUbiquitousItem(at: snips)
    }
    reconcile()
  }

  // Sync is on AND iCloud Drive is reachable for this account.
  private static var isActive: Bool {
    MoshroomDefaults.isICloudSyncEnabled() && FileManager.default.ubiquityIdentityToken != nil
  }

  private static var localURL: URL {
    URL(fileURLWithPath: MoshroomPaths.moshroomHostsFile())
  }

  // MARK: - Reconcile (the one sync path)

  @objc static func reconcile() {
    guard isActive else { return }
    guard let cloudURL = MoshroomPaths.iCloudHostsLocationURL() else {
      // The single most diagnostic failure: iCloud Drive off (globally or for Moshroom) or no account.
      _setSummary("iCloud container unavailable — check iCloud Drive is on for Moshroom")
      return
    }
    let local = localURL
    _setSyncing(true)
    queue.async {
      defer { _setSyncing(false) }
      try? FileManager.default.startDownloadingUbiquitousItem(at: cloudURL)

      // iCloud forked the file? Collect every unresolved sibling for the merge below.
      let conflictVersions = NSFileVersion.unresolvedConflictVersionsOfItem(at: cloudURL) ?? []
      let conflictData = conflictVersions.compactMap { try? Data(contentsOf: $0.url) }

      var cloud: (data: Data, date: Date)?
      var coordError: NSError?
      NSFileCoordinator().coordinate(readingItemAt: cloudURL, options: [], error: &coordError) { src in
        guard FileManager.default.fileExists(atPath: src.path),
              let date = modificationDate(of: src),
              let data = try? Data(contentsOf: src) else { return }
        cloud = (data, date)
      }

      let localData = try? Data(contentsOf: local)
      let localDate = modificationDate(of: local)
      let defaults = UserDefaults.standard
      let markerLocal = defaults.object(forKey: markerLocalKey) as? Date
      let markerCloud = defaults.object(forKey: markerCloudKey) as? Date

      func changed(_ date: Date?, since marker: Date?) -> Bool {
        guard let date else { return false }
        guard let marker else { return true }        // first sync: treat as changed → merge (safe)
        return date.timeIntervalSince(marker) > 0.5  // mtimes are stamped equal after each sync
      }

      var flavor = ""   // appended to the counts — how this pass ended
      switch (localData, cloud) {
      case (nil, nil):
        flavor = " · nothing to sync yet"
        _markSynced(localDate: nil, cloudDate: nil)

      case (let l?, nil):
        // Nothing in the cloud yet — publish the local file.
        writeCloud(l, to: cloudURL, stamp: localDate)
        flavor = " · sent to iCloud"
        _markSynced(localDate: localDate, cloudDate: localDate)

      case (nil, let c?):
        // Nothing local yet — adopt the cloud copy.
        adoptLocally(c.data, stamp: c.date, at: local)
        flavor = " · fetched from iCloud"
        _markSynced(localDate: c.date, cloudDate: c.date)

      case (let l?, let c?):
        if l == c.data && conflictData.isEmpty {
          flavor = " · up to date"
          _markSynced(localDate: localDate, cloudDate: c.date)
          break
        }
        let localChanged = changed(localDate, since: markerLocal)
        let cloudChanged = changed(c.date, since: markerCloud)

        // Safety valves. Plain newest-wins is how edits and deletions propagate, but two shapes
        // are far more likely a half-initialized or divergent sibling (fresh install, broken or
        // partial transport) than a real user action — those go through the merge, whose union
        // keeps the data:
        //  - an empty list replacing a non-empty one ("delete everything" doesn't propagate;
        //    redoing that by hand is trivial, losing every host silently is not);
        //  - adopting a cloud list that would silently drop more than half of this device's hosts.
        let localList = decode(l)
        let cloudList = decode(c.data)
        let emptyClobber =
          (cloudChanged && (cloudList?.isEmpty ?? false) && !(localList?.isEmpty ?? true)) ||
          (localChanged && (localList?.isEmpty ?? false) && !(cloudList?.isEmpty ?? true))
        let shrinkClobber = cloudChanged && !localChanged
          && (localList?.count ?? 0) >= 2
          && (cloudList?.count ?? 0) * 2 < (localList?.count ?? 0)

        if (localChanged && cloudChanged) || !conflictData.isEmpty || emptyClobber || shrinkClobber {
          // True conflict → merge every dataset we can see. Local first, so ties keep local.
          let merged = merge(datasets: [l, c.data] + conflictData)
          guard let data = encode(merged) else { break }   // never write anything we can't encode
          let now = Date()
          try? data.write(to: local, options: .atomic)
          try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: local.path)
          writeCloud(data, to: cloudURL, stamp: now)
          conflictVersions.forEach { $0.isResolved = true }
          try? NSFileVersion.removeOtherVersionsOfItem(at: cloudURL)
          flavor = " · merged both sides"
          _markSynced(localDate: now, cloudDate: now)
          DispatchQueue.main.async {
            MoshHosts.loadHosts()
            // The connect path reads the generated ssh_config, NOT the hosts blob — regenerate it
            // from the freshly-merged list or a synced host can't be reached (hostName falls back
            // to the alias → getaddrinfo fails with "Socket error: No such file or directory").
            MoshHosts.saveAllToSSHConfig()
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
          }
        } else if cloudChanged {
          adoptLocally(c.data, stamp: c.date, at: local)
          flavor = " · fetched from iCloud"
          _markSynced(localDate: c.date, cloudDate: c.date)
        } else if localChanged {
          writeCloud(l, to: cloudURL, stamp: localDate)
          flavor = " · sent to iCloud"
          _markSynced(localDate: localDate, cloudDate: localDate)
        } else {
          flavor = " · up to date"
          _markSynced(localDate: localDate, cloudDate: c.date)
        }
      }

      // Materialize snips that arrived from another device (they land as placeholders until
      // something asks for them), count what's visible, and publish the honest readout.
      let snips = _downloadAndCountSnips()
      DispatchQueue.main.async {
        // Runs after any adopt/merge reload enqueued above — counts are the fresh, post-sync truth.
        let hosts = MoshHosts.allHosts().count
        _setSummary("\(hosts) host\(hosts == 1 ? "" : "s") · \(snips) snip\(snips == 1 ? "" : "s")\(flavor)")
      }
    }
  }

  // Nudge every file in the iCloud snips folder to download and count what's there.
  private static func _downloadAndCountSnips() -> Int {
    guard let snips = MoshroomPaths.iCloudSnippetsLocationURL() else { return 0 }
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: snips, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
    var count = 0
    for case let url as URL in enumerator {
      if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
      try? fm.startDownloadingUbiquitousItem(at: url)
      count += 1
    }
    return count
  }

  // MARK: - Merge (union by alias, newest per-host lastModified wins)

  private static func decode(_ data: Data) -> [MoshHosts]? {
    try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: MoshHosts.self, from: data)
  }

  private static func encode(_ hosts: [MoshHosts]) -> Data? {
    try? NSKeyedArchiver.archivedData(withRootObject: hosts as NSArray, requiringSecureCoding: true)
  }

  private static func merge(datasets: [Data]) -> [MoshHosts] {
    var byAlias: [String: MoshHosts] = [:]
    var order: [String] = []   // first-seen order (local dataset comes first) — stable output
    for data in datasets {
      guard let hosts = decode(data) else { continue }   // an unreadable side can't erase the other
      for host in hosts {
        guard let alias = host.host, !alias.isEmpty else { continue }
        if let existing = byAlias[alias] {
          let a = existing.lastModified ?? .distantPast
          let b = host.lastModified ?? .distantPast
          if b > a { byAlias[alias] = host }             // strictly newer wins; ties keep first (local)
        } else {
          byAlias[alias] = host
          order.append(alias)
        }
      }
    }
    return order.compactMap { byAlias[$0] }
  }

  // MARK: - File helpers

  // Replace the local blob and reload MoshHosts on main. Stamping the cloud's date keeps the next
  // comparison stable (no re-pull loop).
  private static func adoptLocally(_ data: Data, stamp: Date?, at local: URL) {
    guard (try? data.write(to: local, options: .atomic)) != nil else { return }
    if let stamp {
      try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: local.path)
    }
    DispatchQueue.main.async {
      MoshHosts.loadHosts()
      // The connect path reads the generated ssh_config, NOT the hosts blob — regenerate it from
      // the just-adopted list. Without this a device that only ever RECEIVED hosts over iCloud (and
      // never saved one locally) has a stale/empty ssh_config, so `mosh <alias>`/`ssh <alias>`
      // resolves nothing and hostName falls back to the alias → "Socket error: No such file or
      // directory". (saveHost regenerates it locally; a pull never went through saveHost.)
      MoshHosts.saveAllToSSHConfig()
      NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
  }

  // Coordinated replace of the cloud copy, stamped with the given date so no device pulls back
  // its own push.
  private static func writeCloud(_ data: Data, to cloudURL: URL, stamp: Date?) {
    var coordError: NSError?
    NSFileCoordinator().coordinate(writingItemAt: cloudURL, options: .forReplacing, error: &coordError) { dst in
      try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
      guard (try? data.write(to: dst, options: .atomic)) != nil else { return }
      if let stamp {
        try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: dst.path)
      }
    }
  }

  private static func modificationDate(of url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }
}
