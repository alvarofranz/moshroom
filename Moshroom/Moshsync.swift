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

import Foundation
import Security
import SwiftUI
import UIKit
import MoshroomConfig

// Moshsync — the SECRETS half of "Sync with iCloud", and the guardrails around deleting them.
//
// HostsCloudMirror carries the METADATA (host configs, key records) over iCloud Drive. The secrets —
// SSH private keys, host passwords, vault passwords, 2FA accounts — never touch Drive: they ride the
// iCloud Keychain, end-to-end encrypted, as `kSecAttrSynchronizable` items. Two things were missing
// from that arrangement, and both live here.
//
// 1. THE FLAVOR MIGRATION. `kSecAttrSynchronizable` is fixed when an item is written and
//    `SecItemUpdate` cannot change it, so a secret written while the toggle was OFF stays
//    device-local FOREVER — turning sync on later did nothing for it, because the toggle only
//    governed the NEXT write. The metadata still travelled, so the other device showed a key it
//    could not use, and the only way out was to delete that key and import it again — which
//    tombstones the record and takes it off the first device too. The "fix" destroyed data.
//    `migrate()` re-writes those local-only items as synchronizable, so the switch means what it
//    says: everything you have follows you, not just what you touch from now on.
//
// 2. THE HEALTH READOUT. What the user can see about sync used to stop at the Drive files. `health()`
//    counts what is actually in the iCloud Keychain versus what is still device-only, and how many
//    identities are holding a public half with no private one — the exact symptom of the keychain
//    transport not delivering (usually iCloud Keychain switched off in the system settings, which no
//    API will tell us directly). Counts only: no secret is read to produce them.
//
// Deliberately NOT here: a downgrade pass for turning sync OFF. Making a synced item local again
// means DELETING the synced one, and the OS propagates that deletion to every other device — so a
// tidy-looking "unsync" on the Mac would wipe the iPhone's keys. Turning the switch off stops new
// writes from syncing and leaves what is already there alone; the Settings footer says exactly that.
enum Moshsync {

  // MARK: - The four services Moshroom keeps secrets in

  // All generic passwords in the data-protection keychain, namespaced under the build's KEYCHAIN_ID1
  // exactly like the stores that write them (MoshPubKey.m, MoshHosts.m, MoshvaultStore.swift).
  private struct Service { let suffix: String; let label: String }
  private static let services: [Service] = [
    Service(suffix: "pkcard", label: "keys"),
    Service(suffix: "pwd", label: "host passwords"),
    Service(suffix: "vault", label: "vault"),
    Service(suffix: "totp", label: "2FA"),
  ]

  private static var namespace: String { XCConfig.infoPlistKeyChainID1() }
  private static func serviceName(_ service: Service) -> String { "\(namespace).\(service.suffix)" }

  // Accessibility classes that mean "this device and no other". Nothing Moshroom writes uses one, but
  // if an item ever carries one it was chosen to keep that secret here, and it is not ours to overrule.
  private static let deviceBound: Set<String> = [
    kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
    kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String,
  ]

  // MARK: - Raw keychain access (one flavor at a time — never `Any`)

