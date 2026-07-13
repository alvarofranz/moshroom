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

#import "MoshroomDefaults.h"

#include "ios_system/ios_system.h"
#include "ios_error.h"
#include "UIApplication+Version.h"
#include <Moshroom-Swift.h>
#include "MCPSession.h"

void __print_commands(void) {
  MCPSession *session = (__bridge MCPSession *)thread_context;
  if (!session) {
    return;
  }

  NSString *formattedCommands = [CompleteClass formattedCommandsWithWidth: session.device.cols];
  puts(formattedCommands.UTF8String);
}

__attribute__ ((visibility("default")))
int help_main(int argc, char *argv[]) {
  
  if (argc == 2 && [@"list-commands" isEqual: @(argv[1])]) {
    __print_commands();
    return 0;
  }
  NSString *help = [@[
    @"",
    [UIApplication moshroomVersion],
    @"",
    @"Available commands:",
    @"  <tab>: list available UNIX commands.",
    @"  mosh: mosh client.",
    @"  ssh: ssh client.",
    @"  config: Setup ssh keys, hosts, keyboard, etc.",
    @"  help: Prints this.",
    @"  exit: Close this shell.",
    @"",
    @"Gestures:",
    @"  👆 swipe -> Scroll the terminal.  ",
    @"  👆 long press -> Select a word, then Copy.  ",
    @"",
    @"Shortcuts:",
    @"  Press and hold ⌘ on hardware kb to show a list of shortcuts.",
    @"  Run config. Go to Keyboard > Shortcuts for configuration.",
    @"",
    @"Selection Control:",
    @"  VIM users:",
    @"    h j k l (left, down, up, right)",
    @"    w b (forward/backward by word)",
    @"    o (change selection point)",
    @"    y p (yank, paste)",
    @"  EMACS users:",
    @"    C-f,b,n,p (right, left, down, up)",
    @"    C-M-f,b (forward/backward by word)",
    @"    C-x (change selection point)",
    @"  OTHER: arrows and fingers",
    @"",

 ] componentsJoinedByString:@"\n"];
 
  puts(help.UTF8String);
  
  return 0;
}
