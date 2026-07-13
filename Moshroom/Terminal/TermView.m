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

#import "TermView.h"
#import "TermDevice.h"
#import "MoshroomDefaults.h"
#import "MoshFont.h"
#import "MoshTheme.h"
#import "TermJS.h"
#import "LayoutConstraintManager.h"
#import <AVFoundation/AVFoundation.h>

#import "Moshroom-Swift.h"

NSString * TermViewReadyNotificationKey = @"TermViewReadyNotificationKey";

struct winsize __winSizeFromJSON(NSDictionary *json) {
  struct winsize res;
  res.ws_col = [json[@"cols"] integerValue];
  res.ws_row = [json[@"rows"] integerValue];
  res.ws_xpixel = 0;
  res.ws_ypixel = 0;
  
  return res;
}


@interface TermView () <WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate>
@end

@implementation TermView {
  WKWebViewGesturesInteraction *_gestureInteraction;
  
  BOOL _jsIsBusy;
  dispatch_queue_t _jsQueue;
  NSMutableString *_jsBuffer;
  CGRect _currentBounds;
  UIEdgeInsets _currentAdditionalInsets;
  NSTimer *_layoutDebounceTimer;
  
  UIView *_coverView;
  UIView *_parentScrollView;

  UIEditMenuInteraction *_editMenuIteraction;
  NSTimer *_selectionMenuDebounceTimer;

  // The program's own terminal title (OSC 0/2), captured live from JS on every change and stored
  // here so the tab name survives even if WKWebView.title lags behind document.title. See -title.
  NSString *_oscTitle;

  // WebKit jettison recovery (see webViewWebContentProcessDidTerminate:): the next terminalReady
  // is a RECOVERY, not a first load — re-apply live UI state and nudge the session to repaint.
  BOOL _recoveringFromJettison;
  // The process died while this tab was hidden/backgrounded — reload deferred to the moment the
  // tab is next shown (reloading a hidden tab under memory pressure would just get killed again).
  BOOL _needsReloadOnReveal;
}


- (instancetype)initWithFrame:(CGRect)frame termUIState:(TermUIState *)termUIState
{
  self = [super initWithFrame:frame];

  if (!self) {
    return self;
  }

  _selectionRect = CGRectZero;
  _layoutDebounceTimer = nil;
  _currentBounds = CGRectZero;
  _jsQueue = dispatch_queue_create(@"TermView.js".UTF8String, DISPATCH_QUEUE_SERIAL);
  _jsBuffer = [[NSMutableString alloc] init];

  self.termUIState = termUIState;

  [self _addWebView];
  
  _coverView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.height)];
  _coverView.backgroundColor = [UIColor blackColor];
  [self addSubview:_coverView];
  
  return self;
}

- (void)setBackgroundColor:(UIColor *)backgroundColor {
  if (!backgroundColor) {
    return;
  }
  [super setBackgroundColor:backgroundColor];
  _webView.backgroundColor = backgroundColor;
  // Keep the webview's own scroll layer the terminal colour too, so any region WebKit hasn't
  // painted yet during a fast TUI scroll shows the theme background, never a black strip.
  _webView.scrollView.backgroundColor = backgroundColor;
  _coverView.backgroundColor = backgroundColor;
}

- (void)layoutSubviews {
  [super layoutSubviews];

  _coverView.frame = self.bounds;
  [self bringSubviewToFront:_coverView];
}


// SpaceController already pins the terminal inside the safe area (with the floating-bar strips), so
// the web view fills this view edge-to-edge — report a zero inset so the framework doesn't inset it
// a second time.
- (UIEdgeInsets)safeAreaInsets {
  return UIEdgeInsetsZero;
}

- (CGRect)webViewFrame {
  if (_layoutLocked) {
    return _layoutLockedFrame;
  }
  
  // With constraints, return the actual frame of the WebView
  return _webView.frame;
}

- (BOOL)canBecomeFirstResponder {
  return NO;
}

- (void)setUserInteractionEnabled:(BOOL)userInteractionEnabled {
  [super setUserInteractionEnabled:userInteractionEnabled];
  [_webView setUserInteractionEnabled:userInteractionEnabled];
}

