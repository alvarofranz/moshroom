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

// Moshify — the music tab. The library is ONE folder on ONE saved SSH host; playback is
// download-then-play over the app's own SFTP stack (no streaming, no server software), with a
// ten-track prefetch window and an LRU cache the user can see in Files.app. The engine is a
// singleton that outlives the tab page: switching tabs keeps the music playing, closing the tab
// stops it. Background audio + lock-screen controls (play/pause + next; never previous or seek).

import UIKit
import Combine
import AVFoundation
import MediaPlayer
import CryptoKit

import MoshroomConfig
import MoshroomFiles
import SSH

// MARK: - Model

struct MoshifyTrack: Equatable {
  let remotePath: String     // absolute path on the host — THE identity
  let fileName: String       // remote basename, extension included
  let size: UInt64

  var title: String { (fileName as NSString).deletingPathExtension }
  var ext: String { (fileName as NSString).pathExtension.lowercased() }
  var cacheKey: String { Moshify.cacheKey(for: remotePath) }

  static func == (l: MoshifyTrack, r: MoshifyTrack) -> Bool { l.remotePath == r.remotePath }
}

enum MoshifyError: LocalizedError {
  case notConfigured
  case timeout

  var errorDescription: String? {
    switch self {
    case .notConfigured: return "Moshify is not set up yet."
    case .timeout: return "Connection timed out."
    }
  }
}

// MARK: - Constants, defaults, notifications

enum Moshify {
  // What counts as music. Deliberately audio-only — no video player in Moshroom.
  static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff"]
  static let scanDepth = 5
  static let prefetchWindow = 10

  static let hostKey = "MoshroomMoshifyHost"
  static let folderKey = "MoshroomMoshifyFolder"
  static let shuffleKey = "MoshroomMoshifyShuffle"
  static let cacheGBKey = "MoshroomMoshifyCacheGB"
  static let recentsKey = "MoshroomMoshifyRecents"

  /// One library the user has actually listened to: a host and the folder inside it. A music tab
  /// always opens on the picker (it is its own tab, not a continuation of the last one), so these
  /// are what make that cheap — one tap and the library is back.
  struct Recent: Codable, Equatable {
    let host: String
    let folder: String

    /// Just the folder's own name ("Media"), which is what identifies a library at a glance. The
    /// full path is what we connect to, not what the card has to read out.
    var folderName: String { Moshify.folderName(folder) }
  }

  /// The last component of a remote path, or the path itself when there is nothing shorter to say
  /// (the root).
  static func folderName(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    return name.isEmpty || name == "/" ? path : name
  }

  static let recentsLimit = 6

  static var recents: [Recent] {
    guard let data = UserDefaults.standard.data(forKey: recentsKey),
          let decoded = try? JSONDecoder().decode([Recent].self, from: data) else { return [] }
    return decoded
  }

  /// Most recent first, no duplicates, capped. Called when a library actually starts playing.
  static func noteRecent(host: String, folder: String) {
    let entry = Recent(host: host, folder: folder)
    var list = recents.filter { $0 != entry }
    list.insert(entry, at: 0)
    list = Array(list.prefix(recentsLimit))
    guard let data = try? JSONEncoder().encode(list) else { return }
    UserDefaults.standard.set(data, forKey: recentsKey)
  }

  static func forgetRecent(host: String, folder: String) {
    let entry = Recent(host: host, folder: folder)
    let list = recents.filter { $0 != entry }
    guard let data = try? JSONEncoder().encode(list) else { return }
    UserDefaults.standard.set(data, forKey: recentsKey)
  }

  static var configuredHost: String? {
    UserDefaults.standard.string(forKey: hostKey).flatMap { $0.isEmpty ? nil : $0 }
  }
  static var configuredFolder: String? {
    UserDefaults.standard.string(forKey: folderKey).flatMap { $0.isEmpty ? nil : $0 }
  }
  static var cacheCapBytes: UInt64 {
    let gb = UserDefaults.standard.integer(forKey: cacheGBKey)
    return UInt64(min(max(gb == 0 ? 2 : gb, 1), 8)) * 1_000_000_000
  }

  static func cacheKey(for remotePath: String) -> String {
    Insecure.MD5.hash(data: Data(remotePath.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  // Where the music lands: Documents/audio/<host> — user-visible in Files.app as
  // Moshroom › audio › host, right beside Moshxplore's Documents/<host> downloads.
  static func audioDirectory(host: String) -> URL {
    let safe = host.replacingOccurrences(of: "/", with: "-")
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("audio", isDirectory: true)
      .appendingPathComponent(safe, isDirectory: true)
  }

  static var audioRootDirectory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("audio", isDirectory: true)
  }

  static var stagingDirectory: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("moshify-staging", isDirectory: true)
  }

  static var indexFileURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Moshroom", isDirectory: true)
      .appendingPathComponent("moshify-index.json")
  }
}

extension Notification.Name {
  /// The engine changed hands: one library plays at a time, so every OTHER music tab drops back to
  /// its picker when this fires.
  static let moshifyOwnerDidChange = Notification.Name("MoshroomMoshifyOwnerDidChange")
  static let moshifyStateDidChange = Notification.Name("MoshroomMoshifyStateDidChange")
  static let moshifyLibraryDidChange = Notification.Name("MoshroomMoshifyLibraryDidChange")
  static let moshifyProgressDidChange = Notification.Name("MoshroomMoshifyProgressDidChange")
}

// MARK: - Cache + index

// The on-disk library cache. Bytes live under Documents/audio/<host>/ with their ORIGINAL
// basenames (a hash suffix only on a collision) — this folder is user-visible, so no cryptic
// names. The index maps remotePath → local file + play history and is the identity; the file
// name is presentation. Main-thread only.
final class MoshifyCache {

  struct Entry: Codable {
    let remotePath: String
    var fileName: String        // LOCAL file name inside the host's audio directory
    var size: UInt64
    var lastPlayed: Date?
    var playCount: Int
    /// Known only once the bytes are here (the player reads it exactly). Optional so an index
    /// written before durations existed still decodes.
    var duration: TimeInterval?
  }

  private(set) var entries: [String: Entry] = [:]   // keyed by cacheKey
  private var host: String

  init(host: String) {
    self.host = host
    load()
    reconcile()
  }

  private var dir: URL { Moshify.audioDirectory(host: host) }

  // Everything Moshify writes must stay readable while the device is LOCKED (background playback,
  // gap downloads): the entitlement default is Complete protection, which would kill playback
  // seconds after lock. New files inherit the directory's class.
  private func ensureDirectory() {
    let fm = FileManager.default
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                          ofItemAtPath: dir.path)
    var root = Moshify.audioRootDirectory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true   // a media cache must not inflate the iCloud backup
    try? root.setResourceValues(values)
  }

  private func load() {
    guard let data = try? Data(contentsOf: Moshify.indexFileURL),
          let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
    entries = decoded
  }

  private func save() {
    let url = Moshify.indexFileURL
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(entries) else { return }
    try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  // Drop index entries whose file vanished (the user can delete from Files.app) and files with no
  // entry (a stale run); re-stat sizes so the LRU math is honest.
  private func reconcile() {
    ensureDirectory()
    let fm = FileManager.default
    var keep: [String: Entry] = [:]
    var referenced = Set<String>()
    for (key, var e) in entries {
      let url = dir.appendingPathComponent(e.fileName)
      guard let attrs = try? fm.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? NSNumber else { continue }
      e.size = size.uint64Value
      keep[key] = e
      referenced.insert(e.fileName)
    }
    let dropped = entries.count - keep.count
    entries = keep
    if let onDisk = try? fm.contentsOfDirectory(atPath: dir.path) {
      for name in onDisk where !referenced.contains(name) {
        try? fm.removeItem(at: dir.appendingPathComponent(name))
      }
    }
    save()
    if dropped > 0 { MoshLog.log("moshify", "cache reconcile dropped \(dropped) stale entries") }
  }

  var totalSize: UInt64 { entries.values.reduce(0) { $0 + $1.size } }

  func localURL(for track: MoshifyTrack) -> URL? {
    guard let e = entries[track.cacheKey] else { return nil }
    return dir.appendingPathComponent(e.fileName)
  }

  func isCached(_ track: MoshifyTrack) -> Bool { entries[track.cacheKey] != nil }

  // The local name a download should land under: the original basename, or (on a collision with a
  // DIFFERENT remote path) the basename with a short hash suffix — still readable in Files.app.
  func localFileName(for track: MoshifyTrack) -> String {
    let taken = entries.values.contains {
      $0.fileName == track.fileName && $0.remotePath != track.remotePath
    }
    guard taken else { return track.fileName }
    let stem = (track.fileName as NSString).deletingPathExtension
    let suffix = String(track.cacheKey.prefix(4))
    return track.ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(track.ext)"
  }

  func destinationURL(for track: MoshifyTrack) -> URL {
    ensureDirectory()
    return dir.appendingPathComponent(localFileName(for: track))
  }

  func noteDownloaded(_ track: MoshifyTrack, at url: URL) {
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
    entries[track.cacheKey] = Entry(remotePath: track.remotePath,
                                    fileName: url.lastPathComponent,
                                    size: size?.uint64Value ?? track.size,
                                    lastPlayed: entries[track.cacheKey]?.lastPlayed,
                                    playCount: entries[track.cacheKey]?.playCount ?? 0,
                                    duration: entries[track.cacheKey]?.duration)
    save()
  }

  /// The exact length, learned when the file plays (or is read locally). Written once; a track the
  /// user has never had on the device simply shows its size, never a guessed time.
  func noteDuration(_ seconds: TimeInterval, for track: MoshifyTrack) {
    guard seconds > 0, var e = entries[track.cacheKey], e.duration != seconds else { return }
    e.duration = seconds
    entries[track.cacheKey] = e
    save()
  }

  func duration(of track: MoshifyTrack) -> TimeInterval? { entries[track.cacheKey]?.duration }

  func notePlayed(_ track: MoshifyTrack) {
    guard var e = entries[track.cacheKey] else { return }
    e.lastPlayed = Date()
    e.playCount += 1
    entries[track.cacheKey] = e
    save()
  }

  func remove(_ track: MoshifyTrack) {
    if let e = entries.removeValue(forKey: track.cacheKey) {
      try? FileManager.default.removeItem(at: dir.appendingPathComponent(e.fileName))
      save()
    }
  }

  // Drop entries whose remote file is gone from the library (deleted on the server outside us).
  func purge(notIn tracks: [MoshifyTrack]) {
    let live = Set(tracks.map { $0.cacheKey })
    let stale = entries.keys.filter { !live.contains($0) }
    for key in stale {
      if let e = entries.removeValue(forKey: key) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(e.fileName))
      }
    }
    if !stale.isEmpty { save(); MoshLog.log("moshify", "purged \(stale.count) tracks gone from the server") }
  }

  // Least-recently-played first, never a protected key (playing / downloading / the prefetch
  // window). Returns how many bytes were freed.
  @discardableResult
  func evict(toFit cap: UInt64, protected: Set<String>) -> UInt64 {
    var freed: UInt64 = 0
    while totalSize > cap {
      let candidates = entries.filter { !protected.contains($0.key) }
      guard let victim = candidates.min(by: {
        ($0.value.lastPlayed ?? .distantPast) < ($1.value.lastPlayed ?? .distantPast)
      }) else { break }
      freed += victim.value.size
      try? FileManager.default.removeItem(at: dir.appendingPathComponent(victim.value.fileName))
      entries.removeValue(forKey: victim.key)
    }
    if freed > 0 { save(); MoshLog.log("moshify", "LRU evicted \(freed) bytes") }
    return freed
  }

  // Whether a new download of `incoming` bytes can fit under the cap after evicting only
  // unprotected entries. `planned` is bytes already promised to queued prefetches.
  func canFit(incoming: UInt64, planned: UInt64, cap: UInt64, protected: Set<String>) -> Bool {
    let protectedBytes = entries.reduce(UInt64(0)) { sum, kv in
      protected.contains(kv.key) ? sum + kv.value.size : sum
    }
    return protectedBytes + planned + incoming <= cap
  }

  // The whole host library goes away (host/folder changed in setup).
  func wipe() {
    try? FileManager.default.removeItem(at: dir)
    entries = [:]
    save()
  }
}

