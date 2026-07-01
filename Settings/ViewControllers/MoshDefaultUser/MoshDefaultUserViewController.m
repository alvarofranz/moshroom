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

#import "MoshDefaultUserViewController.h"
#import "MoshroomDefaults.h"
@interface MoshDefaultUserViewController ()

@property (nonatomic, weak) IBOutlet UITextField *userNameField;

@end

@implementation MoshDefaultUserViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.userNameField.text = [MoshroomDefaults defaultUserName];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string
{
  if([string isEqualToString:@" "]){
    return NO;
  }
  return YES;
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (void)willMoveToParentViewController:(UIViewController *)parent {
  if(self.userNameField.text != nil && ![self.userNameField.text isEqualToString:@""]){
    NSString *sanitisedName = [self.userNameField.text stringByReplacingOccurrencesOfString:@" " withString:@""];
    [MoshroomDefaults setDefaultUserName:sanitisedName];
    [MoshroomDefaults saveDefaults];
  }
}

@end
