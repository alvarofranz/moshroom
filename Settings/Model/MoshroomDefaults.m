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

#import "MoshroomDefaults.h"
#import "MoshFont.h"
#import "UIDevice+DeviceName.h"
#import "MoshroomPaths.h"
#import "DeviceInfo.h"
#import "Moshroom-Swift.h"
#import "LayoutConstraintManager.h"
#import <MoshroomConfig/XCConfig.h>


MoshroomDefaults *defaults;

NSString *const MoshAppearanceChanged = @"MoshAppearanceChanged";

// Mirror the "Sync with iCloud" flag into the app-group user defaults so MoshroomConfig
// (MoshHosts/MoshPubKey) can read it synchronously without importing this class — that would be a
// dependency cycle. The vault/2FA stores in the app target read the same key. Kept in lockstep with
// kMoshroomICloudSyncEnabledKey in MoshHosts.m / MoshPubKey.m.
static void __mirrorICloudSyncFlag(BOOL enabled) {
  NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:[XCConfig infoPlistFullGroupID]];
  [d setBool:enabled forKey:@"MoshroomICloudSyncEnabled"];
}

@implementation MoshroomDefaults

#pragma mark - NSCoding

- (id)init
{
  self = [super init];
  if (!self) {
    return self;
  }
  

  return self;
}

- (id)initWithCoder:(NSCoder *)coder
{
  self = [super init];
  if (!self) {
    return self;
  }
  NSSet *strings = [NSSet setWithObjects:NSString.class, nil];
  NSSet *numbers = [NSSet setWithObjects:NSNumber.class, nil];
  
  
  _themeName = [coder decodeObjectOfClasses:strings forKey:@"themeName"];
  _fontName = [coder decodeObjectOfClasses:strings forKey:@"fontName"];
  _fontSize = [coder decodeObjectOfClasses:numbers forKey:@"fontSize"];
  _defaultUser = [coder decodeObjectOfClasses:strings forKey:@"defaultUser"];
  _globalSSHConfig = [coder decodeObjectOfClasses: [NSSet setWithObjects: [MoshGlobalSSHConfig class], nil] forKey:@"globalSSHConfig"];
  _cursorBlink = [coder decodeBoolForKey:@"cursorBlink"];
  _enableBold = [coder decodeIntegerForKey:@"enableBold"];
  _boldAsBright = [coder decodeBoolForKey:@"boldAsBright"];
  _layoutMode = (MoshLayoutMode)[coder decodeIntegerForKey:@"layoutMode"];
  _disableCustomKeyboards = [coder decodeBoolForKey:@"disableCustomKeyboards"];
  _playSoundOnBell = [coder decodeBoolForKey:@"playSoundOnBell"];
  _notificationOnBellUnfocused = [coder decodeBoolForKey:@"notificationOnBellUnfocused"];
  _hapticFeedbackOnBellOff = [coder decodeBoolForKey:@"hapticFeedbackOnBellOff"];
  _oscNotifications = [coder decodeBoolForKey:@"oscNotifications"];
  _invertVerticalScroll = [coder decodeBoolForKey:@"invertVerticalScroll"];

  _iCloudSyncEnabled = [coder decodeBoolForKey:@"iCloudSyncEnabled"];
  _requireBiometricUnlock = [coder decodeBoolForKey:@"requireBiometricUnlock"];
  _scratchLanguageMode = [coder decodeObjectOfClass:[NSString class] forKey:@"scratchLanguageMode"];

  return self;
}

