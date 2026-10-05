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

/// Typealias for session parameter objects that can be snapshotted and securely coded
public typealias MoshSessionParams = (any NSSecureCoding & MoshSessionParamsSnapshotting)

@objc class MoshParams: NSObject, NSSecureCoding, MoshSessionParamsSnapshotting {
  @objc var ip: String? = nil
  @objc var port: String? = nil
  @objc var key: String? = nil
  @objc var predictionMode: String? = nil
  @objc var predictOverwrite: String? = nil
  @objc var startupCmd: String? = nil
  @objc var serverPath: String? = nil
  @objc var experimentalRemoteIp: String? = nil

  // The mosh client's state checkpoint: written by the client's own thread, consumed by the next
  // client that starts from it, and copied into the tab's archive from the main thread. Three
  // threads, so every access goes through the lock. A checkpoint can seed exactly ONE client: a
  // second client started from the same bytes rewinds the session behind the server, and the
  // server never talks to it again (see MCPSession).
  private var _encodedState: Data? = nil
  private let _encodedStateLock = NSLock()

  override init() { super.init() }

  private enum Key: String, CodingKey {
    case ip, port, key, predictionMode, predictOverwrite, startupCmd, serverPath, experimentalRemoteIp
  }

  @objc func hasEncodedState() -> Bool {
    _encodedStateLock.lock(); defer { _encodedStateLock.unlock() }
    return _encodedState != nil
  }

  @objc func takeEncodedState() -> Data? {
    _encodedStateLock.lock(); defer { _encodedStateLock.unlock() }
    let data = _encodedState
    _encodedState = nil
    return data
  }

  @objc func peekEncodedState() -> Data? {
    _encodedStateLock.lock(); defer { _encodedStateLock.unlock() }
    return _encodedState
  }

  @objc func putEncodedState(_ data: Data) {
    _encodedStateLock.lock(); defer { _encodedStateLock.unlock() }
    _encodedState = data
  }

  func encode(with coder: NSCoder) {
    coder.bk_encode(ip, for: Key.ip)
    coder.bk_encode(port, for: Key.port)
    coder.bk_encode(key, for: Key.key)
    coder.bk_encode(predictionMode, for: Key.predictionMode)
    coder.bk_encode(predictOverwrite, for: Key.predictOverwrite)
    coder.bk_encode(startupCmd, for: Key.startupCmd)
    coder.bk_encode(serverPath, for: Key.serverPath)
    coder.bk_encode(experimentalRemoteIp, for: Key.experimentalRemoteIp)
  }
  
  required init?(coder: NSCoder) {
    super.init()
    
    self.ip = coder.bk_decode(for: Key.ip)
    self.port = coder.bk_decode(for: Key.port)
    self.key = coder.bk_decode(for: Key.key)
    self.predictionMode = coder.bk_decode(for: Key.predictionMode)
    self.predictOverwrite = coder.bk_decode(for: Key.predictOverwrite)
    self.startupCmd = coder.bk_decode(for: Key.startupCmd)
    self.serverPath = coder.bk_decode(for: Key.serverPath)
    self.experimentalRemoteIp = coder.bk_decode(for: Key.experimentalRemoteIp)
  }
  
  static var supportsSecureCoding: Bool { true }
  
  public func copy(from params: MoshParams) {
    self.ip = params.ip
    self.port = params.port
    self.key = params.key
    self.predictionMode = params.predictionMode
    self.predictOverwrite = params.predictOverwrite
    self.startupCmd = params.startupCmd
    self.serverPath = params.serverPath
    self.experimentalRemoteIp = params.experimentalRemoteIp
  }
}

/// The `tmux <host>` child (MoshroomTmux): which remote session belongs to this tab, and what a
/// re-attach needs to paint it again. Written by the child's thread while the main thread archives
/// it, so every field goes through one lock. It carries no checkpoint: the session itself lives on
/// the host, so the snapshot methods are no-ops.
@objc class TmuxParams: NSObject, NSSecureCoding, MoshSessionParamsSnapshotting {
  private struct Fields {
    var hostAlias: String? = nil
    var sessionName: String? = nil
    var sessionCreated: String? = nil
    var paneId: Int = -1
    var version: String? = nil
    var lastCols: Int = 0
    var lastHistorySize: Int = 0
    var bracketedPaste = false
    var mouseAnyMotion = false
    var everAttached = false
    var viewHoldsSession = false
  }
  private var _f = Fields()
  private let _lock = NSLock()

  private func _get<T>(_ k: KeyPath<Fields, T>) -> T {
    _lock.lock(); defer { _lock.unlock() }
    return _f[keyPath: k]
  }
  private func _set<T>(_ k: WritableKeyPath<Fields, T>, _ v: T) {
    _lock.lock(); defer { _lock.unlock() }
    _f[keyPath: k] = v
  }

