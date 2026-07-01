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

#import "MoshUserConfigurationManager.h"
#import "MoshroomDefaults.h"

NSString *const MoshUserConfigAutoLock = @"autoLock";
NSString *const MoshUserConfigChangedNotification = @"MoshUserConfigChangedNotification";


@implementation MoshUserConfigurationManager

+ (void)setUserSettingsValue:(BOOL)value forKey:(NSString *)key
{
  NSMutableDictionary *userSettings = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] objectForKey:@"userSettings"]];
  if (userSettings == nil) {
    userSettings = [NSMutableDictionary dictionary];
  }
  [userSettings setObject:[NSNumber numberWithBool:value] forKey:key];
  [[NSUserDefaults standardUserDefaults] setObject:userSettings forKey:@"userSettings"];
  
  [[NSNotificationCenter defaultCenter] postNotificationName:MoshUserConfigChangedNotification object:nil];
}

+ (BOOL)userSettingsValueForKey:(NSString *)key
{
  NSDictionary *userSettings = [[NSUserDefaults standardUserDefaults] objectForKey:@"userSettings"];
  if (userSettings != nil) {
    if ([userSettings objectForKey:key]) {
      NSNumber *value = [userSettings objectForKey:key];
      return value.boolValue;
    } else {
      return NO;
    }
  } else {
    return NO;
  }
  return NO;
}


+ (NSString *)UIKeyModifiersToString:(UIKeyModifierFlags) flags
{
  NSMutableArray *components = [[NSMutableArray alloc] init];
  
  if ((flags & UIKeyModifierShift) == UIKeyModifierShift) {
    [components addObject:@"⇧"];
  }
  
  if ((flags & UIKeyModifierControl) == UIKeyModifierControl) {
    [components addObject:@"⌃"];
  }
  
  if ((flags & UIKeyModifierAlternate) == UIKeyModifierAlternate) {
    [components addObject:@"⌥"];
  }
  
  if ((flags & UIKeyModifierCommand) == UIKeyModifierCommand) {
    [components addObject:@"⌘"];
  }
  
  return [components componentsJoinedByString:@""];
}
@end
