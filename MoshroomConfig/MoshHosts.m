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

#import "MoshHosts.h"
#import "UICKeyChainStore.h"
#import "MoshroomPaths.h"
#import "XCConfig.h"
#import "MoshPubKey.h"
#import <MoshroomConfig/MoshroomConfig-Swift.h>

NSMutableArray *__hosts;

// YES while the hosts blob exists on disk but could not be READ (protected data not available yet).
// Same contract as the keys blob in MoshPubKey.m: an empty list is never written over a file this run
// could not see.
static BOOL __hostsUnreadable = NO;

// Host passwords live under the build's KEYCHAIN_ID1 plus ".pwd" (e.g. com.alvarofranz.moshroom.pwd),
// never a hardcoded foreign namespace. The store and the write that never loses the old value are the
// shared ones in MoshPubKey.m (declared in MoshPubKey.h): when sync is ON passwords ride the iCloud
// Keychain, when OFF they stay on this device, and each item keeps the flavor of its last write.
static UICKeyChainStore *__get_keychain() {
  return MoshroomKeychainStore(@"pwd");
}

static BOOL __kc_set(UICKeyChainStore *keychain, NSString *value, NSString *key) {
  return MoshroomKeychainSetString(keychain, value, key);
}

@implementation MoshHosts

+ (BOOL) supportsSecureCoding {
  return YES;
}

- (id)initWithCoder:(NSCoder *)coder
{
  self = [super init];
  if (!self) {
    return self;
  }
  
  NSSet *strings = [NSSet setWithObjects:NSString.class, nil];
  NSSet *numbers = [NSSet setWithObjects:NSNumber.class, nil];

  _host = [coder decodeObjectOfClasses:strings forKey:@"host"];
  _hostName = [coder decodeObjectOfClasses:strings forKey:@"hostName"];
  _port = [coder decodeObjectOfClasses:numbers forKey:@"port"];
  _user = [coder decodeObjectOfClasses:strings forKey:@"user"];
  _passwordRef = [coder decodeObjectOfClasses:strings forKey:@"passwordRef"];
  _key = [coder decodeObjectOfClasses:strings forKey:@"key"];
  _moshServer = [coder decodeObjectOfClasses:strings forKey:@"moshServer"];
  _moshPredictOverwrite = [coder decodeObjectOfClasses:strings forKey:@"moshPredictOverwrite"];
  _moshExperimentalIP = [coder decodeObjectOfClasses:numbers forKey:@"moshExperimentalIP"];
  _moshPort = [coder decodeObjectOfClasses:numbers forKey:@"moshPort"];
  _moshPortEnd = [coder decodeObjectOfClasses:numbers forKey:@"moshPortEnd"];
  _moshStartup = [coder decodeObjectOfClasses:strings forKey:@"moshStartup"];
  _commandOnConnect = [coder decodeObjectOfClasses:strings forKey:@"commandOnConnect"];
  _hostDescription = [coder decodeObjectOfClasses:strings forKey:@"hostDescription"];
  _useTmux = [coder decodeObjectOfClasses:numbers forKey:@"useTmux"];
  _tmuxSession = [coder decodeObjectOfClasses:strings forKey:@"tmuxSession"];
  _prediction = [coder decodeObjectOfClasses:numbers forKey:@"prediction"];
  _proxyCmd = [coder decodeObjectOfClasses:strings forKey:@"proxyCmd"];
  _proxyJump = [coder decodeObjectOfClasses:strings forKey:@"proxyJump"];
  _sshConfigAttachment = [coder decodeObjectOfClasses:strings forKey:@"sshConfigAttachment"];
  _agentForwardPrompt = [coder decodeObjectOfClasses:numbers forKey:@"agentForwardPrompt"];
  _agentForwardKeys = [coder decodeArrayOfObjectsOfClass:NSString.class forKey:@"agentForwardKeys"];
  _lastModified = [coder decodeObjectOfClasses:[NSSet setWithObjects:NSDate.class, nil] forKey:@"lastModified"];
  return self;
}

