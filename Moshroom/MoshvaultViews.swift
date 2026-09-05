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

// Moshvault UI — the credentials hub. Two tabs: Passwords (a personal password vault) and 2FA (a TOTP
// authenticator). Both are backed by the iCloud Keychain via MoshVaultStore / MoshTOTPStore, so they
// sync end-to-end across the user's devices when "Sync with iCloud" is on. Clean, native SwiftUI —
// looks right on iPhone, iPad and Mac.

extension Color {
  // The ONE green in an otherwise all-mushroom-red app: a live, valid 2FA code reads green
  // (and the "copied" check uses the same green). A code only turns red — blinking — in its last
  // 5 seconds, as the one "about to regenerate" cue.
  static let moshGreen = Color(red: 0.22, green: 0.80, blue: 0.40)
}

// MARK: - Root

struct MoshvaultRootView: View {
  enum Section: Hashable { case passwords, twofa }

  let onClose: () -> Void
  @State private var section: Section = .passwords

  // Presentation state lives HERE, at the root, so the editor covers fill the whole vault. Moshvault
  // draws its own header in-content (no window toolbar): on Mac Catalyst a NavigationStack toolbar
  // renders in the window title bar, which a fullScreenCover does NOT cover — the editor would leave
  // the vault's +/✕ chrome showing above it and their taps would fight the modal. In-content header +
  // root-owned covers means the modal is truly full-screen and every chip is a plain, tappable Button.
  @State private var editingPassword: MoshVaultEntry?
  @State private var editingTOTP: MoshTOTPAccount?
  @State private var showingManualTOTP = false
  @State private var showingScan = false
  @State private var showingMigrate = false
  @State private var reloadTick = 0
  @State private var totpBanner: String?

  var body: some View {
    VStack(spacing: 0) {
      header
      Picker("Section", selection: $section) {
        Text("Passwords").tag(Section.passwords)
        Text("2FA").tag(Section.twofa)
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.bottom, 10)
      .frame(maxWidth: 520)

      Divider()

      switch section {
      case .passwords:
        MoshvaultPasswordsView(reloadTick: reloadTick, onEdit: { editingPassword = $0 })
      case .twofa:
        MoshvaultTOTPView(reloadTick: reloadTick, banner: totpBanner, onEdit: { editingTOTP = $0 })
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemGroupedBackground).ignoresSafeArea())
    .tint(.moshTint)
    .fullScreenCover(item: $editingPassword, onDismiss: bumpReload) { MoshvaultPasswordEditor(entry: $0) }
    .fullScreenCover(item: $editingTOTP, onDismiss: bumpReload) { MoshTOTPManualEntry(existing: $0) }
    .fullScreenCover(isPresented: $showingManualTOTP, onDismiss: bumpReload) { MoshTOTPManualEntry() }
    .fullScreenCover(isPresented: $showingScan, onDismiss: bumpReload) {
      MoshTOTPScanSheet { uri in
        guard let acc = MoshTOTP.parse(uri: uri) else { return false }
        // Only a stored account counts as scanned — otherwise the sheet closes on a code that went
        // nowhere, and the QR is usually gone by the time anyone notices.
        return MoshTOTPStore.shared.save(acc)
      }
    }
    .fullScreenCover(isPresented: $showingMigrate, onDismiss: bumpReload) {
      MoshTOTPMigrateSheet { added, skipped in
        totpBanner = "Imported \(added) account\(added == 1 ? "" : "s")"
          + (skipped > 0 ? " · \(skipped) HOTP skipped" : "")
      }
    }
  }

  private func bumpReload() { reloadTick += 1 }

