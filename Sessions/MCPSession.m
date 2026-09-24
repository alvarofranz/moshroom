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
#include <string.h>
#include <libgen.h>
#include <sys/stat.h>
#include <dispatch/dispatch.h>

#import "MCPSession.h"
#import "MoshPubKey.h"
#import "SSHCopyIDSession.h"
#import "SSHSession.h"

#import "MoshroomPaths.h"


#include <ios_system/ios_system.h>

#include "ios_error.h"
#include "Moshroom-Swift.h"


@implementation MCPSession {
  NSString * _sessionUUID;
  Session *_childSession;
  NSString *_currentCmd;
  NSMutableArray *_sshClients;
//  dispatch_queue_t _cmdQueue;
  dispatch_queue_t _sshQueue;
  TermStream *_cmdStream;
  NSString *_currentCmdLine;
  // The tab is closing (see -kill): nothing may start a client for it any more.
  BOOL _moshroomKilled;
  // A reconnect the user asked for (see -moshroomReconnectWith:), taken once by the command queue.
  NSString *_moshroomReconnectCommand;
}

@dynamic sessionParams;

- (id)initWithDevice:(TermDevice *)device andParams:(MCPParams *)params {
  if (self = [super initWithDevice:device andParams:params]) {
    _sshClients = [[NSMutableArray alloc] init];
    _sessionUUID = [[NSProcessInfo processInfo] globallyUniqueString];
    _cmdQueue = dispatch_queue_create("mcp.command.queue", DISPATCH_QUEUE_SERIAL);
    _sshQueue = dispatch_queue_create("mcp.sshclients.queue", DISPATCH_QUEUE_SERIAL);
    [self setActiveSession];
    device.readlineListener = self;
  }

  return self;
}

- (void)executeWithArgs:(NSString *)args {
  dispatch_async(_cmdQueue, ^{
    [self setActiveSession];
    ios_setStreams(_stream.in, _stream.out, _stream.out);

    NSString *homePath = [MoshroomPaths homePath];
    ios_setMiniRoot(homePath);
    [self updateAllowedPaths];

    // A tab relaunched with a parked mosh session picks it back up before anything else.
    if ([self _moshroomRunParkedSession] || [self _moshroomRunReconnectIfAsked]) {
      return;
    }
    NSString *initialCommand = self.sessionParams.initialCommand;
    if (initialCommand.length > 0) {
      [self enqueueCommand:initialCommand];
      return;
    }
    // A resumed child that ended for real falls through to here: sanitize the display modes the
    // dead session may have latched, exactly like the post-command path in _runCommand does.
    // No-op on a plain fresh boot.
    #if TARGET_OS_MACCATALYST
      MoshHosts *localhost = [MoshHosts withHost:@"localhost"];
      if (localhost) {
        [_device.view moshroomSanitizeModes];
        NSString *sshcmd = [NSString stringWithFormat: @"ssh -A %@", localhost.host];
        [self enqueueCommand:sshcmd];
      } else {
        [self _moshroomBackAtPrompt];
      }
    #else
    [self _moshroomBackAtPrompt];
    #endif
  });
}

// A mosh session PARKS whenever the app goes to sleep: its client checkpoints its state and steps
// off the network, and a new client continues from that checkpoint when the tab is back. This is
// the one place that runs a parked session, for a relaunched tab and an in-process resume alike.
//
// It decides by the one signal that cannot lie: whether the client that just returned produced a
// checkpoint, which is always a client's last act (MoshroomMosh.moshroomParked). Nothing is read
// from timing, from flags raised by other code, or from state left lying around. A client that
// parks while the app is awake (it was still answering a suspend when the app came back, or the
// user typed the client's own suspend keys) is simply woken again from its fresh checkpoint.
//
// Returns YES while the session stays parked because the app is asleep (moshroomResume continues it),
// NO once nothing is parked: there never was anything, or the session ended for real. Either way the
// child marker is then cleared, so the tab reads as the plain local shell it now is.
// Command queue only.
- (BOOL)_moshroomRunParkedSession
{
  NSUInteger wakes = 0;
  while ([@"mosh" isEqualToString:self.sessionParams.childSessionType] && self.sessionParams.hasEncodedState) {
    // A reconnect replaces this session, a closed tab has nothing to show it in: let it go.
    if ([self _moshroomHasReconnect]) {
      break;
    }
    if (self.moshroomSuspended) {
      return YES;
    }
    // Only a client that parks the instant it starts, again and again, gets here: stop rather than spin.
    if (++wakes > 8) {
      break;
    }
    MoshParams *moshParams = (MoshParams *)self.sessionParams.childSessionParams;
    MoshroomMosh *mosh = nil;
    // Published under the same lock -kill takes, so a closing tab either sees this client (and
    // stops it) or stops it from being created at all.
    @synchronized (self) {
      if (_moshroomKilled || !_device) {
        return YES;
      }
      mosh = [[MoshroomMosh alloc] initWithMcpSession:self device:_device andParams:moshParams];
      _childSession = mosh;
    }
    [mosh executeAttachedWithArgs:@""];
    @synchronized (self) {
      _childSession = nil;
    }
    if (!mosh.moshroomParked) {
      break;
    }
  }
  [self _clearChildSession];
  return NO;
}

