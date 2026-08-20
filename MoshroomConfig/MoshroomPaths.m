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

#import "MoshroomPaths.h"
#import "XCConfig.h"

@implementation MoshroomPaths

NSString *__homePath = nil;
NSString *__documentsPath = nil;
NSString *__groupContainerPath = nil;
NSString *__iCloudsDriveDocumentsPath = nil;

+ (NSString *)homePath {
  if (__homePath == nil) {
    __homePath = [[self groupContainerPath] stringByAppendingPathComponent:@"home"];
  }

  return __homePath;
}

+ (NSURL *)homeURL
{
  return [NSURL fileURLWithPath:[self homePath]];
}

+ (NSString *)documentsPath
{
  if (__documentsPath == nil) {
    __documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    // Linked and resolved files has prefix /private
    if (![__documentsPath hasPrefix:@"/private"]) {
      __documentsPath = [@"/private" stringByAppendingString:__documentsPath];
    }
  }
  return __documentsPath;
}

+ (NSString *)groupContainerPath {
  if (__groupContainerPath == nil) {

    NSString *groupID = [XCConfig infoPlistFullGroupID];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = [fm containerURLForSecurityApplicationGroupIdentifier:groupID].path;
    __groupContainerPath = path;
  }
  return __groupContainerPath;
}

+ (NSString *)iCloudDriveDocuments
{
  if (__iCloudsDriveDocumentsPath == nil) {
    NSString *iCloudID = [XCConfig infoPlistFullCloudID];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = [[fm URLForUbiquityContainerIdentifier:iCloudID] URLByAppendingPathComponent:@"Documents"].path;
    [self _ensureFolderAtPath:path];
    __iCloudsDriveDocumentsPath = path;
  }

  return __iCloudsDriveDocumentsPath;
}

+ (void)linkICloudDriveIfNeeded
{
  [self _linkAtPath:[[self homePath] stringByAppendingPathComponent:@"iCloud"]
    destinationPath:[self iCloudDriveDocuments]];
}

+ (void)linkDocumentsIfNeeded {
  [self _linkAtPath:[[self homePath] stringByAppendingPathComponent:@"Documents"]
    destinationPath:[self documentsPath]];
}

+ (void)_linkAtPath:(NSString *)path destinationPath:(NSString *)destinationPath {
  NSFileManager *fm = [NSFileManager defaultManager];
  
  // Don't use fileExists as that would traverse the symlink.
  if ([fm attributesOfItemAtPath:path error:nil]) {
    NSString *currentDestinationPath = [fm destinationOfSymbolicLinkAtPath:path error:nil];
    if (!currentDestinationPath) {
      return;
    }

    // We lost access. Remove that symlink.
    if (![fm isReadableFileAtPath: currentDestinationPath]) {
      [fm removeItemAtPath: path error: nil];
    } else {
      return;
    }
  }
  NSError *error = nil;

  BOOL ok = [fm createSymbolicLinkAtPath:path
                     withDestinationPath:destinationPath
                                   error:&error];

  if (!ok) {
    NSLog(@"Error: %@", error);
  };
}

+ (NSString *)moshroomHome {
  NSString *dotMoshroom = [[self homePath] stringByAppendingPathComponent:@".moshroom"];
  [self _ensureFolderAtPath:dotMoshroom];
  return dotMoshroom;
}

+ (NSString *)ssh {
  NSString *dotSSH = [[self homePath] stringByAppendingPathComponent:@".ssh"];
  [self _ensureFolderAtPath:dotSSH];
  return dotSSH;
}

+ (NSString *)moshroomAgentSettings {
  NSString *path = [[self moshroomHome] stringByAppendingPathComponent:@"agents"];
  [self _ensureFolderAtPath:path];
  return path;
}

+ (void)_ensureFolderAtPath:(NSString *)path {
  BOOL isDir = NO;
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:path isDirectory:&isDir]) {
    if (isDir) {
      return;
    }

    [fm removeItemAtPath:path error:nil];
  }
  [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{} error:nil];
}


+ (NSURL *)moshroomURL
{
  return [NSURL fileURLWithPath:[self moshroomHome]];
}

+ (NSURL *)moshroomAgentSettingsURL
{
  return [NSURL fileURLWithPath:[self moshroomAgentSettings]];
}

+ (NSString *)moshroomKeysFile
{
  return [[self moshroomHome] stringByAppendingPathComponent:@"keys"];
}

+ (NSURL *)moshroomKBConfigURL
{
  return [[self moshroomURL] URLByAppendingPathComponent:@"kb.json"];
}

+ (NSString *)moshroomHostsFile
{
  return [[self moshroomHome] stringByAppendingPathComponent:@"hosts"];
}

+ (NSURL *)moshroomGlobalSSHConfigFileURL
{
  return [[self moshroomURL] URLByAppendingPathComponent:@"ssh_global"];
}

+ (NSURL *)moshroomSSHConfigFileURL
{
  return [[self moshroomURL] URLByAppendingPathComponent:@"ssh_config"];
}


+ (NSString *)moshroomProfileFile
{
  return [[self moshroomHome] stringByAppendingPathComponent:@"profile"];
}

+ (NSString *)historyFile
{
  return [[self moshroomHome] stringByAppendingPathComponent:@"history.txt"];
}

+ (NSURL *)localSnippetsLocationURL
{
  return [NSURL fileURLWithPath:[[self documentsPath] stringByAppendingPathComponent:@"snips"]];
}

+ (NSURL *)iCloudSnippetsLocationURL {
  NSString *path = [self iCloudDriveDocuments];
  if (path) {
    return [NSURL fileURLWithPath:[path stringByAppendingPathComponent:@"snips"]];
  }
  return nil;
}

+ (NSURL *)iCloudHostsLocationURL {
  NSString *path = [self iCloudDriveDocuments];
  if (path) {
    return [NSURL fileURLWithPath:[path stringByAppendingPathComponent:@"hosts"]];
  }
  return nil;
}

+ (NSURL *)iCloudKeysLocationURL {
  NSString *path = [self iCloudDriveDocuments];
  if (path) {
    return [NSURL fileURLWithPath:[path stringByAppendingPathComponent:@"keys"]];
  }
  return nil;
}

+ (NSString *)knownHostsFile
{
  return [[self ssh] stringByAppendingPathComponent:@"known_hosts"];
}

+ (NSString *)moshroomDefaultsFile
{
  return [[self moshroomHome] stringByAppendingPathComponent:@"defaults"];
}

@end
