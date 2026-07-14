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
+ (BOOL)saveGroupContainerKeys:(NSArray<MoshPubKey *> *)keys;
+ (void)addCard:(nonnull MoshPubKey *)pubKey;
- (void)storePrivateKeyInKeychain:(nonnull NSString *) privateKey;
- (void)storeCertificateInKeychain:(nullable NSString *) certificate;
+ (nonnull NSArray<MoshPubKey *> *)all;
+ (NSInteger)count;
- (BOOL)isEncrypted;
- (void)removeCard;

// Deprecated. Use loadPrivateKey
- (nullable NSString *)privateKey DEPRECATED_ATTRIBUTE;

@end