- (BOOL)_moshroomHasReconnect
{
  @synchronized (self) {
    return _moshroomReconnectCommand != nil;
  }
}

// After a session let go for a reconnect: run the connect as if typed at the prompt, with no prompt
// in between (it would flash Quick Connect over a tab that is already connecting). Command queue only.
- (BOOL)_moshroomRunReconnectIfAsked
{
  NSString *command;
  @synchronized (self) {
    command = _moshroomReconnectCommand;
    _moshroomReconnectCommand = nil;
  }
  if (command.length == 0 || !_device) {
    return NO;
  }
  // The session that let go never said goodbye to the screen: leave its modes behind, like a fresh
  // connect from the prompt would find them.
  [_device.view moshroomSanitizeModes];
  [self enqueueCommand:command skipHistoryRecord:YES];
  return YES;
}

// The user asked to reconnect this tab (TermController.moshroomReconnect): whatever its mosh session is
// doing (waiting for a server that no longer answers, parked, still connecting), let it go and connect
// again, here. The client lets go of the server through its park, which never needs the server; the
// checkpoint is then dropped and `command` runs. The queue block covers a session with no client
// running; with one, the command loop picks the reconnect up as the client leaves.
- (void)moshroomReconnectWith:(NSString *)command
{
  @synchronized (self) {
    if (_moshroomKilled) {
      return;
    }
    _moshroomReconnectCommand = [command copy];
  }
  Session *child = _childSession;
  if ([child isKindOfClass:[MoshroomMosh class]]) {
    [(MoshroomMosh *)child moshroomLetGo];
  }
  dispatch_async(_cmdQueue, ^{
    if (![self _moshroomHasReconnect]) {
      return;
    }
    [self setActiveSession];
    [self _clearChildSession];
    [self _moshroomRunReconnectIfAsked];
  });
}

// The app woke this tab (it is being shown again): continue a parked session. Serial with every
// command on the queue, so by the time it runs nothing else is: a parked session is the only thing
// it can find, and a client that never parked (still connecting when the app slept) has carried on
// or finished by itself.
- (void)moshroomResume
{
  self.moshroomSuspended = NO;
  dispatch_async(_cmdQueue, ^{
    if (![@"mosh" isEqualToString:self.sessionParams.childSessionType]) {
      return;
    }
    [self setActiveSession];
    if ([self _moshroomRunParkedSession] || [self _moshroomRunReconnectIfAsked]) {
      return;
    }
    [self _moshroomBackAtPrompt];
  });
}

// A mosh checkpoint landed or was consumed: the tab's archive must follow (see SessionDelegate).
- (void)moshroomCheckpointDidChange
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.delegate sessionCheckpointDidChange];
  });
}

// The terminal view was rebuilt and shows nothing. A mosh session holds the whole screen itself, so it
// owns the repaint: a running client redraws locally, a parked one paints everything when it wakes.
// Answers YES when that has it covered; NO sends the caller to its resize nudge instead.
- (BOOL)moshroomMoshCanRepaint
{
  Session *child = _childSession;
  return [child isKindOfClass:[MoshroomMosh class]] && ((MoshroomMosh *)child).moshroomCanRepaint;
}

- (BOOL)moshroomRepaintMoshSession
{
  if (![@"mosh" isEqualToString:self.sessionParams.childSessionType]) {
    return NO;
  }
  Session *child = _childSession;
  if (![child isKindOfClass:[MoshroomMosh class]]) {
    return YES;
  }
  return [(MoshroomMosh *)child moshroomRepaintRebuiltView];
}

