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
import MoshroomConfig

// Moshvault storage. The password vault and the 2FA accounts are Moshroom's own personal secrets
// store — nothing the connect path uses. Each record is ONE data-protection-keychain generic-password
// item (one per record), so the keychain IS both the source of truth AND the sync transport: when
// "Sync with iCloud" is on the items ride the iCloud Keychain (end-to-end encrypted, follows the
// user's devices); when off they stay local. There is no separate index file, so there is no
// metadata that could fall out of sync with the secrets — the whole record travels together.

// MARK: - The shared "Sync with iCloud" flag (mirrored by MoshroomDefaults into the app group)

enum MoshKeychainSync {
  // Kept in lockstep with kMoshroomICloudSyncEnabledKey in MoshHosts.m / MoshPubKey.m.
  static var enabled: Bool {
    UserDefaults(suiteName: XCConfig.infoPlistFullGroupID())?.bool(forKey: "MoshroomICloudSyncEnabled") ?? false
  }
}

// MARK: - Records

// A record kept as a single keychain item. `id` is the keychain account (a UUID string), stable for
// the life of the entry; `lastModified` drives the cross-device merge tie-break (same as hosts/keys).
protocol MoshVaultRecord: Codable, Identifiable {
  var id: String { get }
  var lastModified: Date { get set }
}

struct MoshVaultEntry: MoshVaultRecord, Equatable {
  var id: String
  var service: String
  var username: String
  var email: String
  var password: String
  var notes: String
  var url: String
  var lastModified: Date

  init(id: String = UUID().uuidString,
       service: String = "", username: String = "", email: String = "",
       password: String = "", notes: String = "", url: String = "",
       lastModified: Date = Date()) {
    self.id = id; self.service = service; self.username = username; self.email = email
    self.password = password; self.notes = notes; self.url = url; self.lastModified = lastModified
  }

  var isEmpty: Bool {
    [service, username, email, password, notes, url].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }
  // The one-line subtitle under the service name in the list.
  var subtitle: String {
    let s = username.isEmpty ? email : username
    return s.isEmpty ? url : s
  }
}

enum MoshOTPAlgorithm: String, Codable, CaseIterable {
  case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512"
}

struct MoshTOTPAccount: MoshVaultRecord, Equatable {
  var id: String
  var issuer: String          // e.g. "GitHub"
  var account: String         // e.g. "alvaro@example.com"
  var secret: String          // Base32, upper-cased, no spaces/padding
  var algorithm: MoshOTPAlgorithm
  var digits: Int
  var period: Int             // seconds
  var lastModified: Date

  init(id: String = UUID().uuidString,
       issuer: String = "", account: String = "", secret: String = "",
       algorithm: MoshOTPAlgorithm = .sha1, digits: Int = 6, period: Int = 30,
       lastModified: Date = Date()) {
    self.id = id; self.issuer = issuer; self.account = account; self.secret = secret
    self.algorithm = algorithm; self.digits = digits; self.period = period; self.lastModified = lastModified
  }

  // What to show as the primary title, then the secondary line.
  var title: String { issuer.isEmpty ? (account.isEmpty ? "Unnamed" : account) : issuer }
  var subtitle: String { issuer.isEmpty ? "" : account }
}

// MARK: - The keychain-backed record store (one item per record)

final class MoshSecretStore<T: MoshVaultRecord> {
  private let service: String

  // `serviceSuffix` is appended to the build's KEYCHAIN_ID1 so the service is namespaced to Moshroom
  // exactly like the SSH key / host-password services (".pkcard" / ".pwd") — never a foreign namespace.
  init(serviceSuffix: String) {
    self.service = "\(XCConfig.infoPlistKeyChainID1() ?? "").\(serviceSuffix)"
  }

  private static var encoder: JSONEncoder {
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
  }
  private static var decoder: JSONDecoder {
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
  }

  // Base query shared by every operation: the data-protection keychain (required for access groups +
  // iCloud Keychain sync on macOS), matching both sync flavors so we always find/replace the right
  // item regardless of the current toggle.
  private func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
    ]
  }

  func all() -> [T] {
    var q = baseQuery()
    q[kSecMatchLimit as String] = kSecMatchLimitAll
    q[kSecReturnData as String] = true
    q[kSecReturnAttributes as String] = true
    var result: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
          let items = result as? [[String: Any]] else { return [] }
    return items.compactMap { item in
      guard let data = item[kSecValueData as String] as? Data else { return nil }
      return try? Self.decoder.decode(T.self, from: data)
    }
  }

  func get(id: String) -> T? {
    var q = baseQuery()
    q[kSecAttrAccount as String] = id
    q[kSecReturnData as String] = true
    var result: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return try? Self.decoder.decode(T.self, from: data)
  }

  // Insert or replace. Like the SSH stores, we delete any existing variant first and add fresh, so
  // the item always takes the CURRENT sync flavor (SecItemUpdate can't change kSecAttrSynchronizable).
  @discardableResult
  func upsert(_ record: T) -> Bool {
    guard let data = try? Self.encoder.encode(record) else { return false }
    delete(id: record.id)
    var attrs = baseQuery()
    attrs[kSecAttrSynchronizable as String] = MoshKeychainSync.enabled   // concrete flavor for the new item
    attrs[kSecAttrAccount as String] = record.id
    attrs[kSecValueData as String] = data
    attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
  }

  func delete(id: String) {
    var q = baseQuery()
    q[kSecAttrAccount as String] = id
    SecItemDelete(q as CFDictionary)
  }
}

// MARK: - Concrete stores

final class MoshVaultStore {
  static let shared = MoshVaultStore()
  private let store = MoshSecretStore<MoshVaultEntry>(serviceSuffix: "vault")

  // Sorted by service name (case-insensitive), stable and predictable in the list.
  func all() -> [MoshVaultEntry] {
    store.all().sorted { $0.service.localizedCaseInsensitiveCompare($1.service) == .orderedAscending }
  }
  func count() -> Int { store.all().count }
  @discardableResult func save(_ e: MoshVaultEntry) -> Bool {
    var e = e; e.lastModified = Date(); return store.upsert(e)
  }
  func delete(_ e: MoshVaultEntry) { store.delete(id: e.id) }
}

final class MoshTOTPStore {
  static let shared = MoshTOTPStore()
  private let store = MoshSecretStore<MoshTOTPAccount>(serviceSuffix: "totp")

  func all() -> [MoshTOTPAccount] {
    store.all().sorted {
      let a = ($0.issuer.isEmpty ? $0.account : $0.issuer)
      let b = ($1.issuer.isEmpty ? $1.account : $1.issuer)
      return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }
  }
  func count() -> Int { store.all().count }
  @discardableResult func save(_ a: MoshTOTPAccount) -> Bool {
    var a = a; a.lastModified = Date(); return store.upsert(a)
  }
  func delete(_ a: MoshTOTPAccount) { store.delete(id: a.id) }

  // Import many at once (Google migration / batch), de-duping by (issuer, account, secret) so a
  // repeated scan doesn't pile up copies. Returns how many were newly added.
  @discardableResult func importAccounts(_ incoming: [MoshTOTPAccount]) -> Int {
    let existing = all()
    func key(_ a: MoshTOTPAccount) -> String { "\(a.issuer)\u{1}\(a.account)\u{1}\(a.secret)".lowercased() }
    let seen = Set(existing.map(key))
    var added = 0
    for acc in incoming where !seen.contains(key(acc)) {
      if store.upsert(acc) { added += 1 }
    }
    return added
  }
}
