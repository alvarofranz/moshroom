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
//import GameController

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
//  @State private var _keyboardConnectPublisher = KBConfigView.keyboardPublisher
//  @State private var _connectedKeyboardVendorName: String? = GCKeyboard.coalesced?.vendorName
  
  
//  static var keyboardPublisher: AnyPublisher<NotificationCenter.Publisher.Output, Never> {
//    let connectPublisher = NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)
//    let disconnectPublisher = NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)
//    return connectPublisher.merge(with: disconnectPublisher).eraseToAnyPublisher()
//  }
  
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
        footer: Text("You can disable third-party custom keyboards. You have to restart Moshroom for this change to take effect.")) {
        DefaultRow(title: "Shortcuts") {
          ShortcutsConfigView(
            config: self.config,
            commandsMode: true
          )
          .navigationBarTitle("Shortcuts")
        }
        HStack {
          Toggle("Custom Keyboards", isOn: customKeyboards)
        }
      }
      Section(
        header: Text("Terminal"),
        footer: Text("")//Text(_connectedKeyboardVendorName == nil ? "" : "Connected Keyboard: \(_connectedKeyboardVendorName ?? "")" )
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
          .navigationBarTitle("Presses")
        }
      }
    }
    .listStyle(GroupedListStyle())
    .navigationBarTitle("Keyboard")
    .navigationBarItems(trailing:
      Button(
        action: {
          MoshroomDefaults.setDisableCustomKeyboards(false)
          MoshroomDefaults.save()
          self._enableCustomKeyboards = !MoshroomDefaults.disableCustomKeyboards()
          self.config.reset()
        },
        label: { Text("Reset") }
      )
    )
    .onReceive(config.objectWillChange.debounce(for: 0.5, scheduler: RunLoop.main)) {
      KBTracker.shared.save(config: self.config)
    }
//    .onReceive(_keyboardConnectPublisher) { _ in
//      _connectedKeyboardVendorName = GCKeyboard.coalesced?.vendorName
//    }
  }
}