- (void)encodeWithCoder:(NSCoder *)encoder
{
  [encoder encodeObject:_host forKey:@"host"];
  [encoder encodeObject:_hostName forKey:@"hostName"];
  [encoder encodeObject:_port forKey:@"port"];
  [encoder encodeObject:_user forKey:@"user"];
  [encoder encodeObject:_passwordRef forKey:@"passwordRef"];
  [encoder encodeObject:_key forKey:@"key"];
  [encoder encodeObject:_moshServer forKey:@"moshServer"];
  [encoder encodeObject:_moshPredictOverwrite forKey:@"moshPredictOverwrite"];
  [encoder encodeObject:_moshExperimentalIP forKey:@"moshExperimentalIP"];
  [encoder encodeObject:_moshPort forKey:@"moshPort"];
  [encoder encodeObject:_moshPortEnd forKey:@"moshPortEnd"];
  [encoder encodeObject:_moshStartup forKey:@"moshStartup"];
  [encoder encodeObject:_commandOnConnect forKey:@"commandOnConnect"];
  [encoder encodeObject:_hostDescription forKey:@"hostDescription"];
  [encoder encodeObject:_useTmux forKey:@"useTmux"];
  [encoder encodeObject:_tmuxSession forKey:@"tmuxSession"];
  [encoder encodeObject:_prediction forKey:@"prediction"];
  [encoder encodeObject:_proxyCmd forKey:@"proxyCmd"];
  [encoder encodeObject:_proxyJump forKey:@"proxyJump"];
  [encoder encodeObject:_sshConfigAttachment forKey:@"sshConfigAttachment"];
  [encoder encodeObject:_agentForwardPrompt forKey:@"agentForwardPrompt"];
  [encoder encodeObject:_agentForwardKeys forKey:@"agentForwardKeys"];
  [encoder encodeObject:_lastModified forKey:@"lastModified"];
}

- (id)initWithAlias:(NSString *)alias
           hostName:(NSString *)hostName
            sshPort:(NSString *)sshPort
               user:(NSString *)user
        passwordRef:(NSString *)passwordRef
            hostKey:(NSString *)hostKey
         moshServer:(NSString *)moshServer
      moshPortRange:(NSString *)moshPortRange
moshPredictOverwrite:(NSString *)moshPredictOverwrite
 moshExperimentalIP:(enum MoshMoshExperimentalIP)moshExperimentalIP
         startUpCmd:(NSString *)startUpCmd
         prediction:(enum MoshMoshPrediction)prediction
           proxyCmd:(NSString *)proxyCmd
          proxyJump:(NSString *)proxyJump
sshConfigAttachment:(NSString *)sshConfigAttachment
 agentForwardPrompt:(enum MoshAgentForward)agentForwardPrompt
   agentForwardKeys:(NSArray<NSString *> *)agentForwardKeys
{
  self = [super init];
  if (self) {
    _host = alias;
    _hostName = hostName;
    if (![sshPort isEqualToString:@""]) {
      _port = [NSNumber numberWithInt:sshPort.intValue];
    }
    _user = user;
    _passwordRef = passwordRef;
    _key = hostKey;
    if (![moshServer isEqualToString:@""]) {
      _moshServer = moshServer;
    }
    if (![moshPredictOverwrite isEqualToString:@""]) {
      _moshPredictOverwrite = moshPredictOverwrite;
    }
    if (![moshPortRange isEqualToString:@""]) {
      NSArray<NSString *> *parts = [moshPortRange componentsSeparatedByString:@":"];
      _moshPort = [NSNumber numberWithInt:parts[0].intValue];
      if (parts.count > 1) {
        _moshPortEnd = [NSNumber numberWithInt:parts[1].intValue];
      }
    }
    _moshStartup = startUpCmd;
    _moshExperimentalIP = [NSNumber numberWithInt:moshExperimentalIP];
    _prediction = [NSNumber numberWithInt:prediction];
    _proxyCmd = proxyCmd;
    _proxyJump = proxyJump;
    _sshConfigAttachment = sshConfigAttachment;
    _agentForwardPrompt = [NSNumber numberWithInt: agentForwardPrompt];
    _agentForwardKeys = agentForwardKeys;
  }
  return self;
}

- (NSString *)password
{
  if (!_passwordRef) {
    return nil;
  } else {
    return [__get_keychain() stringForKey:_passwordRef];
  }
}

+ (instancetype)withHost:(NSString *)aHost
{
  for (MoshHosts *host in __hosts) {
    if ([host->_host isEqualToString:aHost]) {
      return host;
    }
  }
  return nil;
}

+ (NSMutableArray<MoshHosts *> *)all
{
  if (!__hosts.count) {
    [MoshHosts loadHosts];
  }
  return __hosts;
}

+ (NSArray<MoshHosts *> *)allHosts
{
  if (!__hosts.count) {
    [MoshHosts loadHosts];
  }
  return [__hosts copy];
}

+ (NSInteger)count
{
  return [[self all] count];
}

