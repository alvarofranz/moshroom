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
    self.childSessionParams = coder.bk_decode(of: [MoshParams.self], for: Key.childSessionParams)
  }

  // MARK: - MoshSessionParamsSnapshotting (forward)
  @objc func hasEncodedState() -> Bool { childSessionParams?.hasEncodedState() ?? false }
  @objc func takeEncodedState() -> Data? { childSessionParams?.takeEncodedState() }
  @objc func peekEncodedState() -> Data? { childSessionParams?.peekEncodedState() }
  @objc func putEncodedState(_ data: Data) { childSessionParams?.putEncodedState(data) }
}
