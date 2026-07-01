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

#import "TermStream.h"

@implementation TermStream

- (void)close {
  if (_in) {
    fclose(_in);
    _in = NULL;
  }
  if (_out) {
    fclose(_out);
    _out = NULL;
  }
  if (_err) {
    fclose(_err);
    _err = NULL;
  }
}

// We are not a TTY, but the closest is to read directly from stdin as we offer it, without
// intermediaries (except the terminal itself).
- (FILE*)openTTY {
  return fdopen(dup(fileno(_in)), "rb");
}

- (void)closeIn {
  if (_in) {
    fflush(_in);
    fclose(_in);
    _in = NULL;
  }
}

- (instancetype) duplicate {
  TermStream *dupe = [[TermStream alloc] init];
  
  dupe.in = fdopen(dup(fileno(_in)), "rb");
  // If there is no underlying descriptor (writing to the WV), then duplicate the fterm.
  dupe.out = fdopen(dup(fileno(_out)), "wb");
  dupe.err = fdopen(dup(fileno(_err)), "wb");
  setvbuf(dupe.out, NULL, _IONBF, 0);
  setvbuf(dupe.err, NULL, _IONBF, 0);
  setvbuf(dupe.in, NULL, _IONBF, 0);

  return dupe;
}

@end
