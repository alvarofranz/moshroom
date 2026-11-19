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


// Hosts in and out of the app as a plain JSON file: hosts with their projects, written by Export or
// by hand (or by a script), read by Import. The hosts blob itself is a keyed archive in the sandbox
// and is never the way in.
//
// The file NEVER holds a secret: no password, no key material. A host names its key by the name it
// has under Keys & Certificates; a password is typed once in the app (or in the folder browser).
//
// Import only adds and updates, it never deletes: a host already here keeps every field the file
// does not mention (or leaves empty), its password and its projects; a project in the file updates the one with the
// same session (or else the same name), and every other project stays.
//
// The format, every field but `alias` optional (`address` is required for a NEW host):
//
//   { "format": "moshroom-hosts", "version": 1, "hosts": [
//     { "alias": "prod", "description": "…", "address": "prod.example.com", "port": 22, "user": "deploy",
//       "key": "id_ed25519", "useTmux": true, "tmuxSession": "main", "commandOnConnect": "…",
//       "moshServer": "…", "moshPort": "60001:60010", "moshCommand": "…",
//       "proxyCommand": "…", "proxyJump": "…", "sshConfig": "Compression yes\nServerAliveInterval 30",
//       "projects": [ { "name": "api", "folder": "~/src/api", "command": "opencode", "session": "api" } ] } ] }

import Foundation

struct MoshHostsFile: Codable {
  static let formatName = "moshroom-hosts"

  var format: String? = MoshHostsFile.formatName
  var version: Int? = 1
  var hosts: [Host]

  struct Host: Codable {
    var alias: String
    var description: String?
    var address: String?
    var port: Int?
    var user: String?
    var key: String?
    var useTmux: Bool?
    var tmuxSession: String?
    var commandOnConnect: String?
    var moshServer: String?
    var moshPort: String?
    var moshCommand: String?
    var proxyCommand: String?
    var proxyJump: String?
    var sshConfig: String?
    var projects: [Project]?
  }

  struct Project: Codable {
    var name: String?
    var folder: String
    var command: String?
    var session: String?
  }
}

enum MoshHostsTransfer {

  // MARK: Export

  /// Every saved host with its projects, as the file Import reads. Empty strings are left out so the
  /// file reads like something a person wrote.
  static func exportData() throws -> Data {
    func value(_ s: String?) -> String? {
      guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
      return s
    }
    let hosts = MoshHosts.allHosts().sorted { $0.host < $1.host }.map { h -> MoshHostsFile.Host in
      var moshPort: String? = nil
      if let start = h.moshPort {
        if let end = h.moshPortEnd {
          moshPort = "\(start):\(end)"
        } else {
          moshPort = start.stringValue
        }
      }
      let projects = h.moshroomProjects.map {
        MoshHostsFile.Project(name: $0.name, folder: $0.folder, command: value($0.command), session: $0.session)
      }
      return MoshHostsFile.Host(
        alias: h.host,
        description: value(h.hostDescription),
        address: value(h.hostName),
        port: h.port?.intValue,
        user: value(h.user),
        key: value(h.key) == "None" ? nil : value(h.key),
        useTmux: h.useTmux?.boolValue,
        tmuxSession: value(h.tmuxSession),
        commandOnConnect: value(h.commandOnConnect),
        moshServer: value(h.moshServer),
        moshPort: moshPort,
        moshCommand: value(h.moshStartup),
        proxyCommand: value(h.proxyCmd),
        proxyJump: value(h.proxyJump),
        sshConfig: value(h.sshConfigAttachment),
        projects: projects.isEmpty ? nil : projects
      )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(MoshHostsFile(hosts: hosts))
  }

  /// The export written to a fresh temporary folder (emptied on the next export), ready for a share
  /// sheet. The caller removes the folder when the sheet is done.
  static func exportFile() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hosts-export", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("Moshroom Hosts.json")
    try exportData().write(to: url, options: .atomic)
    return url
  }

  // MARK: Import

  struct ImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// A file read and checked, not applied yet: what it would add and what it would update.
  struct Plan {
    let hosts: [MoshHostsFile.Host]
    let newAliases: [String]
    let existingAliases: [String]
    /// Where an existing host would connect differently ("prod: address a → b"). Its saved password
    /// stays and goes wherever the host now points, so the user sees every such change first.
    let connectionChanges: [String]
    /// ssh_config lines left out because they would weaken host key checking.
    let droppedLines: Int
    var projectCount: Int { hosts.reduce(0) { $0 + ($1.projects?.count ?? 0) } }
  }