- (void)encodeWithCoder:(NSCoder *)encoder
{
  [encoder encodeObject:_themeName forKey:@"themeName"];
  [encoder encodeObject:_fontName forKey:@"fontName"];
  [encoder encodeObject:_fontSize forKey:@"fontSize"];
  [encoder encodeObject:_defaultUser forKey:@"defaultUser"];
  [encoder encodeObject:_globalSSHConfig forKey:@"globalSSHConfig"];
  [encoder encodeBool:_cursorBlink forKey:@"cursorBlink"];
  [encoder encodeInteger:_enableBold forKey:@"enableBold"];
  [encoder encodeBool:_boldAsBright forKey:@"boldAsBright"];
  [encoder encodeInteger:_layoutMode forKey:@"layoutMode"];
  [encoder encodeBool:_disableCustomKeyboards forKey:@"disableCustomKeyboards"];
  [encoder encodeBool:_playSoundOnBell forKey:@"playSoundOnBell"];
  [encoder encodeBool:_notificationOnBellUnfocused forKey:@"notificationOnBellUnfocused"];
  [encoder encodeBool:_hapticFeedbackOnBellOff forKey:@"hapticFeedbackOnBellOff"];
  [encoder encodeBool:_oscNotifications forKey:@"oscNotifications"];
  [encoder encodeBool:_invertVerticalScroll forKey:@"invertVerticalScroll"];
  [encoder encodeBool:_iCloudSyncEnabled forKey:@"iCloudSyncEnabled"];
  [encoder encodeBool:_requireBiometricUnlock forKey:@"requireBiometricUnlock"];
  [encoder encodeObject:_scratchLanguageMode forKey:@"scratchLanguageMode"];

}

+ (BOOL)supportsSecureCoding {
  return YES;
}

+ (BOOL)saveDefaults {
  NSError *error = nil;
  NSData *data = [NSKeyedArchiver archivedDataWithRootObject:defaults
                                       requiringSecureCoding:YES
                                                       error:&error];
  
  if (error || !data) {
    NSLog(@"[MoshroomDefaults] Failed to archive: %@", error);
    return NO;
  }
  
  BOOL result = [data writeToFile:[MoshroomPaths moshroomDefaultsFile]
                          options:NSDataWritingAtomic | NSDataWritingFileProtectionNone
                            error:&error];
  
  if (error || !result) {
    NSLog(@"[MoshroomDefaults] Failed to save data to file: %@", error);
    return NO;
  }
  
  [MoshroomDefaults saveGlobalSSHConfig];
  
  return result;
}


+ (void)loadDefaults {
  defaults = [[MoshroomDefaults alloc] init];
  
  NSError *error = nil;
  NSData *data = [NSData dataWithContentsOfFile:[MoshroomPaths moshroomDefaultsFile]
                                        options:NSDataReadingMappedIfSafe
                                          error:&error];
  
  if (error || !data) {
    NSLog(@"[MoshroomDefaults] Failed to load data: %@", error);
  } else {
    MoshroomDefaults * result = [NSKeyedUnarchiver unarchivedObjectOfClass:[MoshroomDefaults class]
                                                            fromData:data
                                                               error:&error];
    if (error || !result) {
      NSLog(@"[MoshroomDefaults] Failed to unarchive: %@", error);
//      CFStringRef str = CFStringCreateWithBytesNoCopy(NULL, data.bytes, data.length, kCFStringEncodingASCII, NO, kCFAllocatorNull);
//      CFRange range = CFStringFind(str, CFSTR("classnameX$classesZBKDefaults"), 0);
//      CFRelease(str);
//      if (range.location > 0 && range.length > 0) {
      
      NSLog(@"[MoshroomDefaults] try again with MoshDefaults replacement");
      error = nil;
      [NSKeyedUnarchiver setClass:[MoshroomDefaults class] forClassName:@"MoshDefaults"];
      result = [NSKeyedUnarchiver unarchivedObjectOfClass:[MoshroomDefaults class]
                                                              fromData:data
                                                                 error:&error];
      if (error || ! result) {
        NSLog(@"[MoshroomDefaults] Failed again to unarchive with MoshDefaults replacement: %@", error);
      } else {
        NSLog(@"[MoshroomDefaults] loaded with MoshDefaults replacement");
        defaults = result;
      }
    } else {
      defaults = result;
    }
  }
  
  if (defaults.layoutMode == MoshLayoutModeDefault) {
    defaults.layoutMode = [LayoutConstraintManager deviceDefaultLayoutMode];
  }

  if (!defaults.fontName) {
    if ([MoshFont withName:@"Pragmata Pro Mono"] != nil) {
      [defaults setFontName:@"Pragmata Pro Mono"];
    } else {
      [defaults setFontName:@"Source Code Pro"];
    }
  }
  if (!defaults.themeName) {
    [defaults setThemeName:@"Default"];
  }
  
  if (!defaults.fontSize) {
    #if TARGET_OS_MACCATALYST
      [defaults setFontSize:[NSNumber numberWithInt:22]];
    #else
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
      [defaults setFontSize:[NSNumber numberWithInt:18]];
    } else {
      [defaults setFontSize:[NSNumber numberWithInt:10]];
    }
    #endif
  }
  if(!defaults.defaultUser || ![[defaults.defaultUser stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length]){
    [defaults setDefaultUser:[UIDevice getInfoTypeFromDeviceName:MoshDeviceInfoTypeUserName]];
  }

  if(!defaults.globalSSHConfig) {
    [MoshroomDefaults saveGlobalSSHConfig];
  }

  // Publish the loaded sync flag to the app group so MoshroomConfig sees the authoritative value
  // from the very first keychain access this launch.
  __mirrorICloudSyncFlag(defaults.iCloudSyncEnabled);
}

