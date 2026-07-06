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

#import "SSHCopyIDSession.h"
#import "MoshPubKey.h"
#import "SSHSession.h"

static const char *copy_command =
"sh -c 'umask 077; test -d ~/.ssh || mkdir ~/.ssh ; cat >> .ssh/authorized_keys; test -x /sbin/restorecon && /sbin/restorecon .ssh .ssh/authorized_keys'";

static const char *usage_format =
  "Usage: ssh-copy-id identity_file [user@]host";

@implementation SSHCopyIDSession

- (int)main:(int)argc argv:(char **)argv
{
  if (argc != 3) {
    return [self dieMsg:@(usage_format)];
  }

  NSString *keyName = [NSString stringWithFormat:@"%s", argv[1]];
  MoshPubKey *pkcard = [MoshPubKey withID:keyName];

  if (!pkcard) {
    return [self dieMsg:@"ERROR: No identities found."];
  }
  const char *public_key = [[pkcard publicKey] UTF8String];

  SSHSession *sshSession = [[SSHSession alloc] initWithDevice:_device andParams:nil];
  
  // Pipe public key
  int pinput[2];
  pipe(pinput);
  FILE *inputr = fdopen(pinput[0], "r");
  fclose(sshSession.stream.in);
  sshSession.stream.in = inputr;

  write(pinput[1], public_key, strlen(public_key));
  write(pinput[1], "\n", 1);
  close(pinput[1]);

  NSString *ssh_command = [NSString stringWithFormat:@"ssh -v %s -- %s", argv[2], copy_command];
  [sshSession executeAttachedWithArgs:ssh_command];

  close(pinput[0]);

  return 0;
}

- (int)dieMsg:(NSString *)msg
{
  fprintf(_stream.out, "%s\n", [msg UTF8String]);
  return -1;
}

@end
