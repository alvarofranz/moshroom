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

// The iCloud Drive mirror. It keeps two local blobs — the SSH-hosts blob (`~/.moshroom/hosts`) and
// the keys-metadata blob (`~/.moshroom/keys`) — mirrored to and from iCloud Drive while
// "Sync with iCloud" is on. The local files stay the synchronous, authoritative source the connect
// path reads; iCloud Drive is a background mirror. (The class keeps its historical name; it now
// mirrors both datasets and drives the whole Settings sync readout.)
//
// Two independent transports carry a full backup across a user's devices:
//   1. This Drive mirror — the *metadata* (host configs; key public/type/storage records).
//   2. The iCloud Keychain — the *secrets* (host passwords, private key material), synced E2E by the
//      OS whenever the same toggle is on (see MoshHosts.m / MoshPubKey.m). Secure-Enclave keys are
//      hardware-bound and ride neither transport.
//
// Sync model — safe by construction, a conflict can never lose data:
// - Normal case: whole-projection newest-wins by modification date. Edits AND deletions propagate,
//   because only one side changed since this device last synced.
// - True conflict (BOTH sides changed since this device's last sync, or iCloud forked the file into
//   unresolved versions): the lists are MERGED — union by identity; where the same item was edited
//   on both sides, the entry with the newer per-item `lastModified` wins. Worst case a deletion on
//   one device loses to an edit on another — never the other way around.
//
// Keys are mirrored as a PROJECTION: only Keychain-backed keys travel (their private material rides
// the iCloud Keychain). Secure-Enclave / passkey / security keys are device- or provider-bound, so
// their metadata is never uploaded and — critically — the local device-only keys are always kept
// when a remote keys list is adopted or merged. A synced device therefore rebuilds its keys file as
// (its own device-only keys) + (the shared Keychain-key projection).
//
// Self-installs once (`install()` from AppDelegate): reconciles when either blob is saved
// (`MoshroomHostsDidSave` / `MoshroomKeysDidSave`), on every foreground and at launch, and on demand
// via `syncNow()`. `isSyncing` + `lastSyncDate` + `lastSyncSummary` + `syncStateNotification` drive
// the Settings row. All file work runs off the main thread with NSFileCoordinator; the only
// main-thread steps are reloading MoshHosts / MoshPubKey after a local file changed.
@objc final class HostsCloudMirror: NSObject {

  // Posted by MoshHosts / MoshPubKey after their local blob is written (kept in sync with the .m files).
  static let didSaveNotification = Notification.Name("MoshroomHostsDidSave")
  static let keysDidSaveNotification = Notification.Name("MoshroomKeysDidSave")
  // Posted (main thread) after a reconcile replaced a local blob — open UI can refresh off these.
  static let didChangeNotification = Notification.Name("MoshroomHostsDidChangeFromICloud")
  static let keysDidChangeNotification = Notification.Name("MoshroomKeysDidChangeFromICloud")
  // Posted (main thread) whenever `isSyncing` flips or a sync finishes — the Settings row observes.
  static let syncStateNotification = Notification.Name("MoshroomCloudSyncStateChanged")

  private static let queue = DispatchQueue(label: "moshroom.cloudmirror", qos: .utility)
  private static var installed = false

  // MARK: - Extra count providers (set by the vault/2FA stores at launch)

  // The password vault and 2FA accounts live in the iCloud Keychain (not in a Drive blob), so this
  // coordinator can't count them itself. The stores register a counter so the Settings readout can
  // still show "N passwords · N 2FA". nil ⇒ that store hasn't loaded yet (shown as 0 / omitted).
  static var passwordsCountProvider: (() -> Int)?
  static var totpCountProvider: (() -> Int)?

  // MARK: - Sync status (read by Settings)

  private static let lastSyncKey = "MoshroomCloudLastSyncDate"
  private static let lastSummaryKey = "MoshroomCloudLastSyncSummary"

  // Per-dataset "what this device last saw" markers (local + cloud modification dates).
  private static let hostsMarkerLocalKey = "MoshroomCloudLastSyncedLocalDate"
  private static let hostsMarkerCloudKey = "MoshroomCloudLastSyncedCloudDate"
  private static let keysMarkerLocalKey = "MoshroomCloudKeysLastSyncedLocalDate"
  private static let keysMarkerCloudKey = "MoshroomCloudKeysLastSyncedCloudDate"

  // When this device last completed a successful reconcile (any direction, including no-op).
  @objc static var lastSyncDate: Date? {
    UserDefaults.standard.object(forKey: lastSyncKey) as? Date
  }

