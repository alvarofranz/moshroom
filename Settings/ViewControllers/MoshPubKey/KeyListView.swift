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

//MARK: - Key Card Model
fileprivate struct KeyCard {
  let key: MoshPubKey
  let name: String
  let keyType: String?
  let certType: String?
  let isAccessible: Bool

  init(key: MoshPubKey) {
    self.key = key
    self.name = key.id
    self.keyType = key.keyType
    self.certType = key.certType
    self.isAccessible = MoshPubKey.all().signerWithID(name) != nil ? true : false
  }
}


/// What a freshly created key is commented with: this device's name. (It used to glue a global
/// "default user" in front of it — that setting is gone, because a user belongs to a host, not to
/// every key this device makes.)
enum MoshKeyDefaults {
  static var comment: String {
    UIDevice.getInfoType(fromDeviceName: MoshDeviceInfoTypeDeviceName) ?? "moshroom"
  }
}

//MARK: - Key Row View
struct KeyRow: View {
  fileprivate let card: KeyCard
  let reloadCards: () -> ()

  var body: some View {
    Row(
      content: {
        HStack {
          VStack(alignment: .leading) {
            Text(card.name)
            Text([card.keyType, card.certType].compactMap({$0}).joined(separator: " + ")).font(.footnote)
              .foregroundColor(.secondary)
          }
          Spacer()
          if card.isAccessible {
            Text(card.key.storageType.shortName())
              .font(.system(.subheadline))
          } else {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundColor(.orange)
          }
        }
      },
      details: {
        KeyDetailsView(card: card.key, reloadCards: reloadCards)
      }
    )
  }
}


//MARK: - Main Key Sort View
struct KeySortView: View {
  @Binding fileprivate var sortType: KeysObservable.KeySortType

  var body: some View {
    // The chip is OUR view and the Menu rides on top with a clear label: the Mac Catalyst
    // toolbar re-renders a Menu's label with its own template colour and metrics (washed-out,
    // off-centre glyph), so nothing visible may live inside the label — the system can restyle
    // a transparent square all it wants.
    MoshNavGlyph(systemName: "list.bullet")
      .overlay(
        Menu {
          Section(header: Text("Order")) {
            SortButton(label: "Name",    sortType: $sortType, asc: .nameAsc, desc: .nameDesc)
            SortButton(label: "Type",    sortType: $sortType, asc: .typeAsc, desc: .typeDesc)
            SortButton(label: "Storage", sortType: $sortType, asc: .storageAsc, desc: .storageDesc)
          }
        } label: {
          Color.clear
            .frame(width: MoshNavChip.diameter, height: MoshNavChip.diameter)
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)   // no system disclosure caret over the house chip
      )
  }
}


//MARK: - Main New Key View
struct NewKeyMenuContentView: View {

  @Binding var isMenuPresented: Bool

  @ObservedObject fileprivate var _state: KeysObservable

  var body: some View {
    NavigationView {
      Form {
        plainTextKeySection
        secureEnclaveKeySection
        passkeySection
      }
      .onAppear {
        UITableView.appearance().sectionFooterHeight = 0
      }
      .navigationTitle("New Key")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        MoshNavBarItem(placement: .navigationBarTrailing) {
          Button {
            dismissView()
          } label: {
            MoshNavGlyph(systemName: "xmark")
          }
        }
      }
    }
    //.alert(errorMessage: $state.errorMessage)
  }
}


