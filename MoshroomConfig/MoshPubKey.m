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

//#include <libssh/callbacks.h>

#import <Foundation/Foundation.h>
#import "MoshPubKey.h"
#import "UICKeyChainStore.h"

#import <MoshroomConfig/MoshroomConfig-Swift.h>

#import "MoshroomPaths.h"
#import "XCConfig.h"
//#import <openssl/rsa.h>
//#import <OpenSSH/sshbuf.h>
//#import <OpenSSH/sshkey.h>
//#import <OpenSSH/ssherr.h>
//#import "Moshroom-Swift.h"

NSMutableArray *__identities;

// Keychain service for private keys: derived from the build's KEYCHAIN_ID1
// (e.g. com.alvarofranz.moshroom.pkcard) — never a hardcoded foreign namespace.
static NSString *__keychainService() {
  return [NSString stringWithFormat:@"%@.pkcard", [XCConfig infoPlistKeyChainID1]];
}

// The single global "Sync with iCloud" toggle governs whether secrets ride the iCloud Keychain.
// Its value lives in the app-group user defaults (written by MoshroomDefaults in the app target;
// importing it here would be a dependency cycle). Key + suite are identical in MoshHosts.m and
// MoshroomDefaults.m.
static NSString *const kMoshroomICloudSyncEnabledKey = @"MoshroomICloudSyncEnabled";
static BOOL __icloud_sync_enabled() {
  NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:[XCConfig infoPlistFullGroupID]];
  return [d boolForKey:kMoshroomICloudSyncEnabledKey];
}

// When sync is ON, private keys ride the iCloud Keychain (kSecAttrSynchronizable, end-to-end
// encrypted): they survive an app reinstall and follow the user's devices. When OFF, they are
// written local to this device. Secure Enclave keys are unaffected either way — hardware-bound by
// design (SEKey.swift), never synced.
static UICKeyChainStore *__get_keychain() {
  UICKeyChainStore *keychain = [UICKeyChainStore keyChainStoreWithService: __keychainService()];
  keychain.synchronizable = __icloud_sync_enabled();
  return keychain;
}

// Write a keychain string so the item always takes the CURRENT sync flavor. SecItemUpdate cannot
// change an existing item's kSecAttrSynchronizable, so delete any existing variant first (the lookup
// matches both flavors via kSecAttrSynchronizableAny) and add fresh.
//
// That delete-then-add opens a window where the only copy of a private key lives nowhere but this
// stack frame: if the add fails (locked before first unlock, keychain busy, quota) the old value is
// already gone and the key is destroyed. So the previous value is read first and PUT BACK when the
// write fails, and the outcome is returned instead of dropped — nothing can quietly leave an
// identity holding a public half and no private one.
static BOOL __kc_set(UICKeyChainStore *keychain, NSString *value, NSString *key) {
  NSString *previous = [keychain stringForKey:key];
  [keychain removeItemForKey:key];

  NSError *error = nil;
  if ([keychain setString:value forKey:key error:&error]) {
    return YES;
  }

  if (previous) {
    // Best effort: the value survives, even if it lands in the current flavor rather than its own.
    [keychain setString:previous forKey:key];
  }
  NSLog(@"[MoshPubKey] Keychain write failed for %@: %@%@", key, error,
        previous ? @" (previous value restored)" : @"");
  return NO;
}

@implementation MoshPubKey {
  NSString *_privateKeyRef;
  NSString *_tag;
  NSData *_rawAttestationObject;
}


+ (void)initialize
{
  // Maintain compatibility with previous version of the class
  [NSKeyedUnarchiver setClass:self forClassName:@"PKCard"];
}

+ (const NSString *)keychainService {
  return __keychainService();
}

+ (instancetype)withID:(NSString *)ID
{
  // Find the ID and return it.
  for (MoshPubKey *i in __identities) {
    if ([i->_ID isEqualToString:ID]) {
      return i;
    }
  }

  return nil;
}

+ (NSArray *)all
{
  if (!__identities.count) {
    [self loadIDS];
  }
  return [__identities copy];
}

