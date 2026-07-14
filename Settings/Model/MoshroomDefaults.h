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

#import <MoshroomConfig/MoshroomConfig-Swift.h>


extern NSString *const MoshAppearanceChanged;

typedef NS_ENUM(NSInteger, MoshLayoutMode) {
  MoshLayoutModeDefault = 0,
  MoshLayoutModeFill, // Fit screen
  MoshLayoutModeCover, //  Cover screen
  MoshLayoutModeSafeFit, // Honors safe layout guides
};


@interface MoshroomDefaults : NSObject <NSSecureCoding>

@property (nonatomic, strong) NSString *themeName;
@property (nonatomic, strong) NSString *fontName;
@property (nonatomic, strong) NSNumber *fontSize;
@property (nonatomic, strong) NSString *defaultUser;
@property (nonatomic, strong) MoshGlobalSSHConfig *globalSSHConfig;
@property (nonatomic) BOOL cursorBlink;
@property (nonatomic) NSUInteger enableBold;
@property (nonatomic) BOOL boldAsBright;
@property (nonatomic) MoshLayoutMode layoutMode;
@property (nonatomic) BOOL disableCustomKeyboards;
@property (nonatomic) BOOL playSoundOnBell;
@property (nonatomic) BOOL notificationOnBellUnfocused;
@property (nonatomic) BOOL hapticFeedbackOnBellOff;
@property (nonatomic) BOOL oscNotifications;
@property (nonatomic) BOOL invertVerticalScroll;
@property (nonatomic) BOOL iCloudSyncEnabled;
@property (nonatomic) BOOL requireBiometricUnlock;
@property (nonatomic, strong) NSString *scratchLanguageMode;

+ (void)loadDefaults NS_SWIFT_NAME(loadDefaults());
+ (BOOL)saveDefaults NS_SWIFT_NAME(save());
+ (void)setCursorBlink:(BOOL)state;
+ (void)setBoldAsBright:(BOOL)state;
+ (void)setEnableBold:(NSUInteger)state;
+ (void)setDisableCustomKeyboards:(BOOL)state;
+ (void)setFontName:(NSString *)fontName;
+ (void)setThemeName:(NSString *)themeName;
+ (void)setFontSize:(NSNumber *)fontSize;
+ (void)setPlaySoundOnBell:(BOOL)state;
+ (void)setNotificationOnBellUnfocused:(BOOL)state;
+ (void)setHapticFeedbackOnBellOff:(BOOL)state;
+ (void)setOscNotifications:(BOOL)state;
+ (void)setInvertedVerticalScroll:(BOOL) state;
+ (void)setICloudSyncEnabled:(BOOL)state;
+ (void)setRequireBiometricUnlock:(BOOL)state;
+ (BOOL)isRequireBiometricUnlock;
+ (NSString *)selectedFontName;
+ (NSString *)selectedThemeName;
+ (NSNumber *)selectedFontSize;
+ (BOOL)isCursorBlink;
+ (NSUInteger)enableBold;
+ (BOOL)isBoldAsBright;
+ (BOOL)disableCustomKeyboards;
+ (void)setDefaultUserName:(NSString*)name;
+ (void)saveGlobalSSHConfig;
+ (NSString*)defaultUserName;
+ (MoshLayoutMode)layoutMode;
+ (BOOL)isPlaySoundOnBellOn;
+ (BOOL)isNotificationOnBellUnfocusedOn;
+ (BOOL)hapticFeedbackOnBellOff;
+ (BOOL)isOscNotificationsOn;
+ (BOOL)doInvertVerticalScroll;
+ (BOOL)isICloudSyncEnabled;
+ (void)setScratchLanguageMode:(NSString *)mode;
+ (NSString *)scratchLanguageMode;



// Direct access to the raw persisted instance.
// Used by migrators that need to read/reset legacy values.
// At one point MoshDefaults should lose its methods and the Migrators should own the structure
// for compatibility purposes.

@end
