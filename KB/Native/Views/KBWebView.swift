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


import UIKit

class MoshroomCommand: UIKeyCommand {
  var bindingAction: KeyBindingAction = .none
}

class KBWebView: KBWebViewBase {

  private(set) var webViewReady = false
  private(set) var moshroomKeyCommands: [MoshroomCommand] = []
  private(set) var allMoshroomKeyCommands: [MoshroomCommand] = []
  
  func configure(_ cfg: KBConfig) {
    _buildCommands(cfg)

    guard
      let data = try? JSONEncoder().encode(cfg),
      let json = String(data: data, encoding: .utf8)
    else {
      return
    }
    report("config", arg: json as NSString)
  }
  
  func _buildCommands(_ cfg: KBConfig) {
    
    self.moshroomKeyCommands.removeAll()
    self.allMoshroomKeyCommands.removeAll()
    
    cfg.shortcuts.forEach { shortcut in
      guard !shortcut.isCleared else { return }
      let cmd = MoshroomCommand(
        title: "",
        image: nil,
        action: #selector(SpaceController._onMoshroomCommand(_:)),
        input: shortcut.input,
        modifierFlags: shortcut.modifiers,
        propertyList: nil
      )
      cmd.bindingAction = shortcut.action
      
      allMoshroomKeyCommands.append(cmd)
      
      if !shortcut.action.isCommand {
        moshroomKeyCommands.append(cmd)
      }
    }
  }
  
  
  override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
    return .none
  }
  
  func matchCommand(input: String, flags: UIKeyModifierFlags) -> (UIKeyCommand, UIResponder)? {
    var result: (UIKeyCommand, UIResponder)? = nil
    
    var iterator: UIResponder? = self
    
    // try first on space controller
    let cmd = allMoshroomKeyCommands.first(
      where: {
        $0.input == input && $0.modifierFlags == flags
      }
    )
    
    if let cmd = cmd {
      while let responder = iterator {
        if let _ = responder as? SpaceController,
           let action = cmd.action,
           responder.canPerformAction(action, withSender: self) {
          return (cmd, responder)
        }
        iterator = responder.next
      }
    }
    
    iterator = self
    
    while let responder = iterator {
      if let cmd = responder.keyCommands?.first(
        where: {
          $0.input == input && $0.modifierFlags == flags
        }),
         let action = cmd.action,
         responder.canPerformAction(action, withSender: self)
      {
        result = (cmd, responder)
      }
      iterator = responder.next
    }

    return result
  }
  
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    guard
      let key = presses.first?.key,
      let (cmd, responder) = matchCommand(input: key.charactersIgnoringModifiers, flags: key.modifierFlags),
      let action = cmd.action
    else {
      if let key = presses.first?.key,
         key.keyCode.rawValue == 55,
         key.characters == "UIKeyInputEscape"
      {
        self.reportToolbarPress(key.modifierFlags.union(.command), keyId: "190:0")
        return
      }
      super.pressesBegan(presses, with: event)
      return
    }

    responder.perform(action, with: cmd)
  }

  func contentView() -> UIView? {
    scrollView.subviews.first
  }
  
  func disableTextSelectionView() {
    let subviews = scrollView.subviews
    guard
      subviews.count > 2,
      let v = subviews[1].subviews.first
    else {
      return
    }
    NotificationCenter.default.removeObserver(v)
  }
  
  override func ready() {
    webViewReady = true
    super.ready()
    configure(KBTracker.shared.loadConfig())
  }
  
  override func didMoveToSuperview() {
    super.didMoveToSuperview()
  }
}
