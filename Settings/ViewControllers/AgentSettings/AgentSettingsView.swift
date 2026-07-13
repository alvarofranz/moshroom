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
import SwiftUI


struct DefaultAgentSettingsView: View {
  @State private var agentSettings: MoshAgentSettings? = nil
  @State private var showAlert = false
  @State private var alertMessage = ""
  @State private var dismissAfterAlert = false

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      if let binding = Binding<MoshAgentSettings>($agentSettings) {
        AgentSettingsOptions(agentSettings: binding, enabled: true)
          .onChange(of: agentSettings!) { new in
            do {
              try SSHDefaultAgent.setSettings(new)
            } catch {
              self.alertMessage = "Failed to set settings: \(error.localizedDescription)"
              self.showAlert = true
              self.dismissAfterAlert = true
            }
          }
      }
    }
    .navigationBarTitle("Default Agent")
    .onAppear {
      print("OnAppear")
      if agentSettings == nil {
        print("Init settings")
        do {
          let agentSettings = try SSHDefaultAgent.getSettings() ?? MoshAgentSettings()
          self.agentSettings = agentSettings
        } catch {
          self.alertMessage = "Failed to get settings: \(error.localizedDescription)"
          self.showAlert = true
          self.dismissAfterAlert = true
        }
      }
    }
    .alert(isPresented: $showAlert) {
      Alert(
        title: Text("Error"),
        message: Text(alertMessage),
        dismissButton: .default(Text("OK")) {
          if self.dismissAfterAlert {
            dismiss()
          }
        }
      )
    }
  }
}

struct AgentSettingsOptions: View {
  @Binding var agentSettings: MoshAgentSettings
  @State var prompt: MoshAgentSettingsPrompt
  @State var keys: [String]
  var enabled: Bool

  init(agentSettings: Binding<MoshAgentSettings>, enabled: Bool) {
    self._agentSettings = agentSettings
    self.prompt = agentSettings.wrappedValue.prompt
    self.keys = agentSettings.wrappedValue.keys
    self.enabled = enabled
  }

  var body: some View {
    FieldAgentSettingsPrompt(value: $prompt, enabled: enabled)
      .onChange(of: prompt) { newPrompt in
        self.agentSettings = MoshAgentSettings(prompt: newPrompt, keys: keys)
      }
    if prompt != .Deny {
      FieldAgentSettingsKeys(value: $keys, enabled: enabled)
        .onChange(of: keys) { newKeys in
          self.agentSettings = MoshAgentSettings(prompt: prompt, keys: newKeys)
        }
    }
  }
}

fileprivate struct FieldAgentSettingsPrompt: View {
  @Binding var value: MoshAgentSettingsPrompt
  var enabled: Bool

  var body: some View {
    Row(
      content: {
        HStack {
          FormLabel(text: "Agent Forwarding")
          Spacer()
          Text(value.label)
        }
      },
      details: {
        AgentSettingsPromptPickerView(currentValue: enabled ? $value : .constant(value))
      }
    ).disabled(!enabled)
  }
}

fileprivate struct FieldAgentSettingsKeys: View {
  @Binding var value: [String]
  var enabled: Bool

  var body: some View {
    Row(
      content: {
        HStack {
          FormLabel(text: "Load Keys")
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

struct AgentSettingsPromptPickerView: View {
  @Binding var currentValue: MoshAgentSettingsPrompt

  var body: some View {
    List {
      Section(footer: Text(currentValue.hint)) {
        ForEach(MoshAgentSettingsPrompt.all, id: \.self) { value in
          HStack {
            Text(value.label).tag(value)
            Spacer()
            Checkmark(checked: currentValue == value)
          }
          .contentShape(Rectangle())
          .onTapGesture { currentValue = value }
        }
      }
    }
    .listStyle(InsetGroupedListStyle())
    .navigationTitle("Agent Forwarding")
  }
}

extension MoshAgentSettingsPrompt: Hashable {
  var label: String {
    switch self {
    case .Deny: return "No"
    case .Confirm: return "Confirm"
    case .Allow: return "Allow"
    case _: return ""
    }
  }

  var hint: String {
    switch self {
    case .Deny: return "Deny usage of the key for signatures."
    case .Confirm: return "Confirm each use of a key before signature."
    case .Allow: return "Allow to use the key for signature without confirmation."
    case _: return ""
    }
  }

  static var all: [MoshAgentSettingsPrompt] {
    [
      Deny,
      Confirm,
      Allow,
    ]
  }
}
