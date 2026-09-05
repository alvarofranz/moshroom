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

struct KeyDetailsView: View {
  @State var card: MoshPubKey
  
  let reloadCards: () -> ()
  
  @EnvironmentObject private var _nav: Nav
  @State private var _keyName: String = ""
  @State private var _certificate: String? = nil
  @State private var _originalCertificate: String? = nil
  @State private var _pubkeyLines = 1
  @State private var _certificateLines = 1
  
  @State private var _actionSheetIsPresented = false
  @State private var _filePickerIsPresented = false
  
  @State private var _errorMessage = ""
  
  @State private var _publicKeyCopied = false
  @State private var _certificateCopied = false
  @State private var _privateKeyCopied = false

  // Is the private half actually on THIS device? A key record travels over iCloud Drive while its
  // material rides the iCloud Keychain, so a device can hold a perfectly good record it cannot sign
  // with. That state is repairable in place (below) — it used to mean deleting the key and importing
  // it again, which tombstones the record and takes it off the other device too.
  @State private var _hasPrivateKey = true
  @State private var _privateKeyRestored = false
  // One file importer serves both jobs; this says which one opened it.
  @State private var _fileImportMode: FileImportMode = .certificate
  @State private var _passphrasePromptIsPresented = false
  @State private var _passphrase = ""
  @State private var _pendingPrivateKeyBlob: Data? = nil
  @State private var _pendingDelete: MoshDeletePrompt? = nil

  private enum FileImportMode { case certificate, privateKey }
  
