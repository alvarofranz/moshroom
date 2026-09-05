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

struct ImportKeyView: View {
  @ObservedObject var state: ImportKeyObservable
  
  let onCancel: () -> Void
  let onSuccess: () -> Void
  
  var body: some View {
    List {
      if let match = state.incompleteMatch {
        // The key being imported IS an identity already here, one that arrived without its private
        // half. Completing that identity is the honest outcome — not a second record for the same
        // key, and not the "name already used" dead end that used to end in deleting the key first.
        Section(
          header: Text("RESTORE"),
          footer: Text("This is the private half of an identity you already have. Importing puts it back where it belongs: same name, same record, nothing duplicated and nothing re-synced.")
        ) {
          HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
            VStack(alignment: .leading, spacing: 2) {
              Text(match.id)
              Text("waiting for its private half").font(.footnote).foregroundColor(.secondary)
            }
          }
        }
      } else {
        Section(
          header: Text("NAME"),
          footer: Text("Default key must be named `id_\(state.keyType.lowercased().replacingOccurrences(of: "-", with: "_"))`")
        ) {
          FixedTextField(
            "Enter a name for the key",
            text: $state.keyName,
            id: "keyName",
            nextId: "keyComment",
            autocorrectionType: .no,
            autocapitalizationType: .none
          )
        }
      }
      
      if state.incompleteMatch == nil {
        // A restore writes the private half and nothing else — the public key line, comment included,
        // is the one the identity already has. Offering to type one here would be offering nothing.
        Section(header: Text("COMMENT (OPTIONAL)")) {
          FixedTextField(
            "Comment for your key",
            text: $state.keyComment,
            id: "keyComment",
            returnKeyType: .continue,
            onReturn: {
              if state.saveKey() {
                onSuccess()
              }
            },
            autocorrectionType: .no,
            autocapitalizationType: .none
          )
        }
      }
      
      Section(
        header: Text("INFORMATION"),
        footer: Text("The key is kept in OpenSSH format inside the device keychain — encrypted at rest by the device, and by your iCloud Keychain end-to-end if sync is on. Use \"ssh-copy-id [name]\" to copy the public key to the server.")
      ) { }
    }
    .listStyle(.insetGrouped)
    .moshReadableWidth()
    .toolbar {
      MoshNavBarItem(placement: .navigationBarLeading) {
        Button(action: onCancel) { MoshNavLabel(title: "Cancel") }
      }
      MoshNavBarItem(placement: .navigationBarTrailing) {
        Button(action: {
          if state.saveKey() {
            onSuccess()
          }
        }) { MoshNavLabel(title: state.incompleteMatch == nil ? "Import" : "Restore") }
          .disabled(!state.isValid)
      }
    }
    .navigationTitle(state.incompleteMatch == nil ? "Import \(state.keyType) Key" : "Restore \(state.keyType) Key")
    .navigationBarTitleDisplayMode(.inline)
    .alert(errorMessage: $state.errorMessage)
  }
}

class ImportKeyObservable: ObservableObject {
  let key: SSHKey;
  let keyType: String
  @Published var keyName: String
  @Published var keyComment: String
  @Published var errorMessage = ""
  
  // The identity this key completes, if any: same public half, and its private half is not on this
  // device. Resolved once, at init — answering it walks the keychain.
  let incompleteMatch: MoshPubKey?
  
  var isValid: Bool {
    incompleteMatch != nil || !keyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  
  init(key: SSHKey, keyName: String, keyComment: String) {
    self.key = key
    self.keyType = key.sshKeyType.shortName
    self.keyName = keyName
    self.keyComment = keyComment
    
    let authorized = try? key.authorizedKey(withComment: "")
    self.incompleteMatch = authorized.flatMap { authorized in
      // One keychain listing for all of them, not one per identity.
      MoshPubKey.identitiesMissingPrivateMaterial().first {
        MoshPubKey.publicHalvesMatch(authorized, $0.publicKey)
      }
    }
  }
  
  func saveKey() -> Bool {
    errorMessage = ""
    
    if let match = incompleteMatch {
      do {
        try MoshPubKey.attachPrivateKey(key, to: match)
      } catch {
        errorMessage = error.localizedDescription
        return false
      }
      return true
    }
    
    let keyID = keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    let comment = keyComment.trimmingCharacters(in: .whitespacesAndNewlines)
    
    do {
      if keyID.isEmpty {
        throw KeyUIError.emptyName
      }
      
      if MoshPubKey.withID(keyID) != nil {
        throw KeyUIError.duplicateName(name: keyID)
      }
      
      try MoshPubKey.addKeychainKey(id: keyID, key: key, comment: comment)
      
    } catch {
      errorMessage = error.localizedDescription
      return false
    }

    return true
  }
}
