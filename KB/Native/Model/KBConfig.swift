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


import Combine

class KBConfig: ObservableObject, Codable {
  @Published var capsLock: KeyConfig
  @Published var shift:    KeyConfigPair
  @Published var control:  KeyConfigPair
  @Published var option:   KeyConfigPair
  @Published var command:  KeyConfigPair

  @Published var fnBinding:     KeyBinding
  @Published var cursorBinding: KeyBinding

  @Published var shortcuts:     [KeyShortcut]
  
  private var _cancellable = Set<AnyCancellable>()
  
  init(
    capsLock:      KeyConfig     = .capsLock,
    shift:         KeyConfigPair = .shift,
    control:       KeyConfigPair = .control,
    option:        KeyConfigPair = .option,
    command:       KeyConfigPair = .command,
    fnBinding:     KeyBinding    = KeyBinding(keys: [KeyCode.commandLeft.id]),
    cursorBinding: KeyBinding    = KeyBinding(keys: [KeyCode.commandLeft.id]),
    shortcuts:     [KeyShortcut] = KeyShortcut.defaultList
  ) {
    self.capsLock      = capsLock
    self.shift         = shift
    self.control       = control
    self.option        = option
    self.command       = command
    self.fnBinding     = fnBinding
    self.cursorBinding = cursorBinding
    self.shortcuts     = shortcuts

    _bindNotifications()
  }
  
  func reset() {
    self.capsLock = .capsLock
    self.shift = .shift
    self.control = .control
    self.option = .option
    self.command = .command
    self.fnBinding = KeyBinding(keys: [KeyCode.commandLeft.id])
    self.cursorBinding = KeyBinding(keys: [KeyCode.commandLeft.id])
    self.shortcuts = KeyShortcut.defaultList
    
    _bindNotifications()
  }
  
  func _bindNotifications() {
    _cancellable = Set<AnyCancellable>()
    
    capsLock.objectWillChange.sink(receiveValue: objectWillChange.send).store(in: &_cancellable)
    shift.objectWillChange.sink(receiveValue: objectWillChange.send).store(in: &_cancellable)
    control.objectWillChange.sink(receiveValue: objectWillChange.send).store(in: &_cancellable)
    option.objectWillChange.sink(receiveValue: objectWillChange.send).store(in: &_cancellable)
    command.objectWillChange.sink(receiveValue: objectWillChange.send).store(in: &_cancellable)
    fnBinding.objectWillChange.sink(receiveValue: objectWillChange.send).store(in: &_cancellable)
    cursorBinding.objectWillChange.sink(receiveValue: objectWillChange.send).store(in: &_cancellable)
  }
  
  func touch() {
    objectWillChange.send()
  }
  
  // - MARK: Codable
  
  enum Keys: CodingKey {
    case capsLock
    case shift
    case control
    case option
    case command
    case fn
    case cursor
    case shortcuts
  }
  
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(capsLock,      forKey: .capsLock)
    try c.encode(shift,         forKey: .shift)
    try c.encode(control,       forKey: .control)
    try c.encode(option,        forKey: .option)
    try c.encode(command,       forKey: .command)
    try c.encode(fnBinding,     forKey: .fn)
    try c.encode(cursorBinding, forKey: .cursor)
    try c.encode(shortcuts,     forKey: .shortcuts)
  }
  
  required convenience init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    
    let capsLock      = try c.decode(KeyConfig.self,     forKey: .capsLock)
    let shift         = try c.decode(KeyConfigPair.self, forKey: .shift)
    let control       = try c.decode(KeyConfigPair.self, forKey: .control)
    let option        = try c.decode(KeyConfigPair.self, forKey: .option)
    let command       = try c.decode(KeyConfigPair.self, forKey: .command)
    let fnBinding     = try c.decode(KeyBinding.self,    forKey: .fn)
    let cursorBinding = try c.decode(KeyBinding.self,    forKey: .cursor)
    let shortcuts     = try c.decode([KeyShortcut].self, forKey: .shortcuts)
    
    self.init(
      capsLock: capsLock,
      shift: shift,
      control: control,
      option: option,
      command: command,
      fnBinding: fnBinding,
      cursorBinding: cursorBinding,
      shortcuts: shortcuts
    )
  }
  
}
