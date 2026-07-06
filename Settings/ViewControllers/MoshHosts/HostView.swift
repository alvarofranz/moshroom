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
              .font(.system(.subheadline)).foregroundColor(.red)
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
        // TextEditor can't change background color
        RoundedRectangle(cornerRadius: 4, style: .circular)
          .fill(Color.primary)
          .overlay(
            TextEditor(text: _value)
              .font(.system(.body))
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .opacity(0.9).disabled(!_enabled)
          )
          .padding()
        .navigationTitle(_label)
        .navigationBarTitleDisplayMode(.inline)
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
  @State private var _loaded = false
  @State private var _enabled: Bool = true

  @State private var _agentForwardPrompt: MoshAgentForward = MoshAgentForwardNo
  @State private var _agentForwardKeys: [String] = []

  @State private var _errorMessage: String = ""

  private var _reloadList: () -> ()
  private var _cleanAlias: String {
    _alias.trimmingCharacters(in: .whitespacesAndNewlines)
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

  private func _usageHint() -> String {
    var alias = _cleanAlias
    if alias.count < 2 {
      alias = "[alias]"
    }

    return "Use `mosh \(alias)` or `ssh \(alias)` from the shell to connect."
  }

  var body: some View {
    List {
      Section(
        header: Text(""),
        footer: Text(verbatim: _usageHint())
      ) {
        Field("Alias", _aliasNoSpaces, next: "HostName", placeholder: "Required")
      }.disabled(!_enabled)

      Section(
        header: Text("SSH"),
        footer: Text("How to reach the machine: address, port (22 unless changed), user, and how to authenticate — a key from Keys & Certificates, or a password (leave it empty to be asked each time). ProxyCmd/ProxyJump route the connection through a bastion, and SSH Config takes any extra ssh_config lines verbatim.")
      ) {
        Field("HostName",  $_hostName,  next: "Port",      placeholder: "Host or IP address. Required", enabled: _enabled, kbType: .URL)
        Field("Port",      $_port,      next: "User",      placeholder: "22", enabled: _enabled, kbType: .numberPad)
        Field("User",      $_user,      next: "Password",  placeholder: MoshroomDefaults.defaultUserName(), enabled: _enabled)
        FieldPassword("Password",  $_password,  next: "ProxyCmd",  placeholder: "Ask Every Time", enabled: _enabled)
        FieldSSHKey(value: $_sshKeyName, enabled: _enabled, hasSSHKey: MoshPubKey.all().contains(where: {
          if let keyName = _sshKeyName.first {
            return $0.id == keyName
          }
          return false
        }))
        Field("ProxyCmd",  $_proxyCmd,  next: "ProxyJump", placeholder: "ssh -W %h:%p bastion", enabled: _enabled)
        Field("ProxyJump", $_proxyJump, next: "Server",    placeholder: "bastion1,bastion2", enabled: _enabled)
        FieldTextArea("SSH Config", $_sshConfigAttachment, enabled: _enabled)
      }

      Section(
        header: Text("MOSH"),
        footer: Text("""
        Only used when you connect with `mosh` — all optional.

        Server — full path to mosh-server on the machine, only if it isn't in the login PATH (e.g. /usr/local/bin/mosh-server).

        Port — the UDP port (or PORT:PORT range) mosh talks over; set it when the server firewall only opens specific ports, e.g. 60000:60010. Empty lets mosh-server pick.

        Command — what mosh runs instead of your login shell. The classic use is a persistent session that survives disconnects:
        • tmux new -A -s main — attach the tmux session "main", creating it if needed (the safe default).
        • tmux attach -d — attach the existing session; -d detaches any other client holding it.
        • screen -Rd — reattach your screen session, detaching it elsewhere first; creates one if none.
        Leave empty for a plain shell.
        """)
      ) {
        Field("Server",  $_moshServer,  next: "moshPort",    placeholder: "path/to/mosh-server")
        Field("Port",    $_moshPort,    next: "moshCommand", placeholder: "UDP PORT[:PORT2]", id: "moshPort", kbType: .numbersAndPunctuation)
        Field("Command", $_moshCommand, next: "commandOnConnect", placeholder: "tmux new -A -s main", id: "moshCommand")
        FieldMoshCustomOptions(
          prediction: $_moshPrediction,
          overwrite: $_moshPredictOverwrite,
          experimentalIP: $_moshExperimentalIP,
          enabled: _enabled
        )
      }.disabled(!_enabled)

      Section(
        header: Text("ON CONNECT"),
        footer: Text("Typed into the session right after connecting — over SSH and Mosh alike (e.g. cd dev && claude). It runs inside whatever session comes up, so it does not replace the Mosh command.")
      ) {
        Field("Command", $_commandOnConnect, next: "Alias", placeholder: "cd dev && claude", id: "commandOnConnect")
      }.disabled(!_enabled)

      Section(
        header: Text("SSH AGENT"),
        footer: Text("Agent forwarding lets programs on this host (e.g. git) authenticate with keys that never leave your phone. Choose whether to forward, whether each use needs your confirmation, and which keys are offered.")
      ) {
        FieldAgentForwardPrompt(value: $_agentForwardPrompt, enabled: _enabled)
        if _agentForwardPrompt != MoshAgentForwardNo {
          FieldAgentForwardKeys(value: $_agentForwardKeys, enabled: _enabled)
        }
      }.disabled(!_enabled)
    }
    .listStyle(GroupedListStyle())
    .alert(errorMessage: $_errorMessage)
    .navigationBarItems(
      leading: Group {
        Button("Discard", action: {
          _nav.navController.popViewController(animated: true)
        })
      },
      trailing: Group {
        Button("Save", action: {
          // A validation failure shows the alert and keeps the editor open — never save a bad host.
          guard _validate() else { return }
          _saveHost()
          _reloadList()
          _nav.navController.popViewController(animated: true)
        })
      }
    )
    .navigationBarBackButtonHidden(true)
    .navigationBarTitle(_host == nil ? "New Host" : "Host")
    .onAppear {
      if !_loaded {
        loadHost()
      }
    }

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
    _password = host.password ?? ""
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
    _agentForwardPrompt.rawValue = UInt32(host.agentForwardPrompt?.intValue ?? 0)
    _agentForwardKeys = host.agentForwardKeys ?? []
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
        throw ValidationError.general(message: "Spaces are not permitted in the host name.")
      }

      if cleanHostName.isEmpty {
        throw ValidationError.general(
          message: "HostName is required."
        )
      }
    } catch {
      _errorMessage = error.localizedDescription
      return false
    }
    return true
  }

  private func _saveHost() {
    let savedHost = MoshHosts.saveHost(
      _host?.host.trimmingCharacters(in: .whitespacesAndNewlines),
      withNewHost: _cleanAlias,
      hostName: _hostName.trimmingCharacters(in: .whitespacesAndNewlines),
      sshPort: _port.trimmingCharacters(in: .whitespacesAndNewlines),
      user: _user.trimmingCharacters(in: .whitespacesAndNewlines),
      password: _password,
      hostKey: _sshKeyName.isEmpty ? "" : _sshKeyName[0],
      moshServer: _moshServer,
      moshPredictOverwrite: _moshPredictOverwrite ? "yes" : nil,
      moshExperimentalIP: _moshExperimentalIP,
      moshPortRange: _moshPort,
      startUpCmd: _moshCommand,
      commandOnConnect: _commandOnConnect,
      prediction: _moshPrediction,
      proxyCmd: _proxyCmd,
      proxyJump: _proxyJump,
      sshConfigAttachment: _sshConfigAttachment == HostView.__sshConfigAttachmentExample ? "" : _sshConfigAttachment,
      agentForwardPrompt: _agentForwardPrompt,
      agentForwardKeys: _agentForwardPrompt == MoshAgentForwardNo ? [] : _agentForwardKeys
    )

    guard savedHost != nil else {
      return
    }
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
