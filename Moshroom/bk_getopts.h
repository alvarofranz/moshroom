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


#ifndef bk_getopts_h
#define bk_getopts_h

#include <stdio.h>

extern __thread int    thread_opterr,        /* if error message should be printed */
thread_optind,        /* index into parent argv vector */
thread_optopt,            /* character checked for validity */
thread_optreset;        /* reset getopt */
extern __thread char    * thread_optarg;        /* argument associated with option */


int thread_getopt(int nargc, char * const *nargv, const char *ostr);

#endif /* bk_getopts_h */
