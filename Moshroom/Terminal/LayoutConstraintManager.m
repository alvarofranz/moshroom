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

#import "LayoutConstraintManager.h"
#import "DeviceInfo.h"
#import <Moshroom-Swift.h>

@interface LayoutConstraintManager ()

@property (nonatomic, weak) UIView *managedView;
@property (nonatomic, weak) UIKeyboardLayoutGuide *keyboardGuide;
@property (nonatomic, assign) MoshLayoutMode currentLayoutMode;
@property (nonatomic, assign) BOOL isLayoutLocked;
@property (nonatomic, assign) CGRect lockedFrame;

// Constraint properties
@property (nonatomic, strong) NSLayoutConstraint *topConstraint;
@property (nonatomic, strong) NSLayoutConstraint *leadingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *trailingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *bottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *bottomToKeyboardConstraint;
@property (nonatomic, strong) NSLayoutConstraint *minHeightConstraint;


@end

@implementation LayoutConstraintManager

+ (instancetype)managerForView:(UIView *)view 
                    layoutMode:(MoshLayoutMode)mode 
                keyboardGuide:(UIKeyboardLayoutGuide *)keyboardGuide {
    LayoutConstraintManager *manager = [[LayoutConstraintManager alloc] init];
    manager.managedView = view;
    manager.keyboardGuide = keyboardGuide;
    manager.currentLayoutMode = mode;
    manager.isLayoutLocked = NO;
    
    [manager setupConstraints];
    [manager updateConstraintsForCurrentState];
    
    return manager;
}

- (void)setupConstraints {
    if (!self.managedView) return;
    
    UIView *view = self.managedView;
    UIView *superview = view.superview;
    if (!superview) return;
    
    // Set up autoresizing mask
    view.translatesAutoresizingMaskIntoConstraints = NO;
    
    // Create constraints
    self.topConstraint = [view.topAnchor constraintEqualToAnchor:superview.topAnchor];
    self.leadingConstraint = [view.leadingAnchor constraintEqualToAnchor:superview.leadingAnchor];
    self.trailingConstraint = [view.trailingAnchor constraintEqualToAnchor:superview.trailingAnchor];
    
  self.bottomConstraint =
    [view.bottomAnchor constraintLessThanOrEqualToAnchor:superview.bottomAnchor constant:0];
  self.bottomConstraint.priority = UILayoutPriorityRequired; // 1000

  // Keyboard constraint
  if (self.keyboardGuide) {
      self.bottomToKeyboardConstraint =
        [view.bottomAnchor constraintEqualToAnchor:self.keyboardGuide.topAnchor];
      self.bottomToKeyboardConstraint.priority = UILayoutPriorityDefaultHigh; // 750 or 999

      // Optional: minimum height to avoid collapse
      self.minHeightConstraint =
        [view.heightAnchor constraintGreaterThanOrEqualToConstant:50];
      self.minHeightConstraint.priority = UILayoutPriorityRequired;
  }
    
    // Activate all constraints
    NSMutableArray *constraintsToActivate = [NSMutableArray arrayWithObjects:
        self.topConstraint,
        self.leadingConstraint,
        self.trailingConstraint,
        self.bottomConstraint,
        nil];
    
    if (self.bottomToKeyboardConstraint) {
        [constraintsToActivate addObject:self.bottomToKeyboardConstraint];
      [constraintsToActivate addObject: self.minHeightConstraint];
    }
    
    [NSLayoutConstraint activateConstraints:constraintsToActivate];
}

- (void)updateLayoutMode:(MoshLayoutMode)mode {
    if (self.isLayoutLocked) return; // Don't update if locked
    
    self.currentLayoutMode = mode;
    [self updateConstraintsForCurrentState];
}

- (void)setLayoutLocked:(BOOL)locked withFrame:(CGRect)frame {
    self.isLayoutLocked = locked;
    self.lockedFrame = frame;
    
    if (locked) {
        // Store current constraint values as locked frame
        [self updateConstraintsForLockedFrame];
    } else {
        // Restore to normal layout mode behavior
        [self updateConstraintsForCurrentState];
    }
}

- (void)updateConstraintsForCurrentState {
    if (self.isLayoutLocked) {
        [self updateConstraintsForLockedFrame];
        return;
    }
    
    UIEdgeInsets insets = [self calculateInsetsForLayoutMode:self.currentLayoutMode];
    
    self.topConstraint.constant = insets.top;
    self.leadingConstraint.constant = insets.left;
    self.trailingConstraint.constant = -insets.right;
    self.bottomConstraint.constant = -insets.bottom;
}

- (void)updateConstraintsForLockedFrame {
    if (CGRectIsEmpty(self.lockedFrame)) return;
    
    UIView *superview = self.managedView.superview;
    if (!superview) return;
    
    // Calculate insets based on locked frame
    CGFloat top = self.lockedFrame.origin.y;
    CGFloat left = self.lockedFrame.origin.x;
    CGFloat right = superview.bounds.size.width - CGRectGetMaxX(self.lockedFrame);
    CGFloat bottom = superview.bounds.size.height - CGRectGetMaxY(self.lockedFrame);
    
    self.topConstraint.constant = top;
    self.leadingConstraint.constant = left;
    self.trailingConstraint.constant = -right;
    self.bottomConstraint.constant = -bottom;
}

- (UIEdgeInsets)calculateInsetsForLayoutMode:(MoshLayoutMode)mode {
    UIView *view = self.managedView;
    UIWindow *window = view.window;
    if (!window) return UIEdgeInsetsZero;

    UIScreen *mainScreen = UIScreen.mainScreen;
    if (mainScreen != window.screen) {
        return window.safeAreaInsets;
    }
    
    // Moshroom uses a single terminal layout. SpaceController already pins the viewport
    // inside the safe area and reserves room for the floating Moshkeys bars (top + bottom),
    // so here we only add a small uniform margin so glyphs never sit flush against the edges.
    CGFloat margin = 6;
    return UIEdgeInsetsMake(margin, margin, margin, margin);
}


+ (MoshLayoutMode) deviceDefaultLayoutMode {
  DeviceInfo *device = [DeviceInfo shared];
  if (device.hasNotch) {
    return MoshLayoutModeSafeFit;
  }
  
  if (device.hasCorners) {
    return MoshLayoutModeFill;
  }
  
  return MoshLayoutModeCover;
}

@end
