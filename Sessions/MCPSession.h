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

#import "TermDevice.h"
#import "Session.h"


@class MCPParams;
@class MoshroomSSH;

@interface MCPSession : Session <TermDeviceReadlineListener>

@property (strong) MCPParams *sessionParams;
@property (readonly) dispatch_queue_t cmdQueue;
// Set by the mosh child right before mosh_main returns: YES when the return was an app-driven
// suspend (keep the child marker and encoded state for the resume), NO when the session ended
// for real. Explicit on purpose: inferring "suspended" from hasEncodedState races the session
// payload's takeEncodedState (it extracts the checkpoint into its snapshot on suspend).
@property (nonatomic) BOOL moshroomChildSuspended;

- (void)registerSSHClient:(id __weak)sshClient;
- (void)unregisterSSHClient:(id __weak)sshClient;

- (void)enqueueCommand:(NSString *)cmd;
- (void)enqueueCommand:(NSString *)cmd skipHistoryRecord: (BOOL) skipHistoryRecord;
- (bool)isRunningCmd;

// Moshroom: the terminal's web view was reloaded after WebKit jettisoned its content process —
// the rendered transcript (and with it the prompt line) is gone. If the shell is sitting idle at
// its prompt, print it again so the recovered tab reads as a live shell, not an empty void.
- (void)moshroomReprintPromptIfIdle;

- (void)updateAllowedPaths;
- (void)setActiveSession;

@end
