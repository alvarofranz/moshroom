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
import ios_system

public typealias Argv = UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?

extension Argv {
  static func build(_ args: [String]) -> (argc: Int32, argv: Self, buff: UnsafeMutablePointer<Int8>?) {
    let argc = args.count

    let cArgsSize = args.reduce(argc) { $0 + $1.utf8.count }

    // Store arguments in contiguous memory.
    guard
      let argsBuffer = calloc(cArgsSize, MemoryLayout<Int8>.size)?.assumingMemoryBound(to: Int8.self)
    else {
      return (argc: 0, argv: nil, buff: nil)
    }

    let argv = UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>.allocate(capacity: argc)

    var currentArgsPosition = argsBuffer

    args.enumerated().forEach { i, arg in
      let len = strlen(arg)
      strncpy(currentArgsPosition, arg, len)
      argv[i] = currentArgsPosition
      currentArgsPosition = currentArgsPosition.advanced(by: len + 1)
    }


    return (argc: Int32(argc), argv: argv, buff: argsBuffer)
  }

  static func build(_ args: String ...) -> (argc: Int32, argv: Self, buff: UnsafeMutablePointer<Int8>?) {
    build(args)
  }

  func args(count: Int32) -> [String] {
    guard let argv = self else {
      return []
    }
    var res: [String] = []
    for i in 0..<count {
      guard let cStr = argv[Int(i)] else {
        res.append("")
        continue
      }

      res.append(String(cString: cStr))
    }
    return res
  }
}

struct CommandError: LocalizedError {
  let message: String
  // Shown as is wherever the app reports a failed connect (explorer, uploads, music tab).
  var errorDescription: String? { message }
}

/// What a headless connect could not decide on its own. Wherever the app only reports a failure
/// (uploads, the music tab, a tmux re-attach) it reads exactly like before; the folder browser asks
/// the question instead, then dials again with the answer (MoshroomHeadlessAnswers).
enum MoshroomHeadlessNeed: LocalizedError {
  /// The server's key is not in known_hosts (`changed` false), or differs from the one there.
  case hostKey(fingerprint: String, changed: Bool)
  /// The server wants a password nobody saved (or did not take the key, or the saved password).
  case password

  var errorDescription: String? {
    switch self {
    case .hostKey(_, let changed):
      return changed
        ? "This host's key has changed since it was last trusted. Connect to it from a terminal tab to review the new key."
        : "This host's key is not known on this device yet. Connect to it once from a terminal tab to confirm it."
    case .password:
      return "This host asks for a password (or did not accept your key). Connect to it once from a terminal tab, where the password can be saved with the host."
    }
  }
}

/// Answers the user gave on the spot for one app-side connect, after a MoshroomHeadlessNeed.
struct MoshroomHeadlessAnswers {
  /// The fingerprint the user saw and trusted. Only an UNKNOWN key with exactly this fingerprint is
  /// accepted (and written to known_hosts, like a yes in a terminal); a changed key never is.
  var trustedHostKey: String?
  /// Used for this connect only. Whoever asked decides whether it is kept (the host editor puts it
  /// in its password field, saved with the host).
  var password: String?
}

func tty() -> TermDevice {
  let session = Unmanaged<MCPSession>.fromOpaque(thread_context).takeUnretainedValue()
  return session.device
}

/// Who an app-side connect dials: a saved host by alias, or a host the editor holds and has not saved
/// yet (`draft`), plus whatever the user already answered for it.
struct MoshroomConnectTarget {
  /// The saved alias, or the one being typed for an unsaved host. Messages and logs use it.
  let alias: String
  /// ssh_config settings (lowercase keys) that come before the saved ones. nil: the saved host as is.
  var draft: [String: Any]? = nil
  var answers = MoshroomHeadlessAnswers()

  init(alias: String) {
    self.alias = alias
  }

  /// A target from an editor's fields: what is on screen is what gets dialed, saved or not. A field
  /// left empty falls back to ssh_config (the saved entry for this alias, then `Host *`).
  init(alias: String, hostName: String, port: String, user: String, key: String?, password: String,
       proxyCommand: String, proxyJump: String, sshConfig: String) {
    let clean = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
    var content: [String: Any] = [:]
    let address = clean(hostName)
    // The alias is only a name here; an unsaved host without one is known by its address.
    let name = clean(alias)
    self.alias = name.isEmpty ? address : name
    if !address.isEmpty { content["hostname"] = address }
    if !clean(port).isEmpty { content["port"] = clean(port) }
    if !clean(user).isEmpty { content["user"] = clean(user) }
    if let key, !key.isEmpty, key != "None" { content["identityfile"] = [key] }
    if !password.isEmpty { content["password"] = password }
    if !clean(proxyCommand).isEmpty { content["proxycommand"] = clean(proxyCommand) }
    if !clean(proxyJump).isEmpty { content["proxyjump"] = clean(proxyJump) }
    // The host's extra ssh_config lines, read the way MoshHosts.sshConfig() writes them: AFTER the
    // fields, and a line replaces a field of the same name (the generated file's Host.set does the
    // same), so the browse dials exactly what a connect will. List settings stay lists, one entry per line.
    let listKeys: Set<String> = ["identityfile", "certificatefile", "localforward", "remoteforward", "dynamicforward", "sendenv"]
    for line in sshConfig.split(whereSeparator: \.isNewline) {
      let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: CharacterSet(charactersIn: " \t"))
      guard parts.count >= 2, !parts[0].hasPrefix("#") else { continue }
      let key = parts[0].lowercased()
      let value = parts[1...].joined(separator: " ")
      if listKeys.contains(key) {
        content[key] = ((content[key] as? [String]) ?? []) + [value]
      } else {
        content[key] = value
      }
    }
    draft = content
  }

  /// Something to dial: a saved alias, or a draft with an address.
  var isDialable: Bool {
    guard let draft else { return !alias.isEmpty }
    return draft["hostname"] != nil
  }
}
