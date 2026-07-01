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

#include <stdio.h>
#import <UIKit/UIKit.h>
#include "ios_system/ios_system.h"
#include "ios_error.h"
#include "bk_getopts.h"
#include "xcall.h"
#include "openurl.h"

@implementation MoshroomXCall {
  NSCondition *_condition;
}

+ (NSMutableDictionary<NSString *, MoshroomXCall *> *)_registry {
  static NSMutableDictionary *registry = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    registry = [[NSMutableDictionary alloc] init];
  });
  return registry;
}

- (instancetype)init
{
  self = [super init];
  if (self) {
    _callID = NSProcessInfo.processInfo.globallyUniqueString;
    
    _parseOutputParams = [[NSMutableArray alloc] init];
    _encodeInputParams = [[NSMutableArray alloc] init];
    
    _xSuccessURL = [NSURL URLWithString: [NSString stringWithFormat:@"moshroomshell://x-success/%@", _callID]];
    _xErrorURL = [NSURL URLWithString: [NSString stringWithFormat:@"moshroomshell://x-error/%@", _callID]];
    _xCancelURL = [NSURL URLWithString: [NSString stringWithFormat:@"moshroomshell://x-cancel/%@", _callID]];
  }
  return self;
}

- (void)_register {
  [[MoshroomXCall _registry] setObject:self forKey:_callID];
}

- (void)_unregister {
  [[MoshroomXCall _registry] removeObjectForKey:_callID];
}

