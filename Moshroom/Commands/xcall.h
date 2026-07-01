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


#ifndef xcall_h
#define xcall_h

@interface MoshroomXCall: NSObject

@property NSString *callID;

@property BOOL async;
@property BOOL verbose;

@property NSURL *xURL;
@property NSURL *xCallbackURL;

@property NSURL *xSuccessURL;
@property NSURL *xErrorURL;
@property NSURL *xCancelURL;

@property NSURL *xOriginalSuccessURL;
@property NSURL *xOriginalErrorURL;
@property NSURL *xOriginalCancelURL;

@property NSMutableArray<NSArray<NSString *> *> *parseOutputParams; // [<paramName>, <decoder:json|base64>]
@property NSMutableArray<NSArray<NSString *> *> *encodeInputParams; // [<paramName>, <value>]

@property NSString *stdInParameterName;

@end

void moshroom_xcall(NSURL *url);
void moshroom_handle_url(NSURL *url);

#endif /* xcall_h */
