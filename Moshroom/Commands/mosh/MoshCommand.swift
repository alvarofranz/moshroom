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
import ArgumentParser

fileprivate let Version = "1.4.0"

struct MoshCommand: ParsableCommand {
  static var configuration = CommandConfiguration(
    commandName: "mosh",
    abstract: "",
    discussion: """
      """,
    version: Version)

  @Option(name: .shortAndLong,
          help: "Path to remote mosh-server binary.")
  var server: String?

  @Option(
    name: [.customShort("r")],
    help: "Prediction mode",
    transform: { try MoshMoshPrediction(parsing: $0) })
  var predict: MoshMoshPrediction?

  @Flag (
    name: [.customShort("o")]
  )
  var predictOverwrite: Bool = false

  @Flag var verbose: Bool = false

  @Flag (
    name: [.customShort("T")],
    help: "Do not start a TTY"
  )
  var noSshPty: Bool = false

  @Option(
    name: [.customShort("R")],
    help: "How to discover the IP address that the mosh-client connects to: default, remote or local",
    transform: { try MoshMoshExperimentalIP(parsing: $0) }
  )
  var experimentalRemoteIP: MoshMoshExperimentalIP?

  @Flag(exclusivity: .exclusive)
  var addressFamily: AddressFamily?

  // Mosh Key
  @Option(
    name: [.customShort("k")],
    help: "Use the provided server-side key for mosh connection."
  )
  var customKey: String?

  // UDP Port
  @Option(
    name: [.customShort("p")],
    help: "Use a particular server-side UDP port or port range, for example, if this is the only port that is forwarded through a firewall to the server. Otherwise, mosh will choose a port between 60000 and 61000."
  )
  var customUDPPort: String?

  // SSH Port
  @Option(
    name: [.customShort("P")],
    help: "Specifies the SSH port to initialize mosh-server on remote host."
  )
  var customSSHPort: UInt16?

  // Identity
  @Option(
    name: [.customShort("I")],
    help: .init(
      """
        Selects a file from which the identity (private key) for public key authentication is read. The default is ~/.ssh/id_dsa, ~/.ssh/id_ecdsa, ~/.ssh/id_ed25519 and ~/.ssh/id_rsa.  Identity files may also be specified on a per-host basis in the configuration pane in the Settings of Moshroom.
        """,
      valueName: "identity"
    )
  )
  var identityFile: String?

  // Connect to User at Host
  @Argument(help: "[user@]host[#port]",
            transform: { UserAtHostAndPort($0) })
  var userAtHostAndPort: UserAtHostAndPort
  var hostAlias: String { userAtHostAndPort.hostAlias }
  var user: String? { userAtHostAndPort.user }
  var sshPort: UInt16? {
    get { if let port = customSSHPort { port } else { userAtHostAndPort.port } }
  }

  @Argument(
    parsing: .unconditionalRemaining,
    help: .init(
      "If a <remoteCommand> is specified, it is executed on the remote host instead of a login shell",
      valueName: "remoteCommand"
    )
  )

  fileprivate var cmd: [String] = []
  var remoteExecCommand: [String] {
    get {
      if cmd.first == "--" {
        return Array(cmd.dropFirst())
      } else {
        return cmd
      }
    }
  }

  func validate() throws {
    if addressFamily != nil && experimentalRemoteIP != MoshMoshExperimentalIPLocal {
      throw ValidationError("Address Family can only be used with 'local' IP resolution (-R).")
    }
  }
}

extension MoshCommand {
  func bkSSHHost() throws -> MoshSSHHost {
    var params: [String:Any] = [:]

    if let user = self.user {
      params["user"] = user
    }

    if let port = self.sshPort {
      params["port"] = String(port)
    }

    if let identityFile = self.identityFile {
      params["identityfile"] = identityFile
    }

    if self.verbose {
      params["loglevel"] = "INFO"
    }
    // params["loglevel"] = "DEBUG"

    params["compression"] = "no"
    return try MoshSSHHost(content: params)
  }
}

extension MoshMoshPrediction: CustomStringConvertible {
  init(parsing: String) throws {
    switch parsing.lowercased() {
    case "adaptive":
      self = MoshMoshPredictionAdaptive
    case "always":
      self = MoshMoshPredictionAlways
    case "never":
      self = MoshMoshPredictionNever
    case "experimental":
      self = MoshMoshPredictionExperimental
    default:
      throw ValidationError("Unknown prediction mode, must be: adaptive, always, never, experimental.")
    }
  }

  public var description: String {
    switch self {
    case MoshMoshPredictionAdaptive:
      "adaptive"
    case MoshMoshPredictionAlways:
      "always"
    case MoshMoshPredictionNever:
      "never"
    case MoshMoshPredictionExperimental:
      "experimental"
    default:
      "unknown"
    }
  }
}

extension MoshMoshExperimentalIP {
  init(parsing: String) throws {
    switch parsing.lowercased() {
    case "default":
      self = MoshMoshExperimentalIPNone
    case "local":
      self = MoshMoshExperimentalIPLocal
    case "remote":
      self = MoshMoshExperimentalIPRemote
    default:
      throw ValidationError("Unknown experimental-ip mode, must be: default, local or remote.")
    }
  }
}

enum AddressFamily: String, EnumerableFlag {
  case IPv4
  case IPv6

  static func name(for value: AddressFamily) -> NameSpecification {
    switch value {
    case .IPv4:
      return NameSpecification([.customShort(Character("4")), .customLong("inet4")])
    case .IPv6:
      return NameSpecification([.customShort(Character("6")), .customLong("inet6")])
    }
  }

  static func help(for value: AddressFamily) -> ArgumentHelp? {
    switch value {
    case .IPv4:
      return "Use IPv4 only on 'local' IP resolution"
    case .IPv6:
      return "Use IPv6 only on 'local' IP resolution"
    }
  }
}
