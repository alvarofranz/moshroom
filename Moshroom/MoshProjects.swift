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


// Projects: a folder on a saved host with a session of its own.
//
// A host is a server, defined once. A project is a place on it: a folder, the tmux session that lives
// there, and optionally the command that starts in it (an agent such as opencode). Each project opens
// in its own tab and keeps running on the server when the tab closes, exactly like the host's own
// session does.
//
// The list is stored ON the host (MoshHosts.projectsJSON), so it goes wherever the host goes: the hosts
// blob, the iCloud mirror and its per-host merge (a project edit stamps the host's lastModified).
//
// How each way in reaches a project:
// - `tmux <host> <project>`: a control-mode tab on the project's session, created IN the folder; the
//   command is typed once, only when the session is brand new (tmux.swift).
// - `mosh <host> <project>`: mosh-server runs a startup script that decides new-or-existing on the
//   server, so nothing is ever typed into a running agent (moshStartup below).
// - plain SSH (tmux missing, or the host does not use tmux): `cd <folder> && <command>` typed once
//   after connecting, through MoshroomProjectHandoff.

import Foundation

struct MoshProject: Codable, Identifiable, Hashable {
  var id: String
  var name: String
  /// Absolute path on the server (chosen in the folder browser). `~` and `~/…` are accepted too.
  var folder: String
  /// What starts in the folder when the session is new. Empty: just a shell there.
  var command: String
  /// The tmux session, unique on the host and never the host's own. Kept when the project is renamed,
  /// so a running session is never orphaned by a new name.
  var session: String

  init(id: String = UUID().uuidString, name: String, folder: String, command: String, session: String) {
    self.id = id
    self.name = name
    self.folder = folder
    self.command = command
    self.session = session
  }

  private enum CodingKeys: String, CodingKey { case id, name, folder, command, session }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
    name = (try? c.decode(String.self, forKey: .name)) ?? ""
    folder = (try? c.decode(String.self, forKey: .folder)) ?? ""
    command = (try? c.decode(String.self, forKey: .command)) ?? ""
    session = (try? c.decode(String.self, forKey: .session)) ?? ""
  }

  var trimmedCommand: String { MoshProject.plainShellText(command).trimmingCharacters(in: .whitespacesAndNewlines) }

  /// A command is shell text, never prose: the text system's smart punctuation turns a typed `--` into
  /// an em dash and straight quotes into curly ones, and the shell then sees an option it does not
  /// know (`opencode —-flag`). Undo exactly those substitutions; nothing a shell would want is touched.
  static func plainShellText(_ text: String) -> String {
    // `—-` first: an em dash typed over the first of two hyphens leaves exactly that behind.
    var out = text.replacingOccurrences(of: "\u{2014}-", with: "--")
    for (smart, plain) in [("\u{2014}", "--"), ("\u{2013}", "--"), ("\u{2018}", "'"), ("\u{2019}", "'"),
                           ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2026}", "...")] {
      out = out.replacingOccurrences(of: smart, with: plain)
    }
    return out
  }

  /// The folder's last component, the name a new project starts with.
  static func folderName(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    return name.isEmpty || name == "/" ? path : name
  }

  /// A session name for `name` that tmux keeps as typed, unique among `taken` and never `hostSession`.
  static func sessionName(for name: String, hostSession: String, taken: Set<String>) -> String {
    var base = MoshHosts.moshroomTmuxSessionName(name)
    while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
    while base.hasSuffix("-") { base.removeLast() }
    if base.isEmpty { base = "project" }
    var candidate = base
    var n = 2
    while candidate == hostSession || taken.contains(candidate) {
      candidate = "\(base)-\(n)"
      n += 1
    }
    return candidate
  }

  /// `[a, b]` as stored on the host: nil for none, so a host without projects looks as it always did.
  static func json(_ list: [MoshProject]) -> String? {
    guard !list.isEmpty, let data = try? JSONEncoder().encode(list) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func list(fromJSON json: String?) -> [MoshProject] {
    guard let json, !json.isEmpty, let data = json.data(using: .utf8),
          let list = try? JSONDecoder().decode([MoshProject].self, from: data) else { return [] }
    return list.filter { !$0.session.isEmpty && !$0.folder.isEmpty }
  }
}

extension MoshHosts {
  /// The host's projects, in the order the user put them.
  var moshroomProjects: [MoshProject] { MoshProject.list(fromJSON: projectsJSON) }

  func moshroomProject(id: String) -> MoshProject? {
    moshroomProjects.first { $0.id == id }
  }

  /// The project a typed `tmux <host> <words…>` / `mosh <host> <words…>` names: its session name
  /// first (what Quick Connect types, never ambiguous), then its name, ignoring case.
  func moshroomProject(matching words: [String]) -> MoshProject? {
    let query = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return nil }
    let projects = moshroomProjects
    return projects.first { $0.session == query }
      ?? projects.first { $0.name.compare(query, options: [.caseInsensitive]) == .orderedSame }
      ?? projects.first { $0.session.compare(query, options: [.caseInsensitive]) == .orderedSame }
  }
}

