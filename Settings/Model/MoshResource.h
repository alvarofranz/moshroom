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


@interface MoshResource : NSObject <NSCoding>

@property (nonatomic, strong) NSString *name;
@property (nonatomic, strong) NSString *filename;

+ (NSURL *)resourcesURL;
+ (instancetype)withName:(NSString *)name;
+ (BOOL)saveAll;
+ (instancetype)saveResource:(NSString *)name withContent:(NSData *)content error:(NSError *__autoreleasing *)error;
+ (void)removeResourceAtIndex:(int)index;
+ (NSArray *)all;
+ (NSInteger)count;
// Funcs to return the default and custom arrays, and then counts on top
+ (NSInteger)defaultResourcesCount;
+ (NSMutableArray *)defaultResources;
+ (NSMutableArray *)customResources;

- (BOOL)isCustom;
- (NSString *)fullPath;
- (NSString *)content;

@end
