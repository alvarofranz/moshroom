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

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// MARK: - Shared keychain plumbing
//
// One home for what MoshPubKey.m, MoshHosts.m, MoshroomDefaults.m and the Swift stores used to copy
// by hand: the "Sync with iCloud" flag (kept in the app-group defaults so this framework can read it
// without importing the app target) and the delete-then-add write that never loses the old value.
// Implemented in MoshPubKey.m.

// The app-group defaults key that carries the "Sync with iCloud" toggle.
FOUNDATION_EXPORT NSString * _Nonnull const MoshroomICloudSyncEnabledKey;
// The toggle as the keychain stores see it: YES means new secrets are written synchronizable.
FOUNDATION_EXPORT BOOL MoshroomICloudSyncEnabled(void);

@class UICKeyChainStore;
// A store for `<KEYCHAIN_ID1>.<serviceSuffix>` whose writes take the CURRENT sync flavor.
FOUNDATION_EXPORT UICKeyChainStore * _Nonnull MoshroomKeychainStore(NSString * _Nonnull serviceSuffix)
  NS_SWIFT_UNAVAILABLE("ObjC keychain plumbing");
// Write a string so the item takes the current sync flavor. SecItemUpdate cannot change
// kSecAttrSynchronizable, so any existing variant is deleted and the value added fresh; the previous
// value is read first and put back, in its OWN flavor and accessibility, if the add is refused.
FOUNDATION_EXPORT BOOL MoshroomKeychainSetString(UICKeyChainStore * _Nonnull keychain,
                                                 NSString * _Nonnull value,
                                                 NSString * _Nonnull key)
  NS_SWIFT_UNAVAILABLE("ObjC keychain plumbing");
// The account names under a service, from an attributes-only query (no secret is read). nil when the
// keychain could not answer (locked before first unlock, busy), an empty set when there is nothing.
FOUNDATION_EXPORT NSSet<NSString *> * _Nullable MoshroomKeychainAccounts(UICKeyChainStore * _Nonnull keychain)
  NS_SWIFT_UNAVAILABLE("ObjC keychain plumbing");


typedef enum: NSUInteger {
  MoshPubKeyStorageTypeKeyChain = 0,
  MoshPubKeyStorageTypeSecureEnclave,
  MoshPubKeyStorageTypeiCloudKeyChain,
  MoshPubKeyStorageTypePlatformKey, // passkey
  MoshPubKeyStorageTypeSecurityKey,
  MoshPubKeyStorageTypeDistributed, // Bunkr master key
} MoshPubKeyStorageType;

@interface MoshPubKey : NSObject <NSSecureCoding, UIActivityItemSource>

@property (nonnull) NSString *ID; // unique name of the key
@property (nonnull) NSString *tag; // unique identifier of the key
@property (readonly, nonnull)  NSString *publicKey;
@property (readonly, nullable) NSString *keyType;
@property (readonly, nullable) NSString *certType;
@property (readonly) MoshPubKeyStorageType storageType;
@property (readonly, nullable) NSData * rawAttestationObject;
@property (readonly, nullable) NSString * rpId;
// When this identity was last created/modified. Stamped on add and on certificate change; drives the
// per-key newest-wins tie-break when the keys list is merged across devices during an iCloud sync.
@property (nullable) NSDate *lastModified;

- (nullable NSString *)loadPrivateKey;
- (nullable NSString *)loadCertificate;
// Is the private half present on THIS device? Answered from an account listing, so asking does not
// pull the secret out of the keychain. Always YES for Secure Enclave / passkey identities, whose
// material lives in hardware by design.
- (BOOL)hasPrivateKeyMaterial;
// Every identity whose private half is missing, resolved from a single keychain listing. Main thread
// (it reads the shared identities array), like +all.
+ (nonnull NSArray<MoshPubKey *> *)identitiesMissingPrivateMaterial;
// Called from Swift as storePrivateKey(inKeychain:) / storeCertificate(inKeychain:) — the bridged
// spelling, which is why a grep for the ObjC name finds no callers. Both return NO when the keychain
// refused the write (the previous value is restored); a caller that ignores the result is a bug —
// that is how an identity ends up with a public half and no private one.
- (BOOL)storePrivateKeyInKeychain:(nonnull NSString *) privateKey;
- (BOOL)storeCertificateInKeychain:(nullable NSString *) certificate;

+ (void)initialize;
+ (nullable instancetype)withID:(nullable NSString *)ID;

- (nullable instancetype)initWithID:(nonnull NSString *)ID
                                tag:(nonnull NSString *)tag
                          publicKey:(nonnull NSString *)publicKey
                            keyType:(nonnull NSString *)keyType
                           certType:(nullable NSString *)certType
               rawAttestationObject:(nullable NSData *)rawAttestationObject
                               rpId:(nullable NSString *)rpId
                        storageType:(MoshPubKeyStorageType)storageType;

+ (void)loadIDS;
+ (BOOL)saveIDS;
+ (void)addCard:(nonnull MoshPubKey *)pubKey;
+ (nonnull NSArray<MoshPubKey *> *)all;
+ (NSInteger)count;
- (BOOL)isEncrypted;
- (void)removeCard;

// Deprecated. Use loadPrivateKey
- (nullable NSString *)privateKey DEPRECATED_ATTRIBUTE;

@end
