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

import Foundation
import UIKit

fileprivate var attachedShortcuts: [UIKeyCommand] = []

//To rebuild a menu, call the setNeedsRebuild method. Call setNeedsRevalidate when you need the menu system to revalidate a menu.
@objc public class MenuController: NSObject {
  enum ShellMenu: String, CaseIterable {
    case windowNew
    case windowClose
    case tabNew
    case tabClose
  }

  enum EditMenu: String, CaseIterable {
    case clipboardCopy
    case clipboardCopyRaw
    case clipboardPaste
    case selectionGoogle
    case selectionStackOverflow
    case selectionShare
  }
  
  enum ViewMenu: String, CaseIterable {
    case zoomIn
    case zoomOut
    case zoomReset
  }
  
  enum WindowMenu: String, CaseIterable {
    case windowFocusOther
    case tabMoveToOtherWindow
    case tabNext
    case tabPrev
    case tabLast
  }

  override private init() {}
  
  @objc public class func buildMenu(with builder: UIMenuBuilder) {
    // Drop the system menus that own shortcuts we want FIRST, before adding any command of our own:
    // a command whose key equivalent is still taken at the moment it is inserted gets dropped
    // silently (that is how New Tab went missing — the Font menu still held ⌘T).
    // We embed our own textSize inside View, so remove that one to avoid collisions.
    builder.remove(menu: .textSize)
    // remove cmd+b, cmd+i and cmd+u
    builder.remove(menu: .textStyle)
    // remove cmd+t (Show Fonts), which collides with New Tab
    builder.remove(menu: .font)

    let kbConfig = KBTracker.shared.loadConfig()

    attachedShortcuts = []
    let editMenuCommands:   [UICommand] = EditMenu.allCases.map   { _generate(Command(rawValue: $0.rawValue)!, with: kbConfig) }
      + Self.remainingStandardEditMenuCommands()
    let viewMenuCommands:   [UICommand] = ViewMenu.allCases.map   { _generate(Command(rawValue: $0.rawValue)!, with: kbConfig) }
    let windowMenuCommands: [UICommand] = WindowMenu.allCases.map { _generate(Command(rawValue: $0.rawValue)!, with: kbConfig) }

    // The shell commands (New Window / New Tab / Close Tab / Close Window) live in the STANDARD File
    // menu, and they are installed through File's LEAF GROUPS rather than through `.file` itself.
    // Two things were measured on macOS 26 Catalyst: a custom top-level "Shell" menu inserted with
    // `insertSibling(_:beforeMenu: .edit)` never appears (the menu bar showed Apple, Moshroom, File,
    // Edit, Format, View, Window, Help — so New Tab and its ⌘T did not exist at all), and
    // `replaceChildren(ofMenu: .file)` is silently ignored too (the builder still reported the
    // original children right after the call). The File menu is a container of system groups
    // (new-item, open, close, document, print) and replacing THOSE works — which also puts New Tab
    // and Close Tab exactly where a Mac user looks for them.
    builder.replaceChildren(ofMenu: UIMenu.Identifier("com.apple.menu.new-item")) { _ in
      [_shellCommand(.windowNew, kbConfig), _shellCommand(.tabNew, kbConfig)]
    }
    builder.replaceChildren(ofMenu: UIMenu.Identifier("com.apple.menu.close")) { _ in
      [_shellCommand(.tabClose, kbConfig), _shellCommand(.windowClose, kbConfig)]
    }
    // Document commands Catalyst adds by default, every one meaningless in a terminal:
    // Open… / Open Recent, Duplicate / Move / Rename… / Export As…, and Print.
    builder.remove(menu: UIMenu.Identifier("com.apple.menu.open"))
    builder.remove(menu: UIMenu.Identifier("com.apple.menu.document"))
    builder.remove(menu: UIMenu.Identifier("com.apple.menu.print"))

