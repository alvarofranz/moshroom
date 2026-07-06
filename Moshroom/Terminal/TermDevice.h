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
#import "TermStream.h"
#import "TermView.h"
#include <sys/ioctl.h>

@class TermDevice;

@protocol TermInput <NSObject>

@property (weak) TermDevice *device;
@property BOOL secureTextEntry;

- (void)setHasSelection:(BOOL)value;
- (void)reset;

@end

@protocol TermDeviceReadlineListener
- (void)lineSubmitted:(NSString *)line;
- (void)handleControl:(NSString *)control;
@end

@protocol TermDeviceDelegate

- (void)deviceIsReady;
- (void)deviceSizeChanged;
- (void)viewFontSizeChanged:(NSInteger)size;
- (void)deviceFocused;
- (void)apiCall:(NSString *)api andRequest:(NSString *)request;
- (void)viewNotify:(NSDictionary *)data;
- (void)viewDidReceiveBellRing;
- (UIViewController *)viewController;

@end

@interface TermDevice : NSObject {
  @public struct winsize win;
}

@property (nonatomic) struct winsize win;
@property (readonly) TermStream *stream;
@property (readonly) TermView *view;
@property (readonly) UIView<TermInput> *input;
@property id<TermDeviceDelegate> delegate;
@property id<TermDeviceReadlineListener> readlineListener;
@property (nonatomic) BOOL rawMode;
@property (nonatomic) BOOL autoCR;
@property (nonatomic) BOOL secureTextEntry;
@property (nonatomic) BOOL shouldBlockFirstResponder;
@property (nonatomic) BOOL isReady;
@property (nonatomic) NSInteger rows;
@property (nonatomic) NSInteger cols;

// Offer the pointer as it is a struct on itself. This is helpful because on Swift,
// we cannot used a synthesized expression to get the UnsafeMutablePointer.
- (struct winsize *)window;
- (void)attachInput:(UIView<TermInput> *)termInput;
- (void)attachView:(TermView *)termView;

- (void)onSubmit:(NSString *)line;
- (void)prompt:(NSString *)prompt secure:(BOOL)secure shell:(BOOL)shell;
- (NSString *)readline:(NSString *)prompt secure:(BOOL)secure;
- (void)closeReadline;

- (void)focus;
- (void)blur;

- (void)write:(NSString *)input;
- (void)writeIn:(NSString *)input;
- (void)writeInDirectly:(NSString *)input;
- (void)writeOut:(NSString *)output;
- (void)writeOutLn:(NSString *)output;
- (void)close;


@end

@interface TermDevice () <TermViewDeviceProtocol>
@end
