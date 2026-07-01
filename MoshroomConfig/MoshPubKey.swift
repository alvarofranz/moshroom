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

public extension MoshPubKey {
  
  @objc static func saveDefaultKey() -> Bool {
    do {
      let key = try SSHKey(type: .rsa, bits: 4096)
      try addKeychainKey(id: "id_rsa", key: key, comment: "moshroom")
    } catch {
      debugPrint(error)
      return false
    }
    
    return  true
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
    
    card.storePrivateKey(inKeychain: privateKey)
    
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
