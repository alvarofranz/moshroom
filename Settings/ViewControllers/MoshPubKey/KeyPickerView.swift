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

fileprivate struct CardRow: View {
  let key: MoshPubKey
  let isChecked: Bool
  
  var body: some View {
    HStack {
      VStack(alignment: .leading) {
        Text(key.id)
        Text(key.keyType ?? "").font(.footnote)
      }.contentShape(Rectangle())
      Spacer()
      Checkmark(checked: isChecked)
    }.contentShape(Rectangle())
  }
}

struct KeyPickerView: View {
  @Binding var currentKey: [String]
  @EnvironmentObject private var _nav: Nav
  @State private var _list: [MoshPubKey] = MoshPubKey.all()
  let multipleSelection: Bool
  
  var body: some View {
    List {
      HStack {
        Text("None")
        Spacer()
        Checkmark(checked: currentKey.isEmpty)
      }
      .contentShape(Rectangle())
      .onTapGesture {
        _selectKey("")
      }
      ForEach(_list, id: \.tag) { key in
        CardRow(key: key, isChecked: currentKey.contains { key.id == $0 })
          .onTapGesture {
            _selectKey(key.id)
          }
      }
    }
    .listStyle(.insetGrouped)
    .moshReadableWidth()
    .moshHubChromeBack(title: "Select a Key")
    .onAppear {
      // Make sure the key selection can only be based on the canonical list.
      currentKey = currentKey.filter { key in _list.contains(where: { $0.id == key }) }
    }
  }
  
  private func _selectKey(_ key: String) {
    if multipleSelection {
      if key.isEmpty {
        currentKey = []
      } else if let idx = currentKey.firstIndex(of: key) {
        currentKey.remove(at: idx)
      } else {
        currentKey.append(key)
      }
    } else {
      if key.isEmpty {
        currentKey = []
      } else {
        currentKey = [key]
      }
      _nav.navController.popViewController(animated: true)
    }
  }
}
