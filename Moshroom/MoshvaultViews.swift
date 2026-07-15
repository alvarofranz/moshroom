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

// Moshvault UI — the credentials hub. Two tabs: Passwords (a KeePass-style vault) and 2FA (a TOTP
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

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Picker("Section", selection: $section) {
          Text("Passwords").tag(Section.passwords)
          Text("2FA").tag(Section.twofa)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)

        Divider()

        switch section {
        case .passwords: MoshvaultPasswordsView()
        case .twofa:     MoshvaultTOTPView()
        }
      }
      .frame(maxWidth: .infinity)
      .navigationTitle("Moshvault")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        MoshNavBarItem(placement: .navigationBarTrailing) {
          Button(action: onClose) {
            MoshNavGlyph(systemName: "xmark")
          }
          .accessibilityLabel("Close")
        }
      }
    }
    .tint(.moshTint)
  }
}

// MARK: - Shared bits

// A clean search field that lives right under the tabs (not buried in the nav-bar drawer).
// Same look on both tabs — rounded dark fill, glyph, live clear button.
private struct MoshSearchField: View {
  @Binding var text: String
  var prompt: String
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundColor(.secondary)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .submitLabel(.search)
        .focused($focused)
      if !text.isEmpty {
        Button { text = "" } label: {
          Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .transition(.opacity)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(.tertiarySystemFill)))
    // Match the inset-grouped list's own horizontal section margin so the field lines up
    // edge-for-edge with the card below it.
    .padding(.horizontal, 20)
    .padding(.top, 8)
    .animation(.easeInOut(duration: 0.15), value: text.isEmpty)
  }
}

extension View {
  // Shrink an inset-grouped list's default top inset so a search field placed directly above it
  // reads as attached to the card. contentMargins is iOS 17+; on 16 the default spacing stands.
  @ViewBuilder func moshListTopInset(_ v: CGFloat) -> some View {
    if #available(iOS 17.0, *) {
      self.contentMargins(.top, v, for: .scrollContent)
    } else {
      self
    }
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

// A tappable "Copied" flash used across both tabs.
private struct CopyChip: View {
  let text: String
  let value: String
  var mono: Bool = false
  @State private var copied = false
  var body: some View {
    Button {
      UIPasteboard.general.string = value
      withAnimation { copied = true }
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = false } }
    } label: {
      HStack(spacing: 6) {
        Text(copied ? "Copied" : text)
          .font(mono ? .system(.body, design: .monospaced) : .body)
          .foregroundColor(copied ? .moshTint : .primary)
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .font(.footnote)
          .foregroundColor(.secondary)
      }
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Passwords

struct MoshvaultPasswordsView: View {
  @State private var entries: [MoshVaultEntry] = []
  @State private var editing: MoshVaultEntry?
  @State private var query = ""

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
        VStack(spacing: 0) {
          MoshSearchField(text: $query, prompt: "Search passwords")
          List {
            ForEach(filtered) { entry in
              Button { editing = entry } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Text(entry.service.isEmpty ? "Untitled" : entry.service)
                    .foregroundColor(.primary)
                  if !entry.subtitle.isEmpty {
                    Text(entry.subtitle).font(.footnote).foregroundColor(.secondary)
                  }
                }
              }
              // Right-click (Mac) / long-press (iOS) — the Mac has no swipe, so edit & delete live here too.
              .contextMenu {
                Button { editing = entry } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { deleteEntries([entry]) } label: { Label("Delete", systemImage: "trash") }
              }
            }
            .onDelete { deleteEntries($0.map { filtered[$0] }) }
          }
          .listStyle(.insetGrouped)
          .moshListTopInset(2)   // trim the list's default top inset so the card sits under the search field
          .overlay { if filtered.isEmpty { MoshNoMatches() } }
        }
        .moshReadableWidth()
      }
    }
    .toolbar {
      MoshNavBarItem(placement: .navigationBarLeading) {
        Button { editing = MoshVaultEntry() } label: { MoshNavGlyph(systemName: "plus") }
          .accessibilityLabel("Add password")
      }
    }
    .onAppear(perform: reload)
    .sheet(item: $editing, onDismiss: reload) { entry in
      MoshvaultPasswordEditor(entry: entry)
    }
  }

  private func reload() { entries = MoshVaultStore.shared.all() }

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

  // Derive "new vs edit" from the store, not a passed-in flag — the flag raced with the sheet
  // presentation and showed "Edit Password" on a brand-new entry.
  private var isNew: Bool { !MoshVaultStore.shared.all().contains { $0.id == entry.id } }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          labeledField("Service", text: $entry.service)
          labeledField("Username", text: $entry.username)
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
            if !entry.password.isEmpty {
              CopyChip(text: "", value: entry.password)
            }
          }
        }
        Section {
          labeledField("URL", text: $entry.url, keyboard: .URL)
        }
        Section("Notes") {
          TextEditor(text: $entry.notes).frame(minHeight: 90)
        }
      }
      .navigationTitle(isNew ? "New Password" : "Edit Password")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        MoshNavBarItem(placement: .cancellationAction) {
          Button { dismiss() } label: { MoshNavGlyph(systemName: "xmark") }
            .accessibilityLabel("Cancel")
        }
        MoshNavBarItem(placement: .confirmationAction) {
          Button { MoshVaultStore.shared.save(entry); dismiss() } label: { MoshNavLabel(title: "Save") }
            .disabled(entry.isEmpty)
        }
      }
      .tint(.moshTint)
    }
  }

  private func labeledField(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
    HStack {
      Text(title).foregroundColor(.secondary).frame(width: 92, alignment: .leading)
      TextField(title, text: text)
        .keyboardType(keyboard)
        .autocorrectionDisabled()
        .textInputAutocapitalization(keyboard == .default ? .sentences : .never)
    }
  }
}