// MARK: - SFTP worker

// The Moshify SFTP session: MoshxploreSession's run-loop-thread skeleton, but with a REAL op
// queue — one self-contained op at a time (SFTP over one channel is serial anyway), user ops
// jumping ahead of prefetches, one lazy redial retry for idempotent ops. This is what lets a
// ten-deep prefetch window coexist with "the user just tapped an uncached track".
final class MoshifySession {

  enum Priority { case user, prefetch }

  private final class Op {
    let priority: Priority
    let retryOnReconnect: Bool
    let remotePath: String?    // downloads carry it for dedupe/cancel; scans and deletes vary
    let describe: String
    var attempts = 0
    // Builds the pipeline against the connected root. MUST deliver user-facing SUCCESS itself
    // (hopping to main), then report to `done`. On failure it reports ONLY to `done` — the
    // session decides between a redial retry and delivering `deliverFailure`.
    let make: (Translator, @escaping (Error?) -> Void) -> AnyCancellable
    let deliverFailure: (Error) -> Void

    init(priority: Priority, retryOnReconnect: Bool, remotePath: String?, describe: String,
         make: @escaping (Translator, @escaping (Error?) -> Void) -> AnyCancellable,
         deliverFailure: @escaping (Error) -> Void) {
      self.priority = priority
      self.retryOnReconnect = retryOnReconnect
      self.remotePath = remotePath
      self.describe = describe
      self.make = make
      self.deliverFailure = deliverFailure
    }
  }

  private var thread: Thread?
  private var runLoopRef: CFRunLoop?
  private let ready = DispatchSemaphore(value: 0)
  private var alive = false

  // Worker-thread state.
  private var pending: [Op] = []
  private var activeOp: Op?
  private var activeC: AnyCancellable?
  private var dialC: AnyCancellable?
  private var root: Translator?
  private var hostAlias: String?
  private weak var device: TermDevice?

  // MARK: worker plumbing (MoshxploreSession's exact skeleton)

  private func start() {
    guard thread == nil else { return }
    let t = Thread { [weak self] in
      guard let self else { return }
      let keepAlive = Port()
      RunLoop.current.add(keepAlive, forMode: .default)
      self.runLoopRef = CFRunLoopGetCurrent()
      self.alive = true
      self.ready.signal()
      while self.alive {
        RunLoop.current.run(mode: .default, before: .distantFuture)
      }
      RunLoop.current.remove(keepAlive, forMode: .default)
    }
    t.name = "moshify.sftp"
    t.stackSize = 2 << 20
    thread = t
    t.start()
    ready.wait()
  }