  private func _copyPublicKey() {
    _publicKeyCopied = false
    
    UIPasteboard.general.string = card.publicKey
    withAnimation {
      _publicKeyCopied = true
    }
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
      withAnimation {
        _publicKeyCopied = false
      }
    }
  }
  
  private func _copyCertificate() {
    _certificateCopied = false
    UIPasteboard.general.string = _certificate ?? ""
    withAnimation {
      _certificateCopied = true
    }
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
      withAnimation {
        _certificateCopied = false
      }
    }
  }
  
  private var _saveIsDisabled: Bool {
    (card.id == _keyName && _certificate == _originalCertificate) || _keyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  
  private func _showError(message: String) {
    _errorMessage = message
  }
  
  private func _importCertificateFromClipboard() {
    do {
      guard
        let str = UIPasteboard.general.string,
        !str.isEmpty
      else {
        return _showError(message: "Pasteboard is empty")
      }
      
      guard let blob = str.data(using: .utf8) else {
        return _showError(message: "Can't convert to string with UTF8 encoding")
      }
      try _importCertificateFromBlob(blob)
    } catch {
      _showError(message: error.localizedDescription)
    }
  }
  
  private func _importFromFile(result: Result<URL, Error>) {
    do {
      let url = try result.get()
      guard
        url.startAccessingSecurityScopedResource()
      else {
        throw KeyUIError.noReadAccess
      }
      defer {
        url.stopAccessingSecurityScopedResource()
      }
      
      let blob = try Data(contentsOf: url, options: .alwaysMapped)
      
      switch _fileImportMode {
      case .certificate: try _importCertificateFromBlob(blob)
      case .privateKey:  _restorePrivateKey(from: blob)
      }
    } catch {
      _showError(message: error.localizedDescription)
    }
  }
  
  private func _importCertificateFromBlob(_ certBlob: Data) throws {
    guard
      let privateKey = card.loadPrivateKey(),
      let privateKeyBlob = privateKey.data(using: .utf8)
    else {
      return _showError(message: "Can't load private key")
    }
    
    _ = try SSHKey(fromFileBlob: privateKeyBlob, passphrase: "", withPublicFileCertBlob: SSHKey.sanitize(key: certBlob))
    
    _certificate = String(data: certBlob, encoding: .utf8)
  }
  
  private func _sharePublicKey(frame: CGRect) {
    let activityController = UIActivityViewController(activityItems: [card], applicationActivities: nil);
  
    activityController.excludedActivityTypes = [
      .postToTwitter, .postToFacebook,
      .assignToContact, .saveToCameraRoll,
      .addToReadingList, .postToFlickr,
      .postToVimeo, .postToWeibo
    ]

    activityController.popoverPresentationController?.sourceView = _nav.navController.view
    activityController.popoverPresentationController?.sourceRect = frame
    _nav.navController.present(activityController, animated: true, completion: nil)
  }
  
  private func _copyPrivateKey() {
    _privateKeyCopied = false
    LocalAuth.shared.authenticate(callback: { success in
      guard
        success,
        let privateKey = card.loadPrivateKey()
      else {
        return
      }
      UIPasteboard.general.string = privateKey
      withAnimation {
        _privateKeyCopied = true
      }
      
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        withAnimation {
          _privateKeyCopied = false
        }
      }
    }, reason: "to copy private key to clipboard.")
  }
  
  // MARK: - Giving an identity its private half back
  //
  // Everything here writes into the EXISTING record: same id, same tag, no delete, nothing
  // tombstoned. The key offered has to prove it is this identity (its public half must match) before
  // a byte is stored — MoshPubKey.attachPrivateKey owns that check.

  private func _restorePrivateKeyFromClipboard() {
    guard
      let str = UIPasteboard.general.string,
      !str.isEmpty
    else {
      return _showError(message: "Pasteboard is empty")
    }
    guard let blob = SSHKey.sanitize(key: str).data(using: .utf8) else {
      return _showError(message: "Can't convert to string with UTF8 encoding")
    }
    _restorePrivateKey(from: blob)
  }

  private func _restorePrivateKey(from blob: Data, passphrase: String = "") {
    do {
      let key = try SSHKey(fromFileBlob: SSHKey.sanitize(key: blob), passphrase: passphrase)
      try MoshPubKey.attachPrivateKey(key, to: card)

      _pendingPrivateKeyBlob = nil
      _passphrase = ""
      _hasPrivateKey = true
      withAnimation { _privateKeyRestored = true }
      reloadCards()
      DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        withAnimation { _privateKeyRestored = false }
      }
    } catch SSHKeyError.wrongPassphrase {
      // Keep the blob: the passphrase prompt feeds it straight back in.
      let isRetry = _pendingPrivateKeyBlob != nil
      _pendingPrivateKeyBlob = blob
      _passphrase = ""
      if isRetry {
        // Re-arming an alert in the same runloop as the dismissal that just happened drops the
        // presentation, and a second wrong passphrase would look like a dead button. One hop out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
          _passphrasePromptIsPresented = true
        }
      } else {
        _passphrasePromptIsPresented = true
      }
    } catch {
      _showError(message: error.localizedDescription)
    }
  }

  // AirDrop / Files / Messages — the transfer that does not go through the clipboard, and the reason
  // an ED25519 key is worth defaulting to: it is a few hundred bytes, so it moves anywhere.
  private func _exportPrivateKey(frame: CGRect) {
    LocalAuth.shared.authenticate(callback: { success in
      guard success, let privateKey = card.loadPrivateKey() else {
        return
      }
      let name = card.id.trimmingCharacters(in: .whitespacesAndNewlines)
      let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(name.isEmpty ? "id_key" : name)
      do {
        try privateKey.write(to: url, atomically: true, encoding: .utf8)
        // Same permissions ssh itself insists on, in case it lands somewhere that keeps them.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      } catch {
        return _showError(message: error.localizedDescription)
      }

      let activityController = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      activityController.excludedActivityTypes = [
        .postToTwitter, .postToFacebook, .assignToContact, .saveToCameraRoll,
        .addToReadingList, .postToFlickr, .postToVimeo, .postToWeibo
      ]
      activityController.popoverPresentationController?.sourceView = _nav.navController.view
      activityController.popoverPresentationController?.sourceRect = frame
      activityController.completionWithItemsHandler = { _, _, _, _ in
        try? FileManager.default.removeItem(at: url)
      }
      _nav.navController.present(activityController, animated: true, completion: nil)
    }, reason: "to export the private key.")
  }

  private func _removeCertificate() {
    _certificate = nil
  }
  
  // Deleting a key is not a local act when sync is on: the record carries a tombstone that wins
  // against every device, and the material goes with the iCloud Keychain. So it asks first, in
  // those words, and only then for Face ID.
  private func _confirmDelete() {
    _pendingDelete = MoshDeletePrompt(
      name: card.id,
      what: "this identity",
      extra: "Anything using it to connect will stop working."
    ) {
      _deleteCard()
    }
  }

  private func _deleteCard() {
    LocalAuth.shared.authenticate(callback: { success in
      if success {
        MoshPubKey.removeCard(card: card)
        reloadCards()
        _nav.navController.popViewController(animated: true)
      }
    }, reason: "to delete key.")
  }
  
  private func _saveCard() {
    let keyID = _keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      if keyID.isEmpty {
        throw KeyUIError.emptyName
      }
      
      if let oldKey = MoshPubKey.withID(keyID) {
        if oldKey !== _card.wrappedValue {
          throw KeyUIError.duplicateName(name: keyID)
        }
      }
      
      _card.wrappedValue.id = keyID
      guard _card.wrappedValue.storeCertificate(inKeychain: _certificate) else {
        // The keychain refused the write and put back what was there; say so instead of popping back
        // as if the certificate had been saved.
        return _showError(message: MoshPubKeyError.keychainWriteFailed.localizedDescription)
      }
      
      MoshPubKey.saveIDS()
      _nav.navController.popViewController(animated: true)
      self.reloadCards()
    } catch {
      _showError(message: error.localizedDescription)
    }
  }
  
  var body: some View {
    List {
      Section(
        header: Text("NAME"),
        footer: Text("Default key must be named `id_\(card.keyType?.lowercased().replacingOccurrences(of: "-", with: "_") ?? "")`")
      ) {
        FixedTextField(
          "Enter a name for the key",
          text: $_keyName,
          id: "keyName",
          nextId: "keyComment",
          autocorrectionType: .no,
          autocapitalizationType: .none
        )
      }
      
      Section(header: Text("Public Key")) {
        HStack {
          Text(card.publicKey).lineLimit(_pubkeyLines)
        }.onTapGesture {
          _pubkeyLines = _pubkeyLines == 1 ? 100 : 1
        }
        
        Button(action: _copyPublicKey, label: {
          HStack {
            Label("Copy", systemImage: "doc.on.doc")
            Spacer()
            Text("Copied").opacity(_publicKeyCopied ? 1.0 : 0.0)
          }
        })
        GeometryReader(content: { geometry in
          let frame = geometry.frame(in: .global)
          Button(action: { _sharePublicKey(frame: frame) }, label: {
            Label("Share", systemImage: "square.and.arrow.up")
          }).frame(width: frame.width, height: frame.height, alignment: .leading)
        })
      }
     
      if card.storageType == MoshPubKeyStorageTypeKeyChain {
        if let certificate = _certificate {
          Section(header: Text("Certificate")) {
            HStack {
              Text(certificate).lineLimit(_certificateLines)
            }.onTapGesture {
              _certificateLines = _certificateLines == 1 ? 100 : 1
            }
            Button(action: _copyCertificate, label: {
              HStack {
                Label("Copy", systemImage: "doc.on.doc")
                Spacer()
                Text("Copied").opacity(_certificateCopied ? 1.0 : 0.0)
              }
            })
            Button(action: _removeCertificate, label: {
              Label("Remove", systemImage: "minus.circle")
            }).tint(.moshTint)
          }
        } else if _hasPrivateKey {
          Section() {
            Button(
              action: { _actionSheetIsPresented = true },
              label: {
                Label("Add Certificate", systemImage: "plus.circle")
              }
            )
            .actionSheet(isPresented: $_actionSheetIsPresented) {
                ActionSheet(
                  title: Text("Add Certificate"),
                  buttons: [
                    .default(Text("Import from clipboard")) { _importCertificateFromClipboard() },
                    .default(Text("Import from a file")) {
                      _fileImportMode = .certificate
                      _filePickerIsPresented = true
                    },
                    .cancel()
                  ]
                )
            }
          }
        }
        
        if _hasPrivateKey {
          Section {
            Button(action: _copyPrivateKey, label: {
              HStack {
                Label("Copy private key", systemImage: "doc.on.doc")
                Spacer()
                Text("Copied").opacity(_privateKeyCopied ? 1.0 : 0.0)
              }
            })
            GeometryReader(content: { geometry in
              let frame = geometry.frame(in: .global)
              Button(action: { _exportPrivateKey(frame: frame) }, label: {
                Label("Export private key", systemImage: "square.and.arrow.up")
              }).frame(width: frame.width, height: frame.height, alignment: .leading)
            })
          } header: {
            Text("Private Key")
          } footer: {
            Text(_privateKeyRestored
                 ? "Private key restored on this device."
                 : "Both ask for Face ID first. Export writes an OpenSSH key file you can AirDrop or save — it is the private key itself, so treat it like one.")
              .foregroundColor(_privateKeyRestored ? Color.green : nil)
          }
        } else {
          Section {
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
              Text("The private half of this identity isn't on this device, so it can't sign in anywhere yet.")
            }
            Button(action: _restorePrivateKeyFromClipboard, label: {
              Label("Paste private key", systemImage: "doc.on.clipboard")
            })
            Button(action: {
              _fileImportMode = .privateKey
              _filePickerIsPresented = true
            }, label: {
              Label("Add from a file", systemImage: "folder")
            })
          } header: {
            Text("Private Key")
          } footer: {
            Text("Copy or export it from the device that has it. Moshroom checks the key really is this identity before storing it, and the identity itself is left alone — nothing is deleted and nothing is re-synced.\n\n" + Moshsync.incompleteKeysHint)
          }
        }
      }
      
      Section() {
        Button(
          action: _confirmDelete,
          label: { Label("Delete", systemImage: "trash").foregroundColor(.moshTint)}
        )
          .tint(.moshTint)
      }
    }
    .listStyle(.insetGrouped)
    .moshReadableWidth()
    .moshHubChromeBack(title: "Key Info") {
      Button(action: _saveCard) { MoshNavLabel(title: "Save") }
        .disabled(_saveIsDisabled)
    }
    .fileImporter(
      isPresented: $_filePickerIsPresented,
      allowedContentTypes: [.text, .data, .item],
      onCompletion: _importFromFile
    )
    .onAppear(perform: {
      _keyName = card.id
      _certificate = card.loadCertificate()
      _originalCertificate = _certificate
      _hasPrivateKey = card.hasPrivateKeyMaterial()
    })
    .alert("Passphrase", isPresented: $_passphrasePromptIsPresented) {
      SecureField("Passphrase", text: $_passphrase)
      Button("Unlock") {
        if let blob = _pendingPrivateKeyBlob {
          _restorePrivateKey(from: blob, passphrase: _passphrase)
        }
      }
      Button("Cancel", role: .cancel) {
        _pendingPrivateKeyBlob = nil
        _passphrase = ""
      }
    } message: {
      Text("This private key is protected with a passphrase.")
    }
    .moshDeleteConfirmation($_pendingDelete)
    .alert(errorMessage: $_errorMessage)
  }
}