  // One honest line about the last pass — the per-type counts plus what the pass did. The Settings
  // row shows it so you can SEE what sync saw.
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

  private static func _markGlobalSynced() {
    UserDefaults.standard.set(Date(), forKey: lastSyncKey)
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: syncStateNotification, object: nil)
    }
  }

  private static func _setMarkers(local: Date?, cloud: Date?, localKey: String, cloudKey: String) {
    let d = UserDefaults.standard
    d.set(local, forKey: localKey)
    d.set(cloud, forKey: cloudKey)
  }

  // MARK: - Lifecycle

  @objc static func install() {
    guard !installed else { return }
    installed = true
    // The vault/2FA counts for the Settings readout — those stores live in the iCloud Keychain, not
    // in a Drive blob, so they can't be counted from the reconcile itself.
    passwordsCountProvider = { MoshVaultStore.shared.count() }
    totpCountProvider = { MoshTOTPStore.shared.count() }
    // The connect path reads the generated ssh_config, not the hosts blob. Regenerate it once at
    // launch so it always matches the persisted hosts — this covers a host that arrived via an
    // iCloud pull (or state restoration) on a device that never saved one locally.
    MoshHosts.saveAllToSSHConfig()
    let nc = NotificationCenter.default
    nc.addObserver(forName: didSaveNotification, object: nil, queue: nil) { _ in reconcile() }
    nc.addObserver(forName: keysDidSaveNotification, object: nil, queue: nil) { _ in reconcile() }
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

  private static var hostsLocalURL: URL { URL(fileURLWithPath: MoshroomPaths.moshroomHostsFile()) }
  private static var keysLocalURL: URL { URL(fileURLWithPath: MoshroomPaths.moshroomKeysFile()) }

  // MARK: - Reconcile (the one sync path)

  @objc static func reconcile() {
    guard isActive else { return }
    guard let hostsCloudURL = MoshroomPaths.iCloudHostsLocationURL(),
          let keysCloudURL = MoshroomPaths.iCloudKeysLocationURL() else {
      // The single most diagnostic failure: iCloud Drive off (globally or for Moshroom) or no account.
      _setSummary("iCloud unavailable — check iCloud Drive is on for Moshroom")
      return
    }
    _setSyncing(true)
    queue.async {
      defer { _setSyncing(false) }

      let hostsFlavor = _reconcileHosts(cloudURL: hostsCloudURL)
      let keysFlavor = _reconcileKeys(cloudURL: keysCloudURL)
      _markGlobalSynced()

      // Materialize snips that arrived from another device, count everything, publish the readout.
      let snips = _downloadAndCountSnips()
      DispatchQueue.main.async {
        // Runs after any adopt/merge reload enqueued above — counts are the fresh, post-sync truth.
        _publishSummary(overall: _combine(hostsFlavor, keysFlavor), snips: snips)
      }
    }
  }

  // MARK: - Hosts dataset

  private static func _reconcileHosts(cloudURL: URL) -> Flavor {
    let local = hostsLocalURL
    return _reconcileProjection(
      cloudURL: cloudURL,
      localProjection: try? Data(contentsOf: local),
      localDate: modificationDate(of: local),
      markerLocalKey: hostsMarkerLocalKey,
      markerCloudKey: hostsMarkerCloudKey,
      count: { decodeHosts($0)?.count },
      merge: { mergeHosts(datasets: $0) },
      apply: { projection, stamp in
        // Hosts: the whole local file IS the projection.
        guard (try? projection.write(to: local, options: .atomic)) != nil else { return }
        if let stamp {
          try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: local.path)
        }
        DispatchQueue.main.async {
          MoshHosts.loadHosts()
          // The connect path reads the generated ssh_config, NOT the hosts blob — regenerate it from
          // the freshly-synced list or a synced host can't be reached (hostName falls back to the
          // alias → getaddrinfo fails with "Socket error: No such file or directory").
          MoshHosts.saveAllToSSHConfig()
          NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
      }
    )
  }

  // MARK: - Keys dataset (Keychain-key projection; device-only keys preserved)

  private static func _reconcileKeys(cloudURL: URL) -> Flavor {
    let local = keysLocalURL
    let localAll = decodeKeys((try? Data(contentsOf: local)) ?? Data()) ?? []
    let localProjectionKeys = localAll.filter { $0.storageType == MoshPubKeyStorageTypeKeyChain }
    // Device-only keys (Secure Enclave / passkey / security) never sync and must survive any adopt or
    // merge of a remote list — captured here so the rebuild below always re-attaches them.
    let deviceOnlyKeys = localAll.filter { $0.storageType != MoshPubKeyStorageTypeKeyChain }
    let localProjection: Data? = localAll.isEmpty
      ? nil                                   // nothing at all locally
      : encodeKeys(localProjectionKeys)       // the syncable subset (may be an empty encoded array)

    return _reconcileProjection(
      cloudURL: cloudURL,
      localProjection: localProjection,
      localDate: modificationDate(of: local),
      markerLocalKey: keysMarkerLocalKey,
      markerCloudKey: keysMarkerCloudKey,
      count: { decodeKeys($0)?.count },
      merge: { mergeKeysByTag(datasets: $0) },
      apply: { projection, stamp in
        // Keys: rebuild the local file as (this device's device-only keys) + (the adopted projection),
        // so a Secure-Enclave / passkey key that only exists here is never dropped by a remote list.
        let adopted = decodeKeys(projection) ?? []
        guard let data = encodeKeys(deviceOnlyKeys + adopted) else { return }
        guard (try? data.write(to: local, options: .atomic)) != nil else { return }
        if let stamp {
          try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: local.path)
        }
        DispatchQueue.main.async {
          MoshPubKey.loadIDS()
          NotificationCenter.default.post(name: keysDidChangeNotification, object: nil)
        }
      }
    )
  }

  // MARK: - Generic projection reconcile (shared by hosts + keys)

  private enum Flavor: Equatable { case upToDate, fetched, sent, merged, empty }

  private static func _combine(_ a: Flavor, _ b: Flavor) -> Flavor {
    // Show the most significant thing that happened this pass.
    let order: [Flavor] = [.merged, .fetched, .sent, .upToDate, .empty]
    for f in order where a == f || b == f { return f }
    return .upToDate
  }

  private static func _reconcileProjection(
    cloudURL: URL,
    localProjection: Data?,
    localDate: Date?,
    markerLocalKey: String,
    markerCloudKey: String,
    count: (Data) -> Int?,
    merge: ([Data]) -> Data?,
    apply: @escaping (_ projection: Data, _ stamp: Date?) -> Void
  ) -> Flavor {
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

    let defaults = UserDefaults.standard
    let markerLocal = defaults.object(forKey: markerLocalKey) as? Date
    let markerCloud = defaults.object(forKey: markerCloudKey) as? Date

    func changed(_ date: Date?, since marker: Date?) -> Bool {
      guard let date else { return false }
      guard let marker else { return true }        // first sync: treat as changed → merge (safe)
      return date.timeIntervalSince(marker) > 0.5  // mtimes are stamped equal after each sync
    }

    switch (localProjection, cloud) {
    case (nil, nil):
      _setMarkers(local: nil, cloud: nil, localKey: markerLocalKey, cloudKey: markerCloudKey)
      return .empty

    case (let l?, nil):
      // Nothing in the cloud yet — publish the local projection.
      writeCloud(l, to: cloudURL, stamp: localDate)
      _setMarkers(local: localDate, cloud: localDate, localKey: markerLocalKey, cloudKey: markerCloudKey)
      return .sent

    case (nil, let c?):
      // Nothing local yet — adopt the cloud copy.
      apply(c.data, c.date)
      _setMarkers(local: c.date, cloud: c.date, localKey: markerLocalKey, cloudKey: markerCloudKey)
      return .fetched

    case (let l?, let c?):
      if l == c.data && conflictData.isEmpty {
        _setMarkers(local: localDate, cloud: c.date, localKey: markerLocalKey, cloudKey: markerCloudKey)
        return .upToDate
      }
      let localChanged = changed(localDate, since: markerLocal)
      let cloudChanged = changed(c.date, since: markerCloud)

      // Safety valves. Plain newest-wins is how edits and deletions propagate, but two shapes are far
      // more likely a half-initialized or divergent sibling (fresh install, broken/partial transport)
      // than a real user action — those go through the merge, whose union keeps the data:
      //  - an empty list replacing a non-empty one ("delete everything" doesn't propagate silently);
      //  - adopting a cloud list that would silently drop more than half of this device's items.
      let localCount = count(l) ?? 0
      let cloudCount = count(c.data) ?? 0
      let emptyClobber =
        (cloudChanged && cloudCount == 0 && localCount > 0) ||
        (localChanged && localCount == 0 && cloudCount > 0)
      let shrinkClobber = cloudChanged && !localChanged
        && localCount >= 2 && cloudCount * 2 < localCount

      if (localChanged && cloudChanged) || !conflictData.isEmpty || emptyClobber || shrinkClobber {
        // True conflict → merge every dataset we can see. Local first, so ties keep local.
        guard let merged = merge([l, c.data] + conflictData) else { return .upToDate }
        let now = Date()
        apply(merged, now)
        writeCloud(merged, to: cloudURL, stamp: now)
        conflictVersions.forEach { $0.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: cloudURL)
        _setMarkers(local: now, cloud: now, localKey: markerLocalKey, cloudKey: markerCloudKey)
        return .merged
      } else if cloudChanged {
        apply(c.data, c.date)
        _setMarkers(local: c.date, cloud: c.date, localKey: markerLocalKey, cloudKey: markerCloudKey)
        return .fetched
      } else if localChanged {
        writeCloud(l, to: cloudURL, stamp: localDate)
        _setMarkers(local: localDate, cloud: localDate, localKey: markerLocalKey, cloudKey: markerCloudKey)
        return .sent
      } else {
        _setMarkers(local: localDate, cloud: c.date, localKey: markerLocalKey, cloudKey: markerCloudKey)
        return .upToDate
      }
    }
  }

  // MARK: - Snips

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

  // MARK: - Summary

  private static func _publishSummary(overall: Flavor, snips: Int) {
    let hosts = MoshHosts.allHosts().count
    let keys = MoshPubKey.all().count
    let passwords = passwordsCountProvider?()
    let totp = totpCountProvider?()

    func unit(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
    var parts = [unit(hosts, "host", "hosts"), unit(keys, "key", "keys")]
    if let passwords { parts.append(unit(passwords, "password", "passwords")) }
    if let totp { parts.append("\(totp) 2FA") }
    parts.append(unit(snips, "snip", "snips"))

    let state: String
    switch overall {
    case .upToDate: state = "up to date"
    case .fetched:  state = "updated from iCloud"
    case .sent:     state = "uploaded to iCloud"
    case .merged:   state = "merged across devices"
    case .empty:    state = "nothing to sync yet"
    }
    _setSummary(parts.joined(separator: " · ") + " — " + state)
  }

  // MARK: - Encode / decode / merge

  private static func decodeHosts(_ data: Data) -> [MoshHosts]? {
    try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: MoshHosts.self, from: data)
  }
  private static func encodeHosts(_ hosts: [MoshHosts]) -> Data? {
    try? NSKeyedArchiver.archivedData(withRootObject: hosts as NSArray, requiringSecureCoding: true)
  }
  private static func decodeKeys(_ data: Data) -> [MoshPubKey]? {
    guard !data.isEmpty else { return [] }
    return try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: MoshPubKey.self, from: data)
  }
  private static func encodeKeys(_ keys: [MoshPubKey]) -> Data? {
    try? NSKeyedArchiver.archivedData(withRootObject: keys as NSArray, requiringSecureCoding: true)
  }

  // Union by alias; where the same alias was edited on both sides, newer per-host lastModified wins.
  private static func mergeHosts(datasets: [Data]) -> Data? {
    var byId: [String: MoshHosts] = [:]
    var order: [String] = []
    for data in datasets {
      guard let list = decodeHosts(data) else { continue }   // an unreadable side can't erase the other
      for item in list {
        guard let id = item.host, !id.isEmpty else { continue }
        if let existing = byId[id] {
          if (item.lastModified ?? .distantPast) > (existing.lastModified ?? .distantPast) { byId[id] = item }
        } else {
          byId[id] = item; order.append(id)
        }
      }
    }
    return encodeHosts(order.compactMap { byId[$0] })
  }

  // Union by TAG (a key's true identity — two keys named the same are still different key material),
  // newer per-key lastModified wins. Only ever operates on the Keychain-key projection.
  private static func mergeKeysByTag(datasets: [Data]) -> Data? {
    var byId: [String: MoshPubKey] = [:]
    var order: [String] = []
    for data in datasets {
      guard let list = decodeKeys(data) else { continue }
      for item in list {
        let id = item.tag
        guard !id.isEmpty else { continue }
        if let existing = byId[id] {
          if (item.lastModified ?? .distantPast) > (existing.lastModified ?? .distantPast) { byId[id] = item }
        } else {
          byId[id] = item; order.append(id)
        }
      }
    }
    return encodeKeys(order.compactMap { byId[$0] })
  }

  // MARK: - File helpers

  // Coordinated replace of the cloud copy, stamped with the given date so no device pulls back its
  // own push.
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