  /// Read and check a file. Nothing is saved; every problem is reported at once, by alias.
  static func plan(from data: Data) throws -> Plan {
    let file: MoshHostsFile
    do {
      file = try JSONDecoder().decode(MoshHostsFile.self, from: data)
    } catch {
      throw ImportError(message: "This is not a Moshroom hosts file (\(error.localizedDescription)).")
    }
    if let format = file.format, format != MoshHostsFile.formatName {
      throw ImportError(message: "This file is a \u{201C}\(format)\u{201D} file, not a Moshroom hosts file.")
    }
    var problems: [String] = []
    var seen = Set<String>()
    var hosts: [MoshHostsFile.Host] = []
    var changes: [String] = []
    var dropped = 0
    for var host in file.hosts {
      // Same rule as the host editor: an alias is typed into a shell, so whitespace becomes a hyphen.
      host.alias = host.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: .whitespacesAndNewlines).joined(separator: "-")
      let alias = host.alias
      guard !alias.isEmpty else { problems.append("A host has no alias."); continue }
      guard seen.insert(alias).inserted else { problems.append("\(alias) appears twice."); continue }
      let address = host.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if address.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
        problems.append("\(alias): the address has spaces.")
      }
      if address.isEmpty && MoshHosts.withHost(alias) == nil {
        problems.append("\(alias): a new host needs an address.")
      }
      if let port = host.port, !(1...65535).contains(port) {
        problems.append("\(alias): \(port) is not a port.")
      }
      for project in host.projects ?? [] where project.folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        problems.append("\(alias): the project \u{201C}\(project.name ?? "")\u{201D} has no folder.")
      }
      // A file from elsewhere never switches host key checking off (or moves where keys are checked).
      if let config = host.sshConfig {
        let lines = config.split(whereSeparator: \.isNewline)
        let kept = lines.filter { line in
          let key = line.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet(charactersIn: " \t=")).first?.lowercased() ?? ""
          return !["stricthostkeychecking", "userknownhostsfile", "globalknownhostsfile"].contains(key)
        }
        dropped += lines.count - kept.count
        host.sshConfig = kept.joined(separator: "\n")
      }
      if let old = MoshHosts.withHost(alias) {
        func differs(_ label: String, _ new: String?, _ old: String?) {
          let new = new?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          let old = old?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          if !new.isEmpty && new != old {
            changes.append("\(alias): \(label) \(old.isEmpty ? "(none)" : old) \u{2192} \(new)")
          }
        }
        differs("address", host.address, old.hostName)
        differs("user", host.user, old.user)
        differs("port", host.port.map(String.init), old.port?.stringValue)
        differs("proxy command", host.proxyCommand, old.proxyCmd)
        differs("proxy jump", host.proxyJump, old.proxyJump)
      }
      hosts.append(host)
    }
    if !problems.isEmpty {
      throw ImportError(message: "Nothing was imported.\n" + problems.joined(separator: "\n"))
    }
    if hosts.isEmpty {
      throw ImportError(message: "The file holds no hosts.")
    }
    let existing = hosts.map(\.alias).filter { MoshHosts.withHost($0) != nil }
    let new = hosts.map(\.alias).filter { MoshHosts.withHost($0) == nil }
    return Plan(hosts: hosts, newAliases: new, existingAliases: existing,
                connectionChanges: changes, droppedLines: dropped)
  }

  /// Apply a plan: new hosts are added; hosts already here are updated only when `updateExisting`.
  /// Returns how many hosts were saved, and the first failure if there was one (hosts saved before it
  /// stay saved).
  @discardableResult
  static func apply(_ plan: Plan, updateExisting: Bool) -> (saved: Int, failure: String?) {
    var saved = 0
    for host in plan.hosts {
      let existing = MoshHosts.withHost(host.alias)
      if existing != nil && !updateExisting { continue }
      guard save(host, over: existing) else {
        return (saved, "\(host.alias) could not be saved: the hosts file is not writable right now. Unlock the device and import again.")
      }
      saved += 1
    }
    return (saved, nil)
  }

  /// One host through the same saveHost the editor uses. A field the file leaves out keeps what the
  /// host already has; the password is never touched (nil = unchanged).
  private static func save(_ file: MoshHostsFile.Host, over old: MoshHosts?) -> Bool {
    // An empty value in the file means "keep": a blank address must never wipe a host's address.
    func pick(_ new: String?, _ old: String?) -> String {
      if let new = new?.trimmingCharacters(in: .whitespacesAndNewlines), !new.isEmpty { return new }
      return (old ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var oldMoshPort = ""
    if let old, let start = old.moshPort {
      if let end = old.moshPortEnd {
        oldMoshPort = "\(start):\(end)"
      } else {
        oldMoshPort = start.stringValue
      }
    }
    var prediction = MoshMoshPredictionAdaptive
    prediction.rawValue = UInt32(old?.prediction?.intValue ?? 0)
    var experimentalIP = MoshMoshExperimentalIPNone
    experimentalIP.rawValue = UInt32(old?.moshExperimentalIP?.intValue ?? 0)
    var agentForward = MoshAgentForwardNo
    agentForward.rawValue = UInt32(old?.agentForwardPrompt?.intValue ?? 0)

    let useTmux: NSNumber? = file.useTmux.map { $0 ? nil : NSNumber(value: false) } ?? old?.useTmux
    let tmuxSession = MoshHosts.moshroomTmuxSessionName(pick(file.tmuxSession, old?.tmuxSession))
    let hostSession = tmuxSession.isEmpty ? MoshHosts.moshroomDefaultTmuxSession : tmuxSession
    let projects = merge(file.projects ?? [], into: old?.moshroomProjects ?? [], hostSession: hostSession)

    let result = MoshHosts.saveHost(
      old?.host,
      withNewHost: file.alias,
      hostName: pick(file.address, old?.hostName),
      sshPort: file.port.map(String.init) ?? (old?.port?.stringValue ?? ""),
      user: pick(file.user, old?.user),
      password: nil,
      hostKey: pick(file.key, old?.key),
      moshServer: pick(file.moshServer, old?.moshServer),
      moshPredictOverwrite: old?.moshPredictOverwrite,
      moshExperimentalIP: experimentalIP,
      moshPortRange: pick(file.moshPort, oldMoshPort),
      startUpCmd: MoshProject.plainShellText(pick(file.moshCommand, old?.moshStartup)),
      commandOnConnect: MoshProject.plainShellText(pick(file.commandOnConnect, old?.commandOnConnect)),
      hostDescription: pick(file.description, old?.hostDescription),
      useTmux: useTmux,
      tmuxSession: tmuxSession,
      projectsJSON: MoshProject.json(projects),
      prediction: prediction,
      proxyCmd: pick(file.proxyCommand, old?.proxyCmd),
      proxyJump: pick(file.proxyJump, old?.proxyJump),
      sshConfigAttachment: pick(file.sshConfig, old?.sshConfigAttachment),
      agentForwardPrompt: agentForward,
      agentForwardKeys: old?.agentForwardKeys ?? []
    )
    return result != nil
  }

  /// The file's projects folded into the host's: a match (same session, else same name ignoring case)
  /// keeps its id and session, so a running session stays its own; the rest are added with a session
  /// of their own. Projects the file does not mention stay as they are.
  static func merge(_ incoming: [MoshHostsFile.Project], into current: [MoshProject], hostSession: String) -> [MoshProject] {
    var result = current
    // Only a project that was there before can be matched, and only once: two entries of one file
    // never fold into each other.
    var claimed = Set<Int>()
    let matchable = { (i: Int) in i < current.count && !claimed.contains(i) }
    for item in incoming {
      let folder = MoshProject.cleanFolder(item.folder)
      let name = (item.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        ?? MoshProject.folderName(folder)
      let command = MoshProject.plainShellText(item.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let wanted = MoshHosts.moshroomTmuxSessionName(item.session ?? "")
      let index = result.indices.first { matchable($0) && !wanted.isEmpty && result[$0].session == wanted }
        ?? result.indices.first { matchable($0) && result[$0].name.compare(name, options: .caseInsensitive) == .orderedSame }
      if let index {
        claimed.insert(index)
        result[index].name = name
        result[index].folder = folder
        result[index].command = command
        continue
      }
      let taken = Set(result.map(\.session))
      let session = (!wanted.isEmpty && wanted != hostSession && !taken.contains(wanted))
        ? wanted
        : MoshProject.sessionName(for: wanted.isEmpty ? name : wanted, hostSession: hostSession, taken: taken)
      result.append(MoshProject(name: name, folder: folder, command: command, session: session))
    }
    // The host's own session is never a project's (a file can change it under a matched project).
    for index in result.indices where result[index].session == hostSession {
      let taken = Set(result.map(\.session))
      result[index].session = MoshProject.sessionName(for: result[index].name, hostSession: hostSession, taken: taken)
    }
    return result
  }
}