/// Shell text for projects. Folders and commands are user input: every one of them reaches a shell
/// through `quote`, never pasted in raw.
enum MoshProjectShell {
  /// One POSIX shell word holding exactly `s`.
  static func quote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// The folder as one shell word: `~` and `~/…` expand to the remote home, anything else is literal.
  static func folderWord(_ folder: String) -> String {
    if folder == "~" { return "\"$HOME\"" }
    if folder.hasPrefix("~/") { return "\"$HOME\"/" + quote(String(folder.dropFirst(2))) }
    return quote(folder)
  }

  /// How a folder reads in a message: under the remote home it starts with `~`.
  static func displayFolder(_ folder: String, home: String?) -> String {
    guard let home = home?.trimmingCharacters(in: .whitespacesAndNewlines), home.count > 1 else { return folder }
    if folder == home { return "~" }
    if folder.hasPrefix(home + "/") { return "~" + folder.dropFirst(home.count) }
    return folder
  }

  /// The marker a preflight prints (followed by the remote $HOME) when the folder is not there.
  static let noFolderMarker = "MOSHROOM_NO_FOLDER"

  static func noFolderMessage(_ folder: String, host: String, home: String?) -> String {
    "The folder \(displayFolder(folder, home: home)) does not exist on \(host)."
  }

  /// `[ -d DIR ] || { say so; exit 125; }`, ready to sit inside a script.
  static func folderCheck(_ folder: String) -> String {
    "[ -d \(folderWord(folder)) ] || { echo \"\(noFolderMarker) $HOME\"; exit 125; }"
  }

  /// Typed into a plain shell once it is up: into the folder, then the command (never elsewhere).
  static func typedStart(_ project: MoshProject) -> String {
    let cd = "cd " + folderWord(project.folder)
    let command = project.trimmedCommand
    return command.isEmpty ? cd : cd + " && " + command
  }

  static let pathFallback = "PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin:/snap/bin\""

  /// Run before mosh-server, over the bootstrap's SSH: an existing session never needs its folder,
  /// a new one does, and a missing folder stops the connect with a reason instead of an agent started
  /// somewhere else.
  static func moshPreflight(_ project: MoshProject) -> String {
    let s = quote("=" + project.session)
    let script = [
      "command -v tmux >/dev/null 2>&1 || \(pathFallback)",
      "if command -v tmux >/dev/null 2>&1 && tmux has-session -t \(s) 2>/dev/null; then exit 0; fi",
      folderCheck(project.folder),
    ].joined(separator: "; ")
    return "sh -c " + quote(script)
  }

  /// What mosh-server runs for a project. The server decides new-versus-existing: a new session is
  /// created in the folder and the command is sent to it once; an existing one is only attached, so
  /// nothing is ever typed into a running agent. Without tmux: a login shell in the folder, the
  /// command started first.
  static func moshStartup(_ project: MoshProject) -> String {
    let s = quote(project.session)
    let target = quote("=" + project.session)
    let pane = quote("=" + project.session + ":")
    let dir = folderWord(project.folder)
    let command = project.trimmedCommand
    var create = "tmux new-session -d -s \(s) -c \(dir) || exit 1"
    if !command.isEmpty {
      // Sent once the shell has drawn its prompt (two seconds at most): keys that arrive before it
      // reads them are echoed by the terminal and then again by the shell.
      create += "; i=0; while [ $i -lt 20 ] && [ -z \"$(tmux capture-pane -p -t \(pane) | tr -d '[:space:]')\" ]; do sleep 0.1; i=$((i+1)); done"
      create += "; tmux send-keys -t \(pane) -l \(quote(command)); tmux send-keys -t \(pane) Enter"
    }
    var plain = "cd \(dir) || exit 1"
    if !command.isEmpty {
      plain += "; \"${SHELL:-sh}\" -lc \(quote(command))"
    }
    let script = [
      "command -v tmux >/dev/null 2>&1 || \(pathFallback)",
      "if command -v tmux >/dev/null 2>&1; then tmux has-session -t \(target) 2>/dev/null || { \(create); }; exec tmux attach-session -t \(target); fi",
      plain,
      "exec \"${SHELL:-sh}\" -l",
    ].joined(separator: "; ")
    return "sh -c " + quote(script)
  }
}

/// A one-off "command on connect" for the next plain `ssh` in one tab: how a project reaches its
/// folder when there is no tmux (the fallback, or a host that does not use it). It REPLACES the host's
/// own command on connect for that one connect, which may well start a session manager. Taken by the
/// ssh command as it starts, whatever happens next, and stale after half a minute.
enum MoshroomProjectHandoff {
  private static var pending: [ObjectIdentifier: (command: String, at: Date)] = [:]
  private static let lock = NSLock()

  static func set(_ command: String, for device: TermDevice) {
    lock.lock(); defer { lock.unlock() }
    pending[ObjectIdentifier(device)] = (command, Date())
  }

  static func take(for device: TermDevice) -> String? {
    lock.lock(); defer { lock.unlock() }
    guard let entry = pending.removeValue(forKey: ObjectIdentifier(device)) else { return nil }
    return Date().timeIntervalSince(entry.at) < 30 ? entry.command : nil
  }
}