- (void)_addWebView
{
  WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
  if (@available(iOS 18.0, *)) {
    configuration.writingToolsBehavior = UIWritingToolsBehaviorNone;
  }
  configuration.defaultWebpagePreferences.preferredContentMode = WKContentModeDesktop;
//  configuration.limitsNavigationsToAppBoundDomains = YES;
  [configuration.userContentController addScriptMessageHandler:self name:@"interOp"];

  _webView = [[SmarterTermInput alloc] initWithFrame:CGRectZero configuration:configuration];
  _webView.UIDelegate = self;
  // Only for webViewWebContentProcessDidTerminate: — WebKit killing the content process of a
  // (typically hidden) terminal used to leave the tab blank forever; now it recovers. See below.
  _webView.navigationDelegate = self;
  // An opaque WKWebView ignores its backgroundColor for not-yet-painted regions and shows WebKit's
  // own default backing — which is what flashes as a black strip during a fast TUI scroll. Making it
  // non-opaque composites it over backgroundColor / scrollView.backgroundColor (both synced to the
  // terminal colour in setBackgroundColor:), so an unpainted area is always the theme background.
  _webView.opaque = NO;
  // The long-press text selection highlight + its grab handles follow the view's tintColor — make
  // them the Moshroom red so "select a word → Copy" reads clearly (a clear tint gave a black,
  // handle-less selection). The blinking insertion caret is hidden separately (term.js applies
  // caret-color:transparent 3×), so a red tint here does NOT bring a caret back — the terminal is
  // read-only (you type in Moshkitor).
  _webView.tintColor = [UIColor moshroomTint];

  _editMenuIteraction = [[UIEditMenuInteraction alloc] initWithDelegate:self];
  [_webView addInteraction:_editMenuIteraction];

   _gestureInteraction = [[WKWebViewGesturesInteraction alloc] initWithJsScrollerPath:@"t.scrollPort_.scroller_"];
  [_webView addInteraction:_gestureInteraction];
  
  [self addSubview:_webView];
}

- (void)didMoveToSuperview {
  [super didMoveToSuperview];
  
  // Setup constraints when view is added to superview (if not already done)
  [self setupWebViewConstraints];
}

- (void)didMoveToWindow {
  [super didMoveToWindow];
  
  [self setupWebViewConstraints];
}

- (void)setupWebViewConstraints {
  // Only setup if we haven't already set up constraints
  if (self.constraintManager) {
    return;
  }
  
  if (!self.window) {
    // Need a window to get keyboard layout guide
    return;
  }
  
  // Get current layout mode from stored termUIState
  MoshLayoutMode layoutMode = MoshLayoutModeDefault;
  if (self.termUIState) {
    layoutMode = self.termUIState.layoutMode;
    // Reset lock modes
    self.termUIState.layoutLocked = NO;
    self.termUIState.layoutLockedFrame = CGRectZero;
  }
  
  self.constraintManager = [LayoutConstraintManager managerForView:_webView
                                                        layoutMode:layoutMode
                                                    keyboardGuide:self.keyboardLayoutGuide];
}

- (NSString *)title {
  // Prefer the OSC title captured live from JS (reliable the instant opencode/ssh/vim set it);
  // fall back to the web view's document title.
  if (_oscTitle.length) {
    return _oscTitle;
  }
  return _webView.title;
}

- (void)load
{
  [_webView.configuration.userContentController addUserScript:[self _termInitScriptWithTermUIState:self.termUIState]];

  NSString *path = [[NSBundle mainBundle] pathForResource:@"term" ofType:@"html"];
  NSURL *url = [NSURL fileURLWithPath:path];
  [_webView loadFileURL:url allowingReadAccessToURL:url];
}

// WebKit silently killed this terminal's web content process (memory pressure — typically it
// picks a hidden background tab). The native session is untouched: only the RENDERER died,
// taking hterm and the on-screen transcript with it — without recovery the tab stays blank
// forever. Reload term.html (the init user script is still registered on the
// userContentController, so hterm rebuilds and posts terminalReady again) — but only while
// actually being looked at: a hidden tab defers to moshroomReloadIfNeeded, fired when it is
// next shown, so memory pressure can't start a kill/reload churn loop.
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
  _isReady = NO;
  BOOL visible = self.window != nil && !self.isHidden
    && self.window.windowScene.activationState == UISceneActivationStateForegroundActive;
  if (visible) {
    [self _reloadAfterJettison];
  } else {
    _needsReloadOnReveal = YES;
  }
}

