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

struct KeySection: View {
  var title: String = ""
  @ObservedObject var key: KeyConfig
  
  var body: some View {
    Group {
      Section(
        header: Text((title + " Press Send").uppercased()).font(.subheadline),
        footer: Text(key.press.usageHint).font(.footnote)) {
        Picker(selection: $key.press, label: Text("")) {
          Text("None").tag(KeyPress.none)
          Text("Escape").tag(KeyPress.escape)
          Text("Escape on Release").tag(KeyPress.escapeOnRelease)
        }
        .pickerStyle(SegmentedPickerStyle())
      }
      
      Section(
        header: Text((title + " As Modifier").uppercased()).font(.subheadline),
        footer: Text(key.mod.usageHint).font(.footnote)) {
        Picker(selection: $key.mod, label: Text("")) {
          Text("Default").tag(KeyModifier.none)
          Text("8-bit").tag(KeyModifier.bit8)
          Text("Ctrl").tag(KeyModifier.control)
          Text("Esc").tag(KeyModifier.escape)
//          Text("Meta").tag(KeyModifier.meta)
          Text("Shift").tag(KeyModifier.shift)
        }
        .pickerStyle(SegmentedPickerStyle())
      }
      if key.code.hasAccents {
        Section(header: Text((title + " Accents").uppercased()).font(.subheadline)) {
          Toggle(isOn: self.$key.ignoreAccents, label: { Text("Ignore") })
        }
      }

    }
  }
}