+ (void)setCursorBlink:(BOOL)state
{
  [TerminalStyleStore.shared setStyleCursorBlink:state];
}

+ (void)setFontName:(NSString *)fontName
{
  [TerminalStyleStore.shared setStyleFontName:fontName];
}

+ (void)setThemeName:(NSString *)themeName
{
  [TerminalStyleStore.shared setStyleThemeName:themeName];
}

+ (void)setFontSize:(NSNumber *)fontSize
{
  [TerminalStyleStore.shared setStyleFontSize:fontSize];
}

+ (void)setDefaultUserName:(NSString*)name
{
  defaults.defaultUser = name;
}

+ (void)saveGlobalSSHConfig
{
  MoshGlobalSSHConfig *config = [[MoshGlobalSSHConfig alloc] initWithUser: defaults.defaultUser];
  [config saveFile];
}

+ (void)setDisableCustomKeyboards:(BOOL)state {
  defaults.disableCustomKeyboards = state;
}

+ (void)setPlaySoundOnBell:(BOOL)state {
  defaults.playSoundOnBell = state;
}

+ (void)setNotificationOnBellUnfocused:(BOOL)state {
  defaults.notificationOnBellUnfocused = state;
}

+ (void)setHapticFeedbackOnBellOff:(BOOL)state {
  defaults.hapticFeedbackOnBellOff = state;
}

+ (void)setOscNotifications:(BOOL)state {
  defaults.oscNotifications = state;
}

+ (void)setICloudSyncEnabled:(BOOL)state {
  defaults.iCloudSyncEnabled = state;
  __mirrorICloudSyncFlag(state);
}

+ (void)setRequireBiometricUnlock:(BOOL)state {
  defaults.requireBiometricUnlock = state;
}

+ (BOOL)isRequireBiometricUnlock {
  return defaults.requireBiometricUnlock;
}

+ (void)setScratchLanguageMode:(NSString *)mode {
  defaults.scratchLanguageMode = mode;
}


+ (NSString *)selectedFontName
{
  return TerminalStyleStore.shared.bridgedFontName;
}
+ (NSString *)selectedThemeName
{
  return TerminalStyleStore.shared.bridgedThemeName;
}

+ (NSNumber *)selectedFontSize
{
  return TerminalStyleStore.shared.bridgedFontSize;
}

+ (BOOL)isCursorBlink
{
  return TerminalStyleStore.shared.bridgedCursorBlink;
}

+ (NSUInteger)enableBold
{
  return TerminalStyleStore.shared.bridgedEnableBold;
}

+ (BOOL)isBoldAsBright
{
  return TerminalStyleStore.shared.bridgedBoldAsBright;
}

+ (NSString*)defaultUserName
{
  return defaults.defaultUser;
}

+ (MoshLayoutMode)layoutMode
{
  return defaults.layoutMode;
}

+ (BOOL)disableCustomKeyboards {
  return defaults.disableCustomKeyboards;
}

+ (BOOL)isPlaySoundOnBellOn {
  return defaults.playSoundOnBell;
}

+ (BOOL)isNotificationOnBellUnfocusedOn {
  return defaults.notificationOnBellUnfocused;
}

+ (BOOL)hapticFeedbackOnBellOff {
  return defaults.hapticFeedbackOnBellOff;
}

+ (BOOL)isOscNotificationsOn {
  return defaults.oscNotifications;
}

+ (BOOL)doInvertVerticalScroll {
  return defaults.invertVerticalScroll;
}

+ (BOOL)isICloudSyncEnabled {
  return defaults.iCloudSyncEnabled;
}

+ (NSString *)scratchLanguageMode {
  return defaults.scratchLanguageMode ?: @"shell";
}


@end