- (void)moshroomReloadIfNeeded
{
  if (!_needsReloadOnReveal) {
    return;
  }
  _needsReloadOnReveal = NO;
  [self _reloadAfterJettison];
}

- (void)_reloadAfterJettison
{
  _recoveringFromJettison = YES;
  // Re-issue the original file load rather than -reload — after a process crash a file URL's
  // sandbox extension can be stale. The init user script is NOT re-added: it is still registered.
  NSString *path = [[NSBundle mainBundle] pathForResource:@"term" ofType:@"html"];
  NSURL *url = [NSURL fileURLWithPath:path];
  [_webView loadFileURL:url allowingReadAccessToURL:url];
}

- (void)applyTermUIState:(TermUIState *)termUIState
{
  self.termUIState = termUIState;

  NSArray<NSString *> *commands = [self _jsCommandsForTermUIState:termUIState];
  NSString *js = [commands componentsJoinedByString:@"\n"];
  [_webView evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
    [self _syncTerminalState];
  }];

  if (termUIState.layoutMode != [self currentLayoutMode]) {
    [self _setLayoutMode:termUIState.layoutMode];
  }
  if (termUIState.layoutLocked && !self.layoutLocked) {
    self.layoutLockedFrame = termUIState.layoutLockedFrame;
    if (self.constraintManager) {
      [self.constraintManager setLayoutLocked:YES withFrame:termUIState.layoutLockedFrame];
    }
    self.layoutLocked = YES;
  } else if (!termUIState.layoutLocked && self.layoutLocked) {
    [self _unlockLayout];
  }
}

// Reads back terminal-side state after JS changes. Currently just bgColor,
// but could grow into a larger state dict as needed.
- (void)_syncTerminalState
{
  [_webView evaluateJavaScript:@"_colorComponents(t.scrollPort_.screen_.style.backgroundColor)"
             completionHandler:^(NSArray *bgColor, NSError *error) {
    if (bgColor && [bgColor count] == 3) {
      self.backgroundColor = [UIColor colorWithRed:[bgColor[0] floatValue] / 255.0f
                                             green:[bgColor[1] floatValue] / 255.0f
                                              blue:[bgColor[2] floatValue] / 255.0f
                                             alpha:1];
    }
  }];
}

- (void)setWidth:(NSInteger)count
{
  [_webView evaluateJavaScript:term_setWidth(count) completionHandler:nil];
}

- (void)setFontSize:(NSNumber *)newSize
{
  [_webView evaluateJavaScript:term_setFontSize(newSize) completionHandler:nil];
}

- (void)cleanSelection
{
  [_webView evaluateJavaScript:term_cleanSelection() completionHandler:nil];
}

- (void)setCursorBlink:(BOOL)state
{
  [_webView evaluateJavaScript:term_setCursorBlink(state) completionHandler:nil];
}

- (void)setBoldAsBright:(BOOL)state
{
  [_webView evaluateJavaScript:term_setBoldAsBright(state) completionHandler:nil];
}

- (void)setBoldEnabled:(NSUInteger)state
{
  [_webView evaluateJavaScript:term_setBoldEnabled(state) completionHandler:nil];
}

- (void)increaseFontSize
{
  if (_layoutLocked) {
    return;
  }
  [_webView evaluateJavaScript:term_increaseFontSize() completionHandler:nil];
}

- (void)decreaseFontSize
{
  if (_layoutLocked) {
    return;
  }
  [_webView evaluateJavaScript:term_decreaseFontSize() completionHandler:nil];
}

- (void)resetFontSize
{
  if (_layoutLocked) {
    return;
  }

  [_webView evaluateJavaScript:term_setFontSize([MoshroomDefaults selectedFontSize]) completionHandler:nil];
}

- (void)setClipboardWrite:(BOOL)state {
  [_webView evaluateJavaScript:term_setClipboardWrite(state) completionHandler:nil];
}

- (void)focus {
  _gestureInteraction.focused = YES;
//  [_webView evaluateJavaScript:term_focus() completionHandler:nil];
}

- (void)blur {
  _gestureInteraction.focused = NO;
//  [_webView evaluateJavaScript:term_blur() completionHandler:nil];
}