  private func onWorker(_ block: @escaping () -> Void) {
    guard let rl = runLoopRef else { return }
    CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, block)
    CFRunLoopWakeUp(rl)
  }

  // MARK: public API (call on main; completions on main)

  // The alias and the interactive device (a LIVE terminal tab's; weak — never retained past its
  // tab). Key auth against a known host never touches the device; it exists for first-connect
  // prompts.
  func configure(hostAlias: String, device: TermDevice?) {
    start()
    onWorker { [weak self] in
      guard let self else { return }
      if self.hostAlias != hostAlias {
        self.root = nil   // different host: the old connection is meaningless
      }
      self.hostAlias = hostAlias
      self.device = device
    }
  }

  func updateDevice(_ device: TermDevice?) {
    onWorker { [weak self] in self?.device = device }
  }

  // Recursive scan of the library folder for audio files, depth-capped, dotfiles and symlinks
  // skipped (no cycles), one directory at a time.
  func scan(folder: String, completion: @escaping (Result<[MoshifyTrack], Error>) -> Void) {
    start()
    enqueue(Op(priority: .user, retryOnReconnect: true, remotePath: nil, describe: "scan",
               make: { root, done in
      Self.listRecursive(root: root, base: folder, depth: Moshify.scanDepth, visited: ScanVisited())
        .sink(receiveCompletion: { c in
          if case .failure(let e) = c { done(e) }
        }, receiveValue: { tracks in
          let sorted = tracks.sorted { $0.remotePath.localizedCaseInsensitiveCompare($1.remotePath) == .orderedAscending }
          DispatchQueue.main.async { completion(.success(sorted)) }
          done(nil)
        })
    }, deliverFailure: { e in completion(.failure(e)) }))
  }

  // One file, staged under Caches and MOVED onto `destination` only when complete — a cancelled
  // or failed transfer can never poison the visible library folder.
  func download(track: MoshifyTrack, to destination: URL, priority: Priority,
                progress: @escaping (Double) -> Void,
                completion: @escaping (Result<URL, Error>) -> Void) {
    start()
    onWorker { [weak self] in
      guard let self else { return }
      // Dedupe: the same file queued or running is a no-op (the window rebuild re-asks).
      if self.activeOp?.remotePath == track.remotePath { return }
      if self.pending.contains(where: { $0.remotePath == track.remotePath }) { return }

      let op = Op(priority: priority, retryOnReconnect: true, remotePath: track.remotePath,
                  describe: "download \(priority)",
                  make: { root, done in
        let staging = Moshify.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let localDir = MoshroomFiles.Local().walkTo(staging.path)
        let remote = root.cloneWalkTo(track.remotePath)
        var sent: UInt64 = 0
        return Publishers.Zip(localDir, remote)
          .flatMap { ldir, rfile in
            ldir.copy(from: [rfile], args: CopyArguments(preserve: CopyAttributesFlag([]), checkTimes: false))
          }
          .sink(receiveCompletion: { c in
            switch c {
            case .finished:
              let fm = FileManager.default
              let staged = staging.appendingPathComponent(track.fileName)
              do {
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: staged, to: destination)
                try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: destination.path)
                try? fm.removeItem(at: staging)
                DispatchQueue.main.async { completion(.success(destination)) }
                done(nil)
              } catch {
                try? fm.removeItem(at: staging)
                done(error)
              }
            case .failure(let e):
              try? FileManager.default.removeItem(at: staging)
              done(e)
            }
          }, receiveValue: { info in
            guard info.size > 0 else { return }
            sent += info.written
            let frac = min(1.0, Double(sent) / Double(info.size))
            DispatchQueue.main.async { progress(frac) }
          })
      }, deliverFailure: { e in completion(.failure(e)) })

      // A user download outranks a running prefetch: kill the prefetch (its staging dir is
      // cleaned by its own failure path being cancelled — the unique staging dir leaks at worst
      // until the next launch sweep) and let the engine's window rebuild re-ask for it.
      if let active = self.activeOp, active.priority == .prefetch, op.priority == .user {
        self.activeC = nil
        self.activeOp = nil
        MoshLog.log("moshify", "prefetch preempted by user download")
      }
      self.pending.append(op)
      self.pump()
    }
  }

  // Deletes NEVER auto-retry: a half-applied unlink is ambiguous.
  func delete(remotePath: String, completion: @escaping (Result<Void, Error>) -> Void) {
    start()
    enqueue(Op(priority: .user, retryOnReconnect: false, remotePath: remotePath, describe: "delete",
               make: { root, done in
      root.cloneWalkTo(remotePath)
        .flatMap { $0.remove() }
        .sink(receiveCompletion: { c in
          if case .failure(let e) = c { done(e) }
        }, receiveValue: { _ in
          DispatchQueue.main.async { completion(.success(())) }
          done(nil)
        })
    }, deliverFailure: { e in completion(.failure(e)) }))
  }

  // The engine rebuilt its window: every queued prefetch is stale (it re-enqueues what it wants).
  func cancelPrefetches() {
    onWorker { [weak self] in
      guard let self else { return }
      self.pending.removeAll { $0.priority == .prefetch }
      if let active = self.activeOp, active.priority == .prefetch {
        self.activeC = nil
        self.activeOp = nil
        self.pump()
      }
    }
  }

  func stop() {
    guard let rl = runLoopRef else { return }
    CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
      self?.pending.removeAll()
      self?.activeC = nil
      self?.activeOp = nil
      self?.dialC = nil
      self?.root = nil
      self?.hostAlias = nil
      self?.alive = false
      CFRunLoopStop(CFRunLoopGetCurrent())
    }
    CFRunLoopWakeUp(rl)
    runLoopRef = nil
    thread = nil
  }

  // MARK: queue internals (worker thread only)

  private func enqueue(_ op: Op) {
    onWorker { [weak self] in
      self?.pending.append(op)
      self?.pump()
    }
  }

  private func pump() {
    guard activeOp == nil, dialC == nil, !pending.isEmpty else { return }
    guard let root else { dial(); return }
    let idx = pending.firstIndex { $0.priority == .user } ?? 0
    let op = pending.remove(at: idx)
    activeOp = op
    activeC = op.make(root) { [weak self] error in
      self?.onWorker { self?.finish(op: op, error: error) }
    }
  }

  private func finish(op: Op, error: Error?) {
    guard activeOp === op else { return }   // preempted/cancelled ops report into the void
    activeOp = nil
    activeC = nil
    if let error {
      if op.retryOnReconnect, op.attempts == 0 {
        // Lazy reconnect: drop the (possibly stale) connection and run the op once more through
        // a fresh dial — this heals server-side idle timeouts after a suspension.
        op.attempts += 1
        root = nil
        pending.insert(op, at: 0)
        MoshLog.log("moshify", "op \(op.describe) failed, retrying over a fresh dial")
      } else {
        DispatchQueue.main.async { op.deliverFailure(error) }
      }
    }
    pump()
  }

  private func dial() {
    guard dialC == nil else { return }
    guard let alias = hostAlias else { failAll(MoshifyError.notConfigured); return }
    // No terminal needed: a music tab connects on its own (see SSHClientConfigProvider — saved keys
    // and saved passwords work headless, anything needing an answer says so).
    let target: (hostName: String, host: MoshSSHHost, config: SSHClientConfig)
    do {
      target = try MoshroomSSH.resolveTarget(hostAlias: alias, device: device)   // device may be nil
    } catch {
      failAll(error)
      return
    }
    MoshLog.log("moshify", "dialing \(alias)")
    dialC = SSHClient.dial(target.hostName, with: target.config, withProxy: MoshroomSSH.executeProxyCommand)
      .flatMap { $0.requestSFTP() }
      .tryMap { try SFTPTranslator(on: $0) as Translator }
      .timeout(.seconds(30), scheduler: RunLoop.current, customError: { MoshifyError.timeout })
      .sink(receiveCompletion: { [weak self] c in
        guard let self else { return }
        self.dialC = nil
        if case .failure(let e) = c { self.failAll(e) }
      }, receiveValue: { [weak self] translator in
        guard let self else { return }
        self.dialC = nil
        self.root = translator
        self.pump()
      })
  }

  // A failed dial fails every queued op honestly — an unreachable host must not loop.
  private func failAll(_ error: Error) {
    let ops = pending
    pending.removeAll()
    DispatchQueue.main.async { ops.forEach { $0.deliverFailure(error) } }
  }

  /// Every directory this scan has already walked, by CANONICAL path. Only the link branch consults
  /// it, and that is enough: a plain tree cannot repeat itself, a link is the only way back up it.
  /// Lives for one scan, touched only from the SFTP worker thread (every op there is serial).
  private final class ScanVisited {
    var canonical = Set<String>()
  }

  // A depth-capped, serial BFS over the library folder. Skips dotfiles and any name containing "/"
  // (the sweepRemote leaf-safety trick). A symlink is RESOLVED before it is judged, through the one
  // shared rule (Translator.moshroomStatFollowingLinks): a linked track plays, a linked album folder
  // is walked like any other but through its canonical path and only once — which is what keeps a
  // link pointing back up the tree from being walked for ever — and a broken link is skipped.
  private static func listRecursive(root: Translator, base: String, depth: Int,
                                    visited: ScanVisited) -> AnyPublisher<[MoshifyTrack], Error> {
    root.cloneWalkTo(base)
      .flatMap { dir -> AnyPublisher<[FileAttributes], Error> in
        visited.canonical.insert(dir.current)
        return dir.directoryFilesAndAttributes()
      }
      .flatMap { rows -> AnyPublisher<[MoshifyTrack], Error> in
        var tracks: [MoshifyTrack] = []
        var subdirs: [String] = []
        var links: [String] = []
        for attrs in rows {
          guard let name = attrs[.name] as? String, !name.isEmpty,
                name != ".", name != "..",
                !name.hasPrefix("."), !name.contains("/") else { continue }
          let type = attrs[.type] as? FileAttributeType
          if type == .typeSymbolicLink {
            links.append(name)
            continue
          }
          if type == .typeDirectory {
            if depth > 0 { subdirs.append(name) }
            continue
          }
          guard type == .typeRegular else { continue }
          let ext = (name as NSString).pathExtension.lowercased()
          guard Moshify.audioExtensions.contains(ext) else { continue }
          let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
          tracks.append(MoshifyTrack(remotePath: base + "/" + name, fileName: name, size: size))
        }

        var branches: [AnyPublisher<[MoshifyTrack], Error>] = subdirs.map { sub in
          listRecursive(root: root, base: base + "/" + sub, depth: depth - 1, visited: visited)
        }
        branches += links.map { name in
          Self.linkBranch(root: root, base: base, name: name, depth: depth, visited: visited)
        }
        guard !branches.isEmpty else {
          return Just(tracks).setFailureType(to: Error.self).eraseToAnyPublisher()
        }
        return Publishers.Sequence(sequence: branches)
          .flatMap(maxPublishers: .max(1)) { $0 }
          .collect()
          .map { tracks + $0.flatMap { $0 } }
          .eraseToAnyPublisher()
      }
      .eraseToAnyPublisher()
  }

  /// One symlink, resolved: a track if it points at audio, a walk if it points at a folder nobody has
  /// walked yet, nothing at all if it is broken. A link that cannot be read is not a scan failure.
  private static func linkBranch(root: Translator, base: String, name: String, depth: Int,
                                 visited: ScanVisited) -> AnyPublisher<[MoshifyTrack], Error> {
    let none = Just([MoshifyTrack]()).setFailureType(to: Error.self).eraseToAnyPublisher()
    return root.moshroomStatFollowingLinks(child: name, in: base)
      .flatMap { attrs -> AnyPublisher<[MoshifyTrack], Error> in
        guard let attrs, let type = attrs[.type] as? FileAttributeType else { return none }
        if type == .typeDirectory {
          guard depth > 0 else { return none }
          return root.cloneWalkTo(base + "/" + name)
            .flatMap { target -> AnyPublisher<[MoshifyTrack], Error> in
              guard visited.canonical.insert(target.current).inserted else { return none }
              return listRecursive(root: root, base: target.current, depth: depth - 1, visited: visited)
            }
            .catch { _ in none }
            .eraseToAnyPublisher()
        }
        guard type == .typeRegular,
              Moshify.audioExtensions.contains((name as NSString).pathExtension.lowercased())
        else { return none }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        return Just([MoshifyTrack(remotePath: base + "/" + name, fileName: name, size: size)])
          .setFailureType(to: Error.self)
          .eraseToAnyPublisher()
      }
      .eraseToAnyPublisher()
  }
}

// MARK: - Engine

// The singleton player. All state mutates on MAIN; the SFTP worker calls back on main. The tab
// page is a thin observer over NotificationCenter — music survives tab switches and the surface
// closing; closing the Moshify TAB calls shutdown() (tab semantics: close = stop).
final class MoshifyEngine: NSObject, AVAudioPlayerDelegate {

  static let shared = MoshifyEngine()

  enum State: Equatable {
    case idle
    case connecting
    case ready
    case downloading(MoshifyTrack, Double)   // a BLOCKING fetch (tap / gap) — never a prefetch
    case playing(MoshifyTrack)
    case paused(MoshifyTrack)
    case error(String)                        // tracks retained so the list still renders

    // The state's SHAPE, download fraction ignored: stateDidChange fires on shape changes only,
    // while fraction ticks ride the throttled progress notification — otherwise every SFTP chunk
    // of a blocking fetch would reload the whole player UI.
    var shape: State {
      if case .downloading(let t, _) = self { return .downloading(t, 0) }
      return self
    }
  }

  private(set) var state: State = .idle {
    didSet {
      guard state.shape != oldValue.shape else { return }
      NotificationCenter.default.post(name: .moshifyStateDidChange, object: nil)
    }
  }

  /// Which music tab the engine currently belongs to. There is ONE audio pipeline in the app, so
  /// there is one owner: starting a library in another tab takes it over and stops what was
  /// playing. nil means nobody has claimed it this run (a fresh launch, or the owner tab closed).
  private(set) var ownerKey: UUID?

  private(set) var tracks: [MoshifyTrack] = []
  private(set) var currentTrack: MoshifyTrack?
  private(set) var prefetch: (track: MoshifyTrack, fraction: Double)?

  // The provider re-resolves a LIVE terminal device at every use — never a retained one (a closed
  // tab's device has fclosed streams; writing into it is a crash, per the TermDevice teardown).
  var deviceProvider: (() -> TermDevice?)?