  // The vault's own header: add (leading, per-tab) · "Moshvault" (centred) · close (trailing). All
  // plain in-content chips, so taps land reliably on Mac (see the note on the state above).
  private var header: some View {
    ZStack {
      Text("Moshvault")
        .font(.system(size: 17, weight: .semibold))
        .foregroundColor(.primary)
      HStack {
        if section == .passwords {
          Button { editingPassword = MoshVaultEntry() } label: { MoshNavGlyph(systemName: "plus") }
            .buttonStyle(.plain)
            .accessibilityLabel("Add password")
        } else {
          MoshNavGlyph(systemName: "plus")
            .overlay(
              Menu {
                Button { showingScan = true } label: { Label("Scan QR Code", systemImage: "qrcode.viewfinder") }
                Button { showingMigrate = true } label: { Label("Migrate from Google Authenticator", systemImage: "square.and.arrow.down.on.square") }
                Button { showingManualTOTP = true } label: { Label("Enter Setup Key", systemImage: "keyboard") }
              } label: {
                Color.clear.frame(width: MoshNavChip.diameter, height: MoshNavChip.diameter).contentShape(Rectangle())
              }
              .menuIndicator(.hidden)
            )
            .accessibilityLabel("Add 2FA account")
        }
        Spacer()
        Button(action: onClose) { MoshNavGlyph(systemName: "xmark") }
          .buttonStyle(.plain)
          .accessibilityLabel("Close")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}

// MARK: - Shared bits

// A rows list with a search field docked flush at the bottom — the two read as ONE rounded card:
// the rows fill the top (rounded top corners, SQUARE bottom), the search is pinned right underneath
// (SQUARE top, rounded bottom), so the search looks like an extension of the list rather than a
// separate floating bar. The search AUTOFOCUSES when the screen appears, so you can type to filter
// immediately. Shared by Moshvault (Passwords, 2FA) and Settings ▸ Hosts so all three match exactly.
//
// The one continuous shape comes from clipping the whole VStack to a single rounded rectangle: only
// the four OUTER corners round (list top + search bottom); the seam where they meet stays straight.
// A plain list (not insetGrouped) is used so the card is drawn once, by this container.
/// The search field itself: docked UNDER a list rather than hidden in a nav-bar drawer, so it never
/// covers the rows and never moves. One implementation for Moshvault's lists and the Settings hubs.
struct MoshDockedSearch: View {
  @Binding var query: String
  var prompt: String
  /// The vault's lists take the keyboard on appear (search-first screens); a Settings hub does not.
  var autofocus = false
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundColor(.secondary)
      TextField(prompt, text: $query)
        .textFieldStyle(.plain)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .submitLabel(.search)
        .focused($focused)
      if !query.isEmpty {
        Button { query = "" } label: {
          Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .transition(.opacity)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .onAppear { if autofocus { DispatchQueue.main.async { focused = true } } }
  }
}

/// The one list shell for a Settings hub screen (Keys, Hosts): inset-grouped rows in a single
/// section, an optional footer explaining the screen, and the same docked search once the list is
/// long enough to want one. The two screens used to be built differently for no reason other than
/// having been written months apart.
struct MoshSettingsList<Rows: View, Header: View>: View {
  var search: Binding<String>? = nil
  var searchPrompt = "Search"
  var showSearch = false
  var noMatches = false
  var footer: String? = nil
  @ViewBuilder var header: () -> Header
  @ViewBuilder var rows: () -> Rows

  var body: some View {
    VStack(spacing: 0) {
      List {
        Section {
          rows()
        } header: {
          header()
        } footer: {
          if let footer { Text(footer) }
        }
        .textCase(nil)
      }
      .listStyle(.insetGrouped)
      .overlay { if showSearch && noMatches { MoshNoMatches() } }

      if let search, showSearch {
        MoshDockedSearch(query: search, prompt: searchPrompt)
          .background(Color(.secondarySystemGroupedBackground))
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .padding(.horizontal, 16)
          .padding(.bottom, 10)
      }
    }
    .moshReadableWidth()
  }
}

extension MoshSettingsList where Header == EmptyView {
  init(search: Binding<String>? = nil, searchPrompt: String = "Search", showSearch: Bool = false,
       noMatches: Bool = false, footer: String? = nil, @ViewBuilder rows: @escaping () -> Rows) {
    self.init(search: search, searchPrompt: searchPrompt, showSearch: showSearch,
              noMatches: noMatches, footer: footer, header: { EmptyView() }, rows: rows)
  }
}

struct MoshSearchList<Rows: View>: View {
  @Binding var query: String
  var prompt: String
  var showSearch: Bool   // only worth a search bar past a threshold (see callers: count > 10)
  var noMatches: Bool
  @ViewBuilder var rows: () -> Rows

  var body: some View {
    VStack(spacing: 0) {
      // Rows sit on the SAME fill as the docked search (transparent rows + one card background), so
      // the list and the search read as one continuous surface — no black-rows-over-a-grey-box mismatch.
      List { rows().listRowBackground(Color.clear) }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)   // the card (below) draws the fill, not the list
        .overlay { if showSearch && noMatches { MoshNoMatches() } }

      if showSearch {
        Divider()   // the seam between the list and the docked search
        MoshDockedSearch(query: $query, prompt: prompt, autofocus: true)
      }
    }
    // One background for the whole thing — the rows, the empty space, and the docked search all share
    // it (the grouped background the surface already sits on), so there is no lighter "box" behind the
    // search or under a short list. Consistent, edge to edge.
    .background(Color(.systemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .padding(.horizontal, 16)
    .padding(.top, 4)
    .padding(.bottom, 12)
    .moshReadableWidth()
    .animation(.easeInOut(duration: 0.15), value: query.isEmpty)
    // (The docked search focuses itself on appear — see MoshDockedSearch.)
  }
}

// A sheet's own header row — a white-chip ✕ (leading), a centred title, and an optional trailing
// chip (Save / Import). Lives INSIDE the sheet content, NOT in a .toolbar: a formSheet's toolbar
// on Mac Catalyst does not deliver taps to custom chip buttons (the content does — verified live),
// so every Moshvault sheet drives close/confirm from here instead. Close/confirm are plain Buttons
// exactly like the in-form eye/copy chips that work.
struct MoshSheetHeader<Trailing: View>: View {
  let title: String
  let onClose: () -> Void
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    ZStack {
      Text(title)
        .font(.system(size: 17, weight: .semibold))
        .foregroundColor(.primary)
      HStack {
        Button(action: onClose) { MoshNavGlyph(systemName: "xmark") }
          .buttonStyle(.plain)
          .accessibilityLabel("Close")
        Spacer()
        trailing()
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}

extension MoshSheetHeader where Trailing == EmptyView {
  init(title: String, onClose: @escaping () -> Void) {
    self.init(title: title, onClose: onClose, trailing: { EmptyView() })
  }
}

// Shown when a search filters everything out.
private struct MoshNoMatches: View {
  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "magnifyingglass").font(.system(size: 34)).foregroundColor(.secondary)
      Text("No matches").font(.headline).foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// Put a vault secret on the clipboard with the least exposure that still lets the user paste it:
// keep it on THIS device only (no Universal Clipboard sync to their other Macs/iPhones) and let the
// OS auto-clear it after a short window, so a copied password/code doesn't linger for the next app
// that reads the pasteboard. Values never touch anything but the local clipboard.
enum MoshClipboard {
  /// How long a copied secret stays on the clipboard: a password long enough to paste it somewhere,
  /// a 2FA code barely past its own 30s life.
  static let passwordSeconds: TimeInterval = 90
  static let codeSeconds: TimeInterval = 30

  /// The one way the vault copies: clipboard + the success buzz that tells the user it landed.
  static func copyWithFeedback(_ value: String, clearAfter seconds: TimeInterval = passwordSeconds) {
    guard !value.isEmpty else { return }
    copy(value, clearAfter: seconds)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
  }

  static func copy(_ value: String, clearAfter seconds: TimeInterval = passwordSeconds) {
    guard !value.isEmpty else { return }
    UIPasteboard.general.setItems(
      [["public.utf8-plain-text": value]],
      options: [
        .localOnly: true,
        .expirationDate: Date(timeIntervalSinceNow: seconds),
      ]
    )
  }
}

// The one copy button in Moshvault: tap puts the value on the clipboard and the icon flips to a
// green tick in place, so nothing in the row shifts. Callers pick the icon and what an empty field
// looks like — omitted entirely (the row's trailing buttons) or dimmed in place (an editor field,
// where the chip belongs to the layout even when there is nothing to copy yet).
private struct MoshVaultCopyButton: View {
  let icon: String
  let value: String
  /// Named for VoiceOver: "Copy password".
  let field: String
  /// How long the clipboard keeps it (see MoshClipboard).
  var clearAfter: TimeInterval = MoshClipboard.passwordSeconds
  var hideWhenEmpty = false
  @State private var copied = false

  private var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    if trimmed.isEmpty && hideWhenEmpty {
      // Not defined on this entry: no button, no placeholder, no gap to explain.
      EmptyView()
    } else {
      Button {
        MoshClipboard.copyWithFeedback(trimmed, clearAfter: clearAfter)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { withAnimation { copied = false } }
      } label: {
        Image(systemName: copied ? "checkmark" : icon)
          .font(.system(size: 15))
          .foregroundColor(copied ? .moshGreen : (trimmed.isEmpty ? Color.secondary.opacity(0.35) : .secondary))
          // A fixed box so the tick swap cannot nudge the row, and a comfortable touch target.
          .frame(width: 30, height: 30)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .moshCatalystPlainButtons()
      .accessibilityLabel("Copy \(field)")
    }
  }
}

/// The trailing copy buttons of a password row: username, email, password, each present only when the
/// entry actually has that field. One tap puts it on the clipboard, so the common case (grab a
/// password, grab a login) never needs the editor.
private struct MoshVaultRowCopyButtons: View {
  let entry: MoshVaultEntry
  var body: some View {
    HStack(spacing: 2) {
      MoshVaultCopyButton(icon: "person", value: entry.username, field: "username", hideWhenEmpty: true)
      MoshVaultCopyButton(icon: "envelope", value: entry.email, field: "email", hideWhenEmpty: true)
      MoshVaultCopyButton(icon: "key", value: entry.password, field: "password", hideWhenEmpty: true)
    }
  }
}

// MARK: - Passwords

struct MoshvaultPasswordsView: View {
  let reloadTick: Int
  let onEdit: (MoshVaultEntry) -> Void
  @State private var entries: [MoshVaultEntry] = []
  @State private var query = ""
  @State private var pendingDelete: MoshDeletePrompt?

  private var filtered: [MoshVaultEntry] {
    guard !query.isEmpty else { return entries }
    let q = query.lowercased()
    return entries.filter {
      $0.service.lowercased().contains(q) || $0.username.lowercased().contains(q)
        || $0.email.lowercased().contains(q) || $0.url.lowercased().contains(q)
    }
  }

  var body: some View {
    Group {
      if entries.isEmpty {
        MoshEmptyState(
          icon: "lock.rectangle.stack",
          title: "Your password vault",
          message: "Keep your service logins here — service, username, email, password, notes and URL. Everything is stored in your iCloud Keychain, end-to-end encrypted, and follows your devices when iCloud sync is on."
        )
      } else {
        MoshSearchList(query: $query, prompt: "Search passwords", showSearch: entries.count > 10, noMatches: filtered.isEmpty) {
          ForEach(filtered) { entry in
            // Two tap targets in one row: the name opens the editor, the trailing icons copy a field
            // each. Both are plain buttons (a row-wide Button would swallow the icons' taps), and the
            // icons are centred against the whole row however tall the name wraps.
            HStack(spacing: 8) {
              Button { onEdit(entry) } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Text(entry.service.isEmpty ? "Untitled" : entry.service)
                    .foregroundColor(.primary)
                  if !entry.subtitle.isEmpty {
                    Text(entry.subtitle).font(.footnote).foregroundColor(.secondary)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .moshCatalystPlainButtons()

              MoshVaultRowCopyButtons(entry: entry)
            }
            // Right-click (Mac) / long-press (iOS) — the Mac has no swipe, so edit & delete live here too.
            .contextMenu {
              Button { onEdit(entry) } label: { Label("Edit", systemImage: "pencil") }
              Button(role: .destructive) { confirmDelete([entry]) } label: { Label("Delete", systemImage: "trash") }
            }
          }
          .onDelete { confirmDelete($0.map { filtered[$0] }) }
        }
      }
    }
    .onAppear(perform: reload)
    .onChange(of: reloadTick) { _ in reload() }
    .moshDeleteConfirmation($pendingDelete)
  }

  private func reload() { entries = MoshVaultStore.shared.all() }

  // A vault entry IS its keychain item — there is no copy of it anywhere else, and with sync on the
  // deletion travels to every device the moment it happens. A swipe alone was never enough for that.
  private func confirmDelete(_ targets: [MoshVaultEntry]) {
    guard !targets.isEmpty else { return }
    let name = targets.count == 1 ? (targets[0].service.isEmpty ? "Untitled" : targets[0].service) : ""
    pendingDelete = MoshDeletePrompt(
      name: name,
      what: targets.count == 1 ? "this password" : "\(targets.count) passwords"
    ) {
      deleteEntries(targets)
    }
  }

  private func deleteEntries(_ targets: [MoshVaultEntry]) {
    LocalAuth.shared.authenticate(callback: { ok in
      if ok { targets.forEach { MoshVaultStore.shared.delete($0) } }
      reload()
    }, reason: "to delete a password.")
  }
}

private struct MoshvaultPasswordEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State var entry: MoshVaultEntry
  @State private var revealPassword = false
  @State private var saveError = ""

  // A vault entry has no home outside the keychain, so a refused write is the whole edit — or, for a
  // new entry, the whole entry. The editor stays open and says so rather than closing on a save that
  // did not happen.
  private static let writeRefused =
    "The keychain refused to save this. Nothing was changed — unlock the device and try again." 

  // Derive "new vs edit" from the store, not a passed-in flag — the flag raced with the sheet
  // presentation and showed "Edit Password" on a brand-new entry.
  private var isNew: Bool { !MoshVaultStore.shared.all().contains { $0.id == entry.id } }

  var body: some View {
    VStack(spacing: 0) {
      MoshSheetHeader(title: isNew ? "New Password" : "Edit Password", onClose: { dismiss() }) {
        Button {
          if MoshVaultStore.shared.save(entry) { dismiss() } else { saveError = Self.writeRefused }
        } label: { MoshNavLabel(title: "Save") }
          .buttonStyle(.plain)
          .disabled(entry.isEmpty)
      }
      Form {
        Section {
          labeledField("Service", text: $entry.service)
          labeledField("User", text: $entry.username)
          labeledField("Email", text: $entry.email, keyboard: .emailAddress)
        }
        Section("Password") {
          HStack {
            if revealPassword {
              TextField("Password", text: $entry.password)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            } else {
              SecureField("Password", text: $entry.password)
            }
            Button {
              if revealPassword { revealPassword = false }
              else { LocalAuth.shared.authenticate(callback: { ok in if ok { revealPassword = true } }, reason: "to reveal the password.") }
            } label: {
              Image(systemName: revealPassword ? "eye.slash" : "eye").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            MoshVaultCopyButton(icon: "doc.on.doc", value: entry.password, field: "password")
          }
        }
        Section {
          labeledField("URL", text: $entry.url, keyboard: .URL)
        }
        Section("Notes") {
          TextEditor(text: $entry.notes).frame(minHeight: 90)
        }
      }
    }
    .background(Color(.systemGroupedBackground).ignoresSafeArea())
    .tint(.moshTint)
    .alert(errorMessage: $saveError)
  }

  // A labeled row: the field name on the left, the editable value, and a copy chip on the right
  // (green check in place on tap). Consistent with the password field and across every row.
  private func labeledField(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
    HStack {
      Text(title)
        .foregroundColor(.secondary)
        .frame(width: 92, alignment: .leading)
      TextField(title, text: text)
        .keyboardType(keyboard)
        .autocorrectionDisabled()
        .textInputAutocapitalization(keyboard == .default ? .sentences : .never)
      MoshVaultCopyButton(icon: "doc.on.doc", value: text.wrappedValue, field: title)
    }
  }
}

// MARK: - 2FA

struct MoshvaultTOTPView: View {
  let reloadTick: Int
  let banner: String?
  let onEdit: (MoshTOTPAccount) -> Void
  @State private var accounts: [MoshTOTPAccount] = []
  @State private var query = ""
  @State private var copiedID: String?
  @State private var pendingDelete: MoshDeletePrompt?
  private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
  @State private var now = Date()

  private var filtered: [MoshTOTPAccount] {
    guard !query.isEmpty else { return accounts }
    let q = query.lowercased()
    return accounts.filter {
      $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
    }
  }

  var body: some View {
    Group {
      if accounts.isEmpty {
        MoshEmptyState(
          icon: "lock.shield",
          title: "Your authentication codes",
          message: "Add your two-factor (2FA) codes here. Scan a QR code, migrate from Google Authenticator, or enter a setup key by hand. Codes are generated on-device and the accounts sync through your iCloud Keychain."
        )
      } else {
        MoshSearchList(query: $query, prompt: "Search codes", showSearch: accounts.count > 10, noMatches: filtered.isEmpty) {
          if let banner {
            Text(banner).font(.footnote).foregroundColor(.secondary)
          }
          ForEach(filtered) { account in
            MoshTOTPRow(account: account, now: now, copied: copiedID == account.id)
              .contentShape(Rectangle())
              .onTapGesture { copyCode(account) }
              .swipeActions(edge: .trailing) {
                Button(role: .destructive) { confirmDelete(account) } label: { Label("Delete", systemImage: "trash") }
                Button { onEdit(account) } label: { Label("Edit", systemImage: "pencil") }.tint(.gray)
              }
              // Mac has no swipe — right-click gives the same edit & delete.
              .contextMenu {
                Button { onEdit(account) } label: { Label("Edit", systemImage: "pencil") }
                Button { copyCode(account) } label: { Label("Copy code", systemImage: "doc.on.doc") }
                Button(role: .destructive) { confirmDelete(account) } label: { Label("Delete", systemImage: "trash") }
              }
          }
        }
      }
    }
    .onReceive(tick) { now = $0 }
    .onAppear(perform: reload)
    .onChange(of: reloadTick) { _ in reload() }
    .moshDeleteConfirmation($pendingDelete)
  }

  private func reload() { accounts = MoshTOTPStore.shared.all() }

  private func copyCode(_ account: MoshTOTPAccount) {
    // A code only lives ~30s; clear it from the clipboard fast so a stale one can't be pasted later.
    MoshClipboard.copyWithFeedback(MoshTOTP.code(for: account), clearAfter: MoshClipboard.codeSeconds)
    // A green check appears left of the code for 2s — no banner, nothing shifts.
    withAnimation { copiedID = account.id }
    let id = account.id
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      if copiedID == id { withAnimation { copiedID = nil } }
    }
  }

  // Losing a 2FA account can lock someone out of the service behind it, and the shared secret only
  // exists here. Ask, name it, and say that the delete travels.
  private func confirmDelete(_ account: MoshTOTPAccount) {
    pendingDelete = MoshDeletePrompt(
      name: account.title,
      what: "this 2FA account",
      extra: "You'd need to set it up again from the service to get codes back."
    ) {
      delete(account)
    }
  }

  private func delete(_ account: MoshTOTPAccount) {
    LocalAuth.shared.authenticate(callback: { ok in
      if ok { MoshTOTPStore.shared.delete(account) }
      reload()
    }, reason: "to delete a 2FA account.")
  }
}

private struct MoshTOTPRow: View {
  let account: MoshTOTPAccount
  let now: Date
  let copied: Bool
  // The code is drawn at its full size and never shrinks, so on a narrow (compact) iPhone a big
  // code steals width from the issuer/account column and squeezes it. Use a slightly smaller code
  // there so the left column — the labels the user actually reads — gets the room. Mac/iPad (regular)
  // keep the large 32pt code.
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    let code = MoshTOTP.code(for: account, at: now)
    let remaining = MoshTOTP.secondsRemaining(for: account, at: now)
    // Green while the code is live; red and blinking (once a second) only in the last 5 seconds,
    // as the single "about to regenerate" cue — no bar, no clock.
    let expiring = remaining <= 5
    let dim = expiring && Int(now.timeIntervalSince1970) % 2 == 0
    HStack(alignment: .center, spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text(account.title)
          .lineLimit(1)
          .truncationMode(.tail)
        if !account.subtitle.isEmpty {
          Text(account.subtitle).font(.footnote).foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      Spacer(minLength: 12)
      // Fixed-width slot for the "copied" check: it is ALWAYS reserved, so toggling it only swaps
      // the glyph in place — the code never moves and the title never reflows.
      ZStack {
        if copied {
          Image(systemName: "checkmark.circle.fill")
            .font(.title2)
            .foregroundColor(.moshGreen)
            .transition(.opacity.combined(with: .scale))
        }
      }
      .frame(width: 26)
      Text(grouped(code))
        .font(.system(size: sizeClass == .compact ? 26 : 32, weight: .semibold, design: .monospaced))
        .foregroundColor(expiring ? .red : .moshGreen)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()   // the code keeps its full size; a long title truncates instead of shrinking it
        .opacity(dim ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.4), value: dim)
    }
    .padding(.vertical, 10)
  }

  private func grouped(_ code: String) -> String {
    guard code.count == 6 || code.count == 8 else { return code }
    let mid = code.index(code.startIndex, offsetBy: code.count / 2)
    return code[..<mid] + " " + code[mid...]
  }
}

// Manual entry / edit of a single account.
private struct MoshTOTPManualEntry: View {
  @Environment(\.dismiss) private var dismiss
  @State private var account: MoshTOTPAccount
  @State private var saveError = ""
  private let isNew: Bool

  init(existing: MoshTOTPAccount? = nil) {
    _account = State(initialValue: existing ?? MoshTOTPAccount())
    isNew = existing == nil
  }

  var body: some View {
    VStack(spacing: 0) {
      MoshSheetHeader(title: isNew ? "New 2FA Account" : "Edit 2FA Account", onClose: { dismiss() }) {
        Button {
          if MoshTOTPStore.shared.save(account) {
            dismiss()
          } else {
            saveError = "The keychain refused to save this account. Nothing was changed — unlock the device and try again."
          }
        } label: { MoshNavLabel(title: "Save") }
          .buttonStyle(.plain)
          .disabled(!MoshTOTP.isValidSecret(account.secret))
      }
      Form {
        Section("Account") {
          field("Issuer", text: $account.issuer)
          field("Account", text: $account.account)
        }
        Section("Secret") {
          TextField("Base32 key", text: $account.secret)
            .autocorrectionDisabled().textInputAutocapitalization(.characters)
            .font(.system(.body, design: .monospaced))
          if !account.secret.isEmpty && !MoshTOTP.isValidSecret(account.secret) {
            Label("Not a valid Base32 key", systemImage: "exclamationmark.triangle")
              .font(.footnote).foregroundColor(.orange)
          }
        }
        Section("Advanced") {
          Picker("Algorithm", selection: $account.algorithm) {
            ForEach(MoshOTPAlgorithm.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }
          Stepper("Digits: \(account.digits)", value: $account.digits, in: 6...8)
          Stepper("Period: \(account.period)s", value: $account.period, in: 15...60, step: 15)
        }
      }
    }
    .background(Color(.systemGroupedBackground).ignoresSafeArea())
    .tint(.moshTint)
    .alert(errorMessage: $saveError)
  }

  private func field(_ title: String, text: Binding<String>) -> some View {
    HStack {
      Text(title).foregroundColor(.secondary).frame(width: 100, alignment: .leading)
      TextField(title, text: text).autocorrectionDisabled()
    }
  }
}

// Single-QR scan: keeps the camera up until a valid otpauth:// code is read.
private struct MoshTOTPScanSheet: View {
  @Environment(\.dismiss) private var dismiss
  let onScan: (String) -> Bool   // return true when accepted → dismiss
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      MoshSheetHeader(title: "Scan QR Code", onClose: { dismiss() })
      ZStack {
        MoshQRScannerView(
          onFound: { payload in if onScan(payload) { dismiss() } },
          onError: { error = $0 }
        )
        VStack {
          Spacer()
          Text(error ?? "Point the camera at a 2FA QR code")
            .font(.callout).foregroundColor(.white)
            .padding(12).background(.black.opacity(0.55)).clipShape(Capsule())
            .padding(.bottom, 28)
        }
      }
    }
    .background(Color.black.ignoresSafeArea())
  }
}

// Google Authenticator export: collects every batch QR, then imports the union.
private struct MoshTOTPMigrateSheet: View {
  @Environment(\.dismiss) private var dismiss
  let onDone: (_ added: Int, _ skipped: Int) -> Void

  @State private var collected: [Int: [MoshTOTPAccount]] = [:]   // batchIndex → accounts
  @State private var skipped = 0
  @State private var batchSize = 0
  @State private var status = "Point the camera at the Google Authenticator export QR"
  @State private var error: String?
  @State private var done = false   // once the batch is complete, ignore further scans + show the result

  var body: some View {
    VStack(spacing: 0) {
      MoshSheetHeader(title: "Migrate 2FA", onClose: { dismiss() }) {
        Button { complete() } label: { MoshNavLabel(title: "Import") }
          .buttonStyle(.plain)
          .disabled(collected.isEmpty || done)
      }
      ZStack {
        MoshQRScannerView(onFound: handle, onError: { error = $0 })
        VStack {
          Spacer()
          Text(error ?? status)
            .font(.callout).foregroundColor(.white).multilineTextAlignment(.center)
            .padding(12).background(.black.opacity(0.55)).clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
      }
    }
    .background(Color.black.ignoresSafeArea())
  }

  private func handle(_ payload: String) {
    guard !done else { return }
    guard let result = MoshOTPMigration.parse(uri: payload) else {
      error = "That isn't a Google Authenticator export code."
      return
    }
    error = nil
    // A batch can span several QR codes; ignore a re-scan of one we already have, but give a haptic
    // + a fresh "Scanned X of Y" the moment a NEW code lands — the last QR used to trigger the import
    // and close instantly, so it read as "nothing happened" (fixed 2026-07-18).
    let isNew = collected[result.batchIndex] == nil
    batchSize = result.batchSize
    collected[result.batchIndex] = result.accounts
    skipped = max(skipped, result.skippedHOTP)
    guard isNew else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    if collected.count >= batchSize {
      complete()
    } else {
      status = "Scanned \(collected.count) of \(batchSize) — scan the next QR code"
    }
  }

  // Import what's collected and confirm ON SCREEN before closing, so the final QR gets visible
  // feedback instead of an instant dismiss.
  private func complete() {
    guard !done else { return }
    done = true
    let all = collected.values.flatMap { $0 }
    let added = MoshTOTPStore.shared.importAccounts(all)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    status = "Imported \(added) account\(added == 1 ? "" : "s") ✓"
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
      onDone(added, skipped)
      dismiss()
    }
  }
}