  private static func items(service: String, synchronizable: Bool, withData: Bool) -> [[String: Any]] {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: synchronizable,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnAttributes as String: true,
    ]
    if withData { q[kSecReturnData as String] = true }
    var result: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
          let items = result as? [[String: Any]] else { return [] }
    return items
  }

  private static func add(service: String, account: String, data: Data,
                          synchronizable: Bool, accessible: String) -> OSStatus {
    let attrs: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: synchronizable,
      kSecAttrAccessible as String: accessible,
      kSecValueData as String: data,
    ]
    return SecItemAdd(attrs as CFDictionary, nil)
  }

  // The flavor is part of the query on purpose: a delete that matched `kSecAttrSynchronizableAny`
  // here would take the synced copy the migration had just made.
  private static func delete(service: String, account: String, synchronizable: Bool) {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: synchronizable,
    ]
    SecItemDelete(q as CFDictionary)
  }

  // MARK: - The migration

  struct Report: Equatable {
    var moved = 0               // local-only secrets that now ride the iCloud Keychain
    var duplicatesRemoved = 0   // a local copy identical to the synced one: pure leftovers
    var divergent = 0           // same name, different value, both flavors — never guessed at
    var deviceBoundSkipped = 0
    var failed = 0

    var changedAnything: Bool { moved > 0 || duplicatesRemoved > 0 }
    var summary: String {
      "moved \(moved), duplicates \(duplicatesRemoved), divergent \(divergent), device-bound \(deviceBoundSkipped), failed \(failed)"
    }
  }

  /// Re-write every device-local secret as a synchronizable one. Idempotent, and a no-op the moment
  /// there is nothing local left (one keychain query per service and out).
  ///
  /// Order is add-then-delete, always: the local copy is only dropped once its synced twin is proven
  /// to exist. A refused add leaves everything exactly where it was.
  @discardableResult
  static func migrate() -> Report {
    var report = Report()
    guard MoshKeychainSync.enabled, !namespace.isEmpty else { return report }

    for service in services {
      let name = serviceName(service)
      let local = items(service: name, synchronizable: false, withData: true)
      guard !local.isEmpty else { continue }

      let synced = Dictionary(
        items(service: name, synchronizable: true, withData: true).compactMap { item -> (String, Data)? in
          guard let account = item[kSecAttrAccount as String] as? String,
                let data = item[kSecValueData as String] as? Data else { return nil }
          return (account, data)
        },
        uniquingKeysWith: { first, _ in first }
      )

      for item in local {
        guard let account = item[kSecAttrAccount as String] as? String,
              let data = item[kSecValueData as String] as? Data else { continue }
        let accessible = (item[kSecAttrAccessible as String] as? String)
          ?? (kSecAttrAccessibleAfterFirstUnlock as String)

        if deviceBound.contains(accessible) {
          report.deviceBoundSkipped += 1
          continue
        }

        if let existing = synced[account] {
          if existing == data {
            delete(service: name, account: account, synchronizable: false)
            report.duplicatesRemoved += 1
          } else {
            // Two different values under one name. Whichever we picked could be the one the user
            // wanted, so we pick neither: reads already match both flavors, and the next save of that
            // record collapses them. It is counted so the log can say it happened.
            report.divergent += 1
          }
          continue
        }

        let status = add(service: name, account: account, data: data,
                         synchronizable: true, accessible: accessible)
        if status == errSecSuccess {
          delete(service: name, account: account, synchronizable: false)
          report.moved += 1
        } else {
          report.failed += 1
        }
      }
    }

    if report.changedAnything || report.failed > 0 || report.divergent > 0 {
      MoshLog.log("sync", "keychain migration — \(report.summary)")
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: HostsCloudMirror.syncStateNotification, object: nil)
      }
    }
    return report
  }

  // MARK: - When to run it

  private static let queue = DispatchQueue(label: "moshroom.moshsync", qos: .utility)
  private static var ranThisLaunch = false
  private static var protectedDataObserver: NSObjectProtocol?

  /// Launch / foreground / "Sync Now" entry point. `force` is for the moments the user actually asked
  /// (flipping the switch on, pressing Sync Now); everything else runs once per launch.
  ///
  /// Nothing runs before the first unlock: the items are `AfterFirstUnlock`, so a keychain read that
  /// early answers "empty" and a migration built on that answer would migrate nothing and record it
  /// as done. It waits for the data to be available instead.
  static func migrateWhenPossible(force: Bool = false) {
    DispatchQueue.main.async {
      guard MoshKeychainSync.enabled else { return }
      guard force || !ranThisLaunch else { return }
      guard UIApplication.shared.isProtectedDataAvailable else { return armProtectedDataObserver() }
      ranThisLaunch = true
      queue.async { _ = migrate() }
    }
  }

  private static func armProtectedDataObserver() {
    guard protectedDataObserver == nil else { return }
    protectedDataObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification,
      object: nil, queue: .main
    ) { _ in
      if let observer = protectedDataObserver {
        NotificationCenter.default.removeObserver(observer)
        protectedDataObserver = nil
      }
      migrateWhenPossible()
    }
  }

  // MARK: - Health

  struct Health: Equatable {
    var inICloud = 0
    var onThisDevice = 0
    var incompleteKeys = 0

    var total: Int { inICloud + onThisDevice }
    var isEmpty: Bool { total == 0 }
    /// "14 in iCloud · 2 on this device" — the second half only when there is something to say.
    var label: String {
      onThisDevice == 0 ? "\(inICloud) in iCloud" : "\(inICloud) in iCloud · \(onThisDevice) local"
    }
  }

  /// Counts only — attributes, never values, so asking about the state of the vault never pulls the
  /// vault out of the keychain. A handful of small queries; the identities half reads the shared
  /// records list, so like everything else built on `MoshPubKey.all()` this belongs on the main thread.
  static func health() -> Health {
    var health = Health()
    guard !namespace.isEmpty else { return health }
    for service in services {
      let name = serviceName(service)
      health.inICloud += items(service: name, synchronizable: true, withData: false).count
      health.onThisDevice += items(service: name, synchronizable: false, withData: false).count
    }
    health.incompleteKeys = keysMissingPrivateMaterial().count
    return health
  }

  /// Identities whose record is here but whose private half is not — the repairable state. Secure
  /// Enclave and passkey identities are complete by definition and never appear. One keychain
  /// listing for all of them (MoshPubKey.identitiesMissingPrivateMaterial), main thread.
  static func keysMissingPrivateMaterial() -> [MoshPubKey] {
    MoshPubKey.identitiesMissingPrivateMaterial()
  }

  /// What to tell someone staring at a key that cannot sign. Written as one sentence because it goes
  /// in a footer, and it names the one setting that is almost always the cause.
  static let incompleteKeysHint =
    "Their public half arrived from iCloud but the private half hasn't. Check that iCloud Keychain " +
    "(Settings ▸ your name ▸ iCloud ▸ Passwords) is on for both devices, or open a key and add its " +
    "private half from the device that has it."
}

