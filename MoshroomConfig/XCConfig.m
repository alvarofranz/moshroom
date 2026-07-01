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


#import "XCConfig.h"

@implementation XCConfig

+ (NSString *)_valueForKey:(NSString *)key {
  NSBundle *bundle = [NSBundle bundleForClass:[XCConfig self]];
  return [bundle objectForInfoDictionaryKey:key];
}

+ (NSString *) infoPlistRevCatPubliKey {
  return [self _valueForKey:@"MOSHROOM_REVCAT_PUBKEY"];
}

+ (NSString *) infoPlistWhatsNewURL {
  return [self _valueForKey:@"MOSHROOM_WHATS_NEW_URL"];
}

+ (NSString *) infoPlistWhatsNewGithubURL {
  return [self _valueForKey:@"MOSHROOM_WHATS_NEW_GITHUB_URL"];
}

+ (NSString *) infoPlistConversionOpportunityURL {
  return [self _valueForKey:@"MOSHROOM_CONVERSION_OPPORTUNITY_URL"];
}

+ (NSString *) infoPlistKeyChainID1 {
  return [self _valueForKey:@"MOSHROOM_KEYCHAIN_ID1"];
}

+ (NSString *) infoPlistCloudID {
  return [self _valueForKey:@"MOSHROOM_CLOUD_ID"];
}

+ (NSString *) infoPlistFullCloudID {
  return [NSString stringWithFormat:@"iCloud.%@", [self infoPlistCloudID]];
}

+ (NSString *) infoPlistGroupID {
  return [self _valueForKey:@"MOSHROOM_GROUP_ID"];
}

+ (NSString *) infoPlistFullGroupID {
  return [NSString stringWithFormat:@"group.%@", [self infoPlistGroupID]];
}


@end
