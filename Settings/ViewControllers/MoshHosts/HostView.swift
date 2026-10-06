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

import Combine
import SwiftUI

struct FormLabel: View {
  let text: String
  var minWidth: CGFloat = 86

  var body: some View {
    Text(text).frame(minWidth: minWidth, alignment: .leading)
  }
}

struct Field: View {
  private let _id: String
  private let _label: String
  private let _placeholder: String
  @Binding private var value: String
  private let _next: String?
  private let _secureTextEntry: Bool
  private let _enabled: Bool
  private let _kbType: UIKeyboardType

  init(_ label: String, _ value: Binding<String>, next: String, placeholder: String, id: String? = nil, secureTextEntry: Bool = false, enabled: Bool = true, kbType: UIKeyboardType = .default) {
    _id = id ?? label
    _label = label
    _value = value
    _placeholder = placeholder
    _next = next
    _secureTextEntry = secureTextEntry
    _enabled = enabled
    _kbType = kbType
  }

  var body: some View {
    HStack {
      FormLabel(text: _label)
      FixedTextField(
        _placeholder,
        text: $value,
        id: _id,
        nextId: _next,
        secureTextEntry: _secureTextEntry,
        keyboardType: _kbType,
        autocorrectionType: .no,
        autocapitalizationType: .none,
        enabled: _enabled
      )
    }
  }
}

struct FieldPassword: View {
  private let _label: String
  private let _placeholder: String
  @Binding private var value: String
  private let _next: String?
  private let _enabled: Bool
  @State private var _showPassword: Bool = false

  init(_ label: String, _ value: Binding<String>, next: String, placeholder: String, enabled: Bool = true) {
    _label = label
    _value = value
    _placeholder = placeholder
    _next = next
    _enabled = enabled
  }

  var body: some View {
    HStack {
      FormLabel(text: _label)
      FixedTextField(
        _placeholder,
        text: $value,
        id: _label,
        nextId: _next,
        secureTextEntry: !_showPassword,
        keyboardType: .default,
        autocorrectionType: .no,
        autocapitalizationType: .none,
        enabled: _enabled
      )
      Button(action: {
        _showPassword.toggle()
      }) {
        Image(systemName: _showPassword ? "eye.slash.fill" : "eye.fill")
          .foregroundColor(.secondary)
      }
      .buttonStyle(PlainButtonStyle())
      .disabled(!_enabled)
    }
  }
}

struct FieldSSHKey: View {
  @Binding var value: [String]
  var enabled: Bool = true
  var hasSSHKey: Bool

  var body: some View {
    Row(
      content: {
        HStack {
          if (hasSSHKey || value.isEmpty) {
            FormLabel(text: "Key")
            Spacer()
            Text(value.isEmpty ? "None" : value[0])
              .font(.system(.subheadline)).foregroundColor(.secondary)
          } else {
            Label("Key", systemImage: "exclamationmark.icloud.fill")
            Spacer()
            Text(value[0])
              .font(.system(.subheadline)).foregroundColor(.moshTint)
          }
        }
      },
      details: {
        KeyPickerView(currentKey: enabled ? $value : .constant(value), multipleSelection: false)
      }
    )
  }
}


fileprivate struct FieldMoshCustomOptions: View {
  @Binding var prediction: MoshMoshPrediction
  @Binding var overwrite: Bool
  @Binding var experimentalIP: MoshMoshExperimentalIP
  var enabled: Bool

  var body: some View {
    Row(
      content: {
        HStack {
          FormLabel(text: "Advanced")
          Spacer()
          //Text(prediction.label + "...").font(.system(.subheadline)).foregroundColor(.secondary)
        }
      },
      details: {
        MoshCustomOptionsPickerView(
          predictionValue: enabled ? $prediction : .constant(prediction),
          overwriteValue: enabled ? $overwrite : .constant(overwrite),
          experimentalIPValue: enabled ? $experimentalIP : .constant(experimentalIP)
        )
      }
    )
  }
}

