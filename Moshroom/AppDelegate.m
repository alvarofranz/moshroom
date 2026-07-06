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

#import "AppDelegate.h"
#import <MoshroomConfig/MoshroomPaths.h>
#import "MoshroomDefaults.h"
#import <MoshroomConfig/MoshHosts.h>
#import <MoshroomConfig/MoshPubKey.h>
#import <ios_system/ios_system.h>
#import <UserNotifications/UserNotifications.h>
#include <libssh/callbacks.h>
#include "Moshroom-Swift.h"

@interface AppDelegate () <UNUserNotificationCenterDelegate>
@end

@implementation AppDelegate {
  NSTimer *_suspendTimer;
  UIBackgroundTaskIdentifier _suspendTaskId;
  BOOL _suspendedMode;
  BOOL _enforceSuspension;
}
  
void __on_pipebroken_signal(int signum){
  NSLog(@"PIPE is broken");
}

void __setupProcessEnv(void) {
  
  NSBundle *mainBundle = [NSBundle mainBundle];
  int forceOverwrite = 1;
  NSString *SSL_CERT_FILE = [mainBundle pathForResource:@"cacert" ofType:@"pem"];
  setenv("SSL_CERT_FILE", SSL_CERT_FILE.UTF8String, forceOverwrite);
  
  NSString *locales_path = [mainBundle pathForResource:@"locales" ofType:@"bundle"];
  setenv("PATH_LOCALE", locales_path.UTF8String, forceOverwrite);
  setlocale(LC_ALL, "UTF-8");
  setenv("TERM", "xterm-256color", forceOverwrite);
  setenv("LANG", "en_US.UTF-8", forceOverwrite);
  ssh_threads_set_callbacks(ssh_threads_get_pthread());
  ssh_init();
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  
  [AppDelegate reloadDefaults];
  [[UIView appearance] setTintColor:[UIColor moshroomTint]];

  // iCloud Drive hosts mirror: self-installs (pushes on save, pulls on foreground). No-op when sync is off.
  [HostsCloudMirror install];

  signal(SIGPIPE, __on_pipebroken_signal);
 
  dispatch_queue_t bgQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
  dispatch_async(bgQueue, ^{
    [MoshroomPaths linkDocumentsIfNeeded];
    [MoshroomPaths linkICloudDriveIfNeeded];
    
  });

  sideLoading = false; // Turn off extra commands from iOS system
  initializeEnvironment(); // initialize environment variables for iOS system
  dispatch_async(bgQueue, ^{
    addCommandList([[NSBundle mainBundle] pathForResource:@"moshroomCommandsDictionary" ofType:@"plist"]); // Load Moshroom commands into ios_system
    __setupProcessEnv(); // we should call this after ios_system initializeEnvironment to override its defaults.
    [AppDelegate _loadProfileVars];
  });
  
  NSString *homePath = MoshroomPaths.homePath;
  setenv("HOME", homePath.UTF8String, 1);
  setenv("SSH_HOME", homePath.UTF8String, 1);

  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc addObserver:self
         selector:@selector(_onSceneDidEnterBackground:)
             name:UISceneDidEnterBackgroundNotification object:nil];
  [nc addObserver:self
           selector:@selector(_onSceneWillEnterForeground:)
               name:UISceneWillEnterForegroundNotification object:nil];
  [nc addObserver:self
         selector:@selector(_onSceneDidActiveNotification:)
             name:UISceneDidActivateNotification object:nil];
  [UNUserNotificationCenter currentNotificationCenter].delegate = self;

  [UIApplication sharedApplication].applicationSupportsShakeToEdit = NO;

  return YES;
}

+ (void)reloadDefaults {
  [MoshroomDefaults loadDefaults];
  [MoshPubKey loadIDS];
  [MoshHosts loadHosts];
  [AppDelegate _loadProfileVars];
}

+ (void)_loadProfileVars {
  NSCharacterSet *whiteSpace = [NSCharacterSet whitespaceCharacterSet];
  NSString *profile = [NSString stringWithContentsOfFile:[MoshroomPaths moshroomProfileFile] encoding:NSUTF8StringEncoding error:nil];
  [profile enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
    NSMutableArray<NSString *> *parts = [[line componentsSeparatedByString:@"="] mutableCopy];
    if (parts.count < 2) {
      return;
    }
    
    NSString *varName = [parts.firstObject stringByTrimmingCharactersInSet:whiteSpace];
    if (varName.length == 0) {
      return;
    }
    [parts removeObjectAtIndex:0];
    NSString *varValue = [[parts componentsJoinedByString:@"="] stringByTrimmingCharactersInSet:whiteSpace];
    if ([varValue hasSuffix:@"\""] || [varValue hasPrefix:@"\""]) {
      NSData *data =  [varValue dataUsingEncoding:NSUTF8StringEncoding];
      varValue = [varValue substringWithRange:NSMakeRange(1, varValue.length - 1)];
      if (data) {
        id value = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:nil];
        if ([value isKindOfClass:[NSString class]]) {
          varValue = value;
        }
      }
    }
    if (varValue.length == 0) {
      return;
    }
    BOOL forceOverwrite = 1;
    setenv(varName.UTF8String, varValue.UTF8String, forceOverwrite);
  }];
}

// MARK: NSUserActivity

