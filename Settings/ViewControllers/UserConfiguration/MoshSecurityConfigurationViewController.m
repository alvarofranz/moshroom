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

#import "MoshSecurityConfigurationViewController.h"
#import "MoshUserConfigurationManager.h"
#import "Moshroom-Swift.h"

//MARK: - Private properties and outlets for the view controller
@interface MoshSecurityConfigurationViewController ()

@property (nonatomic, weak) IBOutlet UISwitch *toggleAppLock;
@property (weak, nonatomic) IBOutlet UIButton *customLockButton;
@property (weak, nonatomic) IBOutlet UITableViewCell *customLockTableViewCell;

@end

@implementation MoshSecurityConfigurationViewController


//MARK: - Lifecycle
- (void)viewDidLoad {
  [super viewDidLoad];
  
  ///Load the user settings and set the initial state of the toggle switch
  [_toggleAppLock setOn:[MoshUserConfigurationManager userSettingsValueForKey:MoshUserConfigAutoLock]];
  
  ///Show initial Lock TimeInterval
  [self.customLockButton setTitle:[NSString stringWithFormat:@"%ld minutes", (long)[LocalAuth.shared getMaxMinutesTimeInterval]] forState:UIControlStateNormal];
  
  ///Initially hide the customLockTableViewCell
  _customLockTableViewCell.hidden = YES;
  
  ///Check if auto-lock is enabled, and show the customLockTableViewCell accordingly
  if ([MoshUserConfigurationManager userSettingsValueForKey:MoshUserConfigAutoLock]) {
    _customLockTableViewCell.hidden = NO;
  }
  
  ///Set up the custom lock menu
  [self setupCustomLockMenu];
}


//MARK: - IBActions
- (IBAction)didToggleSwitch:(UISwitch *)toggleSwitch {
  BOOL isOn = toggleSwitch.isOn;
  
  ///Authenticate using LocalAuth
  [[LocalAuth shared] authenticateWithCallback:^(BOOL success) {
    if (success) {
      
      ///Update the user settings and set the customLockButton title
      [MoshUserConfigurationManager setUserSettingsValue:isOn forKey:MoshUserConfigAutoLock];
      [_customLockButton setTitle:@"10 minutes" forState:UIControlStateNormal];
    } else {
      
      ///If authentication fails, toggle the switch back to its previous state
      toggleSwitch.on = !isOn;
    }
    
    ///Toggle the visibility of customLockTableViewCell based on the switch state
    _customLockTableViewCell.hidden = !isOn;
    
  } reason: isOn ? @"to turn off auto lock." : @"to turn on auto lock."];
}


//MARK: - Handle the selection of auto-lock time from the menu
- (void)setNewAutoLockTimeUI:(UIAction *)action API_AVAILABLE(ios(13.0)) {
  NSString *title = action.title;
  
  ///Update the customLockButton title based on the selected time
  [_customLockButton setTitle:title forState:UIControlStateNormal];
}


//MARK: - Set up the custom lock menu with actions for different time intervals
- (void)setupCustomLockMenu {
  UIAction *oneMinuteAction = [UIAction actionWithTitle:@"1 minute" image:nil identifier:nil handler:^(__kindof UIAction * _Nonnull action) {
    [self setNewAutoLockTimeUI:action];
    [[LocalAuth shared] setNewLockTimeIntervalWithMinutes: 1];
  }];
  
  UIAction *fiveMinutesAction = [UIAction actionWithTitle:@"5 minutes" image:nil identifier:nil handler:^(__kindof UIAction * _Nonnull action) {
    [self setNewAutoLockTimeUI:action];
    [[LocalAuth shared] setNewLockTimeIntervalWithMinutes: 5];
  }];
  
  UIAction *tenMinutesAction = [UIAction actionWithTitle:@"10 minutes" image:nil identifier:nil handler:^(__kindof UIAction * _Nonnull action) {
    [self setNewAutoLockTimeUI:action];
    [[LocalAuth shared] setNewLockTimeIntervalWithMinutes: 10];
  }];
  
  NSArray<UIAction *> *additionalActions = @[oneMinuteAction, fiveMinutesAction, tenMinutesAction];
  
  ///Create a UIMenu with the specified actions and set it to the customLockButton
  UIMenu *customLockMenu = [UIMenu menuWithTitle:@"" children:additionalActions];
  
  [_customLockButton setMenu:customLockMenu];
  [_customLockButton setShowsMenuAsPrimaryAction:YES];
}

@end
