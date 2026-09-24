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


// MARK: - Protocol

protocol TermSessionPayload {
  static var sessionType: TermSessionPayloadType { get }

  func start(in device: TermDevice, sessionKey: String)
  func suspend()
  func resumeFromSuspended()

  // The payload owns its own serialization: config params + snapshot.
  func encode(with coder: NSCoder)

  var session: Session? { get }
}

enum TermSessionPayloadType: String, Codable {
  case mcp
}

// MARK: - Decode dispatch

// Reads the type tag from the archive and dispatches to the right concrete decoder.
func decodePayload(from coder: NSCoder) -> (any TermSessionPayload)? {
  guard let typeRaw: String = coder.bk_decode(for: TermSessionPayloadKey.sessionType),
        let type = TermSessionPayloadType(rawValue: typeRaw) else { return nil }
  switch type {
  case .mcp:
    return MCPSessionPayload.decode(from: coder)
  }
}

// Shared archive keys for the payload layer.
private enum TermSessionPayloadKey: CodingKey {
  case sessionType
  case snapshot
  // Present in every archive written since checkpoints became single-use (see decode).
  case snapshotIsSingleUse
}

// MARK: - MCPSessionPayload

class MCPSessionPayload : TermSessionPayload {
  static var sessionType: TermSessionPayloadType { .mcp }
  private var _session: MCPSession? = nil
  private var _initialParams: MCPParams
  private var _snapshot: Data? = nil

  var session: Session? { _session }

  init(params: MCPParams) {
    self._initialParams = params
  }

  func start(in device: TermDevice, sessionKey: String) {
    // Inject snapshot into params before the session reads them, then clear.
    if let snapshot = _snapshot {
      _initialParams.putEncodedState(snapshot)
      _snapshot = nil
    }
    self._session = MCPSession(device: device, andParams: _initialParams)
    _session!.execute(withArgs: "")
  }

  // The live session keeps its own checkpoint (in its params) from the moment it parks until a client
  // consumes it, so waking it needs nothing from here: MCPSession owns the whole park/wake cycle.
  func resumeFromSuspended() {
    _session?.moshroomResume()
  }

  func suspend() {
    _session?.suspend()
  }

  private enum Key: CodingKey { case sessionParams }

  func encode(with coder: NSCoder) {
    // Type tag — so decode dispatch knows which payload to reconstruct.
    coder.bk_encode(Self.sessionType.rawValue, for: TermSessionPayloadKey.sessionType)
    // Snapshot: stored as a sibling, never inside the params. COPIED from a live session, never
    // taken: the checkpoint stays for the client that wakes from it, and once that client has
    // consumed it this is nil, so an archive can never seed a second client.
    let snapshot = _session.map { $0.sessionParams.peekEncodedState() } ?? _snapshot
    coder.bk_encode(snapshot, for: TermSessionPayloadKey.snapshot)
    coder.bk_encode(true, for: TermSessionPayloadKey.snapshotIsSingleUse)
    // Config params: always clean, the checkpoint never travels inside them (MoshParams does not
    // encode it), only as the sibling above.
    if let session = _session {
      coder.bk_encode(session.sessionParams, for: Key.sessionParams)
    } else {
      coder.bk_encode(_initialParams, for: Key.sessionParams)
    }
  }

  static func decode(from coder: NSCoder) -> MCPSessionPayload? {
    guard let params: MCPParams = coder.bk_decode(of: [MCPParams.self], for: Key.sessionParams) else {
      return nil
    }
    let payload = MCPSessionPayload(params: params)
    // Archives from before checkpoints became single-use kept a checkpoint on disk after a client had
    // already started from it, so theirs may be spent, and a spent one starts a client the server
    // never answers again (a frozen tab). There is no telling a spent one from a fresh one, so none
    // of them is used: such a tab starts as a fresh shell with Quick Connect, one tap from its host.
    let singleUse: Bool = coder.bk_decode(for: TermSessionPayloadKey.snapshotIsSingleUse)
    if singleUse {
      payload._snapshot = coder.bk_decode(for: TermSessionPayloadKey.snapshot)
    }
    return payload
  }
}
