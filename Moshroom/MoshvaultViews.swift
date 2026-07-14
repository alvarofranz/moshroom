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

private extension Color {
  static let moshTint = Color(UIColor.moshroomTint)
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
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: onClose) {
            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
          }
          .accessibilityLabel("Close")
        }
      }
    }
    .tint(.moshTint)
  }
}

// MARK: - Shared bits

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

// Empty-state explainer shown when a tab has nothing yet.
private struct MoshvaultEmptyState: View {
  let icon: String
  let title: String
  let message: String
  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: icon)
        .font(.system(size: 44))
        .foregroundColor(.moshTint)
      Text(title).font(.title3.weight(.semibold))
      Text(message)
        .font(.callout)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(32)
    .frame(maxWidth: 420)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Passwords

struct MoshvaultPasswordsView: View {
  @State private var entries: [MoshVaultEntry] = []
  @State private var editing: MoshVaultEntry?
  @State private var isNew = false

  var body: some View {
    Group {
      if entries.isEmpty {
        MoshvaultEmptyState(
          icon: "lock.rectangle.stack",
          title: "Your password vault",
          message: "Keep your service logins here — service, username, email, password, notes and URL. Everything is stored in your iCloud Keychain, end-to-end encrypted, and follows your devices when iCloud sync is on."
        )
      } else {
        List {
          ForEach(entries) { entry in
            Button { isNew = false; editing = entry } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(entry.service.isEmpty ? "Untitled" : entry.service)
                  .foregroundColor(.primary)
                if !entry.subtitle.isEmpty {
                  Text(entry.subtitle).font(.footnote).foregroundColor(.secondary)
                }
              }
            }
          }
          .onDelete(perform: delete)
        }
        .listStyle(.insetGrouped)
      }
    }
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button { isNew = true; editing = MoshVaultEntry() } label: { Image(systemName: "plus") }
          .accessibilityLabel("Add password")
      }
    }
    .onAppear(perform: reload)
    .sheet(item: $editing, onDismiss: reload) { entry in
      MoshvaultPasswordEditor(entry: entry, isNew: isNew)
    }
  }

  private func reload() { entries = MoshVaultStore.shared.all() }

  private func delete(_ set: IndexSet) {
    let targets = set.map { entries[$0] }
    LocalAuth.shared.authenticate(callback: { ok in
      if ok { targets.forEach { MoshVaultStore.shared.delete($0) } }
      reload()
    }, reason: "to delete a password.")
  }
}

private struct MoshvaultPasswordEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State var entry: MoshVaultEntry
  let isNew: Bool
  @State private var revealPassword = false

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
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { MoshVaultStore.shared.save(entry); dismiss() }
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
  private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
  @State private var now = Date()

  var body: some View {
    Group {
      if accounts.isEmpty {
        MoshvaultEmptyState(
          icon: "lock.shield",
          title: "Your authentication codes",
          message: "Add your two-factor (2FA) codes here. Scan a QR code, migrate from Google Authenticator, or enter a setup key by hand. Codes are generated on-device and the accounts sync through your iCloud Keychain."
        )
      } else {
        List {
          if let banner {
            Text(banner).font(.footnote).foregroundColor(.secondary)
          }
          ForEach(accounts) { account in
            MoshTOTPRow(account: account, now: now)
              .contentShape(Rectangle())
              .onTapGesture { copyCode(account) }
              .swipeActions(edge: .trailing) {
                Button(role: .destructive) { delete(account) } label: { Label("Delete", systemImage: "trash") }
                Button { editing = account } label: { Label("Edit", systemImage: "pencil") }.tint(.gray)
              }
          }
        }
        .listStyle(.insetGrouped)
      }
    }
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Menu {
          Button { showingScan = true } label: { Label("Scan QR Code", systemImage: "qrcode.viewfinder") }
          Button { showingMigrate = true } label: { Label("Migrate from Google Authenticator", systemImage: "square.and.arrow.down.on.square") }
          Button { showingManual = true } label: { Label("Enter Setup Key", systemImage: "keyboard") }
        } label: { Image(systemName: "plus") }
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
    banner = "Copied \(account.title) code"
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if banner?.hasPrefix("Copied") == true { banner = nil } }
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

  var body: some View {
    let code = MoshTOTP.code(for: account, at: now)
    let remaining = MoshTOTP.secondsRemaining(for: account, at: now)
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text(account.title)
        if !account.subtitle.isEmpty {
          Text(account.subtitle).font(.footnote).foregroundColor(.secondary)
        }
        Text(grouped(code))
          .font(.system(.title3, design: .monospaced).weight(.semibold))
          .foregroundColor(.moshTint)
      }
      Spacer()
      ZStack {
        Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
        Circle()
          .trim(from: 0, to: CGFloat(remaining) / CGFloat(max(1, account.period)))
          .stroke(Color.moshTint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
          .rotationEffect(.degrees(-90))
        Text("\(remaining)").font(.caption2.monospacedDigit()).foregroundColor(.secondary)
      }
      .frame(width: 30, height: 30)
    }
    .padding(.vertical, 4)
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
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { MoshTOTPStore.shared.save(account); dismiss() }
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
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
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
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Import") { finish() }.disabled(collected.isEmpty)
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