  /// The saved host the session is on.
  @objc var hostAlias: String? { get { _get(\.hostAlias) } set { _set(\.hostAlias, newValue) } }
  /// The remote tmux session (moshroom-<8 hex>), this tab's alone.
  @objc var sessionName: String? { get { _get(\.sessionName) } set { _set(\.sessionName, newValue) } }
  /// tmux's session_created: a different value on re-attach means a different session.
  @objc var sessionCreated: String? { get { _get(\.sessionCreated) } set { _set(\.sessionCreated, newValue) } }
  @objc var paneId: Int { get { _get(\.paneId) } set { _set(\.paneId, newValue) } }
  @objc var version: String? { get { _get(\.version) } set { _set(\.version, newValue) } }
  /// The pane's width at the last resync: history captured at another width does not compare.
  @objc var lastCols: Int { get { _get(\.lastCols) } set { _set(\.lastCols, newValue) } }
  @objc var lastHistorySize: Int { get { _get(\.lastHistorySize) } set { _set(\.lastHistorySize, newValue) } }
  /// Modes tmux has no format for, followed in the pane's output (replayed by a full refill).
  @objc var bracketedPaste: Bool { get { _get(\.bracketedPaste) } set { _set(\.bracketedPaste, newValue) } }
  @objc var mouseAnyMotion: Bool { get { _get(\.mouseAnyMotion) } set { _set(\.mouseAnyMotion, newValue) } }
  /// The session was created (or attached) once: from then on only an exact attach is used, so a
  /// session that ended is never silently replaced by a new one.
  @objc var everAttached: Bool { get { _get(\.everAttached) } set { _set(\.everAttached, newValue) } }
  /// Ephemeral: the terminal still shows the session as it was painted (an in-process wake), so a
  /// re-attach only appends what it missed. False after a relaunch or a rebuilt page.
  @objc var viewHoldsSession: Bool { get { _get(\.viewHoldsSession) } set { _set(\.viewHoldsSession, newValue) } }

  override init() { super.init() }

  private enum Key: CodingKey {
    case hostAlias, sessionName, sessionCreated, paneId, version, lastCols, lastHistorySize
    case bracketedPaste, mouseAnyMotion, everAttached
  }

  static var supportsSecureCoding: Bool { true }

  func encode(with coder: NSCoder) {
    let f: Fields = { _lock.lock(); defer { _lock.unlock() }; return _f }()
    coder.bk_encode(f.hostAlias, for: Key.hostAlias)
    coder.bk_encode(f.sessionName, for: Key.sessionName)
    coder.bk_encode(f.sessionCreated, for: Key.sessionCreated)
    coder.bk_encode(f.paneId, for: Key.paneId)
    coder.bk_encode(f.version, for: Key.version)
    coder.bk_encode(f.lastCols, for: Key.lastCols)
    coder.bk_encode(f.lastHistorySize, for: Key.lastHistorySize)
    coder.bk_encode(f.bracketedPaste, for: Key.bracketedPaste)
    coder.bk_encode(f.mouseAnyMotion, for: Key.mouseAnyMotion)
    coder.bk_encode(f.everAttached, for: Key.everAttached)
  }

  required init?(coder: NSCoder) {
    super.init()
    var f = Fields()
    f.hostAlias = coder.bk_decode(for: Key.hostAlias)
    f.sessionName = coder.bk_decode(for: Key.sessionName)
    f.sessionCreated = coder.bk_decode(for: Key.sessionCreated)
    f.paneId = coder.bk_decode(for: Key.paneId)
    f.version = coder.bk_decode(for: Key.version)
    f.lastCols = coder.bk_decode(for: Key.lastCols)
    f.lastHistorySize = coder.bk_decode(for: Key.lastHistorySize)
    f.bracketedPaste = coder.bk_decode(for: Key.bracketedPaste)
    f.mouseAnyMotion = coder.bk_decode(for: Key.mouseAnyMotion)
    f.everAttached = coder.bk_decode(for: Key.everAttached)
    _f = f
  }

  @objc func hasEncodedState() -> Bool { false }
  @objc func takeEncodedState() -> Data? { nil }
  @objc func peekEncodedState() -> Data? { nil }
  @objc func putEncodedState(_ data: Data) {}
}

@objc class MCPParams: NSObject, NSSecureCoding, MoshSessionParamsSnapshotting {
  // The child marker is rewritten by the command queue while the main thread archives it (the tab's
  // archive follows every checkpoint change), so both go through a lock.
  private var _childSessionType: String? = nil
  private var _childSessionParams: MoshSessionParams? = nil
  private let _childLock = NSLock()

  @objc var childSessionType: String? {
    get { _childLock.lock(); defer { _childLock.unlock() }; return _childSessionType }
    set { _childLock.lock(); defer { _childLock.unlock() }; _childSessionType = newValue }
  }
  @objc var childSessionParams: MoshSessionParams? {
    get { _childLock.lock(); defer { _childLock.unlock() }; return _childSessionParams }
    set { _childLock.lock(); defer { _childLock.unlock() }; _childSessionParams = newValue }
  }

  /// Command to run when the session bootstraps. Ephemeral — not encoded.
  /// Consumed once inside `MCPSession.executeWithArgs:`.
  @objc var initialCommand: String? = nil

  private enum Key: CodingKey { case childSessionType, childSessionParams }

  override init() { super.init() }

  // MARK: - NSSecureCoding
  static var supportsSecureCoding: Bool { true }

  func encode(with coder: NSCoder) {
    coder.bk_encode(childSessionType, for: Key.childSessionType)
    coder.bk_encode(childSessionParams, for: Key.childSessionParams)
  }

  required init?(coder: NSCoder) {
    super.init()
    self.childSessionType = coder.bk_decode(for: Key.childSessionType)
    // NOTE: include all known MCP children subclasses here for secure decoding
    self.childSessionParams = coder.bk_decode(of: [MoshParams.self, TmuxParams.self], for: Key.childSessionParams)
  }

  // MARK: - MoshSessionParamsSnapshotting (forward)
  @objc func hasEncodedState() -> Bool { childSessionParams?.hasEncodedState() ?? false }
  @objc func takeEncodedState() -> Data? { childSessionParams?.takeEncodedState() }
  @objc func peekEncodedState() -> Data? { childSessionParams?.peekEncodedState() }
  @objc func putEncodedState(_ data: Data) { childSessionParams?.putEncodedState(data) }
}