// Back at the local prompt with nothing running: never hand the user a prompt still trapped in a dead
// session's modes (alternate screen, mouse reporting armed, hidden cursor), then arm the prompt.
- (void)_moshroomBackAtPrompt
{
  if (!_device) {
    return;
  }
  [_device.view moshroomSanitizeModes];
  [_device prompt:@"" secure:NO shell:YES];
  [self _postPromptReady];
}

// Moshroom: reprint the idle prompt after the terminal web view recovered from a jettison (its
// rendered transcript is gone). Display-only — the OSC prompt escape re-arms term.js's shell
// prompt mode; the command readline path (readlineListener) is untouched. No-op mid-command.
// NOTE the shell prompt renders NO text by design (the OSC handler only arms the line editor,
// see the MoshroomPrompt shell branch): the prompt string is empty everywhere on purpose.
- (void)moshroomReprintPromptIfIdle {
  // A parked session owns this screen too: it repaints when it wakes, and arming the local line
  // editor under it would catch the first keys meant for the remote.
  if ([self isRunningCmd] || self.sessionParams.childSessionType.length > 0) {
    return;
  }
  [_device prompt:@"" secure:NO shell:YES];
  [self _postPromptReady];
}

// The shell just reached its idle moshroom> prompt — tell the UI (the Moshnector quick-connect card
// reveals off this). Posted on the main queue since the prompt prints from the command queue.
- (void)_postPromptReady {
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MoshroomPromptReadyNotification" object:self];
  });
}

- (void)enqueueCommand:(NSString *)cmd {
  [self enqueueCommand:cmd skipHistoryRecord:NO];
}

- (void)enqueueCommand:(NSString *)cmd skipHistoryRecord: (BOOL) skipHistoryRecord {
  // NOTE This shouldn't be done this way. The MCP should read from, but not write to the input.
  // The terminal device in this case is acting like a shell, which is not fully wrong, but I don't like it.
  // The terminal view is also receiving requests for "what's being typed" in order to then do Completion, etc...
  if (_cmdStream) {
    [_device writeInDirectly:[NSString stringWithFormat: @"%@\n", cmd]];
    return;
  }
  dispatch_async(_cmdQueue, ^{
    self->_currentCmdLine = cmd;
    [self _runCommand:cmd skipHistoryRecord:skipHistoryRecord];
    self->_currentCmdLine = nil;
  });
}

- (BOOL)_runCommand:(NSString *)cmdline skipHistoryRecord: (BOOL) skipHistoryRecord {
  
  cmdline = [cmdline stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  
  if (!skipHistoryRecord) {
    [HistoryObj appendIfNeededWithCommand:cmdline];
  }
  
  NSString *mayBeURLString = [cmdline stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  
  NSURL *mayBeHttpURL = [NSURL URLWithString:mayBeURLString];
  NSString *scheme = mayBeHttpURL.scheme.lowercaseString;
  if ([@"http" isEqual: scheme] || [@"https" isEqual:scheme]) {
    cmdline = [NSString stringWithFormat:@"browse %@", mayBeURLString];
  }
  
  NSArray *arr = [cmdline componentsSeparatedByString:@" "];
  NSString *cmd = arr[0];

  if ([cmd isEqualToString:@"exit"]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.delegate sessionFinished];
    });
    
    return NO;
  }
  
  // NOTE We don't have a passthrough for all of it.
  // This should be done at a different function
  setenv("LC_ALL", "UTF-8", 1);
  setenv("LC_CTYPE", "UTF-8", 1);
  setlocale(LC_ALL, "UTF-8");
  setlocale(LC_CTYPE, "UTF-8");
  
  if ([cmd isEqualToString:@"mosh"]) {
    MoshroomMosh *mosh = [self _runMoshWithArgs:cmdline];
    // A client that checkpointed PARKED, it did not end: it carries on from that checkpoint, right
    // away if the app is awake, at the resume otherwise (see _moshroomRunParkedSession).
    if (mosh.moshroomParked && [self _moshroomRunParkedSession]) {
      return NO;
    }
  } else if ([cmd isEqualToString:@"ssh2"]) {
    [self _runSSHWithArgs:cmdline];
  } else if ([cmd isEqualToString:@"ssh-copy-id"]) {
    [self _runSSHCopyIDWithArgs:cmdline];
  } else if (![cmd isEqualToString:@""]) {
    // Manually set raw mode for some commands, as we cannot receive control any other way.
    [_device closeReadline];
    if ([cmd isEqualToString:@"less"]) {
      self.device.rawMode = true;
      self.device.autoCR = TRUE;
    }
    [self setActiveSession];
    [self updateAllowedPaths];

    _currentCmd = cmdline;

    _cmdStream = [_device.stream duplicate];
    ios_setStreams(_cmdStream.in, _cmdStream.out, _cmdStream.out);
    // ios_system provides a get command that returns a "tty" instead of an open.  We can control it here.
    FILE* tty = [_cmdStream openTTY];
    ios_settty(tty);
    ios_setWindowSize((int)self.device.cols, (int)self.device.rows, _sessionUUID.UTF8String);

    pid_t _pid = ios_fork();
    ios_system(cmdline.UTF8String);
    _currentCmd = nil;
    ios_waitpid(_pid);
    ios_releaseThreadId(_pid);
    self.device.autoCR = FALSE;

    fclose(tty);
    tty = nil;
    [_cmdStream close];
    _cmdStream = nil;
    _sshClients = [[NSMutableArray alloc] init];

    setenv("LC_ALL", "UTF-8", 1);
    setenv("LC_CTYPE", "UTF-8", 1);
    setlocale(LC_ALL, "UTF-8");
    setlocale(LC_CTYPE, "UTF-8");
  }
  
  // Reaching this point means the command, and any child session it ran, ENDED for real: this tab is
  // a plain local shell again, whatever the app is doing (a command that finishes while the app is
  // asleep still owes the user a prompt). Without the clear, the child marker outlived the session,
  // the tab never read as a fresh shell again, and neither the fresh-start reset nor the
  // quick-connect card ever came back after an exit. No-op when no child ran.
  [self _clearChildSession];
  if ([self _moshroomRunReconnectIfAsked]) {
    return NO;
  }
  [self _moshroomBackAtPrompt];

  return YES;
}

