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

/// Opt-in storage hook for params that want a built-in Data backing.
@objc public protocol EncodedStateBacked {
  @objc dynamic var encodedStateStorage: Data? { get set }
}

/// Default behavior for snapshot methods when the type provides storage.
public extension EncodedStateBacked {
  @inlinable func _hasEncodedStateDefault() -> Bool {
    return encodedStateStorage != nil
  }

  @inlinable @discardableResult
  func _takeEncodedStateDefault() -> Data? {
    let data = encodedStateStorage
    encodedStateStorage = nil
    return data
  }

  @inlinable func _putEncodedStateDefault(_ data: Data) {
    encodedStateStorage = data
  }
}

@objc class MoshParams: NSObject, NSSecureCoding, MoshSessionParamsSnapshotting, EncodedStateBacked {
  @objc var ip: String? = nil
  @objc var port: String? = nil
  @objc var key: String? = nil
  @objc var predictionMode: String? = nil
  @objc var predictOverwrite: String? = nil
  @objc var startupCmd: String? = nil
  @objc var serverPath: String? = nil
  @objc var experimentalRemoteIp: String? = nil
  
  // Snapshot storage (backing for the default behavior)
  @objc dynamic public var encodedStateStorage: Data? = nil
  
  override init() { super.init() }
  
  private enum Key: String, CodingKey {
    case ip, port, key, predictionMode, predictOverwrite, startupCmd, serverPath, experimentalRemoteIp
  }
  
  // Satisfy @objc protocol by forwarding to helpers:
  @objc func hasEncodedState() -> Bool { _hasEncodedStateDefault() }
  @objc func takeEncodedState() -> Data? { _takeEncodedStateDefault() }
  @objc func putEncodedState(_ data: Data) { _putEncodedStateDefault(data) }
  
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
  @objc var childSessionType: String? = nil
  @objc var childSessionParams: MoshSessionParams?

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
  @objc func putEncodedState(_ data: Data) { childSessionParams?.putEncodedState(data) }
}