// MARK: - 2FA

struct MoshvaultTOTPView: View {
  @State private var accounts: [MoshTOTPAccount] = []
  @State private var editing: MoshTOTPAccount?
  @State private var showingManual = false
  @State private var showingScan = false
  @State private var showingMigrate = false
  @State private var banner: String?
  @State private var query = ""
  @State private var copiedID: String?
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
        VStack(spacing: 0) {
          MoshSearchField(text: $query, prompt: "Search codes")
          List {
            if let banner {
              Text(banner).font(.footnote).foregroundColor(.secondary)
            }
            ForEach(filtered) { account in
              MoshTOTPRow(account: account, now: now, copied: copiedID == account.id)
                .contentShape(Rectangle())
                .onTapGesture { copyCode(account) }
                .swipeActions(edge: .trailing) {
                  Button(role: .destructive) { delete(account) } label: { Label("Delete", systemImage: "trash") }
                  Button { editing = account } label: { Label("Edit", systemImage: "pencil") }.tint(.gray)
                }
                // Mac has no swipe — right-click gives the same edit & delete.
                .contextMenu {
                  Button { editing = account } label: { Label("Edit", systemImage: "pencil") }
                  Button { copyCode(account) } label: { Label("Copy code", systemImage: "doc.on.doc") }
                  Button(role: .destructive) { delete(account) } label: { Label("Delete", systemImage: "trash") }
                }
            }
          }
          .listStyle(.insetGrouped)
          .moshListTopInset(2)   // trim the list's default top inset so the card sits under the search field
          .overlay { if filtered.isEmpty { MoshNoMatches() } }
        }
        .moshReadableWidth()
      }
    }
    .toolbar {
      MoshNavBarItem(placement: .navigationBarLeading) {
        // The chip is OUR view and the Menu rides on top with a clear label — a visible Menu
        // label gets re-rendered washed-out/off-centre by the Mac Catalyst toolbar (see KeySortView).
        MoshNavGlyph(systemName: "plus")
          .overlay(
            Menu {
              Button { showingScan = true } label: { Label("Scan QR Code", systemImage: "qrcode.viewfinder") }
              Button { showingMigrate = true } label: { Label("Migrate from Google Authenticator", systemImage: "square.and.arrow.down.on.square") }
              Button { showingManual = true } label: { Label("Enter Setup Key", systemImage: "keyboard") }
            } label: {
              Color.clear
                .frame(width: MoshNavChip.diameter, height: MoshNavChip.diameter)
                .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)   // no system disclosure caret bleeding through the + glyph
          )
          .accessibilityLabel("Add 2FA account")
      }
    }
    .onReceive(tick) { now = $0 }
    .onAppear(perform: reload)
    .sheet(isPresented: $showingManual, onDismiss: reload) { MoshTOTPManualEntry() }
    .sheet(item: $editing, onDismiss: reload) { MoshTOTPManualEntry(existing: $0) }
    .sheet(isPresented: $showingScan, onDismiss: reload) {
      MoshTOTPScanSheet { uri in
        guard let acc = MoshTOTP.parse(uri: uri) else { return false }
        MoshTOTPStore.shared.save(acc)
        return true
      }
    }
    .sheet(isPresented: $showingMigrate, onDismiss: reload) {
      MoshTOTPMigrateSheet { added, skipped in
        banner = "Imported \(added) account\(added == 1 ? "" : "s")"
          + (skipped > 0 ? " · \(skipped) HOTP skipped" : "")
      }
    }
  }

  private func reload() { accounts = MoshTOTPStore.shared.all() }

  private func copyCode(_ account: MoshTOTPAccount) {
    UIPasteboard.general.string = MoshTOTP.code(for: account)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    // A green check appears left of the code for 2s — no banner, nothing shifts.
    withAnimation { copiedID = account.id }
    let id = account.id
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      if copiedID == id { withAnimation { copiedID = nil } }
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
        if !account.subtitle.isEmpty {
          Text(account.subtitle).font(.footnote).foregroundColor(.secondary)
        }
      }
      Spacer()
      HStack(spacing: 10) {
        if copied {
          Image(systemName: "checkmark.circle.fill")
            .font(.title2)
            .foregroundColor(.moshGreen)
            .transition(.opacity.combined(with: .scale))
        }
        Text(grouped(code))
          .font(.system(size: 32, weight: .semibold, design: .monospaced))
          .foregroundColor(expiring ? .red : .moshGreen)
          .monospacedDigit()
          .minimumScaleFactor(0.7)
          .lineLimit(1)
          .opacity(dim ? 0.4 : 1)
          .animation(.easeInOut(duration: 0.4), value: dim)
      }
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
  private let isNew: Bool

  init(existing: MoshTOTPAccount? = nil) {
    _account = State(initialValue: existing ?? MoshTOTPAccount())
    isNew = existing == nil
  }

  var body: some View {
    NavigationStack {
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
      .navigationTitle(isNew ? "New 2FA Account" : "Edit 2FA Account")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        MoshNavBarItem(placement: .cancellationAction) {
          Button { dismiss() } label: { MoshNavGlyph(systemName: "xmark") }
            .accessibilityLabel("Cancel")
        }
        MoshNavBarItem(placement: .confirmationAction) {
          Button { MoshTOTPStore.shared.save(account); dismiss() } label: { MoshNavLabel(title: "Save") }
            .disabled(!MoshTOTP.isValidSecret(account.secret))
        }
      }
      .tint(.moshTint)
    }
  }

  private func field(_ title: String, text: Binding<String>) -> some View {
    HStack {
      Text(title).foregroundColor(.secondary).frame(width: 80, alignment: .leading)
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
    NavigationStack {
      ZStack {
        MoshQRScannerView(
          onFound: { payload in if onScan(payload) { dismiss() } },
          onError: { error = $0 }
        )
        .ignoresSafeArea(edges: .bottom)
        VStack {
          Spacer()
          Text(error ?? "Point the camera at a 2FA QR code")
            .font(.callout).foregroundColor(.white)
            .padding(12).background(.black.opacity(0.55)).clipShape(Capsule())
            .padding(.bottom, 28)
        }
      }
      .navigationTitle("Scan QR Code")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        MoshNavBarItem(placement: .cancellationAction) {
          Button { dismiss() } label: { MoshNavGlyph(systemName: "xmark") }
            .accessibilityLabel("Cancel")
        }
      }
    }
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

  var body: some View {
    NavigationStack {
      ZStack {
        MoshQRScannerView(onFound: handle, onError: { error = $0 })
          .ignoresSafeArea(edges: .bottom)
        VStack {
          Spacer()
          Text(error ?? status)
            .font(.callout).foregroundColor(.white).multilineTextAlignment(.center)
            .padding(12).background(.black.opacity(0.55)).clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
      }
      .navigationTitle("Migrate 2FA")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        MoshNavBarItem(placement: .cancellationAction) {
          Button { dismiss() } label: { MoshNavGlyph(systemName: "xmark") }
            .accessibilityLabel("Cancel")
        }
        MoshNavBarItem(placement: .confirmationAction) {
          Button { finish() } label: { MoshNavLabel(title: "Import") }
            .disabled(collected.isEmpty)
        }
      }
    }
  }

  private func handle(_ payload: String) {
    guard let result = MoshOTPMigration.parse(uri: payload) else {
      error = "That isn't a Google Authenticator export code."
      return
    }
    error = nil
    batchSize = result.batchSize
    collected[result.batchIndex] = result.accounts
    skipped = max(skipped, result.skippedHOTP)
    if collected.count >= batchSize {
      finish()
    } else {
      status = "Scanned \(collected.count) of \(batchSize) — scan the next QR code"
    }
  }

  private func finish() {
    let all = collected.values.flatMap { $0 }
    let added = MoshTOTPStore.shared.importAccounts(all)
    onDone(added, skipped)
    dismiss()
  }
}