+ (BOOL)saveIDS {
  NSError *error = nil;
  NSData *data = [NSKeyedArchiver archivedDataWithRootObject:__identities
                                       requiringSecureCoding:YES
                                                       error:&error];
  if (error || !data) {
    NSLog(@"[MoshPubKey] Failed to archive to data: %@", error);
    return NO;
  }
  
  // CompleteUntilFirstUserAuthentication (not None): this blob holds key *metadata* (public key,
  // tag, type, storage type) — the private material lives in the keychain, not here — but the
  // metadata still shouldn't be readable at rest before the first unlock. This class allows
  // background reads after the first unlock since boot, matching the keychain's AfterFirstUnlock.
  BOOL result = [data writeToFile:[MoshroomPaths moshroomKeysFile]
                          options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication
                            error:&error];
  
  if (error || !result) {
    NSLog(@"[MoshPubKey] Failed to save data to file: %@", error);
    return NO;
  }

  // Mirror the saved keys up to iCloud Drive — the cloud mirror observes this; a no-op if sync is
  // off. Symmetric with MoshHosts posting MoshroomHostsDidSave.
  [[NSNotificationCenter defaultCenter] postNotificationName:@"MoshroomKeysDidSave" object:nil];

  return result;
}

+ (void)loadIDS {
  __identities = [[NSMutableArray alloc] init];
  
  NSError *error = nil;
  NSData *data = [NSData dataWithContentsOfFile:[MoshroomPaths moshroomKeysFile]
                                        options:NSDataReadingMappedIfSafe
                                          error:&error];
  if (error || !data) {
    NSLog(@"[MoshPubKey] Failed to load data: %@", error);
    return;
  }

  NSArray *result =
    [NSKeyedUnarchiver unarchivedArrayOfObjectsOfClasses:[NSSet setWithObjects:MoshPubKey.class, nil]
                                                fromData:data
                                                   error:&error];
  
  if (error || !result) {
    NSLog(@"[MoshPubKey] Failed to unarchive data: %@", error);
    return;
  }
  
  __identities = [result mutableCopy];
}

- (nullable instancetype)initWithID:(NSString *)ID
                                tag:(nonnull NSString *)tag
                          publicKey:(NSString *)publicKey
                            keyType:(NSString *)keyType
                           certType:(NSString *)certType
               rawAttestationObject:(nullable NSData *)rawAttestationObject
                             rpId:(nullable NSString *)rpId
                        storageType:(MoshPubKeyStorageType)storageType
{

  if (self = [super init]) {
    _ID = ID;
    _tag = tag;
    _publicKey = publicKey;
    _keyType = keyType;
    _certType = certType;
    _rawAttestationObject = rawAttestationObject;
    _rpId = rpId;
    _storageType = storageType;
  }
  
  return self;
}

+ (void)addCard:(MoshPubKey *)pubKey {
  pubKey.lastModified = [NSDate date];
  [__identities addObject:pubKey];
  [MoshPubKey saveIDS];
}

+ (NSInteger)count
{
  return [__identities count];
}

+ (BOOL)supportsSecureCoding {
  return YES;
}

- (id)initWithCoder:(NSCoder *)coder
{
  self = [super init];
  if (!self) {
    return self;
  }
  NSSet *strings = [NSSet setWithObjects:NSString.class, nil];
//  NSSet *numbers = [NSSet setWithObjects:NSNumber.class, nil];
  
  _ID = [coder decodeObjectOfClasses:strings forKey:@"ID"];
  _tag = [coder decodeObjectOfClasses:strings forKey:@"tag"];
  _storageType = [coder decodeInt64ForKey:@"storageType"];
  
  _keyType = [coder decodeObjectOfClasses:strings forKey:@"keyType"];
  _certType = [coder decodeObjectOfClasses:strings forKey:@"certType"];
  
  _privateKeyRef = [coder decodeObjectOfClasses:strings forKey:@"privateKeyRef"];
  _publicKey = [coder decodeObjectOfClasses:strings forKey:@"publicKey"];
  
  _rawAttestationObject = [coder decodeObjectOfClass:NSData.class forKey:@"rawAttestationObject"];
  _rpId = [coder decodeObjectOfClasses:strings forKey:@"rpId"];
  _lastModified = [coder decodeObjectOfClass:NSDate.class forKey:@"lastModified"];

  if (!_tag) {
    _tag = [NSProcessInfo processInfo].globallyUniqueString;
  }
  
  if (!_keyType) {
    _keyType = [MoshPubKey _shortKeyTypeNameFromSshKeyTypeName:[[_publicKey componentsSeparatedByString:@" "] firstObject]];
  }
  
  return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
  [coder encodeObject:_ID forKey:@"ID"];
  [coder encodeObject:_tag forKey:@"tag"];
  [coder encodeInt64:_storageType forKey:@"storageType"];
  
  [coder encodeObject:_keyType forKey:@"keyType"];
  [coder encodeObject:_certType forKey:@"certType"];
  
  [coder encodeObject:_privateKeyRef forKey:@"privateKeyRef"];
  [coder encodeObject:_publicKey forKey:@"publicKey"];
  
  [coder encodeObject:_rawAttestationObject forKey:@"rawAttestationObject"];
  [coder encodeObject:_rpId forKey:@"rpId"];
  [coder encodeObject:_lastModified forKey:@"lastModified"];
}

