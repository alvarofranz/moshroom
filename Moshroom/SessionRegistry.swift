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

class SessionMeta: Codable {
  fileprivate(set) var key: UUID = UUID()
  fileprivate(set) var isSuspended: Bool = false
  // A user-forced tab name; when set it overrides the program's own terminal title.
  var customName: String? = nil
  // The saved host this tab last connected to (Quick Connect). Persisted so a named tab keeps
  // its name across an app relaunch, until the user renames or closes it.
  var connectedHost: String? = nil
}

protocol SuspendableSession: AnyObject {
  var meta: SessionMeta { get }
  init(meta: SessionMeta?)
  /// Wake a session that is still alive in this process. False when there is none to wake (a tab
  /// rebuilt after a relaunch), and the archive has to be read instead.
  func resumeInPlace() -> Bool
  /// Rebuild the session from its archive, or start a fresh one when there is no usable archive.
  func resume(with unarchiver: NSKeyedUnarchiver?)
  /// Put the session to sleep and archive it.
  func suspendSession(with archiver: NSKeyedArchiver)
  /// Archive the session as it is right now, without touching it. False when there was nothing to
  /// archive (no session yet), in which case the archiver holds nothing worth writing.
  @discardableResult func archiveSession(with archiver: NSKeyedArchiver) -> Bool
}

@objc class SessionRegistry: NSObject {
  private var _sessionsIndex: [UUID: SuspendableSession] = [:]
  private var _metaIndex: [UUID: SessionMeta] = [:]
  
  @objc public static let shared = SessionRegistry()
  
  override init() {
    super.init()
    _fsReadMetaIndex()
    NotificationCenter.default.addObserver(self, selector: #selector(_protectedDataDidBecomeAvailable),
                                           name: UIApplication.protectedDataDidBecomeAvailableNotification,
                                           object: nil)

    DispatchQueue.main.asyncAfter(wallDeadline: DispatchWallTime.now() + TimeInterval(10)) {
      self._cleanLostSessions()
    }
  }
  
  func _cleanLostSessions() {
    guard UIApplication.shared.isProtectedDataAvailable
    else {
      return
    }
    
    var keysSet = Set(_metaIndex.keys)
    
    for key in _sessionsIndex.keys {
      keysSet.remove(key)
    }
    
    for key in keysSet {
      if _fsStateExists(forKey: key) == false {
        _metaIndex.removeValue(forKey: key)
      }
    }
    
    // Enumerate files and delete missed in index
    
    _fsWriteMetaIndex()
  }
  
  func track(session: SuspendableSession) {
    let meta = session.meta
    let key = meta.key
    _metaIndex[key] = meta
    _sessionsIndex[key] = session
  }

  // Force (or clear, with nil/empty) a tab's custom name and persist it across launches.
  func renameSession(_ key: UUID, to name: String?) {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    _metaIndex[key]?.customName = (trimmed?.isEmpty == false) ? trimmed : nil
    _fsWriteMetaIndex()
  }

  // Persist the meta index now (used when a tab records the host it connected to).
  func persistMetaIndex() { _fsWriteMetaIndex() }
  
  func sessionFromIndexWith<T: SuspendableSession>(key: UUID) -> T? {
    _sessionsIndex[key] as? T
  }
  
  subscript<T: SuspendableSession>(key: UUID) -> T {
    // 1. we already have it (same type)
    if let session = _sessionsIndex[key] as? T {
      return session
    }
    
    // 2. we have it only in meta index
    if let meta = _metaIndex[key] {
      meta.isSuspended = true
      let session = T(meta: meta)
      track(session: session)
      return session
    }
    
    // 3. creating new one
    let meta = SessionMeta()
    meta.key = key
    meta.isSuspended = true
    let session = T(meta: meta)
    track(session: session)
    return session
  }
  
  /// Keys of the sessions this run actually has (restored or created), as opposed to keys that only
  /// exist in an archive. Used to protect live tabs from a late scene-discard report — see
  /// SpaceController.onDidDiscardSceneSessions.
  var liveSessionKeys: Set<UUID> { Set(_sessionsIndex.keys) }

  func remove(forKey key: UUID) {
    _metaIndex.removeValue(forKey: key)
    _fsRemove(forKey: key)
    _sessionsIndex.removeValue(forKey: key)
  }
  
  
  @objc func suspend() {
    MoshLog.log("session", "parking \(_sessionsIndex.values.filter { !$0.meta.isSuspended }.count) tab(s)")
    _sessionsIndex.forEach { self.suspendIfNeeded(session: $1) }
    _fsWriteMetaIndex()
  }
  
  func suspendIfNeeded(session: SuspendableSession) {
    guard !session.meta.isSuspended else {
      return
    }
    
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    session.suspendSession(with: archiver)
    _fsWrite(archiver.encodedData, forKey: session.meta.key)
    session.meta.isSuspended = true
  }
  