//MARK: - New Key View properties
private extension NewKeyMenuContentView {
  var plainTextKeySection: some View {
    Section {
      HStack {
        VStack {
          baseCellIcon(systemName: "key.horizontal.fill")
          Spacer()
        }
        .padding([.top], 10)
        .padding([.trailing], 8)

        VStack(alignment: .leading) {
          baseCellTitle("Plain-text Key")
          baseCellSubtitle("Create RSA, ECDSA and ED25519 keys, stored in your iCloud Keychain — end-to-end encrypted, they survive reinstalls and follow your devices.")

          actionsDivider()
          actionButtonTitle(title: "Generate New", tintColor: .moshroomTint)
            .onTapGesture {
              dismissView()
              self._state.modal = .newKey
            }
          actionsDivider()
          actionButtonTitle(title: "Import from File", tintColor: .label)
            .onTapGesture {
              dismissView()
              self._state.filePickerIsPresented = true
            }
          actionsDivider()
          actionButtonTitle(title: "Import from Clipboard", tintColor: .label)
            .onTapGesture {
              dismissView()
              self._state.importFromClipboard()
            }
        }

        .padding([.top], 4)
      }
    }
  }
  var secureEnclaveKeySection: some View {
    Section {
      HStack {
        VStack {
          baseCellIcon(systemName: "cpu.fill")
          Spacer()
        }
        .padding([.top], 10)
        .padding([.trailing], 8)

        VStack(alignment: .leading) {
          baseCellTitle("Secure Enclave Key")
          baseCellSubtitle("Isolated in this device's hardware — the private key can never be exported, synced, or leave the device.")

          actionsDivider()
          actionButtonTitle(title: "Generate New", tintColor: .moshroomTint)
            .onTapGesture {
              dismissView()
              self._state.modal = .newSEKey
            }
        }
        .padding([.top], 4)
      }
    }
  }
  var passkeySection: some View {
    Section {
      HStack {
        VStack {
          baseCellIcon(systemName: "person.badge.key.fill")
          Spacer()
        }
        .padding([.top], 10)
        .padding([.trailing], 8)

        VStack(alignment: .leading) {
          baseCellTitle("Passkey")
          baseCellSubtitle("WebAuthn keys for SSH, kept by your passkey provider or on a hardware key. Limitations apply.")

          actionsDivider()
          actionButtonTitle(title: "Generate on device", tintColor: .moshroomTint)
            .onTapGesture {
              dismissView()
              self._state.modal = .newPasskey
            }
          actionsDivider()
          actionButtonTitle(title: "Generate on Hardware key", tintColor: .label)
            .onTapGesture {
              dismissView()
              self._state.modal = .newSecurityKey
            }
        }
        .padding([.top], 4)
      }
    }
  }


  //MARK: Fast methods
  func dismissView() {
    self.isMenuPresented = false
  }


  //MARK: Fast New Key properties
  func baseCellTitle(_ content: String) -> some View {
    Text(content)
      .font(.headline)
  }

  func baseCellSubtitle(_ content: String) -> some View {
    Text(content)
      .font(.subheadline)
      .foregroundStyle(Color.secondary)
  }

  func baseCellIcon(systemName: String) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10)
        .stroke(.secondary.opacity(0.3), lineWidth: 0.8)
        .frame(width: 42, height: 42)

      Image(systemName: systemName)
        .foregroundStyle(Color(.moshroomTint))
    }
    .frame(maxWidth: 42, maxHeight: 42)
  }

  func actionButtonTitle(title: String, tintColor: UIColor) -> some View {
    HStack {
      Text(title)
        .foregroundStyle(Color(tintColor))
        .font(.body)
      Spacer()
    }
      // .background(Color.gray.opacity(0.2))
      .frame(maxWidth: .infinity)
  }

  func actionsDivider() -> some View {
    Divider()
      .padding(.bottom, 1)
      .padding(.trailing, -20)
  }
}


//MARK: - Main Keys List View
struct KeyListView: View {
  @StateObject private var _state = KeysObservable()

  @Environment(\.presentationMode) var presentationMode
  @State private var isMenuPresented = false
  @State private var showAlert = false