  var shuffle: Bool {
    get { UserDefaults.standard.bool(forKey: Moshify.shuffleKey) }
    set {
      // Remembered across launches, and OFF until the user asks for it (a bare UserDefaults bool
      // starts false — nothing here or anywhere else turns it on by itself).
      UserDefaults.standard.set(newValue, forKey: Moshify.shuffleKey)
      MoshLog.log("moshify", "shuffle \(newValue ? "on" : "off")")
      bag.removeAll()
      rebuildUpcoming()
      NotificationCenter.default.post(name: .moshifyStateDidChange, object: nil)
    }
  }

  var elapsed: TimeInterval { player?.currentTime ?? 0 }
  var duration: TimeInterval { player?.duration ?? 0 }

  var currentIndex: Int? { currentTrack.flatMap { t in tracks.firstIndex(of: t) } }

  private let session = MoshifySession()
  private var cache: MoshifyCache?
  private var player: AVAudioPlayer?
  private var intendsToPlay = false
  private var upcoming: [MoshifyTrack] = []
  private var bag: [String] = []            // shuffle bag of cacheKeys — no repeats until dry
  private var consecutiveFailures = 0
  private var gapTask: UIBackgroundTaskIdentifier = .invalid
  private var remoteCommandsInstalled = false
  private var audioSessionConfigured = false
  private var lastProgressPost = Date.distantPast

  private override init() {
    super.init()
    try? FileManager.default.removeItem(at: Moshify.stagingDirectory)   // stale .part leftovers
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(_interruption(_:)),
                   name: AVAudioSession.interruptionNotification, object: nil)
    nc.addObserver(self, selector: #selector(_routeChange(_:)),
                   name: AVAudioSession.routeChangeNotification, object: nil)
    nc.addObserver(self, selector: #selector(_mediaReset),
                   name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
  }

  // MARK: configuration

  var isConfigured: Bool { Moshify.configuredHost != nil && Moshify.configuredFolder != nil }

  /// Point the engine at a library and hand it to `owner`. Whatever was playing stops: one sound
  /// at a time, by construction.
  func configure(hostAlias: String, folder: String, owner: UUID) {
    let handover = (ownerKey != owner)
    ownerKey = owner
    let previousHost = Moshify.configuredHost
    if let previousHost, previousHost != hostAlias {
      // A different host: the old library is meaningless. Clean and ordered.
      MoshifyCache(host: previousHost).wipe()
    }
    UserDefaults.standard.set(hostAlias, forKey: Moshify.hostKey)
    UserDefaults.standard.set(folder, forKey: Moshify.folderKey)
    stopPlayback()
    tracks = []
    cache = MoshifyCache(host: hostAlias)
    MoshLog.log("moshify", "configured host + folder")
    if handover { NotificationCenter.default.post(name: .moshifyOwnerDidChange, object: nil) }
    refreshLibrary()
  }

  /// What this track lasts, if the file has ever been on the device (see MoshifyCache.noteDuration).
  func duration(of track: MoshifyTrack) -> TimeInterval? { cache?.duration(of: track) }

  func refreshLibrary() {
    guard let host = Moshify.configuredHost, let folder = Moshify.configuredFolder else {
      state = .idle
      return
    }
    if cache == nil { cache = MoshifyCache(host: host) }
    state = .connecting
    session.configure(hostAlias: host, device: deviceProvider?())
    session.scan(folder: folder) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let found):
        // Reached it: only now is it worth offering as a recent library.
        if let host = Moshify.configuredHost, let folder = Moshify.configuredFolder {
          Moshify.noteRecent(host: host, folder: folder)
        }
        self.tracks = found
        self.cache?.purge(notIn: found)
        if let current = self.currentTrack, !found.contains(current) {
          self.stopPlayback()
        }
        self.state = self.currentTrack.map { self.intendsToPlay ? .playing($0) : .paused($0) } ?? .ready
        self.rebuildUpcoming()
        NotificationCenter.default.post(name: .moshifyLibraryDidChange, object: nil)
        MoshLog.log("moshify", "library scanned: \(found.count) tracks")
      case .failure(let e):
        self.state = .error(Self.message(for: e))
        NotificationCenter.default.post(name: .moshifyLibraryDidChange, object: nil)
        MoshLog.log("moshify", "scan failed: \(type(of: e))")
      }
    }
  }

  func isCached(_ track: MoshifyTrack) -> Bool { cache?.isCached(track) ?? false }

  // MARK: transport

  func play(at index: Int) {
    guard tracks.indices.contains(index) else { return }
    intendsToPlay = true
    consecutiveFailures = 0
    startOrFetch(track: tracks[index])
  }

  func togglePlayPause() {
    switch state {
    case .playing:
      intendsToPlay = false
      player?.pause()
      if let t = currentTrack { state = .paused(t) }
      updateNowPlaying()
    case .paused:
      intendsToPlay = true
      activateAudioSession()
      player?.play()
      if let t = currentTrack { state = .playing(t) }
      updateNowPlaying()
    case .ready, .idle, .error:
      if tracks.isEmpty {
        // Nothing scanned (a failed connect, a fresh restore): play = try the library again.
        if isConfigured { refreshLibrary() }
        return
      }
      // Nothing loaded yet: start from the top (or the shuffle draw).
      if let first = upcoming.first ?? tracks.first {
        intendsToPlay = true
        startOrFetch(track: first)
      }
    case .connecting, .downloading:
      break
    }
  }

  func next() {
    guard !tracks.isEmpty else { return }
    intendsToPlay = true
    advance()
  }

  // MARK: delete (exact ordering: advance → unlink → only then forget)

  func deleteTrack(_ track: MoshifyTrack, completion: @escaping (String?) -> Void) {
    if track == currentTrack {
      if tracks.count <= 1 {
        stopPlayback()
        state = .ready
      } else {
        advance()
      }
    }
    session.updateDevice(deviceProvider?())
    session.delete(remotePath: track.remotePath) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        self.cache?.remove(track)
        self.tracks.removeAll { $0 == track }
        self.bag.removeAll { $0 == track.cacheKey }
        if self.upcoming.contains(track) { self.rebuildUpcoming() }
        NotificationCenter.default.post(name: .moshifyLibraryDidChange, object: nil)
        MoshLog.log("moshify", "track deleted on server")
        completion(nil)
      case .failure(let e):
        completion(Self.message(for: e))
      }
    }
  }

  // MARK: teardown

  // Closing the Moshify tab stops the music — tab semantics. Config and cache stay for next time.
  func shutdown() {
    ownerKey = nil
    stopPlayback()
    session.stop()
    tracks = []
    upcoming = []
    bag = []
    state = .idle
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    if audioSessionConfigured {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      audioSessionConfigured = false
    }
    MoshLog.log("moshify", "engine shut down")
    NotificationCenter.default.post(name: .moshifyOwnerDidChange, object: nil)
  }

  // MARK: playback internals

  private func startOrFetch(track: MoshifyTrack) {
    guard let cache else { return }
    if let url = cache.localURL(for: track) {
      startPlayback(track: track, url: url)
      return
    }
    state = .downloading(track, 0)
    beginGapTaskIfNeeded()
    session.updateDevice(deviceProvider?())
    session.cancelPrefetches()
    let destination = cache.destinationURL(for: track)
    session.download(track: track, to: destination, priority: .user, progress: { [weak self] frac in
      guard let self, case .downloading(let t, _) = self.state, t == track else { return }
      self.state = .downloading(track, frac)
      self.postProgressThrottled()
    }, completion: { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let url):
        self.cache?.noteDownloaded(track, at: url)
        self.evictAroundWindow()
        self.startPlayback(track: track, url: url)
      case .failure(let e):
        self.endGapTask()
        self.state = .error(Self.message(for: e))
        MoshLog.log("moshify", "user fetch failed: \(type(of: e))")
      }
    })
  }

  private func startPlayback(track: MoshifyTrack, url: URL) {
    activateAudioSession()
    do {
      let p = try AVAudioPlayer(contentsOf: url)
      p.delegate = self
      player = p
      currentTrack = track
      consecutiveFailures = 0
      if intendsToPlay {
        p.play()
        state = .playing(track)
      } else {
        state = .paused(track)
      }
      endGapTask()
      cache?.notePlayed(track)
      cache?.noteDuration(p.duration, for: track)
      rebuildUpcoming()
      updateNowPlaying()
      installRemoteCommandsIfNeeded()
    } catch {
      // A corrupt or purged file: evict it and skip on — but never loop forever.
      MoshLog.log("moshify", "player init failed, skipping track")
      cache?.remove(track)
      consecutiveFailures += 1
      if consecutiveFailures >= 3 {
        endGapTask()
        state = .error("Several tracks failed to play.")
        return
      }
      advance()
    }
  }

  private func stopPlayback() {
    player?.stop()
    player = nil
    currentTrack = nil
    intendsToPlay = false
    endGapTask()
    upcoming = []
  }

  private func advance(auto: Bool = false) {
    guard !tracks.isEmpty else { return }
    let nextTrack = upcoming.first ?? tracks.first!
    startOrFetch(track: nextTrack)
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    guard intendsToPlay else { return }
    advance(auto: true)
  }

  // MARK: the prefetch window

  // The next ten tracks, decided when a track starts so prefetch and advance can never disagree.
  // Shuffle draws from the no-repeat bag; sequential walks the list wrapping. Downloads enqueue
  // IN ORDER at prefetch priority — the serial queue fetches them one after another.
  private func rebuildUpcoming() {
    session.cancelPrefetches()
    upcoming = []
    prefetch = nil
    guard let cache, tracks.count > 1 else { return }
    let want = min(Moshify.prefetchWindow, tracks.count - 1)
    if shuffle {
      var taken = Set<String>()
      if let c = currentTrack { taken.insert(c.cacheKey) }
      while upcoming.count < want {
        bag.removeAll { taken.contains($0) }
        if bag.isEmpty {
          bag = tracks.map { $0.cacheKey }.filter { !taken.contains($0) }.shuffled()
          if bag.isEmpty { break }
        }
        let key = bag.removeFirst()
        taken.insert(key)
        if let t = tracks.first(where: { $0.cacheKey == key }) { upcoming.append(t) }
      }
    } else {
      let start = (currentIndex ?? -1) + 1
      for i in 0..<want {
        upcoming.append(tracks[(start + i) % tracks.count])
      }
    }

    // Enqueue the window's missing files in order, respecting the cap: protected = playing +
    // the whole window; a track that cannot fit ends the prefetch run (the cap always wins).
    var protected = Set(upcoming.map { $0.cacheKey })
    if let c = currentTrack { protected.insert(c.cacheKey) }
    var planned: UInt64 = 0
    let cap = Moshify.cacheCapBytes
    session.updateDevice(deviceProvider?())
    for track in upcoming where !cache.isCached(track) {
      guard cache.canFit(incoming: track.size, planned: planned, cap: cap, protected: protected) else {
        MoshLog.log("moshify", "prefetch stopped by cache cap")
        break
      }
      planned += track.size
      let destination = cache.destinationURL(for: track)
      session.download(track: track, to: destination, priority: .prefetch, progress: { [weak self] frac in
        guard let self else { return }
        self.prefetch = (track, frac)
        self.postProgressThrottled()
      }, completion: { [weak self] result in
        guard let self else { return }
        self.prefetch = nil
        if case .success(let url) = result {
          self.cache?.noteDownloaded(track, at: url)
          self.evictAroundWindow()
          NotificationCenter.default.post(name: .moshifyLibraryDidChange, object: nil)
        }
      })
    }
    evictAroundWindow()
  }

  private func evictAroundWindow() {
    guard let cache else { return }
    var protected = Set(upcoming.map { $0.cacheKey })
    if let c = currentTrack { protected.insert(c.cacheKey) }
    if case .downloading(let t, _) = state { protected.insert(t.cacheKey) }
    cache.evict(toFit: Moshify.cacheCapBytes, protected: protected)
  }

  private func postProgressThrottled() {
    let now = Date()
    guard now.timeIntervalSince(lastProgressPost) > 0.1 else { return }
    lastProgressPost = now
    NotificationCenter.default.post(name: .moshifyProgressDidChange, object: nil)
  }

  // MARK: audio session + interruptions

  private func activateAudioSession() {
    let s = AVAudioSession.sharedInstance()
    if !audioSessionConfigured {
      try? s.setCategory(.playback, mode: .default)
      audioSessionConfigured = true
    }
    try? s.setActive(true)
  }

  @objc private func _interruption(_ note: Notification) {
    guard let info = note.userInfo,
          let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    switch type {
    case .began:
      if case .playing(let t) = state {
        player?.pause()
        state = .paused(t)
        updateNowPlaying()
      }
    case .ended:
      let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
      if opts.contains(.shouldResume), intendsToPlay, case .paused(let t) = state {
        activateAudioSession()
        player?.play()
        state = .playing(t)
        updateNowPlaying()
      }
    @unknown default:
      break
    }
  }

  @objc private func _routeChange(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
          reason == .oldDeviceUnavailable else { return }
    // The classic headphones-unplugged: pause, never blast the speaker.
    DispatchQueue.main.async { [weak self] in
      guard let self, case .playing(let t) = self.state else { return }
      self.intendsToPlay = false
      self.player?.pause()
      self.state = .paused(t)
      self.updateNowPlaying()
    }
  }

  @objc private func _mediaReset() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.audioSessionConfigured = false
      guard let track = self.currentTrack, let url = self.cache?.localURL(for: track) else { return }
      let position = self.player?.currentTime ?? 0
      self.player = try? AVAudioPlayer(contentsOf: url)
      self.player?.delegate = self
      self.player?.currentTime = position
      self.intendsToPlay = false
      self.state = .paused(track)
      self.updateNowPlaying()
    }
  }

  // MARK: background gap

  // While audio plays the app runs unbounded; the dangerous window is the GAP — a track ends in
  // background with the next one not yet cached. A background task + the still-active audio
  // session buy the download time; if iOS still suspends us, the state stays .downloading and
  // playback resumes when the app is next opened (the op retries over a fresh dial).
  private func beginGapTaskIfNeeded() {
    guard intendsToPlay, gapTask == .invalid else { return }
    gapTask = UIApplication.shared.beginBackgroundTask(withName: "moshify.gap") { [weak self] in
      self?.endGapTask()
    }
  }

  private func endGapTask() {
    guard gapTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(gapTask)
    gapTask = .invalid
  }

  // MARK: lock screen / now playing

  private func installRemoteCommandsIfNeeded() {
    guard !remoteCommandsInstalled else { return }
    remoteCommandsInstalled = true
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.addTarget { [weak self] _ in
      guard let self, case .paused = self.state else { return .commandFailed }
      self.togglePlayPause()
      return .success
    }
    center.pauseCommand.addTarget { [weak self] _ in
      guard let self, case .playing = self.state else { return .commandFailed }
      self.togglePlayPause()
      return .success
    }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.togglePlayPause()
      return .success
    }
    center.nextTrackCommand.addTarget { [weak self] _ in
      self?.next()
      return .success
    }
    // No previous, no seek, no skip: the lock screen must not render controls we don't have.
    center.previousTrackCommand.isEnabled = false
    center.changePlaybackPositionCommand.isEnabled = false
    center.skipForwardCommand.isEnabled = false
    center.skipBackwardCommand.isEnabled = false
    center.seekForwardCommand.isEnabled = false
    center.seekBackwardCommand.isEnabled = false
  }

  private func updateNowPlaying() {
    guard let track = currentTrack else {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      return
    }
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: track.title,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]
    if let p = player {
      info[MPMediaItemPropertyPlaybackDuration] = p.duration
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p.currentTime
      info[MPNowPlayingInfoPropertyPlaybackRate] = p.isPlaying ? 1.0 : 0.0
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private static func message(for error: Error) -> String {
    if case let FileError.Fail(msg) = error { return msg }
    return error.localizedDescription
  }
}

