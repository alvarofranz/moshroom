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

#import <UIKit/UIKit.h>

#import "MoshLinkActions.h"
#import "openurl.h"

@implementation MoshLinkActions

// Base of the Moshroom project on GitHub. `location` is an optional sub-path
// (e.g. "discussions", "issues"); pass nil to open the repository root.
+ (void)sendToGitHub:(NSString *)location {
  NSURLComponents *components = [NSURLComponents componentsWithString:@"https://github.com/alvarofranz/moshroom"];

  if (location) {
    NSString *fullURLString = [NSString stringWithFormat:@"%@/%@", components.string, location];
    components = [NSURLComponents componentsWithString:fullURLString];
  }

  moshroom_openurl(components.URL);
}

@end