+ (instancetype)saveHost:(NSString *)host
             withNewHost:(NSString *)newHost
                hostName:(NSString *)hostName
                 sshPort:(NSString *)sshPort
                    user:(NSString *)user
                password:(NSString *)password
                 hostKey:(NSString *)hostKey
              moshServer:(NSString *)moshServer
    moshPredictOverwrite:(NSString *)moshPredictOverwrite
      moshExperimentalIP:(enum MoshMoshExperimentalIP)moshExperimentalIP
           moshPortRange:(NSString *)moshPortRange
              startUpCmd:(NSString *)startUpCmd
         commandOnConnect:(NSString *)commandOnConnect
         hostDescription:(NSString *)hostDescription
                 useTmux:(NSNumber *)useTmux
             tmuxSession:(NSString *)tmuxSession
              prediction:(enum MoshMoshPrediction)prediction
                proxyCmd:(NSString *)proxyCmd
               proxyJump:(NSString *)proxyJump
     sshConfigAttachment:(NSString *)sshConfigAttachment
      agentForwardPrompt:(enum MoshAgentForward)agentForwardPrompt
        agentForwardKeys:(NSArray *)agentForwardKeys
{
  MoshHosts *bkHost = [MoshHosts withHost:host];

  // The password, in three cases (the editor only passes a value when the user changed it):
  //   nil   -> unchanged. A password this device cannot read yet (still arriving through the iCloud
  //            Keychain, or the keychain is locked) is NEVER overwritten by an untouched field.
  //   @""   -> cleared on purpose: the stored item goes.
  //   value -> stored under <alias>.pwd; a previous item under another name (a renamed host) goes
  //            only once the new one is safely written.
  UICKeyChainStore *keychain = __get_keychain();
  NSString *oldRef = bkHost.passwordRef.length ? bkHost.passwordRef : nil;
  NSString *pwdRef = oldRef ?: @"";
  NSString *staleRef = nil;
  if (password.length) {
    NSString *newRef = [newHost stringByAppendingString:@".pwd"];
    if (!__kc_set(keychain, password, newRef)) {
      // The keychain refused it and the previous value is back. Saving the rest would tell the user
      // the password was stored when it was not.
      return nil;
    }
    pwdRef = newRef;
    if (oldRef && ![oldRef isEqualToString:newRef]) {
      staleRef = oldRef;
    }
  } else if (password) {
    staleRef = oldRef;
    pwdRef = @"";
  } else if (oldRef && bkHost && ![bkHost.host isEqualToString:newHost]) {
    // Renamed with the password untouched: move it to the new alias's name so a future host that
    // takes the old alias cannot overwrite it. If it cannot be read right now, the old name stays.
    NSString *newRef = [newHost stringByAppendingString:@".pwd"];
    NSString *current = [keychain stringForKey:oldRef];
    if (current && __kc_set(keychain, current, newRef)) {
      pwdRef = newRef;
      staleRef = oldRef;
    }
  }

  if (!bkHost) {
    bkHost = [[MoshHosts alloc] initWithAlias:newHost
                                   hostName:hostName
                                    sshPort:sshPort
                                       user:user
                                passwordRef:pwdRef
                                    hostKey:hostKey
                                 moshServer:moshServer
                              moshPortRange:moshPortRange
                       moshPredictOverwrite:moshPredictOverwrite
                         moshExperimentalIP:moshExperimentalIP
                                 startUpCmd:startUpCmd
                                 prediction:prediction
                                   proxyCmd:proxyCmd
                                  proxyJump:proxyJump
                        sshConfigAttachment:sshConfigAttachment
                         agentForwardPrompt:agentForwardPrompt
                           agentForwardKeys:agentForwardKeys
    ];
    [__hosts addObject:bkHost];
  } else {
    bkHost.host = newHost;
    bkHost.hostName = hostName;
    if (![sshPort isEqualToString:@""]) {
      bkHost.port = [NSNumber numberWithInt:sshPort.intValue];
    } else {
      bkHost.port = nil;
    }
    bkHost.user = user;
    bkHost.passwordRef = pwdRef;
    bkHost.key = hostKey;
    bkHost.moshServer = moshServer;
    bkHost.moshPredictOverwrite = moshPredictOverwrite;
    bkHost.moshExperimentalIP = [NSNumber numberWithInt:moshExperimentalIP];
    bkHost.moshPort = nil;
    bkHost.moshPortEnd = nil;
    if (![moshPortRange isEqualToString:@""]) {
      NSArray<NSString *> *parts = [moshPortRange componentsSeparatedByString:@":"];
      bkHost.moshPort = [NSNumber numberWithInt:parts[0].intValue];
      if (parts.count > 1) {
        bkHost.moshPortEnd = [NSNumber numberWithInt:parts[1].intValue];
      }
    }
    bkHost.moshStartup = startUpCmd;
    bkHost.prediction = [NSNumber numberWithInt:prediction];
    bkHost.proxyCmd = proxyCmd;
    bkHost.proxyJump = proxyJump;
    bkHost.sshConfigAttachment = sshConfigAttachment;
    bkHost.agentForwardPrompt = [NSNumber numberWithInt: agentForwardPrompt];
    bkHost.agentForwardKeys = agentForwardKeys;
  }
  // Applies to both a freshly-created and an edited host (not part of initWithAlias:).
  bkHost.commandOnConnect = commandOnConnect;
  bkHost.hostDescription = hostDescription;
  bkHost.useTmux = useTmux;
  bkHost.tmuxSession = tmuxSession.length > 0 ? tmuxSession : nil;
  bkHost.lastModified = [NSDate date];
  if (![MoshHosts saveHosts]) {
    return nil;
  }
  // Only now, with the host saved pointing at its new ref, can the old item go.
  if (staleRef) {
    [keychain removeItemForKey:staleRef];
  }
  return bkHost;
}