// MARK: - Progress line

// A hand-rolled progress line: UIProgressView renders its fill GRAY under Mac Catalyst no matter
// what progressTintColor says, so the mushroom-red progress look is painted by us — a faint red
// track with a red fill whose width follows `progress`.
final class MoshifyProgressLine: UIView {
  private let fill = UIView()

  var progress: Float = 0 {
    didSet { setNeedsLayout() }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = UIColor.moshroomTint.withAlphaComponent(Moshstyle.faintTintAlpha)
    layer.cornerRadius = 2
    clipsToBounds = true
    fill.backgroundColor = .moshroomTint
    addSubview(fill)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func layoutSubviews() {
    super.layoutSubviews()
    let w = bounds.width * CGFloat(min(max(progress, 0), 1))
    fill.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
  }
}

// MARK: - Track row

/// One track: a card with the title, its length and size underneath, and the cached dot. A card
/// (not a bare table row) so rows have air between them and the playing one reads as a filled
/// mushroom pill — the same row language as Moshxplore's listings.
final class MoshifyTrackCell: UITableViewCell {

  static let reuseID = "MoshifyTrackCell"
  static let height: CGFloat = 68

  private let card = UIView()
  private let title = UILabel()
  private let meta = UILabel()
  private let dot = UIImageView()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none

    card.translatesAutoresizingMaskIntoConstraints = false
    card.layer.cornerRadius = Moshstyle.rowRadius
    contentView.addSubview(card)

    title.translatesAutoresizingMaskIntoConstraints = false
    title.font = .systemFont(ofSize: 15, weight: .regular)
    title.lineBreakMode = .byTruncatingMiddle
    meta.translatesAutoresizingMaskIntoConstraints = false
    meta.font = .systemFont(ofSize: 12)
    dot.translatesAutoresizingMaskIntoConstraints = false
    dot.contentMode = .center
    dot.setContentHuggingPriority(.required, for: .horizontal)

    let labels = UIStackView(arrangedSubviews: [title, meta])
    labels.axis = .vertical
    labels.spacing = 3
    labels.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(labels)
    card.addSubview(dot)

    NSLayoutConstraint.activate([
      // The 5pt inset IS the gap between rows.
      card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
      card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
      card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      labels.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
      labels.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      labels.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -10),
      dot.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
      dot.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 12),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func configure(title trackTitle: String, meta metaText: String, isCurrent: Bool, cached: Bool) {
    title.text = trackTitle
    title.font = .systemFont(ofSize: 15, weight: isCurrent ? .semibold : .regular)
    title.textColor = isCurrent ? .white : MoshxploreStyle.dark
    meta.text = metaText
    meta.textColor = isCurrent ? UIColor(white: 1, alpha: 0.85) : MoshxploreStyle.gray
    card.backgroundColor = isCurrent ? .moshroomTint : MoshxploreStyle.row
    dot.isHidden = !cached
    dot.image = UIImage(systemName: "circle.fill",
                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 7))?
      .withTintColor(isCurrent ? .white : UIColor.moshroomTint.withAlphaComponent(0.7),
                     renderingMode: .alwaysOriginal)
  }
}

// MARK: - Mini player (top bar of every other tab)

/// The music keeps playing when you leave its tab, so the chrome carries the controls: one compact
/// white capsule to the LEFT of the launcher key with play/pause, skip and the song's title. Tapping
/// the title jumps to the tab that owns the music. Sized to sit on one line next to the Tabs key and
/// the tab pill on a phone, with the title taking whatever room is left.
final class MoshifyMiniPlayer: UIView {

  private let playButton = moshButton()
  private let nextButton = moshButton()
  private let titleLabel = UILabel()
  var onOpen: (() -> Void)?

