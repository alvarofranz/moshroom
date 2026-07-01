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

#include <stdio.h>
#include <UIKit/UIKit.h>
#include "ios_system/ios_system.h"
#include "ios_error.h"

__attribute__ ((visibility("default")))
int config_main(int argc, char *argv[]) {
  if (argc == 1) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [[UIApplication sharedApplication]
       sendAction:NSSelectorFromString(@"showConfigAction") to:nil from:nil forEvent:nil];
    });
    
    return 0;
  }
  
  if (argc == 3 && [@"delete-activities" isEqual: @(argv[1])]) {
    if (@available(iOS 12.0, *)) {
      NSString *activityKey = @(argv[2]);
      if ([activityKey isEqualToString:@"all"]) {
        [NSUserActivity deleteAllSavedUserActivitiesWithCompletionHandler:^{}];
      } else {
        [NSUserActivity deleteSavedUserActivitiesWithPersistentIdentifiers:@[activityKey] completionHandler:^{}];
      }
    } else {
      puts("delete-activities available for iOS 12 and later.");
    }
  }
  
  return 0;
}