+ (NSString *)_shortKeyTypeNameFromSshKeyTypeName:(NSString *)keyTypeName {
  // https://github.com/openssh/openssh-portable/blob/master/sshkey.c#L106
  NSDictionary *map = @{
    @"ssh-ed25519": @"ED25519",
    @"ssh-ed25519-cert-v01@openssh.com": @"ED25519-CERT",
    @"ssh-rsa": @"RSA",
    @"rsa-sha2-256": @"RSA",
    @"rsa-sha2-512": @"RSA",
    @"ssh-dss": @"DSA",
    @"ecdsa-sha2-nistp256": @"ECDSA",
    @"ecdsa-sha2-nistp384": @"ECDSA",
    @"ecdsa-sha2-nistp521": @"ECDSA",
    @"ssh-rsa-cert-v01@openssh.com": @"RSA-CERT",
    @"rsa-sha2-256-cert-v01@openssh.com": @"RSA-CERT",
    @"rsa-sha2-512-cert-v01@openssh.com": @"RSA-CERT",
    @"ssh-dss-cert-v01@openssh.com": @"DSA-CERT",
    @"ecdsa-sha2-nistp256-cert-v01@openssh.com": @"ECDSA-CERT",
    @"ecdsa-sha2-nistp384-cert-v01@openssh.com": @"ECDSA-CERT",
    @"ecdsa-sha2-nistp521-cert-v01@openssh.com": @"ECDSA-CERT",
    // SK
    @"sk-ecdsa-sha2-nistp256@openssh.com" : @"ECDSA-SK",
    @"sk-ecdsa-sha2-nistp256-cert-v01@openssh.com" : @"ECDSA-SK-CERT",
  };
  return map[keyTypeName];
}

- (id)initWithID:(NSString *)ID publicKey:(NSString *)publicKey
{
  self = [self init];
  if (self == nil)
    return nil;

  _ID = ID;
  _tag = [[NSProcessInfo processInfo] globallyUniqueString];
  _privateKeyRef = nil;
  _publicKey = publicKey;

  return self;
}

- (nullable NSString *)loadCertificate {
  UICKeyChainStore *keychain = __get_keychain();
  return [keychain stringForKey:[self _certificateKeychainRef]];
}

- (BOOL)storePrivateKeyInKeychain:(NSString *) privateKey {
  return __kc_set(__get_keychain(), privateKey, [self _privateKeyKeychainRef]);
}

// Is this identity's private half actually ON this device? Answered WITHOUT reading the secret out
// of the keychain (an account listing, not a value fetch), because it is asked for every row of the
// keys list and for the sync health readout. Non-Keychain identities (Secure Enclave, passkeys)
// carry their material elsewhere by design and are always complete.
- (BOOL)hasPrivateKeyMaterial {
  if (_storageType != MoshPubKeyStorageTypeKeyChain) {
    return YES;
  }
  UICKeyChainStore *keychain = __get_keychain();
  NSString *ref = [self _privateKeyRefName];
  if ([[keychain allKeys] containsObject:ref]) {
    return YES;
  }
  // A listing can come back empty on a keychain that isn't readable yet; the authoritative read is
  // the fallback so a transient listing failure can never mark a working key as broken.
  return [keychain stringForKey:ref] != nil;
}

// The same question for every identity at once, from ONE listing instead of one per row — this is
// asked while building the keys list and while drawing the sync status. The per-card value read is
// only reached for a card the listing did not mention, which is exactly the case worth being sure
// about. Main thread, like every other +all-based call: it touches the shared identities array.
+ (NSArray<MoshPubKey *> *)identitiesMissingPrivateMaterial {
  NSArray *accounts = [__get_keychain() allKeys];
  NSSet *present = accounts.count ? [NSSet setWithArray:accounts] : [NSSet set];

  NSMutableArray<MoshPubKey *> *missing = [NSMutableArray array];
  for (MoshPubKey *card in [MoshPubKey all]) {
    if (card.storageType != MoshPubKeyStorageTypeKeyChain) {
      continue;
    }
    if ([present containsObject:[card _privateKeyRefName]]) {
      continue;
    }
    if ([card hasPrivateKeyMaterial]) {
      continue;
    }
    [missing addObject:card];
  }
  return missing;
}

