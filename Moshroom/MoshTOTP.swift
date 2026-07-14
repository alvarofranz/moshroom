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
import CryptoKit

// The 2FA engine: RFC 6238 (TOTP) over RFC 4238 (HOTP), computed on-device with CryptoKit — no
// third-party dependency. Also parses `otpauth://totp/...` URIs (scanned QR, pasted links, manual)
// and does Base32 (RFC 4648) both ways. Everything here is pure and offline.
enum MoshTOTP {

  // MARK: - Base32 (RFC 4648, no padding required)

  private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

  static func base32Decode(_ string: String) -> Data? {
    var lookup = [Character: Int]()
    for (i, c) in base32Alphabet.enumerated() { lookup[c] = i }
    let cleaned = string.uppercased()
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "-", with: "")
      .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    guard !cleaned.isEmpty else { return nil }
    var bits = 0, value = 0
    var out = [UInt8]()
    for ch in cleaned {
      guard let v = lookup[ch] else { return nil }
      value = (value << 5) | v
      bits += 5
      if bits >= 8 {
        bits -= 8
        out.append(UInt8((value >> bits) & 0xFF))
      }
    }
    return Data(out)
  }

  static func base32Encode(_ data: Data) -> String {
    var out = ""
    var bits = 0, value = 0
    for byte in data {
      value = (value << 8) | Int(byte)
      bits += 8
      while bits >= 5 {
        bits -= 5
        out.append(base32Alphabet[(value >> bits) & 0x1F])
      }
    }
    if bits > 0 {
      out.append(base32Alphabet[(value << (5 - bits)) & 0x1F])
    }
    return out
  }

  // MARK: - Code generation

  // The current TOTP code, zero-padded to `digits`.
  static func code(for account: MoshTOTPAccount, at date: Date = Date()) -> String {
    let step = UInt64(max(1, account.period))
    let counter = UInt64(max(0, date.timeIntervalSince1970)) / step
    return hotp(secretBase32: account.secret, counter: counter,
                digits: account.digits, algorithm: account.algorithm)
  }

  // Seconds until the current code rolls over — drives the countdown ring.
  static func secondsRemaining(for account: MoshTOTPAccount, at date: Date = Date()) -> Int {
    let step = max(1, account.period)
    return step - Int(UInt64(max(0, date.timeIntervalSince1970)) % UInt64(step))
  }

  // True when the Base32 secret decodes to a usable key.
  static func isValidSecret(_ secret: String) -> Bool {
    guard let key = base32Decode(secret) else { return false }
    return !key.isEmpty
  }

  private static func hotp(secretBase32: String, counter: UInt64, digits: Int, algorithm: MoshOTPAlgorithm) -> String {
    let safeDigits = min(max(digits, 1), 9)
    guard let key = base32Decode(secretBase32), !key.isEmpty else {
      return String(repeating: "•", count: safeDigits)
    }
    var big = counter.bigEndian
    let message = withUnsafeBytes(of: &big) { Data($0) }
    let symKey = SymmetricKey(data: key)

    let digest: [UInt8]
    switch algorithm {
    case .sha1:   digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symKey))
    case .sha256: digest = Array(HMAC<SHA256>.authenticationCode(for: message, using: symKey))
    case .sha512: digest = Array(HMAC<SHA512>.authenticationCode(for: message, using: symKey))
    }

    let offset = Int(digest[digest.count - 1] & 0x0F)
    let binary = (UInt32(digest[offset] & 0x7F) << 24)
               | (UInt32(digest[offset + 1]) << 16)
               | (UInt32(digest[offset + 2]) << 8)
               |  UInt32(digest[offset + 3])
    var mod: UInt32 = 1
    for _ in 0..<safeDigits { mod &*= 10 }
    let otp = binary % mod
    return String(format: "%0\(safeDigits)u", otp)
  }

  // MARK: - otpauth:// parsing

  // Parse a single `otpauth://totp/...` URI into an account (id/lastModified assigned fresh). HOTP
  // URIs return nil — Moshvault is a TOTP authenticator (the Google import reports HOTP separately).
  static func parse(uri: String) -> MoshTOTPAccount? {
    guard let comps = URLComponents(string: uri.trimmingCharacters(in: .whitespacesAndNewlines)),
          comps.scheme?.lowercased() == "otpauth",
          comps.host?.lowercased() == "totp" else { return nil }

    var label = comps.path
    if label.hasPrefix("/") { label.removeFirst() }
    label = label.removingPercentEncoding ?? label

    var issuer = ""
    var account = label
    if let sep = label.range(of: ":") {
      issuer = String(label[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
      account = String(label[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    let items = comps.queryItems ?? []
    func q(_ name: String) -> String? { items.first { $0.name.lowercased() == name }?.value }

    guard let rawSecret = q("secret"), !rawSecret.isEmpty else { return nil }
    if let qIssuer = q("issuer"), !qIssuer.isEmpty { issuer = qIssuer }
    let algorithm = MoshOTPAlgorithm(rawValue: (q("algorithm") ?? "SHA1").uppercased()) ?? .sha1
    let digits = Int(q("digits") ?? "6") ?? 6
    let period = Int(q("period") ?? "30") ?? 30
    let secret = rawSecret.uppercased().replacingOccurrences(of: " ", with: "")

    guard isValidSecret(secret) else { return nil }
    return MoshTOTPAccount(issuer: issuer, account: account, secret: secret,
                           algorithm: algorithm, digits: digits, period: period)
  }
}