// MARK: - The one "are you sure" for anything that deletes a secret

/// Every destructive action in Moshroom now goes through this: a title naming the exact thing, a
/// message saying what is lost, and — when sync is on — the sentence nobody was being told, that a
/// deletion here is a deletion everywhere. Keys and hosts propagate through their tombstone, vault
/// entries and 2FA accounts through the iCloud Keychain itself; none of it is recoverable, and it
/// used to happen behind a swipe.
struct MoshDeletePrompt: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  let confirm: () -> Void

  init(title: String, message: String, confirm: @escaping () -> Void) {
    self.title = title
    self.message = message
    self.confirm = confirm
  }

  /// `what` completes "Deleting <what> can't be undone." — e.g. "this password", "the key “work”".
  init(name: String, what: String, extra: String = "", confirm: @escaping () -> Void) {
    let synced = MoshroomDefaults.isICloudSyncEnabled()
      ? " Sync is on, so it also disappears from your other devices."
      : ""
    self.init(
      title: name.isEmpty ? "Delete?" : "Delete \u{201C}\(name)\u{201D}?",
      message: "Deleting \(what) can't be undone." + (extra.isEmpty ? "" : " " + extra) + synced,
      confirm: confirm
    )
  }
}

extension View {
  /// Attach anywhere and set the binding to ask. The action runs only on Delete.
  func moshDeleteConfirmation(_ prompt: Binding<MoshDeletePrompt?>) -> some View {
    alert(
      prompt.wrappedValue?.title ?? "Delete?",
      isPresented: Binding(
        get: { prompt.wrappedValue != nil },
        set: { if !$0 { prompt.wrappedValue = nil } }
      ),
      presenting: prompt.wrappedValue
    ) { pending in
      Button("Delete", role: .destructive) { pending.confirm() }
      Button("Cancel", role: .cancel) { }
    } message: { pending in
      Text(pending.message)
    }
  }
}