- (void)processKB:(NSString *)str {
  [self _evalJSScript: term_processKB(str)];
}

- (void)displayInput:(NSString *)input {
  [self _evalJSScript: term_displayInput(input, NO)];
}

// Write data to terminal control
- (void)write:(NSString *)data
{
  dispatch_async(_jsQueue, ^{
    [_jsBuffer appendString:data];
    
    if (_jsIsBusy) {
      return;
    }

    NSString * buffer = _jsBuffer;
    if (buffer.length == 0) {
      return;
    }
  
    _jsIsBusy = YES;
    _jsBuffer = [[NSMutableString alloc] init];
    
    NSString *jsScript = term_write(buffer);
    [self _evalJSScript:jsScript];
  });
}

- (void)writeB64:(NSData *)data
{
  dispatch_async(_jsQueue, ^{
    _jsIsBusy = YES;

    NSString * buffer = _jsBuffer;
    _jsBuffer = [[NSMutableString alloc] init];
    
    NSString *jsScript = term_writeB64(data);
    
    if (buffer.length > 0) {
      jsScript = [term_write(buffer) stringByAppendingString:jsScript];
    }
    [self _evalJSScript:jsScript];
  });
}

- (void)_evalJSScript:(NSString *)jsScript
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [_webView evaluateJavaScript: jsScript completionHandler:^(id result, NSError *error) {
      dispatch_async(_jsQueue, ^{
        _jsIsBusy = NO;
        if (_jsBuffer.length > 0) {
          [self write:@""];
        }
      });
    }];
  });
}

//  Since TermView is a WKScriptMessageHandler, it must implement the userContentController:didReceiveScriptMessage method. This is the method that is triggered each time 'interOp' is sent a message from the JavaScript code.
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
  NSDictionary *sentData = (NSDictionary *)message.body;
  NSString *operation = sentData[@"op"];
  NSDictionary *data = sentData[@"data"] ?: @{};

  if ([operation isEqualToString:@"selectionchange"]) {
    [self _handleSelectionChange:data];
  } else if ([operation isEqualToString:@"sigwinch"]) {
    struct winsize newWinSize = __winSizeFromJSON(data);
    _termUIState.rows = newWinSize.ws_row;
    _termUIState.cols = newWinSize.ws_col;
    [_device viewWinSizeChanged:newWinSize];
  } else if ([operation isEqualToString:@"terminalReady"]) {
    [self _onTerminalReady:data];
  } else if ([operation isEqualToString:@"fontSizeChanged"]) {
    NSInteger size = [data[@"size"] integerValue];
    _termUIState.fontSize = size;
    [_device viewFontSizeChanged:size];
  } else if ([operation isEqualToString:@"copy"]) {
    [_device viewCopyString: data[@"content"]];
  } else if ([operation isEqualToString:@"alert"]) {
    [_device viewShowAlert:data[@"title"] andMessage:data[@"message"]];
  } else if ([operation isEqualToString:@"sendString"]) {
    [_device viewSendString:data[@"string"]];
  } else if ([operation isEqualToString:@"line"]) {
    [_device viewSubmitLine:data[@"text"]];
  } else if ([operation isEqualToString:@"api"]) {
    [_device viewAPICall:data[@"name"] andJSONRequest:data[@"request"]];
  } else if ([operation isEqualToString:@"notify"]) {
    [data setValue:[NSNumber numberWithInt:MoshNotificationTypeOsc] forKey:@"type"];
    [_device viewNotify:data];
  } else if ([operation isEqualToString:@"ring-bell"]) {
    [_device viewDidReceiveBellRing];
  } else if ([operation isEqualToString:@"setTitle"]) {
    // The program set its terminal title (OSC 0/2) — remember it for the tab name.
    _oscTitle = data[@"title"];
  } else if ([operation isEqualToString:@"openLink"]) {
    [self _openLink:data[@"url"]];
  }
}

