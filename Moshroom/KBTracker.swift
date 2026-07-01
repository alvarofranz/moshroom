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

// MARK: - KBObserver Removed
// KBObserver class has been completely removed and replaced by UIKeyboardLayoutGuide integration
// All keyboard tracking is now handled by SpaceController using UIKeyboardLayoutGuide

class KBTracker: NSObject {
  private(set) var hideSmartKeysWithHKB = true

  @objc static let shared = KBTracker()
  
  private(set) var kbTraits = KBTraits.initial
  private(set) var kbDevice = KBDevice.detect()
  
  private(set) var input: SmarterTermInput? = nil
  
  
  @objc var isHardwareKB: Bool = true {
    didSet {
      let oldValue = kbTraits.isHKBAttached;
      kbTraits.isHKBAttached = isHardwareKB
      input?.kbView.traits.isHKBAttached = isHardwareKB
      input?.kbView.setNeedsLayout()
      if kbTraits.isHKBAttached != oldValue {
        input?.sync(traits: kbTraits, device: kbDevice, hideSmartKeysWithHKB: hideSmartKeysWithHKB)
      }
    }
  }
  
  private func _loadKBConfigData() -> Data? {
    guard
      let url = MoshroomPaths.moshroomKBConfigURL(),
      let data = try? Data(contentsOf: url)
      else {
        return nil
    }
    return data
  }
  
  
  func loadConfig() -> KBConfig {
    guard
      let data = _loadKBConfigData(),
      let cfg = try? JSONDecoder().decode(KBConfig.self, from: data)
      else {
        return KBConfig()
    }

    // Single shortcut per action.
    var seenActions = Set<String>()
    cfg.shortcuts.removeAll { shortcut in
      if seenActions.contains(shortcut.action.id) { return true }
      seenActions.insert(shortcut.action.id)
      return false
    }

    // Merge in any new default commands not already present
    for defaultShortcut in KeyShortcut.defaultList {
      let commandExists = cfg.shortcuts.contains { shortcut in
        if case .command(let cmd) = shortcut.action,
           case .command(let defaultCmd) = defaultShortcut.action {
          return cmd == defaultCmd
        }
        return false
      }

      if !commandExists {
        cfg.shortcuts.append(defaultShortcut)
      }
    }
    return cfg;
  }
  
  func save(config: KBConfig) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    guard
      let url = MoshroomPaths.moshroomKBConfigURL(),
      let data = try? encoder.encode(config)
      else {
        return
    }

    try? data.write(to: url, options: .atomicWrite)
    UIMenuSystem.main.setNeedsRebuild()
  }
  
  func attach(input: SmarterTermInput?) {
    self.input = input
    input?.sync(traits: kbTraits, device: kbDevice, hideSmartKeysWithHKB: hideSmartKeysWithHKB)
    input?.configure(loadConfig())
  }
  
  override init() {
    super.init()
    let nc = NotificationCenter.default
    
//    kbTraits.isHKBAttached = true
    
    // MARK: - Notification Observers
    // Keep only observers needed for hardware keyboard detection and input mode changes
    // Keyboard show/hide events are now handled by UIKeyboardLayoutGuide in SpaceController
    nc.addObserver(self, selector: #selector(_keyboardDidChangeFrame(_:)), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
    nc.addObserver(self, selector: #selector(_inputModeChanged), name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
    nc.addObserver(self, selector: #selector(_updateSettings), name: NSNotification.Name.MoshUserConfigChanged, object: nil)
  }
  
  @objc private func _updateSettings() {
    input?.sync(traits: kbTraits, device: kbDevice, hideSmartKeysWithHKB: hideSmartKeysWithHKB)
  }
  
  @objc func _inputModeChanged() {
    if let input = self.input {
      DispatchQueue.main.async {
        input.reportLang()
      }
    }
  }
  
  @objc private func _keyboardDidChangeFrame(_ notification: Notification) {
    guard
      let userInfo = notification.userInfo,
      let _ = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
      let _ = userInfo[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect //,
      else {
        return
    }
    
    
    if isHardwareKB {
      if kbTraits.isFloatingKB {
          kbDevice = .detect()
      }
      kbTraits.isFloatingKB = false
    }
  }

  // MARK: - Legacy Keyboard Methods Removed
  // These empty keyboard event methods have been removed as keyboard tracking
  // is now handled by UIKeyboardLayoutGuide in SpaceController
}
