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
// YES while the keys blob exists on disk but could not be READ (protected data not available yet).
// The in-memory list is empty then, and saving it would overwrite every identity the file holds,
// which the cloud mirror would then read as "all deleted" and tombstone on every device.
static BOOL __identitiesUnreadable = NO;

// Keychain service suffix for private keys: the service is the build's KEYCHAIN_ID1 plus this
// (e.g. com.alvarofranz.moshroom.pkcard), never a hardcoded foreign namespace.
static NSString *const kPrivateKeyServiceSuffix = @"pkcard";

static NSString *__keychainService() {
  return [NSString stringWithFormat:@"%@.%@", [XCConfig infoPlistKeyChainID1], kPrivateKeyServiceSuffix];
}

#pragma mark - Shared keychain plumbing (declared in MoshPubKey.h)

// The single global "Sync with iCloud" toggle governs whether secrets ride the iCloud Keychain. Its
// value lives in the app-group user defaults: MoshroomDefaults (app target) writes it, and this
// framework cannot import the app target, so the key is defined HERE once and everyone else uses it.
NSString *const MoshroomICloudSyncEnabledKey = @"MoshroomICloudSyncEnabled";

BOOL MoshroomICloudSyncEnabled(void) {
  NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:[XCConfig infoPlistFullGroupID]];
  return [d boolForKey:MoshroomICloudSyncEnabledKey];
}

// When sync is ON, secrets ride the iCloud Keychain (kSecAttrSynchronizable, end-to-end encrypted):
// they survive an app reinstall and follow the user's devices. When OFF, they are written local to
// this device. Secure Enclave keys are unaffected either way: hardware-bound by design (SEKey.swift).
UICKeyChainStore *MoshroomKeychainStore(NSString *serviceSuffix) {
  NSString *service = [NSString stringWithFormat:@"%@.%@", [XCConfig infoPlistKeyChainID1], serviceSuffix];
  UICKeyChainStore *keychain = [UICKeyChainStore keyChainStoreWithService:service];
  keychain.synchronizable = MoshroomICloudSyncEnabled();
  return keychain;
}

// The base of every raw query below: the same service, both sync flavors, the data-protection
// keychain (what UICKeyChainStore uses too, see its -query).
static NSMutableDictionary *__kc_query(UICKeyChainStore *keychain) {
  NSMutableDictionary *q = [NSMutableDictionary dictionary];
  q[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
  q[(__bridge id)kSecAttrService] = keychain.service ?: @"";
  q[(__bridge id)kSecUseDataProtectionKeychain] = @YES;
  q[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
  if (keychain.accessGroup) {
    q[(__bridge id)kSecAttrAccessGroup] = keychain.accessGroup;
  }
  return q;
}

// Write a keychain string so the item always takes the CURRENT sync flavor. SecItemUpdate cannot
// change an existing item's kSecAttrSynchronizable, so delete any existing variant first (the lookup
// matches both flavors) and add fresh.
//
// That delete-then-add opens a window where the only copy of a secret lives nowhere but this stack
// frame: if the add fails (locked before first unlock, keychain busy, quota) the old value is already
// gone. So the previous item is read first (data AND its own flavor + accessibility) and PUT BACK as
// it was when the write fails, and the outcome is returned instead of dropped.
BOOL MoshroomKeychainSetString(UICKeyChainStore *keychain, NSString *value, NSString *key) {
  NSMutableDictionary *read = __kc_query(keychain);
  read[(__bridge id)kSecAttrAccount] = key;
  read[(__bridge id)kSecReturnData] = @YES;
  read[(__bridge id)kSecReturnAttributes] = @YES;
  read[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
  CFTypeRef found = NULL;
  NSDictionary *previous = nil;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)read, &found) == errSecSuccess && found) {
    previous = CFBridgingRelease(found);
  }

  [keychain removeItemForKey:key];

  NSError *error = nil;
  if ([keychain setString:value forKey:key error:&error]) {
    return YES;
  }

  BOOL restored = NO;
  NSData *previousData = previous[(__bridge id)kSecValueData];
  if (previousData) {
    NSMutableDictionary *add = __kc_query(keychain);
    add[(__bridge id)kSecAttrAccount] = key;
    add[(__bridge id)kSecValueData] = previousData;
    add[(__bridge id)kSecAttrSynchronizable] = previous[(__bridge id)kSecAttrSynchronizable] ?: @NO;
    add[(__bridge id)kSecAttrAccessible] =
      previous[(__bridge id)kSecAttrAccessible] ?: (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    restored = SecItemAdd((__bridge CFDictionaryRef)add, NULL) == errSecSuccess;
  }
  NSLog(@"[Moshroom] Keychain write failed for %@: %@%@", key, error,
        restored ? @" (previous value restored)" : (previousData ? @" (restore failed)" : @""));
  return NO;
}

NSSet<NSString *> *MoshroomKeychainAccounts(UICKeyChainStore *keychain) {
  NSMutableDictionary *q = __kc_query(keychain);
  q[(__bridge id)kSecReturnAttributes] = @YES;
  q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
  CFTypeRef found = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &found);
  if (status == errSecItemNotFound) {
    return [NSSet set];
  }
  if (status != errSecSuccess || !found) {
    return nil;
  }
  NSArray *items = CFBridgingRelease(found);
  NSMutableSet<NSString *> *accounts = [NSMutableSet set];
  for (NSDictionary *item in items) {
    NSString *account = item[(__bridge id)kSecAttrAccount];
    if ([account isKindOfClass:NSString.class]) {
      [accounts addObject:account];
    }
  }
  return accounts;
}

