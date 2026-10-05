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
//
// This file holds the model, the constants and the cache. The SFTP worker lives in
// MoshifySession.swift, the player in MoshifyEngine.swift and the UI in MoshifyViews.swift.

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
  case cannotConvert(String)
  case cancelled
  case scanIncomplete
  case downloadMissing

  var errorDescription: String? {
    switch self {
    case .notConfigured: return "Moshify is not set up yet."
    case .timeout: return "Connection timed out."
    case .cannotConvert(let name): return "Could not convert \(name) into a playable format."
    case .cancelled: return "Cancelled."
    case .scanIncomplete: return "Some folders could not be read."
    case .downloadMissing: return "The download did not arrive."
    }
  }
}

// MARK: - Constants, defaults, notifications

enum Moshify {
  // What counts as music. Deliberately audio-only — no video player in Moshroom. Every one of these
  // is decoded by Core Audio itself, which is why the list is short and why it is a LIST: `.opus`
  // (Opus in an Ogg container) plays, measured on device — but Ogg-Vorbis does not, so `.ogg`/`.oga`
  // stay out rather than offering tracks that would fail at the first note.
  static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "opus"]
  /// Extensions Core Audio can OPEN but not PLAY. Measured, not assumed: `AVAudioPlayer` reads an
  /// Ogg-Opus file's duration and format happily and then returns false from `play()`, while
  /// ExtAudioFile decodes the very same file to PCM without complaint. So an Opus track is
  /// transcoded ONCE, when it lands, into the m4a the player can actually play — which keeps the
  /// whole player (progress, seek, lock-screen controls, gapless advance) on the single code path it
  /// already had, instead of growing a second playback engine just for one codec.
  static let transcodeExtensions: Set<String> = ["opus"]

  static func needsTranscode(_ fileName: String) -> Bool {
    transcodeExtensions.contains((fileName as NSString).pathExtension.lowercased())
  }

  /// The name a track's file has once it is playable: the remote name, or for a transcoded track
  /// the same stem with the m4a it becomes. The cache picks names (and spots collisions) on THIS.
  static func playableFileName(_ fileName: String) -> String {
    guard needsTranscode(fileName) else { return fileName }
    return ((fileName as NSString).deletingPathExtension as NSString).appendingPathExtension("m4a") ?? fileName
  }

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

  /// A fresh, unique staging folder for one download. It carries the same protection class as the
  /// audio folders: the app's default is Complete, and a Complete file cannot be created or written
  /// once the device has been locked for a few seconds, which is exactly when a background gap
  /// download or a prefetch runs. New files inherit the folder's class.
  static func makeStagingDirectory() -> URL {
    let fm = FileManager.default
    let root = stagingDirectory
    let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for url in [root, dir] {
      try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                            ofItemAtPath: url.path)
    }
    return dir
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

/// ONE cache for all of Moshify, with ONE budget. The bytes live under `Documents/audio/<host>/`
/// with their original basenames (a hash suffix only on a collision) because that folder is
/// user-visible in Files.app; the index maps remotePath → which host, which local file, and the play
/// history, and IT is the identity — the file name is presentation.
///
/// Global on purpose (2026-08-27): it used to be built per host while the index file was shared, so
/// constructing the cache for host A dropped host B's entries and then deleted B's files as
/// "orphans", and switching library wiped the previous host outright. Two libraries could never
/// coexist and the space was thrown away instead of used. Now the Music Cache setting is a budget
/// for EVERYTHING Moshify has downloaded, whichever host or tab it came from, and the only thing
/// that frees space is least-recently-played eviction against that budget. Main-thread only.
final class MoshifyCache {

  static let shared = MoshifyCache()

  struct Entry: Codable {
    let remotePath: String
    var fileName: String        // LOCAL file name inside the host's audio directory
    var size: UInt64
    var lastPlayed: Date?
    var playCount: Int
    /// Known only once the bytes are here (the player reads it exactly). Optional so an index
    /// written before durations existed still decodes.
    var duration: TimeInterval?
    /// Which host's folder holds the file. Optional for the same reason: an index written before the
    /// cache went global has no host, and those entries are reconciled away on first load rather
    /// than guessed at.
    var host: String?
  }

