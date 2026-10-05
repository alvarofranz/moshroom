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
//   2. The iCloud Keychain — the *secrets* (host passwords, private key material, vault + 2FA), synced
//      E2E by the OS whenever the same toggle is on. Deletions there are handled by the OS.
//
// Sync is entirely EVENT-DRIVEN, never polled: a local save/edit/delete posts a notification →
// immediate reconcile (push); a foreground-only NSMetadataQuery watches the iCloud files so a change
// made on another device pulls in live; plus a pass on launch and on foreground. No timer, no cron.
//
// Deletions are first-class and bulletproof via TOMBSTONES. Removing an item drops it from the list
// AND records `{id: deletedAt}` in a small sidecar blob that is itself synced (union, newest wins).
// The reconcile filters out any item whose tombstone is newer than the item's own `lastModified`, so
// a deletion — including "delete everything" — always wins, even against a concurrent edit on another
// device (a plain union merge would otherwise resurrect it). Re-adding a deleted alias just works
// (the new item is newer than its tombstone). Tombstones self-prune after 30 days, by which point
// every device has converged. (The iCloud Keychain already tombstones the secrets it carries.)
//
// A conflict still never loses an EDIT: where the same id was changed on both sides, the newer
// `lastModified` wins and the other side is unioned in. Keys mirror only the projection of
// Keychain-backed keys (their private material rides the iCloud Keychain); Secure-Enclave / passkey
// keys are device-bound, never uploaded, and always preserved locally.
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

  // Tombstones older than this are pruned (every device has long since converged).
  private static let tombstoneTTL: TimeInterval = 30 * 24 * 3600

  // MARK: - Extra count providers (set by the vault/2FA stores at launch)

  static var passwordsCountProvider: (() -> Int)?
  static var totpCountProvider: (() -> Int)?

  // MARK: - Sync status (read by Settings)

  private static let lastSyncKey = "MoshroomCloudLastSyncDate"
  private static let lastSummaryKey = "MoshroomCloudLastSyncSummary"

  private static let hostsMarkerLocalKey = "MoshroomCloudLastSyncedLocalDate"
  private static let hostsMarkerCloudKey = "MoshroomCloudLastSyncedCloudDate"
  private static let keysMarkerLocalKey = "MoshroomCloudKeysLastSyncedLocalDate"
  private static let keysMarkerCloudKey = "MoshroomCloudKeysLastSyncedCloudDate"
  // The set of item ids this device last had locally — diffed each pass to detect local deletions.
  private static let hostsKnownIdsKey = "MoshroomCloudHostsKnownIds"
  private static let keysKnownIdsKey = "MoshroomCloudKeysKnownIds"

  @objc static var lastSyncDate: Date? {
    UserDefaults.standard.object(forKey: lastSyncKey) as? Date
  }

  @objc static var lastSyncSummary: String? {
    UserDefaults.standard.string(forKey: lastSummaryKey)
  }

  /// What the last pass actually saw, per kind, plus what it did. The one-line summary above still
  /// exists for the log; Settings renders THIS as one line per kind (a paragraph of counts squeezed
  /// into a trailing label was unreadable).
  struct SyncStatus: Codable {
    var counts: [Item]
    var state: String

    struct Item: Codable {
      var label: String
      var count: Int
    }
  }

  private static let lastStatusKey = "MoshroomCloudLastSyncStatus"

  static var lastSyncStatus: SyncStatus? {
    guard let data = UserDefaults.standard.data(forKey: lastStatusKey) else { return nil }
    return try? JSONDecoder().decode(SyncStatus.self, from: data)
  }

  private static func _setStatus(_ status: SyncStatus) {
    if let data = try? JSONEncoder().encode(status) {
      UserDefaults.standard.set(data, forKey: lastStatusKey)
    }
  }

  private static func _setSummary(_ text: String) {
    UserDefaults.standard.set(text, forKey: lastSummaryKey)
    DispatchQueue.main.async { NotificationCenter.default.post(name: syncStateNotification, object: nil) }
  }

  @objc private(set) static var isSyncing = false

  private static func _setSyncing(_ on: Bool) {
    DispatchQueue.main.async {
      guard isSyncing != on else { return }
      isSyncing = on
      NotificationCenter.default.post(name: syncStateNotification, object: nil)
    }
  }

  private static func _markGlobalSynced() {
    UserDefaults.standard.set(Date(), forKey: lastSyncKey)
    DispatchQueue.main.async { NotificationCenter.default.post(name: syncStateNotification, object: nil) }
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
    passwordsCountProvider = { MoshVaultStore.shared.count() }
    totpCountProvider = { MoshTOTPStore.shared.count() }
    // The connect path reads the generated ssh_config; regenerate once at launch so it matches the
    // persisted hosts (covers a host that arrived via an iCloud pull on a device that never saved one).
    MoshHosts.saveAllToSSHConfig()

    let nc = NotificationCenter.default
    nc.addObserver(forName: didSaveNotification, object: nil, queue: nil) { _ in reconcile() }
    nc.addObserver(forName: keysDidSaveNotification, object: nil, queue: nil) { _ in reconcile() }
    nc.addObserver(forName: UIScene.willEnterForegroundNotification, object: nil, queue: nil) { _ in reconcile() }
    // Foreground-only live watcher: start when active, stop when backgrounded (never drains battery
    // in the background — it simply isn't running there).
    nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in _startWatcher() }
    nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in _stopWatcher() }

    reconcile()      // launch pass
    _startWatcher()  // in case we're already active
    // The secrets half: anything written while sync was off is still device-local and no amount of
    // Drive reconciling will move it. Runs once per launch, and waits for the first unlock if the app
    // came up before it (see Moshsync).
    Moshsync.migrateWhenPossible()
  }

  @objc static func syncNow() {
    if let snips = MoshroomPaths.iCloudSnippetsLocationURL() {
      try? FileManager.default.startDownloadingUbiquitousItem(at: snips)
    }
    // Pressing Sync Now (or turning the switch on) is the user asking for a FULL pass, secrets
    // included — so this one is forced rather than once-per-launch.
    Moshsync.migrateWhenPossible(force: true)
    reconcile()
  }

  private static var isActive: Bool {
    MoshroomDefaults.isICloudSyncEnabled() && FileManager.default.ubiquityIdentityToken != nil
  }

  private static var hostsLocalURL: URL { URL(fileURLWithPath: MoshroomPaths.moshroomHostsFile()) }
  private static var keysLocalURL: URL { URL(fileURLWithPath: MoshroomPaths.moshroomKeysFile()) }

  // MARK: - Live watcher (NSMetadataQuery, foreground only)

  private static var metaQuery: NSMetadataQuery?
  private static var metaObservers: [NSObjectProtocol] = []
  private static var watchDebounce: DispatchWorkItem?

  private static func _startWatcher() {
    guard isActive, metaQuery == nil else { return }
    let q = NSMetadataQuery()
    q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
    // Only our four files — never the whole container, so this stays cheap.
    q.predicate = NSPredicate(format: "%K IN %@", NSMetadataItemFSNameKey,
                              ["hosts", "keys", "hosts.tombstones", "keys.tombstones"])
    let onChange: (Notification) -> Void = { _ in _debouncedReconcile() }
    metaObservers = [
      NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main, using: onChange),
      NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main, using: onChange),
    ]
    metaQuery = q
    q.start()
  }

  private static func _stopWatcher() {
    metaQuery?.stop()
    metaObservers.forEach { NotificationCenter.default.removeObserver($0) }
    metaObservers = []
    metaQuery = nil
    watchDebounce?.cancel()
    watchDebounce = nil
  }

  // Coalesce a burst of metadata updates (a single remote save can fire several) into one reconcile.
  private static func _debouncedReconcile() {
    watchDebounce?.cancel()
    let work = DispatchWorkItem { reconcile() }
    watchDebounce = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
  }

  // MARK: - Reconcile (the one sync path)

  @objc static func reconcile() {
    guard isActive else { return }
    guard let hostsCloudURL = MoshroomPaths.iCloudHostsLocationURL(),
          let keysCloudURL = MoshroomPaths.iCloudKeysLocationURL() else {
      _setSummary("iCloud unavailable — check iCloud Drive is on for Moshroom")
      return
    }
    _setSyncing(true)
    queue.async {
      defer { _setSyncing(false) }
      let hostsFlavor = _reconcileHosts(cloudURL: hostsCloudURL)
      let keysFlavor = _reconcileKeys(cloudURL: keysCloudURL)
      _markGlobalSynced()
      let snips = _downloadAndCountSnips()
      DispatchQueue.main.async { _publishSummary(overall: _combine(hostsFlavor, keysFlavor), snips: snips) }
    }
  }

  // MARK: - Datasets

  private static func _reconcileHosts(cloudURL: URL) -> Flavor {
    let local = hostsLocalURL
    return _reconcileDataset(
      cloudItemsURL: cloudURL,
      localItemsURL: local,
      markerLocalKey: hostsMarkerLocalKey, markerCloudKey: hostsMarkerCloudKey,
      knownIdsKey: hostsKnownIdsKey,
      decode: { decodeHosts($0) },
      encode: { encodeHosts($0) },
      idOf: { $0.host ?? "" },
      lastModOf: { $0.lastModified },
      applyLocal: { items, stamp, expected in
        _replaceLocal(at: local, expected: expected, stamp: stamp,
                      build: { _ in encodeHosts(items) },
                      reload: {
                        MoshHosts.loadHosts()
                        MoshHosts.saveAllToSSHConfig()   // connect path reads ssh_config, not the blob
                        NotificationCenter.default.post(name: didChangeNotification, object: nil)
                      })
      }
    )
  }

  private static func _reconcileKeys(cloudURL: URL) -> Flavor {
    let local = keysLocalURL
    return _reconcileDataset(
      cloudItemsURL: cloudURL,
      localItemsURL: local,
      markerLocalKey: keysMarkerLocalKey, markerCloudKey: keysMarkerCloudKey,
      knownIdsKey: keysKnownIdsKey,
      // `decode` yields the SYNCABLE projection (Keychain-backed keys only), and nil when the blob
      // cannot be read at all, so an unreadable file is never mistaken for "no keys".
      decode: { decodeKeys($0).map { $0.filter { $0.storageType == MoshPubKeyStorageTypeKeyChain } } },
      encode: { encodeKeys($0) },
      idOf: { $0.tag },
      lastModOf: { $0.lastModified },
      applyLocal: { items, stamp, expected in
        _replaceLocal(at: local, expected: expected, stamp: stamp,
                      build: { current in
                        // Rebuild the local file as (device-only keys) + (the synced projection). The
                        // device-only keys (SE / passkey / security) never sync and must survive any
                        // adopt or merge; they are read from the very bytes being replaced.
                        let deviceOnly = (decodeKeys(current ?? Data()) ?? [])
                          .filter { $0.storageType != MoshPubKeyStorageTypeKeyChain }
                        return encodeKeys(deviceOnly + items)
                      },
                      reload: {
                        MoshPubKey.loadIDS()
                        NotificationCenter.default.post(name: keysDidChangeNotification, object: nil)
                      })
      }
    )
  }

  /// Replace a local blob with what the pass decided, but only if it still holds exactly the bytes the
  /// pass started from. It runs on the MAIN thread, where every local save happens (MoshHosts,
  /// MoshPubKey), so the check, the write and the in-memory reload are one step a save cannot slip
  /// into. A save that landed while the pass was busy makes this return false: that save already
  /// queued its own pass, which starts from the new bytes. (The old code wrote over it, and the host
  /// or key the user had just added was simply gone.)
  ///
  /// The blob keeps the protection class its owners write it with (CompleteUntilFirstUserAuthentication):
  /// without the option the file took the container default, Complete, and became unreadable whenever
  /// the device was locked.
  private static func _replaceLocal(at url: URL, expected: Data?, stamp: Date?,
                                    build: (Data?) -> Data?, reload: () -> Void) -> Bool {
    DispatchQueue.main.sync {
      let current = try? Data(contentsOf: url)
      guard current == expected, let data = build(current) else { return false }
      do {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      } catch {
        MoshLog.log("sync", "could not write \(url.lastPathComponent): \((error as NSError).code)")
        return false
      }
      if let stamp { try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path) }
      reload()
      return true
    }
  }

  // MARK: - Generic dataset reconcile with tombstones

  private enum Flavor: Equatable { case upToDate, fetched, sent, merged, empty }

  private static func _combine(_ a: Flavor, _ b: Flavor) -> Flavor {
    for f in [Flavor.merged, .fetched, .sent, .upToDate, .empty] where a == f || b == f { return f }
    return .upToDate
  }

  private static func _reconcileDataset<Item>(
    cloudItemsURL: URL,
    localItemsURL: URL,
    markerLocalKey: String, markerCloudKey: String,
    knownIdsKey: String,
    decode: (Data) -> [Item]?,
    encode: ([Item]) -> Data?,
    idOf: (Item) -> String,
    lastModOf: (Item) -> Date?,
    applyLocal: (_ items: [Item], _ stamp: Date?, _ expected: Data?) -> Bool
  ) -> Flavor {
    let fm = FileManager.default
    let name = localItemsURL.lastPathComponent
    let localTombURL = localItemsURL.appendingPathExtension("tombstones")
    let cloudTombURL = cloudItemsURL.appendingPathExtension("tombstones")
    try? fm.startDownloadingUbiquitousItem(at: cloudItemsURL)
    try? fm.startDownloadingUbiquitousItem(at: cloudTombURL)

    // Local items (decoded to the syncable projection).
    let localData = try? Data(contentsOf: localItemsURL)
    let localExists = localData != nil
    let decodedLocal = localData.flatMap(decode)
    // A present-but-unreadable local file must NOT be read as "everything was deleted": leave the whole
    // dataset untouched this pass (no tombstones, no overwrite) rather than risk a spurious mass wipe.
    if localExists && decodedLocal == nil { return .upToDate }
    let localItems = decodedLocal ?? []
    let localProjData = encode(localItems)
    let currentIds = Set(localItems.map(idOf).filter { !$0.isEmpty })

    // --- The iCloud side, read BEFORE anything is written. The same rule as the local file applies:
    // a copy that exists but cannot be read (still downloading, coordination failed) or cannot be
    // decoded (corrupt, or written by a version this one does not understand) is NOT an empty list.
    // It aborts the pass with nothing replaced on either side; it used to be read as [] and, being
    // "newer", wiped this device and then every other one.
    let cloud: (data: Data, date: Date)?
    switch _readCloud(cloudItemsURL) {
    case .unreadable:
      MoshLog.log("sync", "\(name): the iCloud copy could not be read, pass skipped")
      return .upToDate
    case .missing:
      cloud = nil
    case let .present(data, date):
      cloud = (data, date ?? .distantPast)
    }
    var cloudItems: [Item] = []
    if let cloud {
      guard !cloud.data.isEmpty, let decoded = decode(cloud.data) else {
        MoshLog.log("sync", "\(name): the iCloud copy is not readable by this version, pass skipped")
        return .upToDate
      }
      cloudItems = decoded
    }
    var cloudTombs: [String: Double] = [:]
    switch _readCloud(cloudTombURL) {
    case .missing:
      break
    case .unreadable:
      // Publishing our tombstones over a file we could not read would erase every other device's
      // deletions (and bring those items back). Wait for it instead.
      MoshLog.log("sync", "\(name): the iCloud tombstones could not be read, pass skipped")
      return .upToDate
    case let .present(data, _):
      guard let decoded = _decodeTombs(data) else {
        MoshLog.log("sync", "\(name): the iCloud tombstones are not readable, pass skipped")
        return .upToDate
      }
      cloudTombs = decoded
    }

    // Deletions this device made since last sync (ids known before, gone now) — inferred ONLY when the
    // local file is actually present. A vanished file means a container reset (reinstall), not a
    // "delete all"; that path adopts the cloud copy instead of tombstoning everything. A real
    // "delete all" keeps the file (an empty archived list), so it still propagates.
    let knownIds = Set((UserDefaults.standard.array(forKey: knownIdsKey) as? [String]) ?? [])
    let locallyDeleted = localExists ? knownIds.subtracting(currentIds) : []

    // --- Tombstones: union local + cloud + this device's new deletions, prune, publish both sides.
    let nowTs = Date().timeIntervalSince1970
    var localTombs = _readTombs(localTombURL)
    for id in locallyDeleted { localTombs[id] = max(localTombs[id] ?? 0, nowTs) }
    var mergedTombs = _mergeTombs(localTombs, cloudTombs)
    mergedTombs = mergedTombs.filter { nowTs - $0.value < tombstoneTTL }   // prune the long-converged
    if mergedTombs != localTombs { _writeTombsLocal(mergedTombs, to: localTombURL) }
    if mergedTombs != cloudTombs { _writeTombsCloud(mergedTombs, to: cloudTombURL) }

    func alive(_ item: Item) -> Bool {
      guard let ts = mergedTombs[idOf(item)] else { return true }
      return (lastModOf(item)?.timeIntervalSince1970 ?? 0) > ts   // item newer than its tombstone ⇒ kept
    }

    // --- Forked conflict versions (iCloud keeps both sides of a concurrent save).
    let conflictVersions = NSFileVersion.unresolvedConflictVersionsOfItem(at: cloudItemsURL) ?? []
    let conflictLists = conflictVersions.compactMap { (try? Data(contentsOf: $0.url)).flatMap(decode) }
    let localDate = modificationDate(of: localItemsURL)

    // Nothing anywhere → just record the (pruned) tombstones and leave.
    if !localExists && cloud == nil {
      _setMarkers(local: nil, cloud: nil, localKey: markerLocalKey, cloudKey: markerCloudKey)
      UserDefaults.standard.set([], forKey: knownIdsKey)
      return .empty
    }

    let defaults = UserDefaults.standard
    let markerLocal = defaults.object(forKey: markerLocalKey) as? Date
    let markerCloud = defaults.object(forKey: markerCloudKey) as? Date
    func changed(_ date: Date?, since marker: Date?) -> Bool {
      guard let date else { return false }
      guard let marker else { return true }
      return date.timeIntervalSince(marker) > 0.5
    }
    let localChanged = changed(localDate, since: markerLocal) || !locallyDeleted.isEmpty
    let cloudChanged = changed(cloud?.date, since: markerCloud)

    // The clobber valve. Plain newest-wins may replace one side with the other only when that loses
    // nothing unaccounted for: an empty list never replaces a non-empty one, and an adopt that would
    // drop more than half of the other side's items goes through the merge instead. A REAL deletion is
    // never blocked by this: it carries a tombstone, tombstoned ids are not counted here, and the
    // tombstone filter below still removes them from the merge.
    func wouldClobber(_ adopted: [Item], over replaced: [Item]) -> Bool {
      let replacedIds = Set(replaced.map(idOf).filter { !$0.isEmpty && mergedTombs[$0] == nil })
      guard !replacedIds.isEmpty else { return false }
      let lost = replacedIds.subtracting(adopted.map(idOf)).count
      return adopted.isEmpty || lost * 2 > replacedIds.count
    }
    func union() -> [Item] {
      _union([localItems, cloudItems] + conflictLists, idOf: idOf, lastModOf: lastModOf)
    }

    // --- Decide the merged item set (newest-wins normal; union on a true conflict or a clobber).
    let decided: [Item]
    let flavor: Flavor
    if !localExists, cloud != nil {
      decided = cloudItems; flavor = .fetched
    } else if localExists, cloud == nil {
      decided = localItems; flavor = .sent
    } else if (localChanged && cloudChanged) || !conflictLists.isEmpty {
      decided = union(); flavor = .merged
    } else if cloudChanged {
      if wouldClobber(cloudItems, over: localItems) {
        MoshLog.log("sync", "\(name): the iCloud copy would drop most of this device's items, merging instead")
        decided = union(); flavor = .merged
      } else {
        decided = cloudItems; flavor = .fetched
      }
    } else if localChanged {
      if wouldClobber(localItems, over: cloudItems) {
        MoshLog.log("sync", "\(name): this device's copy would drop most of iCloud's items, merging instead")
        decided = union(); flavor = .merged
      } else {
        decided = localItems; flavor = .sent
      }
    } else {
      decided = localItems; flavor = .upToDate
    }

    // Tombstones are authoritative: a deletion always wins (this is what a plain union can't do).
    let finalItems = decided.filter(alive)
    guard let finalData = encode(finalItems) else { return flavor }

    // Write only what actually changed, stamping equal dates so neither side re-pulls its own push.
    let now = Date()
    var markL = localDate
    var markC = cloud?.date
    if finalData != localProjData {
      guard applyLocal(finalItems, now, localData) else {
        // A local save landed while this pass ran (its own pass is queued and starts from the new
        // bytes), or the write failed. Either way this pass stops here, markers untouched.
        return .upToDate
      }
      markL = now
    }
    if finalData != cloud?.data {
      guard writeCloud(finalData, to: cloudItemsURL, stamp: now) else {
        // Keep the local marker where it was so the next pass still sees a local change and retries
        // the push, instead of believing both sides agree.
        _setMarkers(local: markerLocal, cloud: markerCloud, localKey: markerLocalKey, cloudKey: markerCloudKey)
        UserDefaults.standard.set(finalItems.map(idOf).filter { !$0.isEmpty }, forKey: knownIdsKey)
        return flavor
      }
      markC = now
    }
    _setMarkers(local: markL, cloud: markC, localKey: markerLocalKey, cloudKey: markerCloudKey)
    UserDefaults.standard.set(finalItems.map(idOf).filter { !$0.isEmpty }, forKey: knownIdsKey)

    // Both sides now hold the merge, which folded in every conflict version, so the forks are done
    // with: mark them resolved and prune them (otherwise every later pass merged them in again, for
    // ever, and an item deleted after the fork came back once its tombstone expired). Only when every
    // version was readable; one we could not decode is kept for a later pass.
    if !conflictVersions.isEmpty && conflictLists.count == conflictVersions.count {
      _resolveConflicts(conflictVersions, of: cloudItemsURL)
    }
    return flavor
  }

  private static func _resolveConflicts(_ versions: [NSFileVersion], of url: URL) {
    for version in versions { version.isResolved = true }
    var coordError: NSError?
    NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordError) { dst in
      do {
        try NSFileVersion.removeOtherVersionsOfItem(at: dst)
      } catch {
        MoshLog.log("sync", "could not prune conflict versions of \(url.lastPathComponent): \((error as NSError).code)")
      }
    }
  }

  private static func _union<Item>(_ lists: [[Item]], idOf: (Item) -> String, lastModOf: (Item) -> Date?) -> [Item] {
    var byId: [String: Item] = [:]
    var order: [String] = []
    for list in lists {
      for item in list {
        let id = idOf(item)
        guard !id.isEmpty else { continue }
        if let ex = byId[id] {
          if (lastModOf(item) ?? .distantPast) > (lastModOf(ex) ?? .distantPast) { byId[id] = item }
        } else {
          byId[id] = item; order.append(id)
        }
      }
    }
    return order.compactMap { byId[$0] }
  }

  // MARK: - Tombstone helpers (JSON {id: epochSeconds})

  private static func _readTombs(_ url: URL) -> [String: Double] {
    (try? Data(contentsOf: url)).flatMap(_decodeTombs) ?? [:]
  }
  private static func _decodeTombs(_ data: Data) -> [String: Double]? {
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: NSNumber] else { return nil }
    return obj.mapValues { $0.doubleValue }
  }
  private static func _encodeTombs(_ t: [String: Double]) -> Data? {
    try? JSONSerialization.data(withJSONObject: t)
  }
  private static func _mergeTombs(_ a: [String: Double], _ b: [String: Double]) -> [String: Double] {
    a.merging(b) { max($0, $1) }
  }
  private static func _writeTombsLocal(_ t: [String: Double], to url: URL) {
    guard let data = _encodeTombs(t) else { return }
    try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
  private static func _writeTombsCloud(_ t: [String: Double], to url: URL) {
    guard let data = _encodeTombs(t) else { return }
    writeCloud(data, to: url, stamp: nil)
  }

  // MARK: - Snips

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

    var items: [SyncStatus.Item] = [.init(label: "Hosts", count: hosts), .init(label: "Keys", count: keys)]
    if let passwords { items.append(.init(label: "Passwords", count: passwords)) }
    if let totp { items.append(.init(label: "2FA codes", count: totp)) }
    items.append(.init(label: "Snips", count: snips))
    _setStatus(SyncStatus(counts: items, state: state))

    _setSummary(parts.joined(separator: " · ") + " — " + state)
  }

  // MARK: - Encode / decode

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

  // MARK: - File helpers

  /// What a coordinated read of an iCloud file found. `unreadable` is the case that matters: the file
  /// exists (here, or only in iCloud as a not-yet-downloaded placeholder) but its bytes could not be
  /// had, which must never be treated like a file that is simply not there.
  private enum CloudRead {
    case missing
    case present(Data, Date?)
    case unreadable
  }

  // The coordinated read downloads a not-yet-local file before handing it over. No `fileExists`
  // pre-check: on iOS a file still in iCloud exists only as a placeholder, and that check answered
  // "missing" for it.
  private static func _readCloud(_ url: URL) -> CloudRead {
    var out: CloudRead?
    var coordError: NSError?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { src in
      if let data = try? Data(contentsOf: src) {
        out = .present(data, modificationDate(of: src))
      } else {
        out = _existsLocallyOrInICloud(src) ? .unreadable : .missing
      }
    }
    if let out { return out }
    return _existsLocallyOrInICloud(url) ? .unreadable : .missing
  }

  private static func _existsLocallyOrInICloud(_ url: URL) -> Bool {
    if FileManager.default.fileExists(atPath: url.path) { return true }
    let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
    return status != nil
  }

  @discardableResult
  private static func writeCloud(_ data: Data, to cloudURL: URL, stamp: Date?) -> Bool {
    var written = false
    var coordError: NSError?
    NSFileCoordinator().coordinate(writingItemAt: cloudURL, options: .forReplacing, error: &coordError) { dst in
      try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard (try? data.write(to: dst, options: .atomic)) != nil else { return }
      written = true
      if let stamp {
        try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: dst.path)
      }
    }
    return written
  }

  private static func modificationDate(of url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }
}