static UICKeyChainStore *__get_keychain() {
  return MoshroomKeychainStore(kPrivateKeyServiceSuffix);
}

static BOOL __kc_set(UICKeyChainStore *keychain, NSString *value, NSString *key) {
  return MoshroomKeychainSetString(keychain, value, key);
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
  if (__identitiesUnreadable) {
    NSLog(@"[MoshPubKey] Refusing to save: the keys file exists but could not be read this run");
    return NO;
  }
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
    // A missing file is a fresh install. Anything else means the file is there and this run cannot
    // see it, so the empty list must never be written over it.
    BOOL missing = [error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileReadNoSuchFileError;
    __identitiesUnreadable = !missing;
    NSLog(@"[MoshPubKey] Failed to load data: %@", error);
    return;
  }
  __identitiesUnreadable = NO;

  NSArray *result =
    [NSKeyedUnarchiver unarchivedArrayOfObjectsOfClasses:[NSSet setWithObjects:MoshPubKey.class, nil]
                                                fromData:data
                                                   error:&error];
  
  if (error || !result) {
    NSLog(@"[MoshPubKey] Failed to unarchive data: %@", error);
    // Keep the bytes before anything can overwrite them: a copy beside the file, made once.
    NSString *aside = [[MoshroomPaths moshroomKeysFile] stringByAppendingString:@".unreadable"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:aside]) {
      [data writeToFile:aside options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
    }
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
// of the keychain (an attributes-only account listing, not a value fetch), because it is asked for
// every row of the keys list and for the sync health readout. Non-Keychain identities (Secure
// Enclave, passkeys) carry their material elsewhere by design and are always complete.
- (BOOL)hasPrivateKeyMaterial {
  return [self _hasPrivateKeyMaterialIn:MoshroomKeychainAccounts(__get_keychain())];
}

// `accounts` is a listing taken by the caller, or nil when the keychain could not answer. Only then
// is the authoritative value read used, so a transient listing failure can never mark a working key
// as broken, and a successful listing never pulls a secret just to answer yes or no.
- (BOOL)_hasPrivateKeyMaterialIn:(nullable NSSet<NSString *> *)accounts {
  if (_storageType != MoshPubKeyStorageTypeKeyChain) {
    return YES;
  }
  NSString *ref = [self _privateKeyRefName];
  if (accounts) {
    return [accounts containsObject:ref];
  }
  return [__get_keychain() stringForKey:ref] != nil;
}

// The same question for every identity at once, from ONE listing instead of one per row: this is
// asked while building the keys list and while drawing the sync status. Main thread, like every
// other +all-based call: it touches the shared identities array.
+ (NSArray<MoshPubKey *> *)identitiesMissingPrivateMaterial {
  NSSet<NSString *> *accounts = MoshroomKeychainAccounts(__get_keychain());

  NSMutableArray<MoshPubKey *> *missing = [NSMutableArray array];
  for (MoshPubKey *card in [MoshPubKey all]) {
    if (![card _hasPrivateKeyMaterialIn:accounts]) {
      [missing addObject:card];
    }
  }
  return missing;
}

- (BOOL)storeCertificateInKeychain:(nullable NSString *) certificate {
  UICKeyChainStore *keychain = __get_keychain();
  NSString *certRef = [self _certificateKeychainRef];
  if (certificate) {
    if (!__kc_set(keychain, certificate, certRef)) {
      // Refused, and the previous value is back: nothing changed, so nothing is restamped or saved.
      return NO;
    }
    _certType = [MoshPubKey _shortKeyTypeNameFromSshKeyTypeName:[[certificate componentsSeparatedByString:@" "] firstObject]];
  } else {
    [keychain removeItemForKey:certRef];
    _certType = nil;
  }
  // A certificate change is a metadata change: restamp so an iCloud merge tie-breaks in its favour,
  // and persist (certType + lastModified live in the keys blob).
  _lastModified = [NSDate date];
  return [MoshPubKey saveIDS];
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
    // Older records file their private half under an explicit ref; it goes with the identity too.
    if (_privateKeyRef && ![_privateKeyRef isEqualToString:[self _privateKeyKeychainRef]]) {
      [kc removeItemForKey:_privateKeyRef];
    }
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
