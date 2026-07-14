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

#import <WebKit/WebKit.h>

#import "MoshAboutViewController.h"

@interface MoshAboutViewController ()
@end

@implementation MoshAboutViewController

- (void)viewDidLoad {
  [super viewDidLoad];

  WKWebViewConfiguration *theConfiguration = [[WKWebViewConfiguration alloc] init];
  WKWebView *webView = [[WKWebView alloc] initWithFrame:self.view.frame configuration:theConfiguration];
  webView.translatesAutoresizingMaskIntoConstraints = NO;
  // The page (about.html) is dark; paint the webview dark too so opening About never
  // flashes WebKit's default opaque white while the page loads.
  webView.opaque = NO;
  webView.backgroundColor = UIColor.blackColor;
  webView.scrollView.backgroundColor = UIColor.blackColor;
  
  [self.view addSubview:webView];
  
  [NSLayoutConstraint activateConstraints:
  @[
    [webView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
    [webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
  ]];
  
  NSString *path = [[NSBundle mainBundle] pathForResource:@"about" ofType:@"html"];
  NSURL *url = [NSURL fileURLWithPath:path];
  NSURLRequest *request=[NSURLRequest requestWithURL:url];
  [webView loadRequest:request];
}

@end
