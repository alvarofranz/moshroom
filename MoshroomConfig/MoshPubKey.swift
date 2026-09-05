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
import SSH

/// What can go wrong around an identity's private half. Separate from `SSHKeyError` because none of
/// these are the SSH library's failures — they are ours, and the messages are shown to the user.
public enum MoshPubKeyError: Error, LocalizedError {
  case keychainWriteFailed
  case publicHalfMismatch
  case notRepairable

  public var errorDescription: String? {
    switch self {
    case .keychainWriteFailed:
      return "The keychain refused to store the private key, so nothing was saved. Unlock the device and try again."
    case .publicHalfMismatch:
      return "That private key belongs to a different identity — its public half doesn't match this one."
    case .notRepairable:
      return "This identity's private key lives in hardware and can't be replaced."
    }
  }
}

public extension MoshPubKey {

  /// Do two authorized-key lines name the same identity? Type + base64 blob decide it; the trailing
  /// comment is free text (a device name, an email) and must never count.
  static func publicHalvesMatch(_ a: String, _ b: String) -> Bool {
    func head(_ s: String) -> [Substring] {
      Array(s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).prefix(2))
    }
    let ha = head(a)
    return ha.count == 2 && ha == head(b)
  }

  /// Give an EXISTING identity its private half back.
  ///
  /// This is the repair for the state where a key record arrived from another device (the record
  /// travels over iCloud Drive) while its material did not (it rides the iCloud Keychain). Before
  /// this existed the only way out was to delete the identity and import it again — which tombstones
  /// the record and takes it off the other device too, i.e. the "fix" destroyed data. Here the record
  /// is untouched: same id, same tag, nothing tombstoned, nothing re-synced.
  ///
  /// The key offered is verified to BE this identity before anything is written.
  static func attachPrivateKey(_ key: SSHKey, to card: MoshPubKey) throws {
    guard card.storageType == MoshPubKeyStorageTypeKeyChain else {
      throw MoshPubKeyError.notRepairable
    }
    guard MoshPubKey.publicHalvesMatch(try key.authorizedKey(withComment: ""), card.publicKey) else {
      throw MoshPubKeyError.publicHalfMismatch
    }
    guard let privateKey = String(data: try key.privateKeyFileBlob(), encoding: .utf8) else {
      throw MoshPubKeyError.keychainWriteFailed
    }
    guard card.storePrivateKey(inKeychain: privateKey) else {
      throw MoshPubKeyError.keychainWriteFailed
    }
  }
  
  static func addKeychainKey(id: String, key: SSHKey, comment: String) throws {
    let tag = ProcessInfo().globallyUniqueString
    let publicKey = try key.authorizedKey(withComment: comment)
    guard
      let card = MoshPubKey(
        id: id,
        tag: tag,
        publicKey: publicKey,
        keyType: key.sshKeyType.shortName,
        certType: nil,
        rawAttestationObject: nil,
        rpId: nil,
        storageType: MoshPubKeyStorageTypeKeyChain
      ),
      let privateKey = String(data: try key.privateKeyFileBlob(), encoding: .utf8)
    else {
      return
    }
    
    // The record is added only AFTER the material is safely in the keychain. A card whose private
    // half never landed is exactly the unusable "public half only" identity the app now refuses to
    // create — better a failed creation the user can retry than a key that looks fine and can't sign.
    guard card.storePrivateKey(inKeychain: privateKey) else {
      throw MoshPubKeyError.keychainWriteFailed
    }

    MoshPubKey.addCard(card);
  }
  
  static func addSEKey(id: String, comment: String) throws {
    let tag = ProcessInfo().globallyUniqueString
    let key = try SEKey.create(tagged: tag)
    
    let keyType = key.sshKeyType
    let publicKey = try key.publicKey.authorizedKey(withComment: comment)
    guard
      let card = MoshPubKey(
        id: id,
        tag: tag,
        publicKey: publicKey,
        keyType: keyType.shortName,
        certType: nil,
        rawAttestationObject: nil,
        rpId: nil,
        storageType: MoshPubKeyStorageTypeSecureEnclave
      )
    else {
      return
    }
    
    MoshPubKey.addCard(card);
  }
  
  static func addPasskey(
    id: String,
    rpId: String,
    tag: String,
    rawAttestationObject: Data,
    comment: String
  ) throws {
    
    let key = try WebAuthnKey(rpId: rpId, rawAttestationObject: rawAttestationObject)
    
    let keyType = key.sshKeyType
    let publicKey = try key.publicKey.authorizedKey(withComment: comment)
    guard
      let card = MoshPubKey(
        id: id,
        tag: tag,
        publicKey: publicKey,
        keyType: keyType.shortName,
        certType: nil,
        rawAttestationObject: rawAttestationObject,
        rpId: rpId,
        storageType: MoshPubKeyStorageTypePlatformKey
      )
    else {
      return
    }
    
    MoshPubKey.addCard(card);
  }
  
  static func addSecurityKey(
    id: String,
    rpId: String,
    tag: String,
    rawAttestationObject: Data,
    comment: String
  ) throws {
    
    let key = try SKWebAuthnKey(rpId: rpId, rawAttestationObject: rawAttestationObject)
    
    let keyType = key.sshKeyType
    let publicKey = try key.publicKey.authorizedKey(withComment: comment)
    guard
      let card = MoshPubKey(
        id: id,
        tag: tag,
        publicKey: publicKey,
        keyType: keyType.shortName,
        certType: nil,
        rawAttestationObject: rawAttestationObject,
        rpId: rpId,
        storageType: MoshPubKeyStorageTypeSecurityKey
      )
    else {
      return
    }
    
    MoshPubKey.addCard(card);
  }
  
  static func removeCard(card: MoshPubKey) {
    if card.storageType == MoshPubKeyStorageTypeSecureEnclave {
      try? SEKey.delete(tag: card.tag)
    }
    
    card.removeCard()
  }
  
}


extension Collection where Element == MoshPubKey {
  public func signerWithID(_ id: String) -> Signer? {
    guard
      let card = self.first(where: { $0.id == id }) //MoshPubKey.withID(id)
    else {
      return nil
    }

    if card.storageType == MoshPubKeyStorageTypeKeyChain {
      guard
        let privateKey = card.loadPrivateKey(),
        let privateKeyBlob = SSHKey.sanitize(key: privateKey).data(using: .utf8)
      else {
        return nil
      }
      
      let certBlob = card.loadCertificate()?.data(using: .utf8)
      return try? SSHKey(fromFileBlob: privateKeyBlob, withPublicFileCertBlob: certBlob)
    }
    
    if card.storageType == MoshPubKeyStorageTypeSecureEnclave {
      // TODO: Certs fro SEKey?
      return SEKey(tagged: card.tag)
    }
    
    if card.storageType == MoshPubKeyStorageTypePlatformKey {
      guard
        let rawAttestationObject = card.rawAttestationObject,
        let rpId = card.rpId
      else {
        return nil
      }

      return try? WebAuthnKey(rpId:rpId, rawAttestationObject: rawAttestationObject)
    }
    
    if card.storageType == MoshPubKeyStorageTypeSecurityKey {
      guard
        let rawAttestationObject = card.rawAttestationObject,
        let rpId = card.rpId
      else {
        return nil
      }

      return try? SKWebAuthnKey(rpId:rpId, rawAttestationObject: rawAttestationObject)
    }
    
    return nil
  }
  

}
