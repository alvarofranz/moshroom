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

#import "MoshSettingsFileDownloader.h"

@implementation MoshSettingsFileDownloader

static NSURLSessionDownloadTask *downloadTask;

+ (void)downloadFileAtUrl:(NSString *)urlString expectedMIMETypes:(NSArray *)mimeTypes withCompletionHandler:(void (^)(NSData *fileData, NSError *error))completionHandler
{
  [MoshSettingsFileDownloader cancelRunningDownloads];

  NSURL *url = [NSURL URLWithString:urlString];
  downloadTask = [[NSURLSession sharedSession]
		   downloadTaskWithURL:url
		     completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
      if (!error && mimeTypes) {
	NSString *responseType = [response MIMEType];
	__block BOOL acceptedMIMEType = NO;
        [mimeTypes enumerateObjectsUsingBlock:^(NSString *type,
						NSUInteger idx,
						BOOL *stop) {
	    if ([type isEqualToString:responseType]) {
	      *stop = YES;
	      acceptedMIMEType = YES;	      
	    } 
	  }];

	if (!acceptedMIMEType) {
	  NSString *msg = [NSString stringWithFormat:@"Unsupported media type %@.", [response MIMEType]];
	  error = [NSError errorWithDomain:@"MoshSettingsErrorDomain"
				      code:415
				  userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(msg, nil)}];
	}
      }
      if (error.code != -999) {
	completionHandler([NSData dataWithContentsOfURL:location], error);
      }
    }];

  [downloadTask resume];
}

+ (void)cancelRunningDownloads
{
  if (downloadTask != nil || downloadTask.state == NSURLSessionTaskStateRunning) {
    [downloadTask cancel];
    downloadTask = nil;
  }
}

@end