- (int)main:(int)argc argv:(char **)argv
{
  return 0;
}

- (void)registerSSHClient:(id __weak)sshClient {
  dispatch_sync(_sshQueue, ^(void){
    [_sshClients addObject:sshClient];
  });
}

- (void)unregisterSSHClient:(id __weak)sshClient {
  dispatch_sync(_sshQueue, ^(void){
    [_sshClients removeObject:sshClient];
  });
}

- (bool)isRunningCmd {
  return _childSession != nil || _currentCmd != nil || _currentCmdLine != nil;
}


- (void)updateAllowedPaths
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableArray<NSString *> *allowedPaths = [[NSMutableArray alloc] init];
  NSString *documentsPath = [MoshroomPaths documentsPath];
  NSString *iCloudDriveDocumentsPath = [MoshroomPaths iCloudDriveDocuments];

  if (documentsPath != NULL) {
    [allowedPaths addObject: documentsPath];
    NSString *resolvedPath = [fm destinationOfSymbolicLinkAtPath:[MoshroomPaths documentsPath] error:nil];
    if (resolvedPath != NULL) {
      [allowedPaths addObject: resolvedPath];
    }
  }

  if (iCloudDriveDocumentsPath != NULL) {
    [allowedPaths addObject: iCloudDriveDocumentsPath];
    NSString *resolvedPath = [fm destinationOfSymbolicLinkAtPath:[MoshroomPaths iCloudDriveDocuments] error:nil];
    if (resolvedPath != NULL) {
      [allowedPaths addObject: iCloudDriveDocumentsPath];
    }
  }

  ios_setAllowedPaths(allowedPaths);
}

// A child session (mosh/ssh2/…) finished for real: drop its marker so the tab reads as a plain
// local shell again. The marker's only purpose is resuming a LIVE (suspended) session.
- (void)_clearChildSession
{
  if (self.sessionParams.childSessionType == nil && self.sessionParams.childSessionParams == nil) {
    return;
  }
  BOOL wasMosh = [@"mosh" isEqualToString:self.sessionParams.childSessionType];
  self.sessionParams.childSessionType = nil;
  self.sessionParams.childSessionParams = nil;
  // A mosh session's archive described something resumable: it must not outlive the session.
  if (wasMosh) {
    [self moshroomCheckpointDidChange];
  }
}

- (void)_runSSHCopyIDWithArgs:(NSString *)args
{
  self.sessionParams.childSessionParams = nil;
  _childSession = [[SSHCopyIDSession alloc] initWithDevice:_device andParams:self.sessionParams.childSessionParams];
  self.sessionParams.childSessionType = @"sshcopyid";
  
  // duplicate args
  NSString *str = [NSString stringWithFormat:@"%@", args];
  [_childSession executeAttachedWithArgs:str];

  _childSession = nil;
}