  static let height: CGFloat = 34

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = Moshstyle.chipFill
    layer.cornerRadius = Self.height / 2
    Moshstyle.applyChipShadow(layer)

    playButton.setMoshIcon("play.fill", pointSize: 12, weight: .semibold)
    playButton.addAction(UIAction { _ in MoshifyEngine.shared.togglePlayPause() }, for: .touchUpInside)
    nextButton.setMoshIcon("forward.end.fill", pointSize: 11, weight: .semibold)
    nextButton.addAction(UIAction { _ in MoshifyEngine.shared.next() }, for: .touchUpInside)

    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    titleLabel.textColor = Moshstyle.ink
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.isUserInteractionEnabled = true
    titleLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(_open)))

    let stack = UIStackView(arrangedSubviews: [playButton, nextButton, titleLabel])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      playButton.widthAnchor.constraint(equalToConstant: 16),
      nextButton.widthAnchor.constraint(equalToConstant: 16),
      // Long titles truncate instead of pushing the tab pill off the bar.
      titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  @objc private func _open() { onOpen?() }

  /// True when there is music to control. Reads the engine; the caller owns the visibility.
  @discardableResult
  func sync() -> Bool {
    let engine = MoshifyEngine.shared
    switch engine.state {
    case .playing(let t):
      titleLabel.text = t.title
      playButton.setMoshIcon("pause.fill", pointSize: 12, weight: .semibold)
      return true
    case .paused(let t):
      titleLabel.text = t.title
      playButton.setMoshIcon("play.fill", pointSize: 12, weight: .semibold)
      return true
    case .downloading(let t, _):
      titleLabel.text = t.title
      playButton.setMoshIcon("play.fill", pointSize: 12, weight: .semibold)
      return true
    default:
      return false
    }
  }
}

// MARK: - The Moshify tab