// A tapped/clicked terminal hyperlink (OSC 8 anchor or a URL in the rendered text) opens on the
// DEVICE. One tap can reach here more than once — on the Mac a real DOM click on an OSC 8 anchor
// fires alongside the native tap dispatch, and a double-click doubles both — so anything inside
// a short window collapses into a single open. Links only ever open from a user tap (hterm calls
// openUrl exclusively from click handlers), and only web/mail schemes qualify: a remote program
// must not be able to poke tel:, facetime:, or app-custom schemes at the user.
- (void)_openLink:(NSString *)urlString
{
  static NSTimeInterval lastOpen = 0;
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  if (now - lastOpen < 0.6) {
    return;
  }

  NSURL *url = [NSURL URLWithString:urlString ?: @""];
  NSString *scheme = url.scheme.lowercaseString;
  if (!scheme || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"mailto"])) {
    return;
  }

  lastOpen = now;
  [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)_onTerminalReady:(NSDictionary *)data
{
  [_webView ready];
  NSArray *bgColor = data[@"bgColor"];
  if (bgColor && bgColor.count == 3) {
    UIColor *color = [UIColor colorWithRed:[bgColor[0] floatValue] / 255.0f
                                           green:[bgColor[1] floatValue] / 255.0f
                                            blue:[bgColor[2] floatValue] / 255.0f
                                           alpha:1];
    self.backgroundColor = color;
    _gestureInteraction.indicatorStyle = color.isLight ? UIScrollViewIndicatorStyleBlack : UIScrollViewIndicatorStyleWhite;
  } else {
    _gestureInteraction.indicatorStyle = UIScrollViewIndicatorStyleDefault;
  }
  
  [_device viewWinSizeChanged:__winSizeFromJSON(data[@"size"])];

  BOOL recovered = _recoveringFromJettison;
  _recoveringFromJettison = NO;

  _isReady = YES;
  [_device viewIsReady];
  [[NSNotificationCenter defaultCenter] postNotificationName:TermViewReadyNotificationKey object:self];

//  if (_gestureInteraction.focused) {
//    [_webView evaluateJavaScript:term_focus() completionHandler:nil];
//  } else {
//    [_webView evaluateJavaScript:term_blur() completionHandler:nil];
//  }

  // On a jettison-recovery ready there is no cover view any more — guard it.
  if (_coverView) {
    [UIView transitionFromView:_coverView toView:_webView duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve completion:^(BOOL finished) {
      [_coverView removeFromSuperview];
      _coverView = nil;
    }];
  }

  if (recovered) {
    // The init user script re-applied the UI state captured at FIRST load — re-apply the live
    // one (font size / theme may have changed since), then let the controller nudge the session
    // into repainting the fresh, blank hterm.
    [self applyTermUIState:self.termUIState];
    id tc = self.termController;
    if ([tc respondsToSelector:@selector(moshroomTermViewDidRecover)]) {
      [tc performSelector:@selector(moshroomTermViewDidRecover)];
    }
  }
}

- (BOOL)isFocused {
  return _gestureInteraction.focused;
}

- (void)_handleSelectionChange:(NSDictionary *)data
{
  _selectedText = data[@"text"];
  _hasSelection = _selectedText.length > 0;
  _gestureInteraction.hasSelection = _hasSelection;

  [_device viewSelectionChanged];

  [_selectionMenuDebounceTimer invalidate];
  _selectionMenuDebounceTimer = nil;

  if (!_hasSelection) {
    [_editMenuIteraction dismissMenu];
    // Selection is gone — give first responder back so hardware keys route normally again.
    [_webView deactivateSelectionUI];
    return;
  }

  // Activate the native selection UI (red highlight + grab handles on iOS) — without this the
  // selection paints as WebKit's deactivated look: a black, handle-less box. On Mac Catalyst this
  // is deliberately a no-op (the page paints the red itself). See activateSelectionUI.
  [_webView activateSelectionUI];

  _selectionRect = CGRectFromString(data[@"rect"]);

  // Present the edit menu anchored at the selection — the delegate supplies the single Copy item.
  // Debounced: a mouse drag / handle drag fires selectionchange continuously, and the menu must
  // appear once the selection settles, not flicker along the way.
  __weak TermView *weakSelf = self;
  _selectionMenuDebounceTimer =
    [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:NO block:^(NSTimer *timer) {
      TermView *sself = weakSelf;
      if (!sself || !sself->_hasSelection) {
        return;
      }
      UIEditMenuConfiguration *cfg =
        [UIEditMenuConfiguration configurationWithIdentifier:nil
                                                 sourcePoint:CGPointMake(CGRectGetMidX(sself->_selectionRect),
                                                                         CGRectGetMinY(sself->_selectionRect))];
      [sself->_editMenuIteraction presentEditMenuWithConfiguration:cfg];
    }];
}

