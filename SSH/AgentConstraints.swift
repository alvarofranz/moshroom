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


public protocol SSHAgentConstraint {
  var name: String { get }
  func enforce(useOf key: SSHAgentKey, by client: SSHClient) -> Bool
}

public class SSHConstraintTrustedConnectionOnly: SSHAgentConstraint {
  
  public var name: String { "Trusted Connection" }
  public init() {}
  public func enforce(useOf key: SSHAgentKey, by client: SSHClient) -> Bool {
    return client.trustAgentConnection
  }
}