fileprivate struct FieldAgentForwardPrompt: View {
  @Binding var value: MoshAgentForward
  var enabled: Bool

  var body: some View {
    Row(
      content: {
        HStack {
          FormLabel(text: "Agent Forwarding")
          Spacer()
          Text(value.label).font(.system(.subheadline)).foregroundColor(.secondary)
        }
      },
      details: {
        AgentForwardPromptPickerView(
          currentValue: enabled ? $value : .constant(value)
        )
      }
    )
  }
}

fileprivate struct FieldAgentForwardKeys: View {
  @Binding var value: [String]
  var enabled: Bool

  var body: some View {
    Row(
      content: {
        HStack {
          FormLabel(text: "Forward Keys")
          Spacer()
          Text(value.isEmpty ? "None" : value.joined(separator: ", "))
            .font(.system(.subheadline)).foregroundColor(.secondary)
        }
      },
      details: {
        KeyPickerView(currentKey: enabled ? $value : .constant(value), multipleSelection: true)
      }
    ).disabled(!enabled)
  }
}

struct FieldTextArea: View {
  private let _label: String
  @Binding private var value: String
  private let _enabled: Bool

  init(_ label: String, _ value: Binding<String>, enabled: Bool = true) {
    _label = label
    _value = value
    _enabled = enabled
  }

  var body: some View {
    Row(
      content: { FormLabel(text: _label) },
      details: {
        // A plain editor page — monospaced, since what lives here is ssh-config text.
        TextEditor(text: _value)
          .font(.system(.body, design: .monospaced))
          .autocapitalization(.none)
          .disableAutocorrection(true)
          .disabled(!_enabled)
          .padding(12)
          .moshHubChromeBack(title: _label)
      }
    )
  }
}

struct HostView: View {
  @EnvironmentObject private var _nav: Nav

  @State private var _host: MoshHosts?
  private var _duplicatedHost: MoshHosts? = nil
  @State private var _alias: String = ""
  @State private var _hostName: String = ""
  @State private var _port: String = ""
  @State private var _user: String = ""
  @State private var _password: String = ""
  // What the password field was loaded with, nil when nothing could be read (no password, or one that
  // has not arrived on this device yet). Saving an untouched field must not write it back.
  @State private var _loadedPassword: String? = nil
  @State private var _sshKeyName: [String] = []
  @State private var _proxyCmd: String = ""
  @State private var _proxyJump: String = ""
  @State private var _sshConfigAttachment: String = HostView.__sshConfigAttachmentExample

  @State private var _moshServer: String = ""
  @State private var _moshPort: String = ""
  @State private var _moshPrediction: MoshMoshPrediction = MoshMoshPredictionAdaptive
  @State private var _moshPredictOverwrite: Bool = false
  @State private var _moshExperimentalIP: MoshMoshExperimentalIP = MoshMoshExperimentalIPNone
  @State private var _moshCommand: String = ""
  @State private var _commandOnConnect: String = ""
  @State private var _hostDescription: String = ""
  // ON unless the host says otherwise (a new host, and a host saved before the setting existed).
  @State private var _useTmux: Bool = true
  @State private var _tmuxSession: String = ""
  @State private var _loaded = false
  @State private var _enabled: Bool = true

  @State private var _agentForwardPrompt: MoshAgentForward = MoshAgentForwardNo
  @State private var _agentForwardKeys: [String] = []

  @State private var _errorMessage: String = ""

  @State private var _projects: [MoshProject] = []
  @State private var _editingProject: HostProjectEdit? = nil
  @State private var _pendingProjectDelete: MoshDeletePrompt? = nil

