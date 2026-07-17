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
#import "MoshroomDefaults.h"

NS_ASSUME_NONNULL_BEGIN

@class LayoutConstraintManager;

@interface LayoutConstraintManager : NSObject

// Setup constraints for a view with layout mode and keyboard guide
+ (instancetype)managerForView:(UIView *)view 
                    layoutMode:(MoshLayoutMode)mode 
                keyboardGuide:(UIKeyboardLayoutGuide *)keyboardGuide;

+ (MoshLayoutMode) deviceDefaultLayoutMode;

// Update layout mode
- (void)updateLayoutMode:(MoshLayoutMode)mode;

// Handle layout lock
- (void)setLayoutLocked:(BOOL)locked withFrame:(CGRect)frame;

// Note: Keyboard handling is now automatic via constraint priorities

// Update keyboard layout guide (for window changes)
- (void)updateKeyboardLayoutGuide:(nullable UIKeyboardLayoutGuide *)keyboardGuide;

// Get current constraint constants for debugging

@end

NS_ASSUME_NONNULL_END