  private(set) var entries: [String: Entry] = [:]   // keyed by cacheKey

  /// Names promised to downloads still on their way, keyed by cacheKey. The window enqueues up to
  /// ten downloads at once, before any of them is in `entries`, so two tracks with the same basename
  /// (`A/01.mp3`, `B/01.mp3`) must not both be handed `01.mp3`. A reservation is dropped when its
  /// track lands; one left behind by a cancelled download only ever costs a suffix.
  private var reserved: [String: (host: String, fileName: String)] = [:]

  /// False while an index exists on disk that could not be READ (protected data not available yet,
  /// most likely). The empty list in memory is then ignorance, not the truth: nothing on disk is
  /// swept and the index is never overwritten until a later read succeeds.
  private var indexReadable = true

  private init() {
    load()
    reconcile()
  }

  private func directory(forHost host: String) -> URL { Moshify.audioDirectory(host: host) }

  /// Where an entry's bytes are, or nil for a pre-global entry with no host recorded.
  private func url(for entry: Entry) -> URL? {
    guard let host = entry.host else { return nil }
    return directory(forHost: host).appendingPathComponent(entry.fileName)
  }

  // Everything Moshify writes must stay readable while the device is LOCKED (background playback,
  // gap downloads): the entitlement default is Complete protection, which would kill playback
  // seconds after lock. New files inherit the directory's class.
  private func ensureDirectory(forHost host: String) {
    let fm = FileManager.default
    let dir = directory(forHost: host)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                          ofItemAtPath: dir.path)
    var root = Moshify.audioRootDirectory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true   // a media cache must not inflate the iCloud backup
    try? root.setResourceValues(values)
  }

  private func load() {
    let url = Moshify.indexFileURL
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    guard let data = try? Data(contentsOf: url) else {
      indexReadable = false
      MoshLog.log("moshify", "cache index unreadable for now, leaving the disk alone")
      return
    }
    entries = Self.decode(data)
  }

  /// One entry that no longer decodes costs that entry, not the whole cache.
  private static func decode(_ data: Data) -> [String: Entry] {
    guard let rows = try? JSONDecoder().decode([String: LenientEntry].self, from: data) else {
      MoshLog.log("moshify", "cache index did not decode")
      return [:]
    }
    return rows.compactMapValues { $0.entry }
  }

  private struct LenientEntry: Decodable {
    let entry: Entry?
    init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
  }

  private func save() {
    let url = Moshify.indexFileURL
    if !indexReadable {
      // Never clobber an index we could not read: fold it in first, or wait for the next chance.
      if FileManager.default.fileExists(atPath: url.path) {
        guard let data = try? Data(contentsOf: url) else { return }
        entries = Self.decode(data).merging(entries) { _, mine in mine }
      }
      indexReadable = true
    }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(entries) else { return }
    try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  /// Make the index and the disk agree, across EVERY host: drop entries whose file vanished (the
  /// user can delete from Files.app), delete files no entry claims (a stale run, or an index written
  /// before the cache went global), re-stat sizes so the LRU maths is honest — and then hold the
  /// budget, so lowering the Music Cache setting takes effect on the next launch.
  private func reconcile() {
    guard indexReadable else { return }
    let fm = FileManager.default
    var keep: [String: Entry] = [:]
    var referenced: [String: Set<String>] = [:]   // host → file names an entry claims
    for (key, var e) in entries {
      guard let url = url(for: e), let host = e.host,
            let attrs = try? fm.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? NSNumber
      else { continue }
      e.size = size.uint64Value
      keep[key] = e
      referenced[host, default: []].insert(e.fileName)
    }
    let dropped = entries.count - keep.count
    entries = keep

    // Sweep every host folder we have, not just the one in use.
    let root = Moshify.audioRootDirectory
    let hosts = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
    for host in hosts {
      let dir = root.appendingPathComponent(host, isDirectory: true)
      guard let onDisk = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
      let claimed = referenced[host] ?? []
      for name in onDisk where !claimed.contains(name) {
        try? fm.removeItem(at: dir.appendingPathComponent(name))
      }
      // A host folder nothing refers to any more goes with it.
      if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
        try? fm.removeItem(at: dir)
      }
    }
    save()
    if dropped > 0 { MoshLog.log("moshify", "cache reconcile dropped \(dropped) stale entries") }
    evict(toFit: Moshify.cacheCapBytes, protected: [])
  }

  var totalSize: UInt64 { entries.values.reduce(0) { $0 + $1.size } }

  func localURL(for track: MoshifyTrack) -> URL? {
    entries[track.cacheKey].flatMap { url(for: $0) }
  }

  func isCached(_ track: MoshifyTrack) -> Bool { entries[track.cacheKey] != nil }

  // The local name a download should land under: the playable basename, or (on a collision with a
  // DIFFERENT track in the SAME host folder, landed or still on its way) the basename with a short
  // hash suffix, still readable in Files.app.
  func localFileName(for track: MoshifyTrack, host: String) -> String {
    let key = track.cacheKey
    if let e = entries[key], e.host == host { return e.fileName }
    let base = Moshify.playableFileName(track.fileName)
    let taken = entries.contains { $0.key != key && $0.value.host == host && $0.value.fileName == base }
      || reserved.contains { $0.key != key && $0.value.host == host && $0.value.fileName == base }
    guard taken else { return base }
    let stem = (base as NSString).deletingPathExtension
    let ext = (base as NSString).pathExtension
    let suffix = String(key.prefix(4))
    return ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
  }

  /// Where a download lands, with the name reserved until it does.
  func destinationURL(for track: MoshifyTrack, host: String) -> URL {
    ensureDirectory(forHost: host)
    let name = localFileName(for: track, host: host)
    reserved[track.cacheKey] = (host, name)
    return directory(forHost: host).appendingPathComponent(name)
  }

  func noteDownloaded(_ track: MoshifyTrack, at url: URL, host: String) {
    reserved.removeValue(forKey: track.cacheKey)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
    entries[track.cacheKey] = Entry(remotePath: track.remotePath,
                                    fileName: url.lastPathComponent,
                                    size: size?.uint64Value ?? track.size,
                                    lastPlayed: entries[track.cacheKey]?.lastPlayed,
                                    playCount: entries[track.cacheKey]?.playCount ?? 0,
                                    duration: entries[track.cacheKey]?.duration,
                                    host: host)
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
    guard let e = entries.removeValue(forKey: track.cacheKey) else { return }
    if let url = url(for: e) { try? FileManager.default.removeItem(at: url) }
    save()
  }

  /// Drop what this library no longer has (a file deleted on the server outside us). Scoped to the
  /// library that was just scanned — the same index holds every other host's tracks, and a scan of
  /// one folder says nothing about them.
  func purge(notIn tracks: [MoshifyTrack], host: String, folder: String) {
    let live = Set(tracks.map { $0.cacheKey })
    let prefix = folder.hasSuffix("/") ? folder : folder + "/"
    let stale = entries.filter { key, e in
      e.host == host && !live.contains(key) && (e.remotePath.hasPrefix(prefix) || e.remotePath == folder)
    }
    for (key, e) in stale {
      entries.removeValue(forKey: key)
      if let url = url(for: e) { try? FileManager.default.removeItem(at: url) }
    }
    if !stale.isEmpty { save(); MoshLog.log("moshify", "purged \(stale.count) tracks gone from the server") }
  }

  // Least-recently-played first, never a protected key (playing / downloading / the prefetch
  // window). One budget for every host. Returns how many bytes were freed.
  @discardableResult
  func evict(toFit cap: UInt64, protected: Set<String>) -> UInt64 {
    var freed: UInt64 = 0
    while totalSize > cap {
      let candidates = entries.filter { !protected.contains($0.key) }
      guard let victim = candidates.min(by: {
        ($0.value.lastPlayed ?? .distantPast) < ($1.value.lastPlayed ?? .distantPast)
      }) else { break }
      freed += victim.value.size
      if let url = url(for: victim.value) { try? FileManager.default.removeItem(at: url) }
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
}