- (BOOL)storeCertificateInKeychain:(nullable NSString *) certificate {
  UICKeyChainStore *keychain = __get_keychain();
  NSString *certRef = [self _certificateKeychainRef];
  BOOL ok = YES;
  if (certificate) {
    _certType = [MoshPubKey _shortKeyTypeNameFromSshKeyTypeName:[[certificate componentsSeparatedByString:@" "] firstObject]];
    ok = __kc_set(keychain, certificate, certRef);
  } else {
    [keychain removeItemForKey:certRef];
    _certType = nil;
  }
  // A certificate change is a metadata change — restamp so an iCloud merge tie-breaks in its favour,
  // and persist (certType + lastModified live in the keys blob).
  _lastModified = [NSDate date];
  [MoshPubKey saveIDS];
  return ok;
}

- (nullable NSString *)privateKey {
  return [self loadPrivateKey];
}

- (nullable NSString *)loadPrivateKey
{
  // Legacy access via privateKeyRef
  if (_privateKeyRef) {
    UICKeyChainStore *keychain = __get_keychain();
    return [keychain stringForKey:_privateKeyRef];
  }
  
  switch (_storageType) {
    case MoshPubKeyStorageTypeiCloudKeyChain:
    case MoshPubKeyStorageTypeKeyChain: {
      UICKeyChainStore *keychain = __get_keychain();
      return [keychain stringForKey:[self _privateKeyKeychainRef]];
      break;
    }
    case MoshPubKeyStorageTypeSecureEnclave:
    case MoshPubKeyStorageTypePlatformKey:
    case MoshPubKeyStorageTypeSecurityKey:
      return nil;
    default:
      return nil;
  }
}

- (NSString *)_certificateKeychainRef {
  return [NSString stringWithFormat: @"%@-cert.pub", _tag];
}

- (NSString *)_privateKeyKeychainRef {
  return [NSString stringWithFormat: @"%@.pem", _tag];
}

// Where this identity's private half is filed. Old records carry an explicit ref; everything since
// derives it from the tag.
- (NSString *)_privateKeyRefName {
  return _privateKeyRef ?: [self _privateKeyKeychainRef];
}

- (BOOL)isEncrypted
{
  NSString *priv = [self loadPrivateKey];
  if ([priv rangeOfString:@"^Proc-Type: 4,ENCRYPTED\n"
                  options:NSRegularExpressionSearch]
      .location != NSNotFound) {
    return YES;
  }
  else if ([priv rangeOfString:@"^-----BEGIN ENCRYPTED PRIVATE KEY-----\n"
                       options:NSRegularExpressionSearch]
             .location != NSNotFound) {
    return YES;
  }
  else {
    return NO;
  }
}

- (void)removeCard {
  if (_storageType == MoshPubKeyStorageTypeKeyChain) {
    UICKeyChainStore * kc = __get_keychain();
    [kc removeItemForKey:[self _certificateKeychainRef]];
    [kc removeItemForKey:[self _privateKeyKeychainRef]];
  }
  [__identities removeObject:self];
  [MoshPubKey saveIDS];
}

// UIActivityItemSource methods
- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)activityViewController
{
  return _publicKey;
}

- (id)activityViewController:(UIActivityViewController *)activityViewController itemForActivityType:(UIActivityType)activityType
{
  if ([activityType  isEqualToString:UIActivityTypeMail] || [activityType isEqualToString:UIActivityTypeAirDrop]) {
    // Create a file to return if sharing through Mail or AirDrop
    NSString *tempFilename = [NSString stringWithFormat:@"%@.pub", _ID];
    NSString *publicKeyString = _publicKey;
    
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingString:tempFilename]];
    NSData *data = [publicKeyString dataUsingEncoding:NSUTF8StringEncoding];
    
    [data writeToURL:url atomically:NO];
    
    [activityViewController setCompletionWithItemsHandler:^(NSString *activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
      // Delete the file when
      NSError *errorBlock;
      if([[NSFileManager defaultManager] removeItemAtURL:url error:&errorBlock] == NO) {
        NSLog(@"Error deleting temporary public key file %@",errorBlock);
        return;
      }
    }];
    
    return url;
  }
  return _publicKey;
}

- (NSString *)activityViewController:(UIActivityViewController *)activityViewController
              subjectForActivityType:(UIActivityType)activityType
{
  return [NSString stringWithFormat:@"Moshroom Public Key: %@", _ID];
}

- (NSString *)activityViewController:(UIActivityViewController *)activityViewController dataTypeIdentifierForActivityType:(UIActivityType)activityType
{
  return @"public.text";
}

@end
