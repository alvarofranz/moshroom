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
import Combine

private func _row(_ key: KeyConfig) -> some View {
  DefaultRow(title: key.fullName, description: key.description) {
    KeyConfigView(key: key)
  }
}

private func _pairRow(_ pair: KeyConfigPair) -> some View {
  DefaultRow(title: pair.fullName, description: pair.description) {
    KeyConfigPairView(pair: pair)
  }
}

private func _bindingRow(_ binding: KeyBinding, title: String, last: String) -> some View {
  DefaultRow(title: title, description: binding.keysDescription(last)) {
    BindingConfigView(title: title, binding: binding)
  }
}

struct KBConfigView: View {
  @ObservedObject var config: KBConfig
  @State private var _enableCustomKeyboards = !MoshroomDefaults.disableCustomKeyboards()

  init(config: KBConfig) {
    self.config = config
  }
  
  var body: some View {
    let customKeyboards = Binding(get: {
      return self._enableCustomKeyboards
    }, set: { value in
      self._enableCustomKeyboards = value
      MoshroomDefaults.setDisableCustomKeyboards(!value)
      MoshroomDefaults.save()
    })
    return List {
      Section(
        header: Text("Moshroom"),
        footer: Text("Shortcuts are app actions bound to hardware-keyboard combos (new tab, paste…). Custom Keyboards allows third-party iOS keyboards inside Moshroom — turning it off takes effect after an app restart.")) {
        DefaultRow(title: "Shortcuts") {
          ShortcutsConfigView(
            config: self.config,
            commandsMode: true
          )
          .navigationTitle("Shortcuts")
          .navigationBarTitleDisplayMode(.inline)
        }
        HStack {
          Toggle("Custom Keyboards", isOn: customKeyboards)
        }
      }
      Section(
        header: Text("Terminal"),
        footer: Text("What each modifier on a connected hardware keyboard sends to the terminal — e.g. map Caps Lock to Ctrl or Option to Esc/Meta. Functional and Cursor Keys pick the modifier that turns number/arrow keys into F1–F10 and page navigation; Custom Presses bind any key combo to an exact escape sequence.")
      ) {
        _row(config.capsLock)
        _pairRow(config.shift)
        _pairRow(config.control)
        _pairRow(config.option)
        _pairRow(config.command)
        _bindingRow(config.fnBinding,     title: "Functional Keys", last: "[0-9]")
        _bindingRow(config.cursorBinding, title: "Cursor Keys",     last: "[Arrow]")
        DefaultRow(title: "Custom Presses") {
          ShortcutsConfigView(
            config: self.config,
            commandsMode: false
          )
          .navigationTitle("Presses")
          .navigationBarTitleDisplayMode(.inline)
        }
      }
    }
    .listStyle(.insetGrouped)
    .moshReadableWidth()
    .navigationTitle("Keyboard")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      MoshNavBarItem(placement: .navigationBarTrailing) {
        Button(
          action: {
            MoshroomDefaults.setDisableCustomKeyboards(false)
            MoshroomDefaults.save()
            self._enableCustomKeyboards = !MoshroomDefaults.disableCustomKeyboards()
            self.config.reset()
          },
          label: { MoshNavLabel(title: "Reset") }
        )
      }
    }
    .onReceive(config.objectWillChange.debounce(for: 0.5, scheduler: RunLoop.main)) {
      KBTracker.shared.save(config: self.config)
    }
  }
}
