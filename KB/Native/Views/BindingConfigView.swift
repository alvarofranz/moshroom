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

private func _bindingRowValue(_ binding: KeyBinding, keyCode: KeyCode) -> some View {
  if binding.keys.contains(keyCode.id) {
    if keyCode.single {
      return AnyView(Checkmark())
    } else {
      return AnyView(Text(binding.modifierText(keyCode: keyCode)))
    }
  } else {
    return AnyView(EmptyView())
  }
}

private func _bindingRow(_ binding: KeyBinding, keyCode: KeyCode) -> some View {
  HStack {
    Text(keyCode.fullName)
    Spacer()
    Button(
      action: {
        binding.cycle(keyCode: keyCode)
      },
      label: {
        _bindingRowValue(binding, keyCode: keyCode)
      }
    )
  }
}


struct BindingConfigView: View {
  var title: String
  @ObservedObject var binding: KeyBinding
  
  var body: some View {
    List {
      _bindingRow(binding, keyCode: KeyCode.capsLock)
      _bindingRow(binding, keyCode: KeyCode.shiftLeft)
      _bindingRow(binding, keyCode: KeyCode.controlLeft)
      _bindingRow(binding, keyCode: KeyCode.optionLeft)
      _bindingRow(binding, keyCode: KeyCode.commandLeft)
    }
    .listStyle(GroupedListStyle())
    .navigationBarTitle(title)
  }
}
