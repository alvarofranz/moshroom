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


#ifndef Moshroom_bridge_h
#define Moshroom_bridge_h

#include <stdio.h>
#include <pthread.h>

typedef int socket_t;
extern void __thread_ssh_execute_command(const char *command, socket_t in, socket_t out);
extern int ios_dup2(int fd1, int fd2);
extern void ios_exit(int errorCode) __dead2; // set error code and exits from the thread.

typedef void (*mosh_state_callback) (const void *context, const void *buffer, size_t size);

#import "MoshroomDefaults.h"
#import "MoshTheme.h"
#import "MoshFont.h"
#import "UIDevice+DeviceName.h"
#import "MoshHosts.h"
#import "MoshroomPaths.h"
#import "DeviceInfo.h"
#import "LayoutConstraintManager.h"
#import "MoshUserConfigurationManager.h"
#import "Session.h"
#import "MCPSession.h"
#import "TermDevice.h"
#import "TermView.h"
#import "KBWebViewBase.h"
#import "openurl.h"
#import "MoshPubKey.h"
#import "MoshHosts.h"
#import "UICKeyChainStore.h"
#import "UIApplication+Version.h"
#import "AppDelegate.h"
#import "MoshLinkActions.h"
#import "mosh/moshiosbridge.h"


#endif /* Moshroom_bridge_h */
