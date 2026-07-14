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

// "Migrate from Google Authenticator" — Google's Export exposes accounts as one or more QR codes of
// the form `otpauth-migration://offline?data=<base64>`, whose payload is a protobuf `MigrationPayload`.
// We decode it with a tiny in-tree protobuf wire reader (varint + length-delimited only), so there is
// no protobuf-library dependency. Large exports are split into several QR codes (`batch_size` /
// `batch_index`); the scanner collects every batch, unions the results, then imports.
enum MoshOTPMigration {

  struct Result {
    var accounts: [MoshTOTPAccount]   // TOTP accounts recovered from this one QR
    var skippedHOTP: Int              // HOTP entries in this QR (not supported by a TOTP authenticator)
    var batchSize: Int                // how many QR codes make up the whole export (>= 1)
    var batchIndex: Int               // which one this is (0-based)
  }

  // Parse ONE migration QR / URI. Returns nil only if it isn't a valid migration payload.
  static func parse(uri: String) -> Result? {
    let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let comps = URLComponents(string: trimmed),
          comps.scheme?.lowercased() == "otpauth-migration",
          let raw = comps.queryItems?.first(where: { $0.name.lowercased() == "data" })?.value,
          let payload = decodeBase64Tolerant(raw) else { return nil }
    return parsePayload(payload)
  }

  // Base64 that survived URL handling: restore any '+' turned into ' ', and pad to a multiple of 4.
  private static func decodeBase64Tolerant(_ s: String) -> Data? {
    var b64 = s.replacingOccurrences(of: " ", with: "+")
    let rem = b64.count % 4
    if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
    return Data(base64Encoded: b64)
  }

  // MARK: - MigrationPayload

  private static func parsePayload(_ data: Data) -> Result {
    var reader = PBReader(data)
    var accounts: [MoshTOTPAccount] = []
    var skipped = 0
    var batchSize = 1
    var batchIndex = 0

    while let (field, wire) = reader.tag() {
      switch (field, wire) {
      case (1, 2):                                    // repeated OtpParameters otp_parameters
        guard let sub = reader.lengthDelimited() else { return finalize() }
        if let params = parseOtpParameters(sub) {
          if params.isHOTP { skipped += 1 } else if let acc = params.account { accounts.append(acc) }
        }
      case (3, 0): batchSize = Int(reader.varint() ?? 1)   // int32 batch_size
      case (4, 0): batchIndex = Int(reader.varint() ?? 0)  // int32 batch_index
      default:
        if !reader.skip(wire: wire) { return finalize() }
      }
    }
    func finalize() -> Result {
      Result(accounts: accounts, skippedHOTP: skipped, batchSize: max(1, batchSize), batchIndex: max(0, batchIndex))
    }
    return finalize()
  }

  // MARK: - OtpParameters

  private struct ParsedParams { var account: MoshTOTPAccount?; var isHOTP: Bool }

  private static func parseOtpParameters(_ data: Data) -> ParsedParams? {
    var reader = PBReader(data)
    var secret = Data()
    var name = ""
    var issuer = ""
    var algorithm: MoshOTPAlgorithm = .sha1
    var digits = 6
    var isHOTP = false

    while let (field, wire) = reader.tag() {
      switch (field, wire) {
      case (1, 2): secret = Data(reader.lengthDelimited() ?? Data())          // bytes secret
      case (2, 2): name = string(reader.lengthDelimited())                     // string name
      case (3, 2): issuer = string(reader.lengthDelimited())                   // string issuer
      case (4, 0):                                                             // enum algorithm
        switch reader.varint() ?? 1 { case 2: algorithm = .sha256; case 3: algorithm = .sha512; default: algorithm = .sha1 }
      case (5, 0): digits = (reader.varint() ?? 1) == 2 ? 8 : 6               // enum digits (SIX/EIGHT)
      case (6, 0): isHOTP = (reader.varint() ?? 2) == 1                        // enum type (HOTP=1, TOTP=2)
      default:
        if !reader.skip(wire: wire) { return nil }
      }
    }

    if isHOTP { return ParsedParams(account: nil, isHOTP: true) }
    guard !secret.isEmpty else { return nil }

    // Google's label often carries the issuer as "Issuer:account" or via the separate issuer field.
    var acctIssuer = issuer
    var acctName = name
    if acctIssuer.isEmpty, let sep = name.range(of: ":") {
      acctIssuer = String(name[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
      acctName = String(name[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    let account = MoshTOTPAccount(
      issuer: acctIssuer,
      account: acctName,
      secret: MoshTOTP.base32Encode(secret),   // our model stores Base32
      algorithm: algorithm,
      digits: digits,
      period: 30                               // Google migration payloads are always 30s TOTP
    )
    return ParsedParams(account: account, isHOTP: false)
  }

  private static func string(_ data: Data?) -> String {
    guard let data else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }

  // MARK: - Minimal protobuf wire reader

  private struct PBReader {
    private let bytes: [UInt8]
    private var i = 0
    init(_ data: Data) { bytes = [UInt8](data) }
    var atEnd: Bool { i >= bytes.count }

    mutating func varint() -> UInt64? {
      var result: UInt64 = 0, shift: UInt64 = 0
      while i < bytes.count {
        let b = bytes[i]; i += 1
        result |= UInt64(b & 0x7F) << shift
        if b & 0x80 == 0 { return result }
        shift += 7
        if shift >= 64 { return nil }
      }
      return nil
    }

    // A field tag: (fieldNumber, wireType). nil at end / on malformed input.
    mutating func tag() -> (Int, Int)? {
      guard !atEnd, let t = varint() else { return nil }
      return (Int(t >> 3), Int(t & 0x07))
    }

    mutating func lengthDelimited() -> Data? {
      guard let len = varint(), i + Int(len) <= bytes.count else { return nil }
      let slice = Data(bytes[i..<i + Int(len)])
      i += Int(len)
      return slice
    }

    // Skip an unknown field of the given wire type. Returns false if the stream is malformed.
    mutating func skip(wire: Int) -> Bool {
      switch wire {
      case 0: return varint() != nil                     // varint
      case 1: i += 8; return i <= bytes.count            // 64-bit
      case 2: return lengthDelimited() != nil            // length-delimited
      case 5: i += 4; return i <= bytes.count            // 32-bit
      default: return false
      }
    }
  }
}