  var body: some View {
    Group {
      if _state.list.isEmpty {
        MoshEmptyState(
          icon: "key",
          title: "Your identity keys",
          message: "Create or import SSH keys. Keychain-backed keys are end-to-end encrypted and follow your devices."
        ) {
          Button(action: toggleNewKeyView) { Label("Add Key", systemImage: "plus") }
        }
      } else {
        MoshSettingsList(
          footer: "Secure Enclave keys never leave this device. Keychain keys live in your iCloud Keychain — end-to-end encrypted, they survive reinstalls and follow your devices.",
          header: {
            if _state.list.contains(where: { !$0.isAccessible }) {
              HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text("The Private Key component of some identities is missing. The Public Key is still available so keys can be recycled at the server.")
              }
            }
          },
          rows: {
            ForEach(_state.list, id: \.name) {
              KeyRow(card: $0, reloadCards: _state.reloadCards)
            }.onDelete(perform: _state.deleteKeys)
          })
      }
    }
    .alert(isPresented: $showAlert) {
      Alert(
        title: Text("Error"),
        message: Text(_state.errorMessage ?? "Unknown error"),
        dismissButton: .default(Text("OK")) {
          _state.errorMessage = nil
        }
      )
    }
    .onAppear {
      if _state.list.isEmpty {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          toggleNewKeyView()
        }
      }
    }
    // A key list pulled from iCloud (Drive metadata + Keychain material) lands live while open.
    .onReceive(NotificationCenter.default.publisher(for: HostsCloudMirror.keysDidChangeNotification)) { _ in
      _state.reloadCards()
    }
    .listStyle(.insetGrouped)
    .moshReadableWidth()
    .moshHubChromeBack(title: "Keys") {
      if !_state.list.isEmpty {
        HStack(spacing: 8) {
          KeySortView(sortType: $_state.sortType)
          Button(action: { toggleNewKeyView() }) {
            MoshNavGlyph(systemName: "plus")
          }
        }
      }
    }
    .fileImporter(
      isPresented: $_state.filePickerIsPresented,
      allowedContentTypes: [.text, .data, .item],
      onCompletion: {
        _state.importFromFile(result: $0)
        if _state.errorMessage != nil { showAlert = true }
      }
    )
    .sheet(isPresented: $isMenuPresented,
           onDismiss: {
             if _state.errorMessage != nil { showAlert = true }
           }
    ) {
      NewKeyMenuContentView(isMenuPresented: $isMenuPresented, _state: _state)
    }
    .sheet(item: $_state.modal) { modal in
      NavigationView {
        switch (modal) {
        case .passphrasePrompt(let keyBlob, let proposedName):
          PassphraseView(
            keyBlob: keyBlob,
            keyProposedName: proposedName,
            onCancel: _state.onModalCancel,
            onSuccess: _state.onModalSuccess
          )
        case .saveImportedKey(let observable):
          ImportKeyView(
            state: observable,
            onCancel: _state.onModalCancel,
            onSuccess: _state.onModalSuccess
          )
        case .newKey:
          NewKeyView(
            onCancel: _state.onModalCancel,
            onSuccess: _state.onModalSuccess
          )
        case .newSEKey:
          NewSEKeyView(
            onCancel: _state.onModalCancel,
            onSuccess: _state.onModalSuccess
          )
        case .newPasskey:
          if #available(iOS 16.0, *) {
            NewPasskeyView(
              onCancel: _state.onModalCancel,
              onSuccess: _state.onModalSuccess
            )
          } else {
            EmptyView()
          }
        case .newSecurityKey:
          if #available(iOS 16.0, *) {
            NewSecurityKeyView(
              onCancel: _state.onModalCancel,
              onSuccess: _state.onModalSuccess
            )
          } else {
            EmptyView()
          }
        }
      }
    }
  }

  //MARK: Fast methods
  func toggleNewKeyView() {
    isMenuPresented.toggle()
  }
}