  private var _reloadList: () -> ()
  private var _cleanAlias: String {
    _alias.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // A tmux session name keeps only what tmux keeps as typed (see MoshHosts.moshroomTmuxSessionName):
  // anything else turns into a hyphen as the user types, like the alias.
  private var _tmuxSessionSafe: Binding<String> {
    Binding(
      get: { _tmuxSession },
      set: { _tmuxSession = MoshHosts.moshroomTmuxSessionName($0) }
    )
  }

  // The alias is typed into the shell (`ssh <alias>`), so whitespace can never be valid —
  // turn it into a hyphen as the user types (covers pasted text too) instead of erroring later.
  private var _aliasNoSpaces: Binding<String> {
    Binding(
      get: { _alias },
      set: { _alias = $0.components(separatedBy: .whitespacesAndNewlines).joined(separator: "-") }
    )
  }


  init(host: MoshHosts?, reloadList: @escaping () -> ()) {
    _host = host
    _reloadList = reloadList
  }

  init(duplicatingHost host: MoshHosts, reloadList: @escaping () -> ()) {
    _host = nil
    _duplicatedHost = host
    _reloadList = reloadList
  }

  // One line under the Connection section: how to reach this host from the shell.
  private func _usageHint() -> String {
    var alias = _cleanAlias
    if alias.count < 2 {
      alias = "[alias]"
    }
    return "Connect from Quick Connect, or type `ssh \(alias)`, `tmux \(alias)` or `mosh \(alias)`."
  }

  // `user@address:port`, live as the fields change: the header's summary of where this host is.
  private var _summary: String {
    let address = _hostName.trimmingCharacters(in: .whitespacesAndNewlines)
    let user = _user.trimmingCharacters(in: .whitespacesAndNewlines)
    let port = _port.trimmingCharacters(in: .whitespacesAndNewlines)
    return (user.isEmpty ? "" : user + "@") + (address.isEmpty ? "address" : address) + ":" + (port.isEmpty ? "22" : port)
  }

  // The session the host's own connects use (what the editor holds now, not what is saved).
  private var _hostSessionName: String {
    let name = MoshHosts.moshroomTmuxSessionName(_tmuxSession)
    return name.isEmpty ? MoshHosts.moshroomDefaultTmuxSession : name
  }

  var body: some View {
    List {
      Section {
        HostEditorHeader(alias: _cleanAlias, summary: _summary, isNew: _host == nil)
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4))

      Section(
        header: Text("Connection"),
        footer: Text(verbatim: _usageHint())
      ) {
        Field("Alias", _aliasNoSpaces, next: "Description", placeholder: "Required, e.g. prod")
        Field("Description", $_hostDescription, next: "Address", placeholder: "Optional one-liner")
        Field("Address", $_hostName, next: "Port", placeholder: "Host name or IP. Required", enabled: _enabled, kbType: .URL)
        Field("Port", $_port, next: "User", placeholder: "22", enabled: _enabled, kbType: .numberPad)
        Field("User", $_user, next: "Password", placeholder: "Login user. Required", enabled: _enabled)
      }.disabled(!_enabled)

      Section(
        header: Text("Authentication"),
        footer: Text("A key from Keys & Certificates, a password, or both. No password means you are asked each time.")
      ) {
        FieldSSHKey(value: $_sshKeyName, enabled: _enabled, hasSSHKey: MoshPubKey.all().contains(where: {
          if let keyName = _sshKeyName.first {
            return $0.id == keyName
          }
          return false
        }))
        FieldPassword("Password", $_password, next: "tmuxSession", placeholder: "Ask every time", enabled: _enabled)
      }

      Section(
        header: Text("Sessions"),
        footer: Text("SSH opens in tmux on the server: it survives the app closing, and falls back to plain SSH without tmux.")
      ) {
        Toggle("Use tmux with SSH", isOn: $_useTmux)
          .tint(.moshTint)
        if _useTmux {
          Field("Session", _tmuxSessionSafe, next: "moshServer", placeholder: MoshHosts.moshroomDefaultTmuxSession, id: "tmuxSession")
        }
      }.disabled(!_enabled)

      Section(
        header: Text("Projects"),
        footer: Text(_host == nil
          ? "Save the host first, then add projects: folders on it, each with its own session and tab."
          : "A folder on this server with its own session: each project opens in its own tab and keeps running when you close it.")
      ) {
        ForEach(_projects) { project in
          Button { _editingProject = HostProjectEdit(project: project, isNew: false) } label: {
            HostProjectRow(project: project)
          }
          .buttonStyle(.plain)
          .moshCatalystPlainButtons()
          // Right-click (Mac) / long-press (iOS): the Mac has no swipe, so delete and order live here too.
          .contextMenu {
            Button { _editingProject = HostProjectEdit(project: project, isNew: false) } label: { Label("Edit", systemImage: "pencil") }
            if _projects.first?.id != project.id {
              Button { _moveProject(project, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
            }
            if _projects.last?.id != project.id {
              Button { _moveProject(project, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
            }
            Divider()
            Button(role: .destructive) { _confirmDeleteProject(project) } label: { Label("Delete", systemImage: "trash") }
          }
        }
        .onDelete { offsets in
          if let index = offsets.first, index < _projects.count { _confirmDeleteProject(_projects[index]) }
        }
        .onMove { from, to in
          _projects.move(fromOffsets: from, toOffset: to)
          _persistProjects()
        }
        Button { _addProject() } label: {
          Label("Add Project", systemImage: "plus.circle.fill")
            .foregroundColor(_host == nil ? .secondary : .moshTint)
        }
        .buttonStyle(.plain)
        .moshCatalystPlainButtons()
        .disabled(_host == nil)
      }

      Section(
        header: Text("Mosh"),
        footer: Text("Only for `mosh`: the server binary if it is not on PATH, a UDP port or range, and what to run instead of the shell.")
      ) {
        Field("Server", $_moshServer, next: "moshPort", placeholder: "path/to/mosh-server", id: "moshServer")
        Field("Port", $_moshPort, next: "moshCommand", placeholder: "UDP PORT[:PORT2]", id: "moshPort", kbType: .numbersAndPunctuation)
        Field("Command", $_moshCommand, next: "commandOnConnect", placeholder: "tmux new -A -s main", id: "moshCommand")
        FieldMoshCustomOptions(
          prediction: $_moshPrediction,
          overwrite: $_moshPredictOverwrite,
          experimentalIP: $_moshExperimentalIP,
          enabled: _enabled
        )
      }.disabled(!_enabled)

      Section(
        header: Text("On Connect"),
        footer: Text("Typed into the host's own session right after connecting, over SSH and Mosh. Projects run their own command instead.")
      ) {
        Field("Command", $_commandOnConnect, next: "ProxyCmd", placeholder: "cd dev && opencode", id: "commandOnConnect")
      }.disabled(!_enabled)

      Section(
        header: Text("Advanced"),
        footer: Text("A bastion to go through, extra ssh_config lines, and agent forwarding for keys that never leave this device.")
      ) {
        Field("ProxyCmd", $_proxyCmd, next: "ProxyJump", placeholder: "ssh -W %h:%p bastion", enabled: _enabled)
        Field("ProxyJump", $_proxyJump, next: "Alias", placeholder: "bastion1,bastion2", enabled: _enabled)
        FieldTextArea("SSH Config", $_sshConfigAttachment, enabled: _enabled)
        FieldAgentForwardPrompt(value: $_agentForwardPrompt, enabled: _enabled)
        if _agentForwardPrompt != MoshAgentForwardNo {
          FieldAgentForwardKeys(value: $_agentForwardKeys, enabled: _enabled)
        }
      }.disabled(!_enabled)
    }
    .listStyle(.insetGrouped)
    .listSectionSpacing(18)
    .moshReadableWidth()
    .alert(errorMessage: $_errorMessage)
    .moshDeleteConfirmation($_pendingProjectDelete)
    .fullScreenCover(item: $_editingProject) { edit in
      MoshProjectEditor(
        hostAlias: _host?.host ?? _cleanAlias,
        hostSession: _hostSessionName,
        otherSessions: Set(_projects.filter { $0.id != edit.project.id }.map(\.session)),
        project: edit.project,
        isNew: edit.isNew,
        onSave: { _saveProject($0) },
        onDelete: edit.isNew ? nil : { _deleteProject(edit.project) }
      )
    }
    .moshHubChrome(title: _host == nil ? "New Host" : "Host", leading: {
      Button(action: {
        _nav.navController.popViewController(animated: true)
      }) { MoshNavLabel(title: "Discard") }
    }, trailing: {
      Button(action: {
        // A validation failure shows the alert and keeps the editor open — never save a bad host.
        guard _validate() else { return }
        guard _saveHost() else {
          _errorMessage = "The host could not be saved. If you changed the password, the keychain refused it: unlock the device and try again."
          return
        }
        _reloadList()
        _nav.navController.popViewController(animated: true)
      }) { MoshNavLabel(title: "Save") }
    })
    .onAppear {
      if !_loaded {
        loadHost()
      }
    }

  }

  // MARK: Projects
  //
  // A project is saved the moment its own editor says Save (or a delete is confirmed), like a vault
  // entry: it belongs to the saved host, whatever happens to the rest of this form. Discard only
  // drops the host's own fields.

  private func _addProject() {
    guard _host != nil else { return }
    _editingProject = HostProjectEdit(project: MoshProject(name: "", folder: "", command: "", session: ""), isNew: true)
  }

  private func _saveProject(_ project: MoshProject) {
    if let index = _projects.firstIndex(where: { $0.id == project.id }) {
      _projects[index] = project
    } else {
      _projects.append(project)
    }
    _persistProjects()
  }

  private func _deleteProject(_ project: MoshProject) {
    _projects.removeAll { $0.id == project.id }
    _persistProjects()
  }

  private func _moveProject(_ project: MoshProject, by delta: Int) {
    guard let index = _projects.firstIndex(where: { $0.id == project.id }) else { return }
    let target = index + delta
    guard _projects.indices.contains(target) else { return }
    _projects.swapAt(index, target)
    _persistProjects()
  }

  private func _confirmDeleteProject(_ project: MoshProject) {
    let host = _host?.host ?? "the server"
    _pendingProjectDelete = MoshDeletePrompt(
      name: project.name.isEmpty ? project.session : project.name,
      what: "this project",
      extra: "Its session on \(host) is left running: end it there if you no longer need it."
    ) {
      _deleteProject(project)
    }
  }

  // Straight onto the saved host (stamped, so the iCloud merge takes this edit) and to disk.
  private func _persistProjects() {
    guard let host = _host else { return }
    host.projectsJSON = MoshProject.json(_projects)
    host.lastModified = Date()
    guard MoshHosts.save() else {
      _errorMessage = "The project could not be saved: the hosts file is not writable right now. Unlock the device and try again."
      return
    }
    _reloadList()
  }

  private static var __sshConfigAttachmentExample: String { "# Compression no" }

  func loadHost() {
    _loaded = true

    guard let host = _host ?? _duplicatedHost else {
      return
    }

    _alias = host.host ?? ""
    _hostName = host.hostName ?? ""
    _port = host.port == nil ? "" : host.port.stringValue
    _user = host.user ?? ""
    _loadedPassword = host.password
    _password = _loadedPassword ?? ""
    _sshKeyName = (host.key == nil || host.key.isEmpty) ? [] : [host.key]
    _proxyCmd = host.proxyCmd ?? ""
    _proxyJump = host.proxyJump ?? ""
    _sshConfigAttachment = host.sshConfigAttachment ?? ""
    if _sshConfigAttachment.isEmpty {
      _sshConfigAttachment = HostView.__sshConfigAttachmentExample
    }
    if let moshPort = host.moshPort {
      if let moshPortEnd = host.moshPortEnd {
        _moshPort = "\(moshPort):\(moshPortEnd)"
      } else {
        _moshPort = moshPort.stringValue
      }
    }

    _moshPrediction.rawValue = UInt32(host.prediction?.intValue ?? 0)
    _moshPredictOverwrite = host.moshPredictOverwrite == "yes"
    _moshExperimentalIP.rawValue = UInt32(host.moshExperimentalIP?.intValue ?? 0)
    _moshServer  = host.moshServer ?? ""
    _moshCommand = host.moshStartup ?? ""
    _commandOnConnect = host.commandOnConnect ?? ""
    _hostDescription = host.hostDescription ?? ""
    _useTmux = host.moshroomUsesTmux
    _tmuxSession = host.tmuxSession ?? ""
    _agentForwardPrompt.rawValue = UInt32(host.agentForwardPrompt?.intValue ?? 0)
    _agentForwardKeys = host.agentForwardKeys ?? []
    // A duplicate starts with no projects: each one is a session on the server, and two hosts
    // pointing at the same sessions would fight over them.
    _projects = _host == nil ? [] : host.moshroomProjects
    _enabled = true
  }

  @discardableResult
  private func _validate() -> Bool {
    let cleanAlias = _cleanAlias

    do {
      if cleanAlias.isEmpty {
        throw ValidationError.general(
          message: "Alias is required."
        )
      }

      if let _ = cleanAlias.rangeOfCharacter(from: .whitespacesAndNewlines) {
        throw ValidationError.general(
          message: "Spaces are not permitted in the alias."
        )
      }

      if let _ = MoshHosts.withHost(cleanAlias), cleanAlias != _host?.host {
        throw ValidationError.general(
          message: "Cannot have two hosts with the same alias."
        )
      }

      let cleanHostName = _hostName.trimmingCharacters(in: .whitespacesAndNewlines)
      if let _ = cleanHostName.rangeOfCharacter(from: .whitespacesAndNewlines) {
        throw ValidationError.general(message: "Spaces are not permitted in the address.")
      }

      if cleanHostName.isEmpty {
        throw ValidationError.general(
          message: "Address is required."
        )
      }

      if let clash = _projects.first(where: { $0.session == _hostSessionName }) {
        throw ValidationError.general(
          message: "The session \u{201C}\(_hostSessionName)\u{201D} belongs to the project \u{201C}\(clash.name)\u{201D}. Pick another session name for the host."
        )
      }
    } catch {
      _errorMessage = error.localizedDescription
      return false
    }
    return true
  }

  // The password travels only when the user changed it: nil leaves the stored one alone (see
  // MoshHosts saveHost:), "" clears it. A new host (or a duplicate) sends whatever the field holds.
  private var _passwordToSave: String? {
    if _host == nil { return _password.isEmpty ? nil : _password }
    return _password == (_loadedPassword ?? "") ? nil : _password
  }

  private func _saveHost() -> Bool {
    let savedHost = MoshHosts.saveHost(
      _host?.host.trimmingCharacters(in: .whitespacesAndNewlines),
      withNewHost: _cleanAlias,
      hostName: _hostName.trimmingCharacters(in: .whitespacesAndNewlines),
      sshPort: _port.trimmingCharacters(in: .whitespacesAndNewlines),
      user: _user.trimmingCharacters(in: .whitespacesAndNewlines),
      password: _passwordToSave,
      hostKey: _sshKeyName.isEmpty ? "" : _sshKeyName[0],
      moshServer: _moshServer,
      moshPredictOverwrite: _moshPredictOverwrite ? "yes" : nil,
      moshExperimentalIP: _moshExperimentalIP,
      moshPortRange: _moshPort,
      startUpCmd: MoshProject.plainShellText(_moshCommand),
      commandOnConnect: MoshProject.plainShellText(_commandOnConnect),
      hostDescription: _hostDescription.trimmingCharacters(in: .whitespacesAndNewlines),
      // ON is the default and is stored as nil, so a host follows the default unless turned off.
      useTmux: _useTmux ? nil : NSNumber(value: false),
      tmuxSession: MoshHosts.moshroomTmuxSessionName(_tmuxSession),
      projectsJSON: MoshProject.json(_projects),
      prediction: _moshPrediction,
      proxyCmd: _proxyCmd,
      proxyJump: _proxyJump,
      sshConfigAttachment: _sshConfigAttachment == HostView.__sshConfigAttachmentExample ? "" : _sshConfigAttachment,
      agentForwardPrompt: _agentForwardPrompt,
      agentForwardKeys: _agentForwardPrompt == MoshAgentForwardNo ? [] : _agentForwardKeys
    )

    return savedHost != nil
  }
}

fileprivate enum ValidationError: Error, LocalizedError {
  case general(message: String, field: String? = nil)

  var errorDescription: String? {
    switch self {
    case .general(message: let message, field: _): return message
    }
  }
}

// MARK: - Header, projects

/// The top of the host editor: the server glyph on a faint mushroom tile, the alias, and a live
/// `user@address:port` summary of where it points.
fileprivate struct HostEditorHeader: View {
  let alias: String
  let summary: String
  let isNew: Bool

  var body: some View {
    HStack(spacing: 14) {
      RoundedRectangle(cornerRadius: Moshstyle.cardRadius, style: .continuous)
        .fill(Color.moshTint.opacity(Double(Moshstyle.faintTintAlpha)))
        .frame(width: 54, height: 54)
        .overlay(
          Image(systemName: "server.rack")
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(.moshTint)
        )
      VStack(alignment: .leading, spacing: 4) {
        Text(alias.isEmpty ? (isNew ? "New host" : "Host") : alias)
          .font(.system(size: 22, weight: .bold))
          .foregroundColor(alias.isEmpty ? .secondary : .primary)
          .lineLimit(1)
        Text(summary)
          .font(.system(.subheadline, design: .monospaced))
          .foregroundColor(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
  }
}

/// A project being edited (the editor is presented per item).
struct HostProjectEdit: Identifiable {
  let project: MoshProject
  let isNew: Bool
  var id: String { project.id }
}

/// One project in the host editor: name, folder in monospace, and the command it starts.
fileprivate struct HostProjectRow: View {
  let project: MoshProject

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "folder.fill")
        .font(.system(size: 16, weight: .medium))
        .foregroundColor(.moshTint)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 3) {
        Text(project.name.isEmpty ? project.session : project.name)
          .font(.body.weight(.semibold))
          .foregroundColor(.primary)
          .lineLimit(1)
        Text(project.folder)
          .font(.system(.footnote, design: .monospaced))
          .foregroundColor(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
        if !project.trimmedCommand.isEmpty {
          HStack(spacing: 5) {
            Image(systemName: "terminal")
              .font(.system(size: 11, weight: .semibold))
            Text(project.trimmedCommand)
              .font(.system(.footnote, design: .monospaced))
              .lineLimit(1)
          }
          .foregroundColor(.secondary)
        }
      }
      Spacer(minLength: 8)
      Image(systemName: "chevron.right")
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(Color(.tertiaryLabel))
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}

/// A project's own editor, full screen (a sheet's toolbar takes no taps on the Mac): where it is on the
/// server (picked by browsing, never typed), its name and the command that starts it.
struct MoshProjectEditor: View {
  let hostAlias: String
  let hostSession: String
  let otherSessions: Set<String>
  @State var project: MoshProject
  let isNew: Bool
  let onSave: (MoshProject) -> Void
  let onDelete: (() -> Void)?

  @Environment(\.dismiss) private var dismiss
  @State private var picking = false
  @State private var pendingDelete: MoshDeletePrompt? = nil

  init(hostAlias: String, hostSession: String, otherSessions: Set<String>, project: MoshProject,
       isNew: Bool, onSave: @escaping (MoshProject) -> Void, onDelete: (() -> Void)?) {
    self.hostAlias = hostAlias
    self.hostSession = hostSession
    self.otherSessions = otherSessions
    _project = State(initialValue: project)
    self.isNew = isNew
    self.onSave = onSave
    self.onDelete = onDelete
  }

  private var cleanName: String {
    let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty && !project.folder.isEmpty ? MoshProject.folderName(project.folder) : name
  }

  // A new project's session follows its name; an existing one keeps the session it already has, so
  // renaming never strands a running session.
  private var session: String {
    if !isNew && !project.session.isEmpty && project.session != hostSession && !otherSessions.contains(project.session) {
      return project.session
    }
    return MoshProject.sessionName(for: cleanName, hostSession: hostSession, taken: otherSessions)
  }

  var body: some View {
    VStack(spacing: 0) {
      MoshSheetHeader(title: isNew ? "New Project" : "Project", onClose: { dismiss() }) {
        Button {
          var saved = project
          saved.name = cleanName
          saved.command = project.trimmedCommand
          saved.session = session
          onSave(saved)
          dismiss()
        } label: { MoshNavLabel(title: "Save") }
          .buttonStyle(.plain)
          .disabled(project.folder.isEmpty)
      }
      Form {
        Section {
          Button { picking = true } label: {
            HStack(spacing: 12) {
              Image(systemName: "folder.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.moshTint)
                .frame(width: 24)
              if project.folder.isEmpty {
                Text("Choose a folder")
                  .foregroundColor(.moshTint)
              } else {
                Text(project.folder)
                  .font(.system(.body, design: .monospaced))
                  .foregroundColor(.primary)
                  .lineLimit(2)
                  .truncationMode(.head)
              }
              Spacer(minLength: 8)
              Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(.tertiaryLabel))
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .moshCatalystPlainButtons()
        } header: {
          Text("Folder")
        } footer: {
          Text("Browse \(hostAlias) and pick it: the session starts there.")
        }

        Section {
          HStack {
            Text("Name").foregroundColor(.secondary).frame(width: 92, alignment: .leading)
            TextField(project.folder.isEmpty ? "The folder's name" : MoshProject.folderName(project.folder), text: $project.name)
              .autocorrectionDisabled()
          }
          HStack {
            Text("Command").foregroundColor(.secondary).frame(width: 92, alignment: .leading)
            TextField("opencode", text: $project.command)
              .font(.system(.body, design: .monospaced))
              .autocorrectionDisabled()
              .textInputAutocapitalization(.never)
          }
        } header: {
          Text("Project")
        } footer: {
          Text(project.folder.isEmpty
               ? "The command starts once, when the project's session is new; empty means a shell in the folder."
               : "Runs in the tmux session \u{201C}\(session)\u{201D}. The command starts once, when that session is new; empty means a shell in the folder.")
        }

        if let onDelete {
          Section {
            Button(role: .destructive) {
              pendingDelete = MoshDeletePrompt(
                name: cleanName,
                what: "this project",
                extra: "Its session on \(hostAlias) is left running: end it there if you no longer need it."
              ) {
                onDelete()
                dismiss()
              }
            } label: {
              Text("Delete Project")
                .frame(maxWidth: .infinity)
                .foregroundColor(.moshTint)
            }
            .moshCatalystPlainButtons()
          }
        }
      }
    }
    .background(Color(.systemGroupedBackground).ignoresSafeArea())
    .tint(.moshTint)
    .moshDeleteConfirmation($pendingDelete)
    .fullScreenCover(isPresented: $picking) {
      MoshFolderPickerScreen(hostAlias: hostAlias, startAt: project.folder.isEmpty ? nil : project.folder) { path in
        // The name follows the folder until the user gives it one of their own.
        let previousDefault = project.folder.isEmpty ? "" : MoshProject.folderName(project.folder)
        let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.folder = path
        if name.isEmpty || name == previousDefault {
          project.name = MoshProject.folderName(path)
        }
      }
    }
  }
}
