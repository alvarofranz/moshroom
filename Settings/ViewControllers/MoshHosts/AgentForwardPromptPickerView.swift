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


import SwiftUI

extension MoshAgentForward: Hashable {
  var label: String {
    switch self {
    case MoshAgentForwardNo: return "No"
    case MoshAgentForwardConfirm: return "Confirm"
    case MoshAgentForwardYes: return "Always"
    case _: return ""
    }
  }
  
  var hint: String {
    switch self {
    case MoshAgentForwardNo: return "Do not forward the agent"
    case MoshAgentForwardConfirm: return "Confirm each use of a key"
    case MoshAgentForwardYes: return "Forward all keys always"
    case _: return ""
    }
  }

  static var all: [MoshAgentForward] {
    [
      MoshAgentForwardNo,
      MoshAgentForwardConfirm,
      MoshAgentForwardYes,
    ]
  }
}

struct AgentForwardPromptPickerView: View {
  @Binding var currentValue: MoshAgentForward

  var body: some View {
    List {
      Section(footer: Text(currentValue.hint)) {
        ForEach(MoshAgentForward.all, id: \.self) { value in
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
