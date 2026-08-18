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

#ifndef TermJS_h
#define TermJS_h

NSString *_encodeString(NSString *str)
{
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:str options:NSJSONWritingFragmentsAllowed error:nil];
  return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

NSString *term_init(BOOL accessibilityEnabled, BOOL lockdownMode)
{
  return [NSString stringWithFormat:@"term_init(%@, %@);", accessibilityEnabled ? @"true" : @"false", lockdownMode ? @"true" : @"false"];
}

NSString *term_write(NSString *data) {
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:data options:NSJSONWritingFragmentsAllowed error:nil];
  
  NSMutableData *result = [[NSMutableData alloc] initWithCapacity:jsonData.length + 11 + 2];
  [result appendBytes:"term_write(" length:11];
  [result appendData:jsonData];
  [result appendBytes:");" length:2];
  return [[NSString alloc] initWithData:result encoding:NSUTF8StringEncoding];
}

NSString *term_writeB64(NSData *data) {
  return [NSString stringWithFormat:@"term_write_b64(\"%@\");", [data base64EncodedStringWithOptions:kNilOptions]];
}

NSString *term_paste(NSString *str) {
  return [NSString stringWithFormat:@"term_paste(%@);", _encodeString(str)];
}

NSString *term_setWidth(NSInteger count)
{
  return [NSString stringWithFormat:@"term_setWidth(\"%ld\");", (long)count];
}

NSString *term_increaseFontSize(void)
{
  return @"term_increaseFontSize();";
}

NSString *term_decreaseFontSize(void)
{
  return @"term_decreaseFontSize();";
}

NSString *term_setFontSize(NSNumber *newSize)
{
  return [NSString stringWithFormat:@"term_setFontSize(\"%@\");", newSize];
}

NSString *term_setCursorBlink(BOOL state)
{
  return [NSString stringWithFormat:@"term_set('cursor-blink', %@);", state ? @"true" : @"false"];
}

NSString *term_setBoldAsBright(BOOL state)
{
  return [NSString stringWithFormat:@"term_set('enable-bold-as-bright', %@);", state ? @"true" : @"false"];
}

NSString *term_setBoldEnabled(NSUInteger state)
{
  NSString *stateStr = @"null";
  if (state == 1) {
    stateStr = @"true";
  } else if (state == 2) {
    stateStr = @"false";
  }
  return [NSString stringWithFormat:@"term_set('enable-bold', %@);", stateStr];
}

NSString *term_setClipboardWrite(BOOL state)
{
  return [NSString stringWithFormat:@"term_setClipboardWrite(%@);", state ? @"true" : @"false"];
}

NSString *term_setFontFamily(NSString *family, NSString * fontSizeDetectionMethod)
{
  return [NSString stringWithFormat:@"term_setFontFamily(%@, %@);", _encodeString(family), _encodeString(fontSizeDetectionMethod)];
}

NSString *term_appendUserCss(NSString *css)
{
  return [NSString stringWithFormat:@"term_appendUserCss(%@)", _encodeString(css)];
}

// Palette black must equal the terminal background: a program that paints an explicit black
// background assumes the terminal is black too, and against Moshroom's near-black that arrives as a
// hard band across the terminal. Applied LAST in the appearance command list, after the theme has set
// both the palette and the background. See _moshroomBlendPaletteBlack in term.js.
NSString *term_blendPaletteBlack(void)
{
  return @"_moshroomBlendPaletteBlack();";
}

NSString *term_cleanSelection(void)
{
  return @"term_cleanSelection();";
}

NSString *term_modifySelection(NSString *direction, NSString *granularity)
{
  return [NSString stringWithFormat:@"term_modifySelection(%@, %@);", _encodeString(direction), _encodeString(granularity)];
}

NSString *term_modifySideSelection(void)
{
  return @"term_modifySideSelection();";
}

NSString *term_processKB(NSString *str) {
  return  [NSString stringWithFormat:@"term_processKB(%@);", _encodeString(str)];
}

NSString *term_displayInput(NSString *str, BOOL display) {
  return  [NSString stringWithFormat:@"term_displayInput(%@, %@);", _encodeString(str), display ? @"true" : @"false"];
}

NSString *term_apiResponse(NSString *name, NSString *response) {
  return  [NSString stringWithFormat:@"term_apiResponse(%@, %@);", _encodeString(name), _encodeString(response)];
}




#endif /* TermJS_h */
