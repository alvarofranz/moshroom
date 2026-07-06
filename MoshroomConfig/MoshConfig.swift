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

import SSH
import SSHConfig


// Responsible to intermediate between the Moshroom configuration formats and the
// SSHClient requirements, facilitating information between them.
// TODO This will work a lot better as a singleton.
public struct MoshConfig {
  let defaultKeyNames = ["id_dsa", "id_rsa", "id_ecdsa", "id_ecdsa_sk", "id_ed25519"]

  private let _allHosts: [MoshHosts]
  private let _allIdentities: [MoshPubKey]
  private let bkSSHConfig: SSHConfig

  // TODO Config files
  public init() throws {
    _allHosts = MoshHosts.allHosts()
    _allIdentities = MoshPubKey.all()
    bkSSHConfig = try SSHConfig.parse(url: MoshroomPaths.moshroomGlobalSSHConfigFileURL())
  }

  private func _host(_ host: String) -> MoshHosts? {
    return _allHosts.first(where: { $0.host == host })
  }

  // Return the stored configuration given the host.
  // The root for the configuration is now the file sequence from .moshroom/ssh_config.
  public func bkSSHHost(_ alias: String) throws -> MoshSSHHost {
    var sshConfig = try bkSSHConfig.resolve(alias: alias)

    // Add protected data (password)
    if let password = _host(alias)?.password {
      sshConfig["password"] = password
    }

    return try MoshSSHHost(content: sshConfig)
  }
  
  public func bkSSHHost(_ alias: String, extending baseHost: MoshSSHHost) throws -> MoshSSHHost {
    let sshConfigHost = try self.bkSSHHost(alias)
    
    var extendedHost = try baseHost.merge(sshConfigHost)
    if extendedHost.hostName == nil {
      extendedHost.hostName = alias
    }
    return extendedHost
  }

  public func resolveHost(alias: String, extending baseHost: MoshSSHHost) throws -> (hostName: String, host: MoshSSHHost) {
    let host = try bkSSHHost(alias, extending: baseHost)
    let hostName = host.hostName ?? alias
    return (hostName, host)
  }

  public func privateKey(forIdentifier identifier: String) -> (String, String)? {
    guard
      let privateKey = _allIdentities.first(where: { $0.id == identifier })?.loadPrivateKey()
    else {
      return nil
    }
    
    return (privateKey, identifier)
  }

  public func signer(forIdentity identity: String) -> (Signer, String)? {
    guard
      let signer = _allIdentities.signerWithID(identity)
    else {
      return nil
    }
    
    return (signer, identity)
  }
  
  public func signer(forHost host: MoshSSHHost) -> [(Signer, String)]? {
    guard
      let identity = host.identityFile
    else {
      return nil
    }
    
    return identity.compactMap { signer(forIdentity: $0) }
  }

  public func defaultSigners() -> [(Signer, String)] {
    return defaultKeyNames.compactMap {
      signer(forIdentity: $0)
    }
  }
  
  public func defaultKeys() -> [(String, String)] {
    return _allIdentities
      .filter {
        defaultKeyNames.contains($0.id)
      }
      .map {
        ($0.loadPrivateKey(), $0.id)
      }
      .compactMap {
        guard
          let privateKey = $0.0
        else {
          return nil
        }
        return (privateKey, $0.1)
      }
  }
}
