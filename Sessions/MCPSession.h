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
// Set by the session payload's suspend BEFORE the child is asked to checkpoint, cleared on
// resume. YES means "the app is backgrounding this session" — its child (mosh) will terminate as
// part of the suspend, but the child marker + params MUST survive for the resume. The command
// loop reads this to tell an app suspend (keep everything) from a user exit (clear the marker).
// atomic: set on the suspend thread, read on the command queue thread.
@property (atomic) BOOL moshroomAppSuspending;

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