// A thin observer over the engine, plus the one-time setup flow (pick a host → pick a folder).
// Plain UIKit on purpose — a UIHostingController page renders nothing on Catalyst inside the
// tabs page VC. The page rests on the live root ground (the Part A rule) so it never cuts a
// different black into the strips around the viewport.
final class MoshifyTabController: UIViewController, MoshroomTabPage,
                                  UITableViewDataSource, UITableViewDelegate {

  let moshroomTabKey: UUID
  var moshroomTabKind: MoshroomTabKind { .moshify }
  /// The library this tab plays — host and folder name — because the row's music glyph already
  /// says what kind of tab it is. A tab still choosing (its picker is up, or another tab took the
  /// engine) has no library to name yet.
  var moshroomTabTitle: String? {
    let engine = MoshifyEngine.shared
    guard engine.ownerKey == moshroomTabKey,
          let host = Moshify.configuredHost,
          let folder = Moshify.configuredFolder
    else { return "Moshify" }
    return "\(host) · \(Moshify.folderName(folder))"
  }

  weak var space: SpaceController?

  private enum Step { case host, folder, player }
  private var step: Step = .player

  // Setup state — browsing reuses MoshxploreSession (connect + list are exactly its job).
  private var setupSession: MoshxploreSession?
  private var setupHost: String?
  private var setupPath = "/"
  private var setupEntries: [MoshxploreEntry] = []
  private var hostsObserver: NSObjectProtocol?

  // Player chrome.
  private let table = UITableView(frame: .zero, style: .plain)
  private let statusLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let bottomBar = UIView()
  private let nowPlayingLabel = UILabel()
  private let progressBar = MoshifyProgressLine()
  private let shuffleButton = moshkeyRoundButton()
  private let playButton = moshkeyRoundButton(diameter: 56)
  private let nextButton = moshkeyRoundButton()
  private let setupChip = moshkeyRoundButton(diameter: 34)

  // Setup chrome (built per step into `setupContainer`).
  private let setupContainer = UIView()
  private var observers: [NSObjectProtocol] = []
  /// The track the list is already centred on — see _centerCurrentTrack.
  private var _centeredKey: String?
  private var progressTimer: Timer?

  init(key: UUID = UUID()) {
    moshroomTabKey = key
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    if let hostsObserver { NotificationCenter.default.removeObserver(hostsObserver) }
    progressTimer?.invalidate()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = space?.view.backgroundColor ?? .moshroomBackground

    let engine = MoshifyEngine.shared
    engine.deviceProvider = { [weak self] in self?.space?.moshroomAnyTermDevice }

    _buildPlayerChrome()
    _buildSetupContainer()

    let nc = NotificationCenter.default
    observers = [
      nc.addObserver(forName: .moshifyStateDidChange, object: nil, queue: .main) { [weak self] _ in
        self?._syncControls()
      },
      nc.addObserver(forName: .moshifyLibraryDidChange, object: nil, queue: .main) { [weak self] _ in
        self?.table.reloadData()
        self?._syncControls()
      },
      nc.addObserver(forName: .moshifyProgressDidChange, object: nil, queue: .main) { [weak self] _ in
        self?._syncProgress()
      },
      // Another music tab took the engine: this one is no longer a player, so it goes back to its
      // picker instead of showing controls that would drive someone else's library.
      nc.addObserver(forName: .moshifyOwnerDidChange, object: nil, queue: .main) { [weak self] _ in
        guard let self, self.step == .player,
              MoshifyEngine.shared.ownerKey != self.moshroomTabKey else { return }
        self._show(step: .host)
      },
    ]

    // A music tab is its own thing: it ALWAYS opens on the picker (recents make that one tap),
    // never as a silent continuation of whatever played last. The one exception is the tab that
    // already owns the engine — switching back to it must find its player, not a wizard.
    if engine.ownerKey == moshroomTabKey, engine.isConfigured {
      _show(step: .player)
      if case .idle = engine.state { engine.refreshLibrary() }
    } else {
      _show(step: .host)
    }
    _syncControls()
  }

  func moshroomTabWillClose() {
    // Tab semantics: closing the tab stops the music — but only if this tab is the one playing.
    // Closing a music tab that had handed the engine over must not silence the tab that owns it.
    setupSession?.stop()
    setupSession = nil
    if MoshifyEngine.shared.ownerKey == moshroomTabKey {
      MoshifyEngine.shared.shutdown()
    }
  }

  // MARK: chrome building

  private func _buildPlayerChrome() {
    table.translatesAutoresizingMaskIntoConstraints = false
    table.backgroundColor = .clear
    table.separatorStyle = .none
    table.dataSource = self
    table.delegate = self
    table.register(MoshifyTrackCell.self, forCellReuseIdentifier: MoshifyTrackCell.reuseID)
    table.rowHeight = MoshifyTrackCell.height
    view.addSubview(table)

    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.backgroundColor = .clear
    view.addSubview(bottomBar)

    nowPlayingLabel.translatesAutoresizingMaskIntoConstraints = false
    nowPlayingLabel.font = .systemFont(ofSize: 14, weight: .medium)
    nowPlayingLabel.textColor = .secondaryLabel
    nowPlayingLabel.textAlignment = .center
    nowPlayingLabel.numberOfLines = 1
    bottomBar.addSubview(nowPlayingLabel)

    progressBar.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.addSubview(progressBar)

    shuffleButton.setMoshIcon("shuffle", pointSize: 17, weight: .semibold)
    shuffleButton.addAction(UIAction { _ in
      MoshifyEngine.shared.shuffle.toggle()
    }, for: .touchUpInside)
    playButton.setMoshIcon("play.fill", pointSize: 24, weight: .semibold)
    playButton.addAction(UIAction { _ in
      MoshifyEngine.shared.togglePlayPause()
    }, for: .touchUpInside)
    nextButton.setMoshIcon("forward.end.fill", pointSize: 17, weight: .semibold)
    nextButton.addAction(UIAction { _ in
      MoshifyEngine.shared.next()
    }, for: .touchUpInside)
    [shuffleButton, playButton, nextButton].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      bottomBar.addSubview($0)
    }

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.font = .preferredFont(forTextStyle: .callout)
    statusLabel.textColor = .secondaryLabel
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 0
    view.addSubview(statusLabel)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    view.addSubview(spinner)

    // The small chip that re-runs setup (change host / folder), tucked top-right of the page.
    setupChip.layer.shadowOpacity = 0
    setupChip.setMoshIcon("folder", pointSize: 14, weight: .semibold)
    setupChip.addAction(UIAction { [weak self] _ in self?._startSetup() }, for: .touchUpInside)
    setupChip.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(setupChip)

    NSLayoutConstraint.activate([
      setupChip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
      setupChip.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

      table.topAnchor.constraint(equalTo: setupChip.bottomAnchor, constant: 6),
      table.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      table.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      table.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

      bottomBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      bottomBar.heightAnchor.constraint(equalToConstant: 134),

      nowPlayingLabel.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 12),
      nowPlayingLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 24),
      nowPlayingLabel.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -24),

      progressBar.topAnchor.constraint(equalTo: nowPlayingLabel.bottomAnchor, constant: 14),
      progressBar.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 24),
      progressBar.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -24),
      progressBar.heightAnchor.constraint(equalToConstant: 4),

      playButton.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 18),
      playButton.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
      shuffleButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
      shuffleButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -34),
      nextButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
      nextButton.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 34),

      statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
      statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),
    ])
  }

  private func _buildSetupContainer() {
    setupContainer.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(setupContainer)
    NSLayoutConstraint.activate([
      setupContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      setupContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      setupContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      setupContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
    ])
    hostsObserver = NotificationCenter.default.addObserver(
      forName: HostsCloudMirror.didSaveNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self, self.step == .host else { return }
      self._buildHostStep()
    }
  }

  private func _show(step: Step) {
    self.step = step
    let player = (step == .player)
    [table, bottomBar, setupChip].forEach { $0.isHidden = !player }
    setupContainer.isHidden = player
    statusLabel.isHidden = !player
    if !player {
      switch step {
      case .host: _buildHostStep()
      case .folder: _buildFolderStep()
      case .player: break
      }
    }
    _syncControls()
  }

  private func _startSetup() {
    setupHost = nil
    setupPath = "/"
    setupEntries = []
    _show(step: .host)
  }

  private func _clearSetupContainer() {
    setupContainer.subviews.forEach { $0.removeFromSuperview() }
  }

  private func _setupTitle(_ text: String) -> UILabel {
    let l = UILabel()
    l.translatesAutoresizingMaskIntoConstraints = false
    l.text = text
    l.font = .systemFont(ofSize: 20, weight: .semibold)
    l.textColor = .label
    return l
  }

  /// A quiet heading inside the setup list ("Recent", "Browse a host").
  private func _setupGroupLabel(_ text: String) -> UILabel {
    let l = UILabel()
    l.text = text.uppercased()
    l.font = .systemFont(ofSize: 12, weight: .semibold)
    l.textColor = .secondaryLabel
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
  }

  private func _buildHostStep() {
    _clearSetupContainer()
    let title = _setupTitle("Where does your music live?")
    let subtitle = UILabel()
    subtitle.translatesAutoresizingMaskIntoConstraints = false
    subtitle.text = "Pick a saved host, then the folder with your audio files."
    subtitle.font = .preferredFont(forTextStyle: .callout)
    subtitle.textColor = .secondaryLabel
    subtitle.numberOfLines = 0

    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)

    // Recents first: a library you have played before is one tap away, host AND folder, no
    // browsing. This is what makes "every music tab asks" cheap instead of tedious.
    let recents = Moshify.recents
    if !recents.isEmpty {
      stack.addArrangedSubview(_setupGroupLabel("Recent"))
      for recent in recents {
        let b = moshHostCardButton(alias: recent.host, description: recent.folderName, icon: "music.note")
        b.addAction(UIAction { [weak self] _ in
          self?._start(host: recent.host, folder: recent.folder)
        }, for: .touchUpInside)
        stack.addArrangedSubview(b)
      }
    }

    let cards = space?.moshroomSavedHostCards ?? []
    if cards.isEmpty {
      subtitle.text = recents.isEmpty
        ? "No saved hosts yet. Add one in Settings → Hosts first."
        : "Pick a recent library, or add a host in Settings → Hosts to browse a new one."
    }
    if !cards.isEmpty && !recents.isEmpty {
      stack.addArrangedSubview(_setupGroupLabel("Browse a host"))
    }
    for card in cards {
      let b = moshHostCardButton(alias: card.alias, description: card.description)
      b.addAction(UIAction { [weak self] _ in self?._pickHost(card.alias) }, for: .touchUpInside)
      stack.addArrangedSubview(b)
    }

    setupContainer.addSubview(title)
    setupContainer.addSubview(subtitle)
    setupContainer.addSubview(scroll)
    NSLayoutConstraint.activate([
      title.topAnchor.constraint(equalTo: setupContainer.topAnchor, constant: 18),
      title.leadingAnchor.constraint(equalTo: setupContainer.leadingAnchor, constant: 20),
      title.trailingAnchor.constraint(lessThanOrEqualTo: setupContainer.trailingAnchor, constant: -20),
      subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
      subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      subtitle.trailingAnchor.constraint(equalTo: setupContainer.trailingAnchor, constant: -20),
      scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
      scroll.leadingAnchor.constraint(equalTo: setupContainer.leadingAnchor, constant: 20),
      scroll.trailingAnchor.constraint(equalTo: setupContainer.trailingAnchor, constant: -20),
      scroll.bottomAnchor.constraint(equalTo: setupContainer.bottomAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
    ])
  }

  private func _pickHost(_ alias: String) {
    // A music tab stands on its own: no terminal tab required, here or in the worker.
    let device = space?.moshroomAnyTermDevice
    setupHost = alias
    _showSetupBusy("Connecting to \(alias)…")
    let session = MoshxploreSession()
    setupSession?.stop()
    setupSession = session
    session.connect(hostAlias: alias, device: device) { [weak self] result in
      guard let self, self.setupHost == alias else { return }
      switch result {
      case .success(let home):
        self.setupPath = home
        self._loadFolder(home)
      case .failure(let e):
        self._showSetupError(e.localizedDescription)
      }
    }
  }

  private func _loadFolder(_ path: String) {
    _showSetupBusy("Loading \(path)…")
    setupSession?.list(path: path) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let entries):
        self.setupPath = path
        self.setupEntries = entries.filter { $0.isDirectory }
        self._show(step: .folder)
      case .failure(let e):
        self._showSetupError(e.localizedDescription)
      }
    }
  }

  private func _buildFolderStep() {
    _clearSetupContainer()
    let title = _setupTitle("Pick the music folder")

    let path = UILabel()
    path.translatesAutoresizingMaskIntoConstraints = false
    path.text = setupPath
    path.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    path.textColor = .secondaryLabel
    path.lineBreakMode = .byTruncatingHead

    let up = moshkeyRoundButton(diameter: 34)
    up.layer.shadowOpacity = 0
    up.setMoshIcon("chevron.up", pointSize: 14, weight: .semibold)
    up.translatesAutoresizingMaskIntoConstraints = false
    up.isEnabled = setupPath != "/"
    up.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      let parent = (self.setupPath as NSString).deletingLastPathComponent
      self._loadFolder(parent.isEmpty ? "/" : parent)
    }, for: .touchUpInside)

    let backToHosts = moshkeyRoundButton(diameter: 34)
    backToHosts.layer.shadowOpacity = 0
    backToHosts.setMoshIcon("server.rack", pointSize: 14, weight: .semibold)
    backToHosts.translatesAutoresizingMaskIntoConstraints = false
    backToHosts.addAction(UIAction { [weak self] _ in self?._startSetup() }, for: .touchUpInside)

    let list = UIScrollView()
    list.translatesAutoresizingMaskIntoConstraints = false
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    list.addSubview(stack)
    for entry in setupEntries {
      var cfg = UIButton.Configuration.filled()
      cfg.baseBackgroundColor = .secondarySystemGroupedBackground
      cfg.baseForegroundColor = .label
      cfg.background.cornerRadius = 12
      cfg.image = UIImage(systemName: "folder",
                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))?
        .withTintColor(.moshroomTint, renderingMode: .alwaysOriginal)
      cfg.imagePadding = 10
      var attr = AttributeContainer()
      attr.font = UIFont.systemFont(ofSize: 15, weight: .medium)
      cfg.attributedTitle = AttributedString(entry.name, attributes: attr)
      cfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
      let b = moshButton()
      b.configuration = cfg
      #if targetEnvironment(macCatalyst)
      b.preferredBehavioralStyle = .pad
      #endif
      b.contentHorizontalAlignment = .leading
      b.addAction(UIAction { [weak self] _ in
        guard let self else { return }
        let base = self.setupPath == "/" ? "" : self.setupPath
        self._loadFolder(base + "/" + entry.name)
      }, for: .touchUpInside)
      stack.addArrangedSubview(b)
    }

    var useCfg = UIButton.Configuration.filled()
    useCfg.baseBackgroundColor = .moshroomTint
    useCfg.baseForegroundColor = .white
    useCfg.cornerStyle = .capsule
    var useAttr = AttributeContainer()
    useAttr.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    useCfg.attributedTitle = AttributedString("Use this folder", attributes: useAttr)
    useCfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 22)
    let use = moshButton()
    use.configuration = useCfg
    #if targetEnvironment(macCatalyst)
    use.preferredBehavioralStyle = .pad
    #endif
    use.translatesAutoresizingMaskIntoConstraints = false
    use.addAction(UIAction { [weak self] _ in self?._useCurrentFolder() }, for: .touchUpInside)

    setupContainer.addSubview(title)
    setupContainer.addSubview(backToHosts)
    setupContainer.addSubview(up)
    setupContainer.addSubview(path)
    setupContainer.addSubview(list)
    setupContainer.addSubview(use)
    NSLayoutConstraint.activate([
      title.topAnchor.constraint(equalTo: setupContainer.topAnchor, constant: 18),
      title.leadingAnchor.constraint(equalTo: setupContainer.leadingAnchor, constant: 20),

      backToHosts.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      backToHosts.trailingAnchor.constraint(equalTo: setupContainer.trailingAnchor, constant: -20),
      up.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      up.trailingAnchor.constraint(equalTo: backToHosts.leadingAnchor, constant: -10),

      path.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
      path.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      path.trailingAnchor.constraint(equalTo: setupContainer.trailingAnchor, constant: -20),

      list.topAnchor.constraint(equalTo: path.bottomAnchor, constant: 12),
      list.leadingAnchor.constraint(equalTo: setupContainer.leadingAnchor, constant: 20),
      list.trailingAnchor.constraint(equalTo: setupContainer.trailingAnchor, constant: -20),
      list.bottomAnchor.constraint(equalTo: use.topAnchor, constant: -14),
      stack.topAnchor.constraint(equalTo: list.contentLayoutGuide.topAnchor),
      stack.leadingAnchor.constraint(equalTo: list.contentLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: list.contentLayoutGuide.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: list.contentLayoutGuide.bottomAnchor),
      stack.widthAnchor.constraint(equalTo: list.frameLayoutGuide.widthAnchor),

      use.centerXAnchor.constraint(equalTo: setupContainer.centerXAnchor),
      use.bottomAnchor.constraint(equalTo: setupContainer.bottomAnchor, constant: -18),
    ])
  }

  private func _useCurrentFolder() {
    guard let host = setupHost else { return }
    _start(host: host, folder: setupPath)
  }

  /// Take the engine and play this library here. The one door into the player, from both the folder
  /// browser and a recents row.
  private func _start(host: String, folder: String) {
    setupSession?.stop()
    setupSession = nil
    setupHost = host
    _show(step: .player)
    MoshifyEngine.shared.configure(hostAlias: host, folder: folder, owner: moshroomTabKey)
    MoshLog.log("moshify", "library started in this tab")
  }

  private func _showSetupBusy(_ text: String) {
    _clearSetupContainer()
    let l = _setupTitle(text)
    l.font = .preferredFont(forTextStyle: .callout)
    l.textColor = .secondaryLabel
    let s = UIActivityIndicatorView(style: .medium)
    s.translatesAutoresizingMaskIntoConstraints = false
    s.startAnimating()
    setupContainer.addSubview(l)
    setupContainer.addSubview(s)
    NSLayoutConstraint.activate([
      l.centerXAnchor.constraint(equalTo: setupContainer.centerXAnchor),
      l.centerYAnchor.constraint(equalTo: setupContainer.centerYAnchor),
      s.centerXAnchor.constraint(equalTo: setupContainer.centerXAnchor),
      s.bottomAnchor.constraint(equalTo: l.topAnchor, constant: -12),
    ])
  }

  private func _showSetupError(_ text: String) {
    _clearSetupContainer()
    let l = _setupTitle(text)
    l.font = .preferredFont(forTextStyle: .callout)
    l.textColor = .secondaryLabel
    l.numberOfLines = 0
    l.textAlignment = .center
    var cfg = UIButton.Configuration.plain()
    var attr = AttributeContainer()
    attr.font = UIFont.preferredFont(forTextStyle: .headline)
    cfg.attributedTitle = AttributedString("Back to hosts", attributes: attr)
    cfg.baseForegroundColor = .moshroomTint
    let retry = moshButton()
    retry.configuration = cfg
    #if targetEnvironment(macCatalyst)
    retry.preferredBehavioralStyle = .pad
    #endif
    retry.translatesAutoresizingMaskIntoConstraints = false
    retry.addAction(UIAction { [weak self] _ in self?._startSetup() }, for: .touchUpInside)
    setupContainer.addSubview(l)
    setupContainer.addSubview(retry)
    NSLayoutConstraint.activate([
      l.centerXAnchor.constraint(equalTo: setupContainer.centerXAnchor),
      l.centerYAnchor.constraint(equalTo: setupContainer.centerYAnchor),
      l.leadingAnchor.constraint(greaterThanOrEqualTo: setupContainer.leadingAnchor, constant: 32),
      l.trailingAnchor.constraint(lessThanOrEqualTo: setupContainer.trailingAnchor, constant: -32),
      retry.topAnchor.constraint(equalTo: l.bottomAnchor, constant: 10),
      retry.centerXAnchor.constraint(equalTo: setupContainer.centerXAnchor),
    ])
  }

  // MARK: live sync

  private func _syncControls() {
    guard step == .player else { return }
    let engine = MoshifyEngine.shared
    let state = engine.state

    // The center status only speaks when the list has nothing to say.
    switch state {
    case .connecting:
      statusLabel.text = engine.tracks.isEmpty ? "Connecting…" : nil
      engine.tracks.isEmpty ? spinner.startAnimating() : spinner.stopAnimating()
    case .error(let message):
      statusLabel.text = message
      spinner.stopAnimating()
    case .ready where engine.tracks.isEmpty:
      statusLabel.text = "No audio files in this folder yet."
      spinner.stopAnimating()
    default:
      statusLabel.text = nil
      spinner.stopAnimating()
    }
    statusLabel.isHidden = (statusLabel.text == nil)

    switch state {
    case .playing(let t):
      nowPlayingLabel.text = t.title
      playButton.setMoshIcon("pause.fill", pointSize: 24, weight: .semibold)
    case .paused(let t):
      nowPlayingLabel.text = t.title
      playButton.setMoshIcon("play.fill", pointSize: 24, weight: .semibold)
    case .downloading(let t, _):
      nowPlayingLabel.text = "Fetching \(t.title)…"
      playButton.setMoshIcon("play.fill", pointSize: 24, weight: .semibold)
    default:
      nowPlayingLabel.text = " "
      playButton.setMoshIcon("play.fill", pointSize: 24, weight: .semibold)
    }

    // Shuffle ON = the one filled-red round key.
    if engine.shuffle {
      shuffleButton.backgroundColor = .moshroomTint
      shuffleButton.setMoshIcon("shuffle", pointSize: 17, weight: .semibold, color: .white)
    } else {
      shuffleButton.backgroundColor = Moshstyle.chipFill
      shuffleButton.setMoshIcon("shuffle", pointSize: 17, weight: .semibold)
    }

    _syncProgress()
    _syncProgressTimer()
    table.reloadData()
    _centerCurrentTrack()
  }

  /// Every song change (tapped, continued or shuffled) brings the playing row to the MIDDLE of the
  /// list, so the eye never has to hunt for where the music is. Only on an actual change of track:
  /// re-centering on every state tick would fight the user scrolling through the library.
  private func _centerCurrentTrack() {
    let engine = MoshifyEngine.shared
    guard let track = engine.currentTrack else { _centeredKey = nil; return }
    guard _centeredKey != track.cacheKey, let row = engine.currentIndex,
          engine.tracks.indices.contains(row) else { return }
    _centeredKey = track.cacheKey
    let path = IndexPath(row: row, section: 0)
    // After the reload above, so the row exists to scroll to.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.step == .player,
            self.table.numberOfRows(inSection: 0) > row else { return }
      self.table.scrollToRow(at: path, at: .middle, animated: true)
    }
  }

  private func _syncProgress() {
    let engine = MoshifyEngine.shared
    switch engine.state {
    case .downloading(_, let frac):
      progressBar.progress = Float(frac)
    case .playing, .paused:
      let d = engine.duration
      progressBar.progress = d > 0 ? Float(engine.elapsed / d) : 0
    default:
      progressBar.progress = 0
    }
  }

  private func _syncProgressTimer() {
    if case .playing = MoshifyEngine.shared.state {
      guard progressTimer == nil else { return }
      progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        self?._syncProgress()
      }
    } else {
      progressTimer?.invalidate()
      progressTimer = nil
    }
  }

  // MARK: table

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    MoshifyEngine.shared.tracks.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: MoshifyTrackCell.reuseID, for: indexPath)
    let engine = MoshifyEngine.shared
    guard let cell = cell as? MoshifyTrackCell,
          engine.tracks.indices.contains(indexPath.row) else { return cell }
    let track = engine.tracks[indexPath.row]
    cell.configure(title: track.title,
                   meta: Self._meta(for: track, engine: engine),
                   isCurrent: track == engine.currentTrack,
                   cached: engine.isCached(track))
    return cell
  }

  /// Length and size, with the length only when it is KNOWN (the file has been on the device) —
  /// a guessed time would be worse than none.
  private static func _meta(for track: MoshifyTrack, engine: MoshifyEngine) -> String {
    let size = ByteCountFormatter.string(fromByteCount: Int64(track.size), countStyle: .file)
    guard let seconds = engine.duration(of: track), seconds > 0 else { return size }
    return "\(_clock(seconds)) · \(size)"
  }

  private static func _clock(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let minutes = total / 60, secs = total % 60
    if minutes >= 60 {
      return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    MoshifyEngine.shared.play(at: indexPath.row)
  }

  // The one delete flow: confirm, unlink on the server, only then forget locally.
  private func _confirmDelete(_ track: MoshifyTrack, done: ((Bool) -> Void)? = nil) {
    let alert = UIAlertController(
      title: "Delete \"\(track.title)\"?",
      message: "The file is removed from the server. This cannot be undone.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done?(false) })
    alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
      MoshifyEngine.shared.deleteTrack(track) { [weak self] errorMessage in
        if let errorMessage {
          let oops = UIAlertController(title: "Could not delete", message: errorMessage, preferredStyle: .alert)
          oops.addAction(UIAlertAction(title: "OK", style: .default))
          self?.present(oops, animated: true)
        }
        done?(errorMessage == nil)
      }
    })
    present(alert, animated: true)
  }

  func tableView(_ tableView: UITableView,
                 trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    let engine = MoshifyEngine.shared
    guard engine.tracks.indices.contains(indexPath.row) else { return nil }
    let track = engine.tracks[indexPath.row]
    let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
      guard let self else { done(false); return }
      self._confirmDelete(track, done: done)
    }
    delete.backgroundColor = .moshroomTint   // destructive is mushroom red, never system red
    return UISwipeActionsConfiguration(actions: [delete])
  }

  // A mouse cannot reveal swipe actions on Mac Catalyst, so delete also lives in the row's
  // context menu (right-click on the Mac, long-press on iPhone).
  func tableView(_ tableView: UITableView,
                 contextMenuConfigurationForRowAt indexPath: IndexPath,
                 point: CGPoint) -> UIContextMenuConfiguration? {
    let engine = MoshifyEngine.shared
    guard engine.tracks.indices.contains(indexPath.row) else { return nil }
    let track = engine.tracks[indexPath.row]
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
      UIMenu(children: [
        UIAction(title: "Delete from server", image: UIImage(systemName: "trash"),
                 attributes: .destructive) { [weak self] _ in
          self?._confirmDelete(track)
        },
      ])
    }
  }
}

// MARK: - SpaceController glue

extension SpaceController {
  // Open (or focus) THE Moshify tab — one music tab, ever: the engine is a singleton and two
  // pages over one player would lie to somebody.
  func openMoshifyTab() {
    if presentedViewController != nil { dismiss(animated: false) }
    // Always a NEW tab with its picker: tapping Moshify means "I want to open a library", and
    // jumping to the one already playing took that choice away (the playing tab is one tap away in
    // Tabs, or through the title in the top-bar controls).
    let ctrl = MoshifyTabController()
    ctrl.space = self
    moshroomOpenTabPage(ctrl)
  }
}