    builder.replaceChildren(ofMenu: .standardEdit) { _ in editMenuCommands   }
    builder.replaceChildren(ofMenu: .view)         { _ in viewMenuCommands  }
    builder.replaceChildren(ofMenu: .window)       { _ in windowMenuCommands }
    
  }
  
  // One shell command (with its configured shortcut, if any) — see buildMenu.
  private class func _shellCommand(_ item: ShellMenu, _ kbConfig: KBConfig) -> UICommand {
    return _generate(Command(rawValue: item.rawValue)!, with: kbConfig)
  }

  private class func _generate(_ command: Command, with kbConfig: KBConfig) -> UICommand {

    // For the action to be different, we are passing it as part of the PropertyList.
    // If the shortcut has already been assigned, then we define it as UICommand.
    if let shortcut = kbConfig.shortcuts.first(where: { s in // s.triggers(command)
      if case .command(let cmd) = s.action,
         case command = cmd
      {
        return true
      }
      return false
    })
    {
      // The same shortcut, or the same action, will make this crash with a
      // 'NSInternalInconsistencyException', reason: 'replacement menu has duplicate submenu,
      // command or key command, or a key command is missing input or action'.
      if !attachedShortcuts.contains(where: {
        $0.input == shortcut.input && $0.modifierFlags == shortcut.modifiers
      }) {
        let cmd =  UIKeyCommand(title: command.title,
                                action: #selector(SpaceController._onShortcut(_:)),
                                input: shortcut.input,
                                modifierFlags: shortcut.modifiers,
                                propertyList: ["Command": command.rawValue])

        if #available(iOS 15.0, *) {
          cmd.wantsPriorityOverSystemBehavior = true
        }
        
        
        attachedShortcuts.append(cmd)
        return cmd
      } else {
        // We will handle dups via pressesBegan, no need to alert user.
        
      }
    }
    return UICommand(
      title: command.title,
      image: nil,
      action: #selector(SpaceController._onShortcut(_:)),
      propertyList: ["Command": command.rawValue]
    )
  }
  
  // As we are rewriting the edit menu, if the standard sequences are not defined,
  // we add them here so they can go through the normal flow, and let our terminal map.
  private class func remainingStandardEditMenuCommands() -> [UICommand] {
    if ProcessInfo().isMacCatalystApp {
      return []
    }
    let copyCommand = UIKeyCommand(
      title: "",
      action: #selector(UIResponder.copy(_:)),
      input: "c",
      modifierFlags: .command,
      propertyList: nil
    )
    let cutCommand  = UIKeyCommand(
      title: "",
      action: #selector(UIResponder.cut(_:)),
      input: "x",
      modifierFlags: .command,
      propertyList: nil
    )
    let selectAllCommand =  UIKeyCommand(
      title: "",
      action: #selector(UIResponder.selectAll(_:)),
      input: "a",
      modifierFlags: .command,
      propertyList: nil
    )
    let toggleBoldCommand = UIKeyCommand(
      title: "",
      action: #selector(UIResponder.toggleBoldface(_:)),
      input: "b",
      modifierFlags: .command,
      propertyList: nil
    )
    let toggleItalicCommand = UIKeyCommand(
      title: "",
      action: #selector(UIResponder.toggleItalics(_:)),
      input: "i",
      modifierFlags: .command,
      propertyList: nil
    )
    let toggleUnderlineCommand = UIKeyCommand(
      title: "",
      action: #selector(UIResponder.toggleUnderline(_:)),
      input: "u",
      modifierFlags: .command,
      propertyList: nil
    )
    
    return [
      copyCommand,
      cutCommand,
      selectAllCommand,
      toggleBoldCommand, // from textStyle menu
      toggleItalicCommand,
      toggleUnderlineCommand
    ]
      .filter { shortcut in
        false == attachedShortcuts.contains(where: {
          $0.input == shortcut.input && $0.modifierFlags == shortcut.modifierFlags
        })
      }
  }
}

