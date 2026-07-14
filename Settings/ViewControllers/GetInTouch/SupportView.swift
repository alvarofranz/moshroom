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

struct SupportView: View {
  var body: some View {
    List {
      Section(header: Text("Project"), footer: Text("Moshroom is free software (GPLv3). Questions, ideas and bug reports all live on GitHub.")) {
        HStack {
          Button {
            MoshLinkActions.send(toGitHub: "discussions")
          } label: {
            Label("Discussions", systemImage: "bubble.left.and.bubble.right")
          }
          Spacer()
          Text("GitHub").foregroundColor(.secondary)
        }
        HStack {
          Button {
            MoshLinkActions.send(toGitHub: "issues")
          } label: {
            Label("Report an Issue", systemImage: "exclamationmark.bubble")
          }
          Spacer()
          Text("GitHub").foregroundColor(.secondary)
        }
        HStack {
          Button {
            MoshLinkActions.send(toGitHub: nil)
          } label: {
            Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
          }
          Spacer()
          Text("GitHub").foregroundColor(.secondary)
        }
      }
    }
    .listStyle(.insetGrouped)
    .moshReadableWidth()
    .navigationTitle("Support")
    .navigationBarTitleDisplayMode(.inline)
  }
}