- (MoshroomMosh *)_runMoshWithArgs:(NSString *)args
{
  self.sessionParams.childSessionParams = [[MoshParams alloc] init];
  self.sessionParams.childSessionType = @"mosh";
  MoshroomMosh *mosh = [[MoshroomMosh alloc] initWithMcpSession: self device:_device andParams:self.sessionParams.childSessionParams];
  @synchronized (self) {
    _childSession = mosh;
  }

  // duplicate args
  NSString *str = [NSString stringWithFormat:@"%@", args];
  [mosh executeAttachedWithArgs:str];

  @synchronized (self) {
    _childSession = nil;
  }
  return mosh;
}

- (void)_runSSHWithArgs:(NSString *)args
{
  self.sessionParams.childSessionParams = nil;
  _childSession = [[SSHSession alloc] initWithDevice:_device andParams:self.sessionParams.childSessionParams];
  self.sessionParams.childSessionType = @"ssh";
  [_childSession executeAttachedWithArgs:args];
  _childSession = nil;
}

- (void)sigwinch
{
  [self setActiveSession];
  ios_setWindowSize((int)self.device.cols, (int)self.device.rows, _sessionUUID.UTF8String);
  
  [_childSession sigwinch];
  dispatch_sync(_sshQueue, ^{
    for (id client in _sshClients) {
      [client sigwinch];
    }
  });
}

// TODO It would be nice if this could be re-used (interrupt children, interrupt yourself).
- (void)kill
{
  // Latch first: a wake in flight (a hidden parked tab is woken by the switch that precedes its close)
  // must find the tab closed instead of building a client on a device that is going away.
  Session *child;
  @synchronized (self) {
    _moshroomKilled = YES;
    _moshroomReconnectCommand = nil;
    child = _childSession;
  }
  if (_sshClients.count > 0) {
    dispatch_sync(_sshQueue, ^{
      for (id client in _sshClients) {
        [client kill];
      }
    });
    
    return;
  } else if (child) {
    [child kill];
  } else if (_cmdStream) {
    [self setActiveSession];
    ios_kill();
  }
  
  ios_closeSession(_sessionUUID.UTF8String);
  [_device close];
  _device = NULL;
}

- (void)suspend
{
  // Raised BEFORE the child is asked to park, so the command queue keeps a client that parks now
  // parked, instead of waking it straight back up (see _moshroomRunParkedSession).
  self.moshroomSuspended = YES;
  [self setActiveSession];
  [_childSession suspend];
}

- (void)handleControl:(NSString *)control
{
  NSString *ctrlC = @"\x03";
  NSString *ctrlD = @"\x04";
  
  if (_childSession) {
    if (_sshClients.count > 0) {
      dispatch_sync(_sshQueue, ^{
        for (id client in _sshClients) {
          // TODO We need the kill here because of the Proxy connections, but if we simplify, SSH will just be a
          // regular child session.
          [client kill];
        }
      });
    } else {
      // Send kill signal to child session.
      [_childSession kill];
    }
    return;
  } else if (_currentCmd) {
    if ([control isEqualToString:ctrlD]) {
      // We give a chance to the session to capture the new stdin, as it may have changed.
      [self setActiveSession];
      if (_cmdStream != NULL) {
        [_cmdStream close];
        _cmdStream = NULL;
        _cmdStream = [_device.stream duplicate];
      }
      ios_setStreams(_cmdStream.in, _cmdStream.out, _cmdStream.out);
      return;
    }
    
    if ([control isEqualToString:ctrlC]) {
      if (_sshClients.count > 0) {
        dispatch_sync(_sshQueue, ^{
          for (id client in _sshClients) {
            [client kill];
          }
        });
      } else {
        [self setActiveSession];
        ios_kill();
      }
      return;
    }
  }

  return;
}

- (void)setActiveSession {
  // Need to reset all thread variables, including context!
  // This fixes "segmentation faults" after a few subsequent session - new command cycles.
  thread_context = NULL;
  ios_switchSession(_sessionUUID.UTF8String);
  ios_setContext((__bridge void*)self);
  thread_stdout = NULL;
  thread_stdin = NULL;
  thread_stderr = NULL;
}

- (void)lineSubmitted:(NSString *)line { 
  [self enqueueCommand:line];
}

@end
