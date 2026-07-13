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

#import "MoshFont.h"
#import <UIKit/UIKit.h>

@implementation MoshFont

+ (NSString *)resourcesPathName
{
  return @"Fonts";
}

+ (NSString *)resourcesExtension
{
  return @"css";
}

+ (NSArray *)all
{
  return [[
          self.defaultResources
          arrayByAddingObjectsFromArray: [self _systemWideFonts]]
          arrayByAddingObjectsFromArray: self.customResources];
}


+ (NSArray<MoshFont *> *)_systemWideFonts
{
  NSMutableDictionary *map = [[NSMutableDictionary alloc] init];
  NSMutableArray *result = [[NSMutableArray alloc] init];
  for (MoshFont *f in self.defaultResources) {
    map[f.name] = f;
  }
  map[@"Apple Color Emoji"] = @(YES);
  
  NSDictionary *traitsAttributes = @{UIFontSymbolicTrait: @(UIFontDescriptorTraitMonoSpace)};
  NSDictionary *fontAttributes = @{UIFontDescriptorTraitsAttribute: traitsAttributes};
  UIFontDescriptor *fontDescriptor = [UIFontDescriptor fontDescriptorWithFontAttributes:fontAttributes];
  NSArray *array = [fontDescriptor matchingFontDescriptorsWithMandatoryKeys:nil];
  for (UIFontDescriptor *descriptor in array) {
    UIFont *f = [UIFont fontWithDescriptor:descriptor size:10];
    if (map[f.familyName]) {
      continue;
    }
  
    MoshFont * font = [[MoshFont alloc] init];
    font.name = f.familyName;
    font.systemWide = YES;
    map[font.name] = font;
    [result addObject:font];
  }
  
  return result;
}

- (NSString *)content
{
  if (!_systemWide) {
    return [super content];
  }
  
  NSString * css = [
  @[
      @"@font-face {",
      @" font-family: '[[family]]';",
      @" src: local('[[family]]');",
      @" font-weight: normal;",
      @" font-style: normal;",
      @"}",
      @"",
      @"@font-face {",
      @" font-family: '[[family]]';",
      @" src: local('[[family]]');",
      @" font-weight: bold;",
      @" font-style: normal;",
      @"}",
      @"",
      @"@font-face {",
      @" font-family: '[[family]]';",
      @" src: local('[[family]]');",
      @" font-weight: normal;",
      @" font-style: italic;",
      @" }",
      @" ",
      @"@font-face {",
      @" font-family: '[[family]]';",
      @" src: local('[[family]]');",
      @" font-weight: bold;",
      @" font-style: italic;",
      @"}",
      @"",
  ] componentsJoinedByString:@"\n"];
  
  return [css stringByReplacingOccurrencesOfString:@"[[family]]" withString:self.name];
}

-(BOOL)isCustom
{
  if (_systemWide) {
    return YES;
  }
  return [super isCustom];
}

- (BOOL)isEqual:(id)object {
  if ([super isEqual:object]) {
    return YES;
  }
  
  if (![object isKindOfClass:[MoshFont class]]) {
    return NO;
  }
  
  MoshFont *other = (MoshFont *)object;
  
  return [self isCustom] == [other isCustom] && [self.name isEqualToString:other.name];
}


@end