- (void)removePasswordFromKeychain {
  if (_passwordRef.length) {
    [__get_keychain() removeItemForKey:_passwordRef];
  }
  _passwordRef = @"";
}

+ (BOOL)saveHosts {
  return [self saveHostsAndEnforce:false];
}

+ (BOOL)forceSaveHosts {
  return [self saveHostsAndEnforce:true];
}

+ (BOOL)saveHostsAndEnforce:(BOOL)force
{
  // App may start in the background and Hosts file may not load, causing hosts to be empty.
  // Then the user would load the app, and the Hosts would be empty, overwriting a never read hosts file.
  // This way we differentiate if saving is due to user, or part of the UI flow.
  if (!__hosts && !force) {
    return NO;
  }
  // The file is there and this run could not read it: the in-memory list is empty, not the truth.
  if (__hostsUnreadable) {
    NSLog(@"[MoshHosts] Refusing to save: the hosts file exists but could not be read this run");
    return NO;
  }
  
  NSError *error = nil;
  NSData *data = [NSKeyedArchiver archivedDataWithRootObject:__hosts
                                       requiringSecureCoding:YES
                                                       error:&error];
  if (error || !data) {
    NSLog(@"[MoshHosts] Failed to archive hosts to data: %@", error);
    return NO;
  }
  
  // CompleteUntilFirstUserAuthentication (not None): the blob holds connection metadata (aliases,
  // hostnames, users, per-host options, password *references*) — no secrets, but it maps the user's
  // infrastructure, so it should not sit readable at rest before the first unlock. This class still
  // allows background reads once the device has been unlocked once since boot, which is exactly what
  // a background SSH/mosh session needs (same trade-off as the keychain's AfterFirstUnlock).
  BOOL result = [data writeToFile:[MoshroomPaths moshroomHostsFile]
                          options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication
                            error:&error];
  
  if (error || !result) {
    NSLog(@"[MoshHosts] Failed to write data to file: %@", error);
    return NO;
  }
  
  [self saveAllToSSHConfig];

  // Mirror the saved hosts up to iCloud Drive — HostsCloudMirror observes this; a no-op if sync is off.
  [[NSNotificationCenter defaultCenter] postNotificationName:@"MoshroomHostsDidSave" object:nil];

  return result;
}

+ (void)loadHosts {
  __hosts = [[NSMutableArray alloc] init];
  
  NSError *error = nil;
  NSData *data = [NSData dataWithContentsOfFile:[MoshroomPaths moshroomHostsFile]
                                        options:NSDataReadingMappedIfSafe
                                          error:&error];
  
  if (error || !data) {
    // A missing file is a fresh install; anything else is a file this run cannot see yet.
    BOOL missing = [error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileReadNoSuchFileError;
    __hostsUnreadable = !missing;
    NSLog(@"[MoshHosts] Failed to load data: %@", error);
    return;
  }
  __hostsUnreadable = NO;
  NSArray *result =
    [NSKeyedUnarchiver unarchivedArrayOfObjectsOfClass:[MoshHosts class]
                                              fromData:data
                                                 error:&error];
  
  if (error || !result) {
    NSLog(@"[MoshHosts] Failed to unarchive data: %@", error);
    // Keep the bytes before anything can overwrite them: a copy beside the file, made once.
    NSString *aside = [[MoshroomPaths moshroomHostsFile] stringByAppendingString:@".unreadable"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:aside]) {
      [data writeToFile:aside options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
    }
    return;
  }
  
  __hosts = [result mutableCopy];
}

@end