- (int)run {

  if (!_xURL) {
    puts("no url");
    return 0;
  }

  NSURLComponents * components = [NSURLComponents componentsWithURL:_xURL resolvingAgainstBaseURL:YES];
  NSArray<NSURLQueryItem *> *originalQueryItems = [components queryItems] ?: @[];
  NSMutableArray<NSURLQueryItem *> *originalItemsWithParams = [originalQueryItems mutableCopy];
  
  for (NSArray *pair in _encodeInputParams) {
    NSURLQueryItem *item = [NSURLQueryItem queryItemWithName:pair.firstObject value:pair.lastObject];
    [originalItemsWithParams addObject:item];
  }
  
  NSMutableArray<NSURLQueryItem *> *newQueryItems = [[NSMutableArray alloc] init];
  for (NSURLQueryItem *item in originalItemsWithParams) {
    BOOL xParam = false;
    if ([@"x-success" isEqual:item.name]) {
      xParam = true;
      _xOriginalSuccessURL = [NSURL URLWithString:item.value];
    } else if ([@"x-error" isEqual:item.name]) {
      xParam = true;
      _xOriginalErrorURL = [NSURL URLWithString:item.value];
    } else if ([@"x-cancel" isEqual:item.name]) {
      xParam = true;
      _xOriginalCancelURL = [NSURL URLWithString:item.value];
    }
    if (_async) {
      [newQueryItems addObject:item];
    } else if (!xParam) {
      [newQueryItems addObject:item];
    }
  }
  
  if (!_async) {
    [newQueryItems addObject:[NSURLQueryItem queryItemWithName:@"x-success" value:_xSuccessURL.absoluteString]];
    [newQueryItems addObject:[NSURLQueryItem queryItemWithName:@"x-error" value:_xErrorURL.absoluteString]];
    [newQueryItems addObject:[NSURLQueryItem queryItemWithName:@"x-cancel" value:_xCancelURL.absoluteString]];
  }
  
  [components setQueryItems:newQueryItems];
  
  NSURL *url = [components URL];
  
  if (_verbose) {
    puts(url.absoluteString.UTF8String);
  }

  if (_async) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    });
    return 0;
  } else {
    _condition = [[NSCondition alloc] init];
    dispatch_async(dispatch_get_main_queue(), ^{
      [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
        if (success) {
          [self _register];
        }
      }];
    });
    
    [_condition wait];
  }
  
  if (_verbose) {
    puts(_xCallbackURL.absoluteString.UTF8String);
  }
  
  NSURLComponents *comps = [NSURLComponents componentsWithURL:_xCallbackURL resolvingAgainstBaseURL:YES];
  NSArray<NSURLQueryItem *> *queryItems = [comps queryItems];
  for (NSURLQueryItem *item in queryItems) {
    for (NSArray * decode in _parseOutputParams) {
      NSString *param = decode.firstObject;
      if (![param isEqual:item.name]) {
        continue;
      }
      
      NSString *decoder = decode.lastObject;
      if ([@"json" isEqual:decoder]) {
        id json = [NSJSONSerialization JSONObjectWithData:[item.value dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingAllowFragments error:nil];
        if (!json) {
          continue;
        }
        NSData *prettyJSON = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(prettyJSON.bytes, prettyJSON.length, 1, thread_stdout);
        puts("");
      } else if ([@"base64" isEqual:decoder]) {
        NSData * b64data = [[NSData alloc] initWithBase64EncodedString:item.value options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (!b64data) {
          continue;
        }
        fwrite(b64data.bytes, b64data.length, 1, thread_stdout);
        puts("");
      } else {
        if (item.value) {
          puts(item.value.UTF8String);
        }
      }
    }
  }
  
  NSURL *originalCallbackURL = nil;
  NSString *xCallbackType = _xCallbackURL.host;
  if ([@"x-success" isEqual:xCallbackType] && _xOriginalSuccessURL) {
    originalCallbackURL = _xOriginalSuccessURL;
  } else if ([@"x-error" isEqual:xCallbackType] && _xOriginalErrorURL) {
    originalCallbackURL = _xOriginalErrorURL;
  } else if ([@"x-cancel" isEqual:xCallbackType] && _xOriginalCancelURL) {
    originalCallbackURL = _xOriginalCancelURL;
  }
  
  if (originalCallbackURL) {
    if (_verbose) {
      puts(originalCallbackURL.absoluteString.UTF8String);
    }
    
    NSURLComponents * originalComps = [NSURLComponents componentsWithURL:originalCallbackURL resolvingAgainstBaseURL:YES];
    originalComps.queryItems = comps.queryItems;
    NSURL *url = originalComps.URL;
    moshroom_openurl(url);
  }
  
  return 0;
}

- (void)onCallback: (NSURL *)url {
  _xCallbackURL = url;
  [_condition signal];
}

- (int)_exitCode {
  if (!_xCallbackURL) {
    return -1;
  }
  
  NSString *xCallbackType = _xCallbackURL.host;
  
  if ([@"x-success" isEqual:xCallbackType]) {
    return 0;
  } else if ([@"x-error" isEqual:xCallbackType]) {
    return -1;
  } else if ([@"x-cancel" isEqual:xCallbackType]) {
    return -2;
  }
  return -1;
}

@end

void moshroom_handle_url(NSURL *url) {

  NSString *xType = url.host;
  if (!xType) {
    return;
  }
  BOOL isValidXType = [xType isEqual:@"x-success"] || [xType isEqual:@"x-error"] || [xType isEqual:@"x-cancel"];
  if (!isValidXType) {
    return;
  }
  
  NSString *callID = [url.pathComponents lastObject];
  NSMutableDictionary *registry = [MoshroomXCall _registry];
  MoshroomXCall *call = registry[callID];
  [call _unregister];
  [call onCallback:url];
}

void __moshroom_call_cleanup_callback(void *callData) {
  MoshroomXCall *call = (__bridge MoshroomXCall *)callData;
  [call _unregister];
}

__attribute__ ((visibility("default")))
int moshroom_xcall_main(int argc, char *argv[]) {
  thread_optind = 1;
  
  NSString *opts = @"ap:j:b:i:s:vh";
  NSString *usage = [NSString stringWithFormat:@"Usage: xcall [%@] url", opts];
  
  MoshroomXCall *call = [[MoshroomXCall alloc] init];
  
  for (;;) {
    int c = thread_getopt(argc, argv, opts.UTF8String);
    
    if (c == -1) {
      break;
    }
    switch (c) {
      case 'h': {
       NSString *help =
       [@[usage,
          @"-a                runs command asynchoniosly.",
          @"-i <param_name>   reads stdin and pass content to url as param_name.",
          @"-p name=value     url encode value and adds that parameter to query.",
          @"-b <param_name>   decodes value of result param_name in base64 and prints it.",
          @"-j <param_name>   prints value of result param_name in pretty json format.",
          @"-s <param_name>   prints value of result param_name (url decoded).",
          @"-v                verbose.",
         ] componentsJoinedByString:@"\n"];
        puts(help.UTF8String);
        return 0;
      }
      case 'a':
        call.async = YES;
        break;
      case 'p': {
        NSMutableArray * parts = [[@(thread_optarg) componentsSeparatedByString:@"="] mutableCopy];
        NSString *name = parts.firstObject;
        [parts removeObjectAtIndex:0];
        NSString *value = [parts componentsJoinedByString:@"="];
        [call.encodeInputParams addObject:@[name, value]];
        break;
      }
      case 'j': {
        [call.parseOutputParams addObject:@[@(thread_optarg), @"json"]];
        break;
      }
      case 'b': {
        [call.parseOutputParams addObject:@[@(thread_optarg), @"base64"]];
        break;
      }
      case 's': {
        [call.parseOutputParams addObject:@[@(thread_optarg), @"string"]];
        break;
      }
      case 'i': {
        call.stdInParameterName = @(thread_optarg);
        break;
      }
      case 'v': {
        call.verbose = YES;
        break;
      }
      default:
        printf("%s\n", usage.UTF8String);
        return -1;
    }
  }
  
  NSString * urlStr = nil;
  if (thread_optind < argc) {
    NSMutableArray<NSString *> *parts = [[NSMutableArray alloc] init];
    for (int i = thread_optind; i < argc; i++) {
      [parts addObject:@(argv[i])];
    }
    urlStr = [parts componentsJoinedByString:@" "];
    
  } else {
    printf("%s\n", usage.UTF8String);
    return -1;
  }
  
  urlStr = [urlStr stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSURL *xUrl = [NSURL URLWithString:urlStr];
  if (!xUrl) {
    puts("invalid url");
    return -1;
  }
  
  call.xURL = xUrl;
  
  BOOL isatty = ios_isatty(fileno(thread_stdin));

  if (!isatty) {
    if (call.stdInParameterName) {
      const int bufsize = 1024;
      char buffer[bufsize];
      NSMutableData* data = [[NSMutableData alloc] init];
      ssize_t count = 0;
      while ((count = read(fileno(thread_stdin), buffer, bufsize-1))) {
        [data appendBytes:buffer length:count];
      }
      
      NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      [call.encodeInputParams addObject:@[call.stdInParameterName, value]];
    }
  }
  
  pthread_cleanup_push(__moshroom_call_cleanup_callback, (__bridge void *)call);
  [call run];
  pthread_cleanup_pop(YES);
  
  return [call _exitCode];
}