  func resumeIfNeeded(session: SuspendableSession) {
    guard session.meta.isSuspended else {
      return
    }

    // Still alive in this process: it wakes from memory. The archive has nothing it lacks, and
    // reading it back is exactly what used to fail silently (a file that could not be read left the
    // tab marked as resumed with nothing running in it: a terminal that swallowed every key).
    if session.resumeInPlace() {
      session.meta.isSuspended = false
      return
    }
    // A tab rebuilt after a relaunch reads its archive, which stays sealed until the device has been
    // unlocked. Read too early it looks missing, and the tab would start over as a fresh shell and
    // lose its session. So it stays suspended and wakes the moment the data is there.
    guard UIApplication.shared.isProtectedDataAvailable else {
      _awaitingProtectedData.insert(session.meta.key)
      return
    }
    session.meta.isSuspended = false
    // From its archive, or as a fresh session when there is none: a missing or unreadable archive
    // must never leave a tab with no session at all.
    let unarchiver = _fsRead(forKey: session.meta.key).flatMap { try? NSKeyedUnarchiver(forReadingFrom: $0) }
    MoshLog.log("session", "restoring a tab (archive: \(unarchiver == nil ? "none" : "yes"))")
    session.resume(with: unarchiver)
  }

  private var _awaitingProtectedData = Set<UUID>()

  @objc private func _protectedDataDidBecomeAvailable() {
    // Only for a tab the user is looking at: an unlock to the home screen or to another app must not
    // start sessions in the background (a restored mosh client would run there with nothing to park
    // it). The foreground triggers resume the rest, and find the data available by then.
    guard UIApplication.shared.applicationState == .active else { return }
    let keys = _awaitingProtectedData
    _awaitingProtectedData.removeAll()
    for key in keys {
      if let session = _sessionsIndex[key] {
        resumeIfNeeded(session: session)
      }
    }
  }

  /// Rewrite a tab's archive from its live state, without suspending it: called whenever what the tab
  /// could resume from changes (a mosh checkpoint landed, or a client consumed one). Keeps the file
  /// telling the truth at every step, so a relaunch after the app died never starts from stale state.
  func persist(session: SuspendableSession) {
    // A closed tab's archive is gone for good: a late notification must not bring it back.
    guard _sessionsIndex[session.meta.key] === session else { return }
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    guard session.archiveSession(with: archiver) else { return }
    _fsWrite(archiver.encodedData, forKey: session.meta.key)
  }
  
  private var _fsSessionsFolderURL: URL? = nil
  
  private func _fsSessionsFolder() throws -> URL {
    if let fsSessionFolderURL = _fsSessionsFolderURL {
      return fsSessionFolderURL
    }
    
    let fm = FileManager.default
    var supporDirUrl = try fm.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    
    supporDirUrl.appendPathComponent("sessions")
    var isDir:ObjCBool = false
    if !fm.fileExists(atPath: supporDirUrl.path, isDirectory: &isDir) {
      try fm.createDirectory(at: supporDirUrl, withIntermediateDirectories: true, attributes: nil)
    }
    
    _fsSessionsFolderURL = supporDirUrl
    
    return supporDirUrl
  }
  
  private func _fsSessionURL(_ key: UUID) throws -> URL {
    let sessionsFolderURL = try _fsSessionsFolder()
    var fileURL = sessionsFolderURL
    fileURL.appendPathComponent(key.uuidString)
    return fileURL
  }
  
  private func _fsRemove(forKey key: UUID) {
    let fm = FileManager.default
    do {
      let sessionURL = try _fsSessionURL(key)
      if fm.fileExists(atPath: sessionURL.path) {
        try fm.removeItem(at: sessionURL)
      }
    } catch let e {
      debugPrint(e)
    }
  }
  
  // Archives are written at the worst possible moment: as the app goes to sleep, often seconds after
  // the phone locked. Complete protection refuses to create a file then, and the write used to fail
  // in silence. "Unless open" still encrypts the file at rest and keeps it unreadable while locked
  // (the archive holds the mosh session key), but lets it be CREATED while locked.
  //
  // A failed write removes the old file rather than leave it: an archive that no longer matches the
  // session could seed a client from a checkpoint already used, and a tab that starts over as a fresh
  // shell is the safe failure (a stale checkpoint is a frozen one).
  private func _fsWrite(_ data: Data, forKey key: UUID) {
    guard let sessionURL = try? _fsSessionURL(key) else { return }
    do {
      try data.write(to: sessionURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    } catch let e {
      MoshLog.log("sessions", "could not archive a tab: \(e.localizedDescription)")
      try? FileManager.default.removeItem(at: sessionURL)
    }
  }
  
  private func _fsStateExists(forKey key: UUID) -> Bool? {
    do {
      let sessionURL = try _fsSessionURL(key)
      return FileManager.default.fileExists(atPath: sessionURL.path)
    } catch {
      return nil
    }
  }
  
  private func _fsRead(forKey key: UUID) -> Data? {
   do {
      let sessionURL = try _fsSessionURL(key)
      let data = try Data(contentsOf: sessionURL)
      return data
    } catch {
      return nil
    }
  }
  
  private func _fsWriteMetaIndex() {
    let jsonEncoder = JSONEncoder()
    do {
      let data = try jsonEncoder.encode(_metaIndex)
      let sessionsFolder = try _fsSessionsFolder()
      let indexURL = sessionsFolder.appendingPathComponent("index.json")
      try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    } catch let e {
      MoshLog.log("sessions", "could not write the tab index: \(e.localizedDescription)")
    }
  }
  
  private func _fsReadMetaIndex() {
    do {
      let sessionsFolder = try _fsSessionsFolder()
      let indexURL = sessionsFolder.appendingPathComponent("index.json")
      let data = try Data(contentsOf: indexURL)
      let jsonDecoder = JSONDecoder()
      _metaIndex = try jsonDecoder.decode(type(of: _metaIndex), from: data)
    } catch let e {
      debugPrint(e)
    }
  }
}