//MARK: - Main Keys Manager
fileprivate class KeysObservable: ObservableObject {
  enum KeySortType {
    case nameAsc, nameDesc, typeAsc, typeDesc, storageAsc, storageDesc

    var sortFn: (_ a: KeyCard, _ b: KeyCard) -> Bool {
      switch self {
      case .nameAsc:     return { a, b in a.name < b.name }
      case .nameDesc:    return { a, b in b.name < a.name }
      case .typeAsc:     return { a, b in a.keyType ?? "" < b.keyType ?? "" }
      case .typeDesc:    return { a, b in b.keyType ?? "" < a.keyType ?? "" }
      case .storageAsc:  return { a, b in a.key.storageType.rawValue < b.key.storageType.rawValue }
      case .storageDesc: return { a, b in b.key.storageType.rawValue < a.key.storageType.rawValue }
      }
    }
  }

  @Published var sortType: KeySortType = .nameAsc {
    didSet {
      list = list.sorted(by: sortType.sortFn)
    }
  }

  @Published var list: [KeyCard] = MoshPubKey.all().map(KeyCard.init(key:)).sorted(by: KeySortType.nameAsc.sortFn)
  @Published var actionSheetIsPresented: Bool = false
  @Published var filePickerIsPresented: Bool = false
  @Published var modal: KeyModals? = nil
  var addKeyObservable: ImportKeyObservable? = nil
  @Published var errorMessage: String? = nil
  var proposedKeyName = ""

  init() { }

  func reloadCards() {
    self.list = MoshPubKey.all().map(KeyCard.init(key:)).sorted(by: sortType.sortFn)
  }

  func removeKey(card: MoshPubKey) {
    MoshPubKey.removeCard(card: card)
    list.removeAll { k in
      k.key.tag == card.tag
    }
  }

  func deleteKeys(indexSet: IndexSet) {
    guard let index = indexSet.first else {
      return
    }

    let card = list[index]
    self.list.remove(atOffsets: indexSet)

    LocalAuth.shared.authenticate(callback: { success in
      if success {
        MoshPubKey.removeCard(card: card.key)
      } else {
        self.reloadCards()
      }
    }, reason: "to delete key.")
  }

  func importFromFile(result: Result<URL, Error>) {
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
      _importKeyFromBlob(blob: blob, proposedKeyName: url.lastPathComponent)
    } catch {
      _showError(message: error.localizedDescription)
    }
  }

  func importFromClipboard() {
    guard
      let string = UIPasteboard.general.string,
      !string.isEmpty
    else {
      return _showError(message: "Clipboard is empty");
    }

    guard
      let blob = SSHKey.sanitize(key: string).data(using: .utf8)
    else {
      return _showError(message: "Can't convert to data")
    }

    _importKeyFromBlob(blob: blob, proposedKeyName: "")
  }

  func onModalCancel() {
    self.modal = nil
  }

  func onModalSuccess() {
    self.modal = nil
    reloadCards()
  }

  private func _importKeyFromBlob(blob: Data, proposedKeyName: String) {
    do {
      let key = try SSHKey(fromFileBlob: blob, passphrase: "")
      modal = .saveImportedKey(ImportKeyObservable(key: key, keyName: proposedKeyName, keyComment: key.comment ?? ""))
    } catch SSHKeyError.wrongPassphrase {
      modal = .passphrasePrompt(keyBlob: blob, proposedKeyName: proposedKeyName)
    } catch {
      return _showError(message: "Could not import key - \(error.localizedDescription)")
    }
  }

  private func _showError(message: String) {
    errorMessage = message
  }
}

fileprivate enum KeyModals: Identifiable {
  case passphrasePrompt(keyBlob: Data, proposedKeyName: String)
  case saveImportedKey(ImportKeyObservable)
  case newKey
  case newSEKey
  case newPasskey
  case newSecurityKey

  var id: Int {
    switch self {
    case .passphrasePrompt: return 0
    case .saveImportedKey: return 1
    case .newKey: return 2
    case .newSEKey: return 3
    case .newPasskey: return 4
    case .newSecurityKey: return 5
    }
  }
}

extension View {
  func navigatePush(whenTrue toggle: Binding<Bool>) -> some View {
    NavigationLink(destination: self, isActive: toggle) { EmptyView() }
  }

  func navigatePush<H>(whenPresent toggle: Binding<H?>) -> some View {
    navigatePush(
      whenTrue: Binding(
        get: { toggle.wrappedValue != nil },
        set: {
          if !$0 {
            toggle.wrappedValue = nil
          }
        }
      )
    )
  }
}


extension MoshPubKeyStorageType {
  public func shortName() -> String {
    switch self {
    case MoshPubKeyStorageTypeKeyChain: return "Keychain"
    case MoshPubKeyStorageTypeSecureEnclave: return "SE"
    case MoshPubKeyStorageTypeiCloudKeyChain: return "iCloud Keychain"
    case MoshPubKeyStorageTypeSecurityKey: return "SK"
    case MoshPubKeyStorageTypePlatformKey: return "Passkey"
    default:
      return ""
    }
  }
}