// Deprecated and no-ops.
// - (BOOL)application:(UIApplication *)application willContinueUserActivityWithType:(NSString *)userActivityType 
// {
//   return YES;
// }

// - (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray * _Nullable))restorationHandler
// {
//   return YES;
// }

- (BOOL)application:(UIApplication *)application shouldAllowExtensionPointIdentifier:(NSString *)extensionPointIdentifier {
  if ([extensionPointIdentifier isEqualToString: UIApplicationKeyboardExtensionPointIdentifier]) {
    return ![MoshroomDefaults disableCustomKeyboards];
  }
  return YES;
}

#pragma mark - State saving and restoring

- (void)applicationProtectedDataWillBecomeUnavailable:(UIApplication *)application
{
  // If a scene is not yet in the background, then await for it to suspend
  NSArray * scenes = UIApplication.sharedApplication.connectedScenes.allObjects;
  for (UIScene *scene in scenes) {
    if (scene.activationState == UISceneActivationStateForegroundActive || scene.activationState == UISceneActivationStateForegroundInactive) {
      _enforceSuspension = true;
      return;
    }
  }

  [self _suspendApplicationOnProtectedDataWillBecomeUnavailable];
}

- (void)applicationWillTerminate:(UIApplication *)application
{
  [self _suspendApplicationOnWillTerminate];
}

- (void)_startMonitoringForSuspending
{
  if (_suspendedMode) {
    return;
  }
  
  UIApplication *application = [UIApplication sharedApplication];
  
  [self _cancelApplicationSuspendTask];
  
  _suspendTaskId = [application beginBackgroundTaskWithName:@"Suspend" expirationHandler:^{
    [self _suspendApplicationWithExpirationHandler];
  }];
  
  NSTimeInterval time = MIN(application.backgroundTimeRemaining * 0.9, 5 * 60);
  [_suspendTimer invalidate];
  _suspendTimer = [NSTimer scheduledTimerWithTimeInterval:time
                                                   target:self
                                                 selector:@selector(_suspendApplicationWithSuspendTimer)
                                                 userInfo:nil
                                                  repeats:NO];
}

- (void)_cancelApplicationSuspendTask {
  [_suspendTimer invalidate];
  if (_suspendTaskId != UIBackgroundTaskInvalid) {
    [[UIApplication sharedApplication] endBackgroundTask:_suspendTaskId];
  }
  _suspendTaskId = UIBackgroundTaskInvalid;
}

- (void)_cancelApplicationSuspend {
  [self _cancelApplicationSuspendTask];
 
  // We can't resume if we don't have access to protected data
  if (UIApplication.sharedApplication.isProtectedDataAvailable) {
    if (_suspendedMode) {
    }

    _suspendedMode = NO;
  }
}

// Simple wrappers to get the reason of failure from call stack
- (void)_suspendApplicationWithSuspendTimer {
  [self _suspendApplication];
}

- (void)_suspendApplicationWithExpirationHandler {
  [self _suspendApplication];
}

- (void)_suspendApplicationOnWillTerminate {
  [self _suspendApplication];
}

- (void)_suspendApplicationOnProtectedDataWillBecomeUnavailable {
  [self _suspendApplication];
}

- (void)_suspendApplication {
  [_suspendTimer invalidate];

  _enforceSuspension = false;
  
  if (_suspendedMode) {
    return;
  }
  
  [[SessionRegistry shared] suspend];
  _suspendedMode = YES;
  [self _cancelApplicationSuspendTask];
}

#pragma mark - Scenes

- (UISceneConfiguration *) application:(UIApplication *)application
configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                               options:(UISceneConnectionOptions *)options {
  // for (NSUserActivity * activity in options.userActivities) {  }
  return [UISceneConfiguration configurationWithName:@"main"
                                         sessionRole:connectingSceneSession.role];
}



- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
  [SpaceController onDidDiscardSceneSessions: sceneSessions];
}

- (void)_onSceneDidEnterBackground:(NSNotification *)notification {
  NSArray * scenes = UIApplication.sharedApplication.connectedScenes.allObjects;
  for (UIScene *scene in scenes) {
    if (scene.activationState == UISceneActivationStateForegroundActive || scene.activationState == UISceneActivationStateForegroundInactive) {
      return;
    }
  }
  if (_enforceSuspension) {
    [self _suspendApplication];
  } else {
    [self _startMonitoringForSuspending];
  }
}

- (void)_onSceneWillEnterForeground:(NSNotification *)notification {
  [self _cancelApplicationSuspend];
}

- (void)_onSceneDidActiveNotification:(NSNotification *)notification {
  [self _cancelApplicationSuspend];
}

#pragma mark - UNUserNotificationCenterDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
  UNNotificationPresentationOptions opts = UNNotificationPresentationOptionSound | UNNotificationPresentationOptionList | UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionBadge;
  completionHandler(opts);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void (^)(void))completionHandler {
  SceneDelegate *sceneDelegate = (SceneDelegate *)response.targetScene.delegate;
  
  SpaceController *ctrl = sceneDelegate.spaceController;
  
  [ctrl moveToShellWithKey:response.notification.request.content.threadIdentifier];
  
  completionHandler();
}

#pragma mark - Menu Building

- (void)buildMenuWithBuilder:(id<UIMenuBuilder>)builder {
  if (builder.system == UIMenuSystem.mainSystem) {
    [MenuController buildMenuWith:builder];
  }
}

@end