- (void)modifySideOfSelection
{
  [_webView evaluateJavaScript:term_modifySideSelection() completionHandler:nil];
}

- (void)modifySelectionInDirection:(NSString *)direction granularity:(NSString *)granularity
{
  [_webView evaluateJavaScript:term_modifySelection(direction, granularity) completionHandler:nil];
}

- (void)apiResponse:(NSString *)name response:(NSString *)response {
  [_webView evaluateJavaScript:term_apiResponse(name, response) completionHandler:nil];
}

- (void)pasteSelection:(id)sender
{
  NSString *str = _selectedText;
  if (str) {
    [_webView evaluateJavaScript:term_paste(str) completionHandler:nil];
  }
  [self cleanSelection];
}

// Sanitize terminal selection for clipboard
// hterm selection may include row-padding spaces at EOL; those should not leak
// into the system clipboard as trailing whitespace.
static NSString * _sanitizeTextForClipboard(NSString *text) {
  if (!text || text.length == 0) {
    return @"";
  }

  // Replace \r\n with \n
  NSString *result = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];

  // Remove trailing spaces/tabs before newlines
  NSRegularExpression *trailingEOL = [NSRegularExpression
    regularExpressionWithPattern:@"[ \\t]+\\n"
    options:0
    error:nil];
  result = [trailingEOL stringByReplacingMatchesInString:result
                                                  options:0
                                                    range:NSMakeRange(0, result.length)
                                             withTemplate:@"\n"];

  // Remove trailing spaces/tabs at end of text
  NSRegularExpression *trailingEnd = [NSRegularExpression
    regularExpressionWithPattern:@"[ \\t]+$"
    options:0
    error:nil];
  result = [trailingEnd stringByReplacingMatchesInString:result
                                                  options:0
                                                    range:NSMakeRange(0, result.length)
                                             withTemplate:@""];

  return result;
}

- (void)copy:(id)sender
{
  NSString *text = _selectedText;
  if (text) {
    [UIPasteboard generalPasteboard].string = _sanitizeTextForClipboard(text);
  }
  [_editMenuIteraction dismissMenu];
  [self cleanSelection];
}

- (void)copyRaw:(id)sender
{
  NSString *text = _selectedText;
  if (text) {
    [UIPasteboard generalPasteboard].string = text;
  }
  [_editMenuIteraction dismissMenu];
  [self cleanSelection];
}

- (void)paste:(id)sender
{
  NSString *str = [UIPasteboard generalPasteboard].string;
  if (str) {
    [_webView evaluateJavaScript:term_paste(str) completionHandler:nil];
  }

  [self cleanSelection];
}

- (void)pasteString:(NSString *)str {
  if (str) {
    [_webView evaluateJavaScript:term_paste(str) completionHandler:nil];
  }
}

- (NSString *)_detectFontFamilyFromContent:(NSString *)content
{
  NSRegularExpression *regex = [NSRegularExpression
                                regularExpressionWithPattern:@"font-family:\\s*([^;]+);"
                                options:NSRegularExpressionCaseInsensitive
                                error:nil];
  __block NSString *result = nil;
  [regex enumerateMatchesInString:content
                          options:0
                            range:NSMakeRange(0, [content length])
                       usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop)
  {
    if (match && match.numberOfRanges == 2) {
     result = [content substringWithRange:[match rangeAtIndex:1]];
    }
    *stop = YES;
  }];
  return result;
}

