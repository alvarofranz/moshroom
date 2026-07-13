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

struct NewKeyView: View {
  let onCancel: () -> Void
  let onSuccess: () -> Void
  
  @StateObject private var _state = NewKeyObservable()
  
  var body: some View {
    List {
      Section(
        header: Text("NAME"),
        footer: Text("Default key must be named `\(_state.keyType.defaultKeyName)`")
      ) {
        FixedTextField(
          "Enter a name for the key",
          text: $_state.keyName,
          id: "keyName",
          nextId: "keyComment",
          autocorrectionType: .no,
          autocapitalizationType: .none
        )
      }
      
      Section(
        header: Text("KEY TYPE"),
        footer: Text(_state.keyType.keyHint)
      ) {
        Picker("", selection: $_state.keyType) {
          Text(SSHKeyType.dsa.shortName).tag(SSHKeyType.dsa)
          Text(SSHKeyType.rsa.shortName).tag(SSHKeyType.rsa)
          Text(SSHKeyType.ecdsa.shortName).tag(SSHKeyType.ecdsa)
          Text(SSHKeyType.ed25519.shortName).tag(SSHKeyType.ed25519)
        }
        .pickerStyle(SegmentedPickerStyle())
        if _state.keyType.possibleBitsValues.count > 1 {
          HStack {
            Text("Bits").layoutPriority(1)
            Spacer().layoutPriority(1)
            VStack {
              Picker("", selection: $_state.keyBits) {
                ForEach(_state.keyType.possibleBitsValues, id: \.self) { bits in
                  Text("\(bits)").tag(bits)
                }
              }
              .pickerStyle(SegmentedPickerStyle())
            }.layoutPriority(1)
          }
        }
      }
      
      Section(header: Text("COMMENT (OPTIONAL)")) {
        FixedTextField(
          "Comment for your key",
          text: $_state.keyComment,
          id: "keyComment",
          returnKeyType: .continue,
          onReturn: _createKey,
          autocorrectionType: .no,
          autocapitalizationType: .none
        )
      }
      
      Section(
        header: Text("INFORMATION"),
        footer: Text("Moshroom creates PKCS#8 public and private keys, with AES 256 bit encryption. Use \"ssh-copy-id [name]\" to copy the public key to the server.")
      ) { }
    }
    .listStyle(GroupedListStyle())
    .toolbar {
      MoshNavBarItem(placement: .navigationBarLeading) {
        Button(action: onCancel) { MoshNavLabel(title: "Cancel") }
      }
      MoshNavBarItem(placement: .navigationBarTrailing) {
        Button(action: _createKey) { MoshNavLabel(title: "Create") }
          .disabled(!_state.isValid)
      }
    }
    .navigationBarTitle("New \(_state.keyType.shortName) Key")
    .alert(errorMessage: $_state.errorMessage)
    .onAppear(perform: {
      FixedTextField.becomeFirstReponder(id: "keyName")
    })

  }
  
  private func _createKey() {
    if _state.createKey() {
      onSuccess()
    }
  }
}

fileprivate class NewKeyObservable: ObservableObject {

  @Published var keyType: SSHKeyType = .rsa {
    didSet {
      keyBits = keyType.possibleBitsValues.last ?? 0
    }
  }
  @Published var keyName: String = ""
  @Published var keyBits: UInt32 = 4096
  @Published var keyComment: String = "\(MoshroomDefaults.defaultUserName() ?? "")@\(UIDevice.getInfoType(fromDeviceName: MoshDeviceInfoTypeDeviceName) ?? "")"
  
  @Published var errorMessage = ""
  
  var isValid: Bool {
    !keyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  
  func createKey() -> Bool {
    errorMessage = ""
    let keyID = keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    let comment = keyComment.trimmingCharacters(in: .whitespacesAndNewlines)
    
    do {
      if keyID.isEmpty {
        throw KeyUIError.emptyName
      }
      
      if MoshPubKey.withID(keyID) != nil {
        throw KeyUIError.duplicateName(name: keyID)
      }
      
      let key = try SSHKey(type: keyType, bits: keyBits)
      try MoshPubKey.addKeychainKey(id: keyID, key: key, comment: comment)
      
    } catch {
      errorMessage = error.localizedDescription
      return false
    }

    return true
  }
}

fileprivate extension SSHKeyType {
  var possibleBitsValues: [UInt32] {
    switch self {
    case .dsa:     return [1024]
    case .rsa:     return [2048, 4096]
    case .ecdsa:   return [256, 384, 521]
    case .ed25519: return []
    default:       return []
    }
  }
  
  var keyHint: String {
    switch self {
    case .dsa: return "DSA keys must be exactly 1024 bits as specified by FIPS 186-2."
    case .rsa: return "Generally, 2048 bits is considered sufficient."
    case .ecdsa: return "For ECDSA keys size determines key length by selecting from one of three elliptic curve sizes: 256, 384 or 521 bits."
    case .ed25519: return "Ed25519 keys have a fixed length."
    default: return ""
    }
  }
}
