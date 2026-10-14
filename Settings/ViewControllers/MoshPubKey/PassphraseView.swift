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
import SSH

struct PassphraseView: View {
  let keyBlob: Data
  let keyProposedName: String
  let onCancel: () -> ()
  let onSuccess: () -> ()
  
  @State private var _passphrase: String = ""
  @State private var _errorMessage: String = ""
  @State private var _importKeyObservable: ImportKeyObservable? = nil
  
  private func _unlock() {
    do {
      let key = try SSHKey(fromFileBlob: keyBlob, passphrase: _passphrase)
      _importKeyObservable = ImportKeyObservable(key: key, keyName: keyProposedName, keyComment: key.comment ?? "")
    } catch {
      _errorMessage = error.localizedDescription
    }
  }
  
  var body: some View {
    List {
      Section {
        HStack {
          Spacer()
          Image(systemName: "lock.doc")
            .font(.system(size: 44))
            .foregroundColor(.moshTint)
          Spacer()
        }
        .listRowBackground(Color.clear)
      }
      Section(
        header: Text("PASSPHRASE"),
        footer: Text("This key is protected with a passphrase. Enter it to import the key.")
      ) {
        FixedTextField(
          "Passphrase",
          text: $_passphrase,
          id: "passphrase",
          onReturn: _unlock,
          secureTextEntry: true,
          autocorrectionType: .no,
          autocapitalizationType: .none
        )
      }
    }
    .listStyle(.insetGrouped)
    .moshReadableWidth()
    // The hidden push to the import step stays OUTSIDE the list: inside it, it drew an empty row.
    .background(
      Group {
        if let importObservable = _importKeyObservable {
          ImportKeyView(state: importObservable, onCancel: onCancel, onSuccess: onSuccess)
        }
      }
      .navigationBarBackButtonHidden(true)
      .navigatePush(whenPresent: $_importKeyObservable)
    )
    .moshSheetChrome(title: "Encrypted Key", onClose: onCancel) {
      Button(action: _unlock) { MoshNavLabel(title: "Unlock") }
        .buttonStyle(.plain)
        .disabled(_passphrase.isEmpty)
    }
    .onAppear() {
      FixedTextField.becomeFirstReponder(id: "passphrase")
    }
    .alert(errorMessage: $_errorMessage)
  }
}
