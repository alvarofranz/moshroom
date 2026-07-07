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
  func resume(with unarchiver: NSKeyedUnarchiver)
  func suspendSession(with archiver: NSKeyedArchiver)
}

@objc class SessionRegistry: NSObject {
  private var _sessionsIndex: [UUID: SuspendableSession] = [:]
  private var _metaIndex: [UUID: SessionMeta] = [:]
  
  @objc public static let shared = SessionRegistry()
  
  override init() {
    super.init()
    _fsReadMetaIndex()
    
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
  
  func remove(forKey key: UUID) {
    _metaIndex.removeValue(forKey: key)
    _fsRemove(forKey: key)
    _sessionsIndex.removeValue(forKey: key)
  }
  
  
  @objc func suspend() {
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

    _resume(forKey: session.meta.key)
    session.meta.isSuspended = false
  }
  
  
  private func _resume(forKey key: UUID) {
    guard
      let session = _sessionsIndex[key],
      let data = _fsRead(forKey: key),
      let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
    else {
      return
    }

    session.resume(with: unarchiver)
    session.meta.isSuspended = false
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
  
  private func _fsWrite(_ data: Data, forKey key: UUID) {
    do {
      let sessionURL = try _fsSessionURL(key)
      try data.write(to: sessionURL, options: [.atomic, .completeFileProtection])
    } catch let e {
      debugPrint(e)
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
      try data.write(to: indexURL, options: [.atomic])
    } catch let e {
      debugPrint(e)
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
