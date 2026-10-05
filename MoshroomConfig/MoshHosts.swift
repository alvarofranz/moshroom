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
import SSHConfig


extension MoshHosts {
  /// Settings > Hosts > "Use tmux with SSH": Quick Connect's SSH mode opens the host with
  /// `tmux <alias>` instead of a plain `ssh <alias>`. ON unless explicitly turned off.
  public var moshroomUsesTmux: Bool { useTmux?.boolValue ?? true }

  /// The tmux session `tmux <alias>` attaches to (or creates): the host's own, else "main".
  public var moshroomTmuxSession: String {
    let name = Self.moshroomTmuxSessionName(tmuxSession ?? "")
    return name.isEmpty ? Self.moshroomDefaultTmuxSession : name
  }

  public static let moshroomDefaultTmuxSession = "main"

  /// A session name tmux keeps as typed: letters, digits, `_` and `-`. Anything else becomes `-`
  /// (tmux itself rewrites `.` and `:` to `_`, which would make the name never match again), and a
  /// name never starts with `-` (it would read as an option).
  public static func moshroomTmuxSessionName(_ raw: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    var out = String(String.UnicodeScalarView(raw.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }))
    while out.hasPrefix("-") { out.removeFirst() }
    return out
  }

  static func sshConfig() throws -> SSHConfig {
    let config = SSHConfig()
    
    let hosts = MoshHosts.allHosts() ?? []
    for h in hosts {
      var cfg: [(String, Any)] = []
      if let user = h.user, !user.isEmpty {
        cfg.append(("User", user))
      }
      if let port = h.port {
        cfg.append(("Port", port.intValue))
      }
      if let hostName = h.hostName, !hostName.isEmpty {
        cfg.append(("HostName", hostName))
      }
      if let key = h.key, !key.isEmpty, key != "None" {
        cfg.append(("IdentityFile", key))
      }
      if let proxyCmd = h.proxyCmd, !proxyCmd.isEmpty {
        cfg.append(("ProxyCommand", proxyCmd))
      }
      if let proxyJump = h.proxyJump, !proxyJump.isEmpty {
        cfg.append(("ProxyJump", proxyJump))
      }
      if let agentForwardPrompt = h.agentForwardPrompt,
         agentForwardPrompt.intValue > 0 {
        cfg.append(("ForwardAgent", "yes"))
      }
      if let sshConfigAttachment = h.sshConfigAttachment, !sshConfigAttachment.isEmpty {
        sshConfigAttachment.split(whereSeparator: \.isNewline).forEach { line in
          let components = line
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet(charactersIn: " \t"))
          if components.count >= 2,
             components[0] != "#" {
            cfg.append((components[0], components[1...].joined(separator: " ")))
          }
        }
      }
      
      try config.add(alias: h.host, cfg: cfg)
    }
    
    return config
  }
  
  @objc public static func saveAllToSSHConfig() {
    do {
      let config = try sshConfig()
      
      let configStr =
"""
# ATTENTION! THIS IS GENERATED FILE. DO NOT CHANGE IT DIRECTLY.
# GENERATED \(Date.now.ISO8601Format())
#
# Use config command do configure your hosts
# Or put your configuration to ~/.ssh/config

\(config.string())
"""

      guard
        let data = configStr.data(using: .utf8),
        let url = MoshroomPaths.moshroomSSHConfigFileURL()
      else {
        // TODO As this file is basically our own, we may want to report
        // errors during transformation by writing somewhere as well.
        print("can't convert to data")
        return
      }
      
      // Same protection class as the hosts blob it is generated from: readable after the first unlock,
      // so a connect made while the device is locked (Moshify fetching the next track, a background
      // redial) can still parse it. The container default (Complete) made it unreadable then.
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      
    } catch {
      // TODO Throw and capture somewhere else.
      print(error)
    }
  }
}