- (NSArray<NSString *> *)_jsCommandsForTermUIState:(TermUIState *)termUIState
{
  NSMutableArray *commands = [[NSMutableArray alloc] init];
  BOOL lockdownMode = [[NSUserDefaults.standardUserDefaults objectForKey:@"LDMGlobalEnabled"] boolValue];
  MoshFont *selectedFont = [MoshFont withName: termUIState.fontName ?: [MoshroomDefaults selectedFontName]];
  MoshFont *font = (lockdownMode && selectedFont.isCustom) ? nil : selectedFont;
  NSString *fontFamily = font.name ?: (lockdownMode ? @"monospace" : nil);
  NSString *content = font.content;
  if (font && font.isCustom && content) {
    [commands addObject:term_appendUserCss(content)];
    fontFamily = [self _detectFontFamilyFromContent:content] ?: font.name;
  }

  if (fontFamily) {
    [commands addObject:term_setFontFamily(fontFamily, font.systemWide ? @"dom" : @"canvas")];
  }

  [commands addObject:term_setBoldEnabled(termUIState.enableBold)];
  [commands addObject:term_setBoldAsBright(termUIState.boldAsBright)];

  NSString *themeContent = [[MoshTheme withName: termUIState.themeName ?: [MoshroomDefaults selectedThemeName]] content];
  if (themeContent) {
    [commands addObject:themeContent];
  }

  [commands addObject:term_setFontSize(termUIState.fontSize == 0 ? [MoshroomDefaults selectedFontSize] : @(termUIState.fontSize))];
  [commands addObject:term_setCursorBlink([MoshroomDefaults isCursorBlink])];

  return commands;
}

- (WKUserScript *)_termInitScriptWithTermUIState:(TermUIState *)termUIState;
{
  BOOL lockdownMode = [[NSUserDefaults.standardUserDefaults objectForKey:@"LDMGlobalEnabled"] boolValue];
  NSArray<NSString *> *commands = [self _jsCommandsForTermUIState:termUIState];

  NSMutableArray *script = [[NSMutableArray alloc] init];
  [script addObject:@"function applyUserSettings() {"];
  [script addObjectsFromArray:commands];
  [script addObject:@"};"];
  [script addObject:term_init(UIAccessibilityIsVoiceOverRunning(), lockdownMode)];

  return [[WKUserScript alloc] initWithSource:
          [script componentsJoinedByString:@"\n"]
                                injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                             forMainFrameOnly:YES];
}

- (void)applyTheme:(NSString *)themeName {
  NSString *themeContent = [[MoshTheme withName: themeName ?: [MoshroomDefaults selectedThemeName]] content];
  if (themeContent) {
    // Apply the theme, then re-point the page <html>/<body> at the new screen background and
    // re-sync the native side (webView + scrollView colours) — so the no-black-strip guarantee
    // holds across theme changes too, not just at launch.
    NSString *script = [NSString stringWithFormat:
      @"(function(){%@})();"
      @"try{document.body.style.backgroundColor=document.documentElement.style.backgroundColor=t.scrollPort_.screen_.style.backgroundColor;}catch(e){}",
      themeContent];
    [_webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
      [self _syncTerminalState];
    }];
  }
}

- (void)terminate
{
  _device = nil;
  // Disconnect message handler
  [_webView terminate];
  [_webView.configuration.userContentController removeScriptMessageHandlerForName:@"interOp"];
}


- (void)dealloc {
  [self terminate];
  [_webView removeInteraction:_gestureInteraction];
  _gestureInteraction = nil;
  [_layoutDebounceTimer invalidate];
  _layoutDebounceTimer = nil;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
  return YES;
}

- (NSInteger)rows {
  return self.termUIState ? self.termUIState.rows : 0;
}

- (NSInteger)cols {
  return self.termUIState ? self.termUIState.cols : 0;
}

// Public methods for layout state
-(MoshLayoutMode)currentLayoutMode {
  if (self.termUIState) {
    return self.termUIState.layoutMode;
  }
  return MoshLayoutModeDefault;
}

-(BOOL)isLayoutLocked {
  return self.layoutLocked;
}

-(void)toggleLayoutLock {
  if (self.termUIState.layoutLocked) {
    [self _unlockLayout];
  } else {
    [self _lockLayout];
  }
}

// Private methods
-(void)_setLayoutMode:(MoshLayoutMode)layoutMode {
  if (self.termUIState) {
    self.termUIState.layoutMode = layoutMode;
  }
  
  // If layout is locked, unlock it when changing layout mode
  if (self.termUIState.layoutLocked) {
    [self _unlockLayout];
  }
  
  // Trigger layout update
  [self setNeedsLayout];
  
  // Update constraints with new layout mode
  if (self.constraintManager) {
    [self.constraintManager updateLayoutMode:layoutMode];
  }
}

