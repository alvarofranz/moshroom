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

  func resumeFromSuspended() {
    guard let session = self._session else { return }
    // The suspend is over — the command loop may clear the marker again on the next real exit.
    session.moshroomAppSuspending = false
    // Inject snapshot back into the live session's params, then clear.
    if let snapshot = _snapshot {
      session.sessionParams.putEncodedState(snapshot)
      _snapshot = nil
    }
    if session.sessionParams.hasEncodedState() {
      session.execute(withArgs: "")
    }
  }

  func suspend() {
    guard let session = self._session else { return }
    // Mark the suspend BEFORE the child is checkpointed: the child (mosh) terminates as part of
    // the suspend and the command loop, seeing it end, would otherwise clear the child marker and
    // strand the resume at Quick Connect. Set here (suspend thread), cleared on resume.
    session.moshroomAppSuspending = true
    session.suspend()
    // Extract snapshot from params. After this, params are clean config.
    _snapshot = session.sessionParams.takeEncodedState()
  }

  private enum Key: CodingKey { case sessionParams }

  func encode(with coder: NSCoder) {
    // Type tag — so decode dispatch knows which payload to reconstruct.
    coder.bk_encode(Self.sessionType.rawValue, for: TermSessionPayloadKey.sessionType)
    // Snapshot — stored as a sibling, never inside the params.
    coder.bk_encode(_snapshot, for: TermSessionPayloadKey.snapshot)
    // Config params — always clean (snapshot was extracted in suspend).
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
    payload._snapshot = coder.bk_decode(for: TermSessionPayloadKey.snapshot)
    return payload
  }
}
