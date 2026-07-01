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
#import <objc/runtime.h>
#include "ios_patches.h"

void __moshroom_ios_patches(void) {
  // Check to class method of UIPressAndHoldPopoverController
  // Opened Radar so this can be fixed or exposed.
  // We won't implement a different fix because plan is to move away from Hterm.
  // Also an issue on macOS: https://apple.stackexchange.com/questions/332769/macos-disable-popup-showing-accented-characters-when-holding-down-a-key
  Class cls = NSClassFromString(@"UIPressAndHoldPopoverController");
  
  SEL selector = sel_getUid("canPresentPressAndHoldPopoverForEvent:");
  Method method = class_getClassMethod(cls, selector);
  IMP override = imp_implementationWithBlock(^BOOL(id me, void* arg0) {
    return NO;
  });
  method_setImplementation(method, override);
}