-(void)_lockLayout {
  if (self.termUIState) {
    self.termUIState.layoutLocked = true;
    self.termUIState.layoutLockedFrame = [self webViewFrame];
  }
  
  // Update local state
  self.layoutLockedFrame = [self webViewFrame];
  
  // Update constraint manager
  if (self.constraintManager) {
    [self.constraintManager setLayoutLocked:YES withFrame:[self webViewFrame]];
  }
  
  self.layoutLocked = true;
}

-(void)_unlockLayout {
  if (self.termUIState) {
    self.termUIState.layoutLocked = false;
    self.termUIState.layoutLockedFrame = CGRectZero;
  }
  
  // Update local state
  self.layoutLocked = false;
  
  // Update constraint manager
  if (self.constraintManager) {
    [self.constraintManager setLayoutLocked:NO withFrame:CGRectZero];
  }
  
  // Trigger layout update
  [self setNeedsLayout];
}

@end


@implementation TermView (UIEditMenuInteractionDelegate)

- (UIMenu *)editMenuInteraction:(UIEditMenuInteraction *)interaction menuForConfiguration:(UIEditMenuConfiguration *)configuration suggestedActions:(NSArray<UIMenuElement *> *)suggestedActions  API_AVAILABLE(ios(16.0)){

  NSMutableArray *actions = [[NSMutableArray alloc] init];

  // Moshroom: a terminal selection only ever needs Copy — that's the whole menu, nothing else.
  if (_hasSelection) {
    return [UIMenu menuWithChildren:@[
      [UICommand commandWithTitle:@"Copy" image:[UIImage systemImageNamed:@"doc.on.doc"] action:@selector(copy:) propertyList:nil]
    ]];
  } else {
    NSMutableArray *layoutActions = [[NSMutableArray alloc] init];

    if ([self _isLayoutLocked]) {
      [layoutActions addObject:[UICommand commandWithTitle:@"Unlock" image: [UIImage systemImageNamed:@"lock.slash"]
                                                    action:@selector(_unlockLayout) propertyList:nil]];
    } else {
      [layoutActions addObject:[UICommand commandWithTitle:@"Lock" image: [UIImage systemImageNamed:@"lock"]
                                                    action:@selector(_lockLayout) propertyList:nil]];
    }
    
    UIMenu *layoutMenu = [UIMenu menuWithTitle:@"Layout" image:[UIImage systemImageNamed:@"squareshape.squareshape.dashed"] identifier:nil options:UIMenuOptionsSingleSelection children:layoutActions];
    
    [actions addObject:layoutMenu];
  }
  
  
  // Copy useful commands, skip cut: and replace paste: with pasteSelection:
  for (UIMenuElement *elem in suggestedActions) {
    if ([elem isKindOfClass:[UIMenu class]]) {
      UIMenu *menu = (UIMenu *)elem;
      if ([menu.identifier isEqual:UIMenuStandardEdit]) {
        NSMutableArray *editItems = [[NSMutableArray alloc] init];
        for (UIMenuElement *editElem in menu.children) {
          if ([editElem isKindOfClass:[UICommand class]]) {

            UICommand *cmd = (UICommand *)editElem;
            if (cmd.action == @selector(cut:)) {
              continue;
            } else if (cmd.action == @selector(paste:) && _hasSelection) {
              [editItems addObject:[UICommand commandWithTitle:@"Paste" image:[UIImage systemImageNamed:@"doc.on.clipboard"] action:@selector(pasteSelection:) propertyList:nil]];
            } else if (cmd.action == @selector(copy:) && _hasSelection) {
              [editItems addObject:editElem];
              [editItems addObject:[UICommand commandWithTitle:@"Copy Raw" image:[UIImage systemImageNamed:@"doc.on.doc.fill"] action:@selector(copyRaw:) propertyList:nil]];
            } else {
              [editItems addObject:editElem];
            }
          }
        }
        UIMenu *newMenu = [UIMenu menuWithTitle:menu.title image:menu.image identifier:menu.identifier options:menu.options children:editItems];
        newMenu.preferredElementSize = menu.preferredElementSize;
        [actions insertObject: newMenu atIndex:0];
        continue;
      }
      [actions addObject:elem];
    }
  }
  
  
  
  return [UIMenu menuWithChildren:actions];
}


- (bool)_isLayoutLocked {
  return self.layoutLocked;
}

@end
