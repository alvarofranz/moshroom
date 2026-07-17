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
#import <WebKit/WebKit.h>
#import "MoshroomDefaults.h"

@class TermView;
@class TermDevice;
@class TermInput;
@class TermUIState;
@class LayoutConstraintManager;

extern NSString * TermViewReadyNotificationKey;

@protocol TermViewDeviceProtocol

@property BOOL rawMode;

- (void)viewIsReady;
- (void)viewFontSizeChanged:(NSInteger)size;
- (void)viewWinSizeChanged:(struct winsize)win;
- (void)viewSendString:(NSString *)data;
- (void)viewCopyString:(NSString *)text;
- (void)viewShowAlert:(NSString *)title andMessage:(NSString *)message;
- (void)viewSubmitLine:(NSString *)line;
- (void)viewAPICall:(NSString *)api andJSONRequest:(NSString *)request;
- (void)viewNotify:(NSDictionary *)data;
- (void)viewSelectionChanged;
- (void)viewDidReceiveBellRing;

@end


@class SmarterTermInput;

@interface TermView : UIView

- (nonnull instancetype)initWithFrame:(CGRect)frame termUIState:(nonnull TermUIState *)termUIState;

@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) BOOL hasSelection;
@property (nonatomic, readonly) NSString *selectedText;
@property (nonatomic) id<TermViewDeviceProtocol> device;
@property (nonatomic) UIEdgeInsets additionalInsets;
@property (nonatomic) BOOL layoutLocked;
@property (nonatomic) CGRect layoutLockedFrame;
@property (nonatomic, strong, nonnull) TermUIState *termUIState;

@property (nonatomic, strong) LayoutConstraintManager *constraintManager;
@property (nonatomic, readonly) BOOL isReady;
@property (nonatomic, readonly) CGRect selectionRect;
@property (nonatomic, readonly) SmarterTermInput *webView;
@property (nonatomic, weak) id termController;
@property (nonatomic, readonly) NSInteger rows;
@property (nonatomic, readonly) NSInteger cols;


- (CGRect)webViewFrame;
- (void)load;
// Reload term.html now if this terminal's web content process was jettisoned while hidden —
// called at the moments a tab becomes the one being looked at (tab switch, app foreground).
- (void)moshroomReloadIfNeeded;
- (void)applyTermUIState:(nonnull TermUIState *)termUIState;
- (void)setWidth:(NSInteger)count;
- (void)setFontSize:(NSNumber *)newSize;
- (void)write:(NSString *)data;
- (void)moshroomSanitizeModes;
- (void)processKB:(NSString *)str;
- (void)setCursorBlink:(BOOL)state;
- (void)setClipboardWrite:(BOOL)state;
- (void)copy:(id _Nullable )sender;
- (void)copyRaw:(id _Nullable )sender;
- (void)pasteSelection:(id _Nullable)sender;
- (void)terminate;
- (BOOL)isFocused;

- (void)blur;
- (void)focus;
- (void)cleanSelection;
- (void)increaseFontSize;
- (void)decreaseFontSize;
- (void)resetFontSize;
- (void)writeB64:(NSData *)data;
- (void)displayInput:(NSString *)input;
- (void)apiResponse:(NSString *)name response:(NSString *)response;

- (void)modifySideOfSelection;
- (void)modifySelectionInDirection:(NSString *)direction granularity:(NSString *)granularity;

- (void)pasteString:(NSString *)str;

// Layout state
- (MoshLayoutMode)currentLayoutMode;
@end
