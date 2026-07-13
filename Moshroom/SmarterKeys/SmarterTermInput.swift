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
import Combine


@objc class SmarterTermInput: KBWebView {
  
  var kbView = KBView()
  var _proxyBarButtonItem: UIBarButtonItem!
  var _barButtonItemGroup: UIBarButtonItemGroup!
  
  lazy var _kbProxy: KBProxy = {
    KBProxy(kbView: self.kbView)
  }()
  
  private var _inputAccessoryView: UIView? = nil
  
  var isHardwareKB: Bool { kbView.traits.isHKBAttached }
  
  weak var device: TermDevice? = nil {
    didSet { reportStateReset() }
  }
  
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  
  override init(frame: CGRect, configuration: WKWebViewConfiguration) {
    
    
    super.init(frame: frame, configuration: configuration)


    _proxyBarButtonItem = UIBarButtonItem(customView: _kbProxy)
    _barButtonItemGroup = UIBarButtonItemGroup(barButtonItems: [_proxyBarButtonItem], representativeItem: nil)
    
    kbView.keyInput = self
    kbView.lang = textInputMode?.primaryLanguage ?? ""
    
    // Assume hardware kb by default, since sometimes we don't have kbframe change events
    // if shortcuts toggle in Settings.app is off.
    kbView.traits.isHKBAttached = true
    
    // iPad's input-assistant bar is unused under Moshroom; only the accessory view is set up.
    if traitCollection.userInterfaceIdiom != .pad {
      _setupAccessoryView()
    }

    #if targetEnvironment(macCatalyst)
    // When a Mac window becomes key again (Cmd-Tab away and back), AppKit restores first
    // responder to the web content view — from then on selections paint through the UIKit
    // overlay (deactivated gray / accent blue) instead of the page's red CSS. Take it back the
    // moment the window returns.
    NotificationCenter.default.addObserver(
      self, selector: #selector(_moshroomWindowDidBecomeKey(_:)),
      name: UIWindow.didBecomeKeyNotification, object: nil)
    #endif
  }

  #if targetEnvironment(macCatalyst)
  @objc private func _moshroomWindowDidBecomeKey(_ note: Notification) {
    guard (note.object as? UIWindow) === window else { return }
    // Async: AppKit may restore the first responder after posting the notification.
    DispatchQueue.main.async { [weak self] in self?.deactivateSelectionUI() }
  }
  #endif
  
  override func layoutSubviews() {
    super.layoutSubviews()
   
    if let value = self.window?.windowScene?.interfaceOrientation.isPortrait  {
      kbView.traits.isPortrait = value
    }
    kbView.setNeedsLayout()
  }
  
  func shouldUseWKCopyAndPaste() -> Bool {
    false
  }
  
  override func ready() {
    super.ready()
    reportLang()
    
//    device?.focus()
    kbView.isHidden = false
    kbView.invalidateIntrinsicContentSize()
  }
  
  func reset() {
    
  }
  
  func reportLang() {
    let lang = self.textInputMode?.primaryLanguage ?? ""
    kbView.lang = lang
    reportLang(lang, isHardwareKB: kbView.traits.isHKBAttached)
  }
  
  override var inputAssistantItem: UITextInputAssistantItem {
    let item = super.inputAssistantItem
    if KBTracker.shared.isHardwareKB {
      item.trailingBarButtonGroups = []
      item.leadingBarButtonGroups = []
    } else if _barButtonItemGroup != nil {
      item.leadingBarButtonGroups = []
      if item.trailingBarButtonGroups.first != _barButtonItemGroup || item.trailingBarButtonGroups.count != 1 {
        item.trailingBarButtonGroups = [_barButtonItemGroup]
        
        // Reload input views later. Fixes crash for detaching/attaching KB
        if let contentView = self.contentView() {
          DispatchQueue.main.async {
            contentView.reloadInputViews()
          }
        }
        
      }
      kbView.isHidden = false
      
    } else {
      item.trailingBarButtonGroups = []
      item.leadingBarButtonGroups = []
    }
    
    return item
  }
  
  override func becomeFirstResponder() -> Bool {
    // Moshroom: the terminal never takes the keyboard — all input goes through Moshkitor.
    if Moshroom.scratchOnly {
      return false
    }
    // Don't become first responder if blocked (e.g., during Snips Input Mode)
    if device?.shouldBlockFirstResponder == true {
      return false
    }

    sync(traits: KBTracker.shared.kbTraits, device: KBTracker.shared.kbDevice, hideSmartKeysWithHKB: KBTracker.shared.hideSmartKeysWithHKB)

    let res = super.becomeFirstResponder()

    if !webViewReady {
      return res
    }

    device?.focus()
    kbView.isHidden = false
    setNeedsLayout()

    _inputAccessoryView?.isHidden = false

    return res
  }
  
  
  var isRealFirstResponder: Bool {
    contentView()?.isFirstResponder == true
  }

  // Moshroom: on iOS, WKWebView only paints the ACTIVE selection look — the tinted (red)
  // highlight plus the grab handles — while its inner content view is first responder. Otherwise
  // UIKit shows the deactivated appearance: a dull dark box, no handles. That's why long-press
  // selections came up "sometimes red and draggable, sometimes black and dead" — it depended on
  // whether WebKit had happened to make the content view first responder earlier. Making it first
  // responder exactly while a selection exists (and resigning when it clears) makes the good case
  // THE case.
  //
  // This does NOT break the scratchOnly invariant (typing goes to Moshkitor, the terminal never
  // shows a keyboard): `becomeFirstResponder` on this view stays blocked; the content view is
  // targeted directly, and no keyboard can come up because the page's editable element was
  // focused programmatically — WebKit never starts an input session for it (same reason the
  // pre-existing "good" selections never raised one).
  //
  // Mac Catalyst deliberately does NOT take first responder: there are no grab handles on the
  // Mac anyway, a first-responder WKWebView swallows hardware keys (the known Ventura+ bug), and
  // the activated overlay paints with the SYSTEM accent (blue) instead of Moshroom red. Left
  // unfocused, the selection is painted by the page itself — where the injected
  // ::selection/:window-inactive CSS keeps it Moshroom red (term.js scopes user-select to the
  // selection's lifetime so that styling applies).
  @objc func activateSelectionUI() {
    #if targetEnvironment(macCatalyst)
    // Not just a no-op: AppKit RESTORES first responder to the content view whenever the window
    // becomes key again (Cmd-Tab away and back), and from then on selections paint through the
    // UIKit overlay — dull black, or accent blue — instead of the page's red CSS. Undo it at
    // every selection so the page stays the painter.
    //
    // (A related trap, fixed at the ROOT elsewhere: presenting a `.fullScreen` modal pulls this
    // web view out of the window, and on re-add WebKit latches selection painting into a dead
    // near-black box that NO responder dance reliably heals — which is why every full-screen
    // Moshroom modal presents as `.overFullScreen` instead, keeping the terminal in the window.)
    deactivateSelectionUI()
    #else
    guard let cv = contentView(), !cv.isFirstResponder else { return }
    cv.becomeFirstResponder()
    #endif
  }

  @objc func deactivateSelectionUI() {
    guard let cv = contentView(), cv.isFirstResponder else { return }
    cv.resignFirstResponder()
  }
  
  func reportStateReset() {
    reportStateReset(false)
    device?.view?.cleanSelection()
  }
  
  func reportStateWithSelection() {
    reportStateReset(device?.view?.hasSelection ?? false)
  }
  
  
  override func resignFirstResponder() -> Bool {
    let res = super.resignFirstResponder()
    if res {
      device?.blur()
      kbView.isHidden = true
      _inputAccessoryView?.isHidden = true
    }
    return res
  }

  func _setupAccessoryView() {
    if isHardwareKB {
      return
    }
    inputAssistantItem.leadingBarButtonGroups = []
    inputAssistantItem.trailingBarButtonGroups = []

    if let _ = _inputAccessoryView as? KBAccessoryView {
    } else {
      _inputAccessoryView = KBAccessoryView(kbView: kbView)
    }
  }

  override var inputAccessoryView: UIView? {
    if isHardwareKB {
      return nil
    }
    
    return _inputAccessoryView
  }

  func sync(traits: KBTraits, device: KBDevice, hideSmartKeysWithHKB: Bool) {
    kbView.kbDevice = device
    
    defer {
      
      kbView.traits = traits
      
      if let scene = window?.windowScene {
        if traitCollection.userInterfaceIdiom == .phone {
          kbView.traits.isPortrait = scene.interfaceOrientation.isPortrait
        } else if kbView.traits.isFloatingKB {
          kbView.traits.isPortrait = true
        } else {
          kbView.traits.isPortrait = scene.interfaceOrientation.isPortrait
        }
      }
      
    }
    
    if traitCollection.userInterfaceIdiom == .phone {
      if hideSmartKeysWithHKB && traits.isHKBAttached {
        _removeSmartKeys()
        return
      }
    }
    
    if traits.isFloatingKB {
      _setupAccessoryView()
      return
    }
    
    if traitCollection.userInterfaceIdiom != .pad {
//      needToReload = (_inputAccessoryView as? KBAccessoryView) == nil
      _setupAccessoryView()
    }
    
  }
  
  func _removeSmartKeys() {
    if let _ = _inputAccessoryView as? KBAccessoryView {
      _inputAccessoryView = UIView(frame: .zero)
      self.contentView()?.reloadInputViews()      
    }
    
    guard let item = contentView()?.inputAssistantItem
      else {
        return
    }
    item.leadingBarButtonGroups = []
    item.trailingBarButtonGroups = []
    setNeedsLayout()
  }
  
  // MARK: - Legacy Keyboard Methods Removed
  // These empty override methods have been removed as keyboard tracking
  // is now handled by UIKeyboardLayoutGuide in SpaceController
  
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    super.pressesBegan(presses, with: event)
    
    guard presses.count == 1, let press = presses.first, let key = press.key,
    // left or right cmd
    key.keyCode.rawValue == 227 || key.keyCode.rawValue == 231
    else {
      commandPressTimestamp = 0
      return
    }
    
    if press.timestamp - commandPressTimestamp > 0.5 {
      commandPressTimestamp = press.timestamp
      return
    }
    
    UIApplication.shared.sendAction(#selector(SpaceController.toggleQuickActionsAction), to: nil, from: nil, for: nil)
    commandPressTimestamp = 0
  }
  
  var commandPressTimestamp: TimeInterval = 0
}

// - MARK: Web communication
extension SmarterTermInput {
  
  override func onOut(_ data: String) {
    defer {
      kbView.turnOffUntracked()
    }
    
    guard
      let device = device,
      let deviceView = device.view,
      let scene = deviceView.window?.windowScene,
      scene.activationState == .foregroundActive
    else {
        return
    }
    
    deviceView.displayInput(data)
    
    device.write(data)
  }
  
  override func onCommand(_ command: String) {
    kbView.turnOffUntracked()
    guard
      let device = device,
      let scene = device.view.window?.windowScene,
      scene.activationState == .foregroundActive,
      let cmd = Command(rawValue: command),
      let spCtrl = spaceController
    else {
      return
    }
    
    spCtrl._onCommand(cmd)
  }
  
  var spaceController: SpaceController? {
    var n = next
    while let responder = n {
      if let spCtrl = responder as? SpaceController {
        return spCtrl
      }
      n = responder.next
    }
    return nil
  }
  
  override func onSelection(_ args: [AnyHashable : Any]) {
    if let dir = args["dir"] as? String, let gran = args["gran"] as? String {
      device?.view?.modifySelection(inDirection: dir, granularity: gran)
    } else if let op = args["command"] as? String {
      switch op {
      case "change": device?.view?.modifySideOfSelection()
      case "copy": copy(self)
      case "paste": device?.view?.pasteSelection(self)
      case "cancel": fallthrough
      default:  device?.view?.cleanSelection()
      }
    }
  }
  
  override func onMods() {
    kbView.stopRepeats()
  }
  
  override func onIME(_ event: String, data: String) {
    if event == "compositionstart" && data.isEmpty {
    } else if event == "compositionend" {
      kbView.traits.isIME = false
    } else { // "compositionupdate"
      kbView.traits.isIME = true
    }
  }
  
  func stuckKey() -> KeyCode? {
    let mods: UIKeyModifierFlags = [.shift, .control, .alternate, .command]
    let stuck = mods.intersection(trackingModifierFlags)
    
    // Return command key first
    if stuck.contains(.command) {
      return KeyCode.commandLeft
    }

    if stuck.contains(.shift) {
      return KeyCode.shiftLeft
    }
    if stuck.contains(.control) {
      return KeyCode.controlLeft
    }
    
    if stuck.contains(.alternate) {
      return KeyCode.optionLeft
    }
    
    return nil
  }
}

// - MARK: Commands

extension SmarterTermInput {
  
  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    // Hardware-keyboard shortcuts (⌘C/⌘V/⌘X) arrive with `sender == nil` — let those keep working.
    // The on-screen selection menu (`sender != nil`, incl. WebKit's own native menu on the drag
    // handles) is a single clean **Copy** for this read-only terminal: everything else is refused.
    let fromKeyboard = (sender == nil)
    switch action {
    case #selector(UIResponder.copy(_:)),
         #selector(Self.copyRaw(_:)):
      return fromKeyboard || (device?.view?.hasSelection == true)
    case #selector(UIResponder.paste(_:)),
         #selector(UIResponder.cut(_:)):
      // Never in the selection menu — only via the hardware keyboard.
      return fromKeyboard
    default:
      // Refuse everything else in the selection menu (Cut, Paste, AutoFill, Select, Select All,
      // Look Up, Translate, Share, pasteSelection/soSelection/…). Keyboard actions defer to super.
      return fromKeyboard ? super.canPerformAction(action, withSender: sender) : false
    }
  }

  // The on-screen selection menu — including WebKit's OWN menu that pops up when you drag the
  // selection handles (WKContentView is first responder then, so `canPerformAction` above never
  // runs) — is built via the responder chain. Replace the standard Cut/Copy/Paste block with a
  // single clean Copy: a read-only terminal only ever needs Copy.
  override func buildMenu(with builder: UIMenuBuilder) {
    super.buildMenu(with: builder)
    if builder.menu(for: .standardEdit) != nil {
      builder.replace(menu: .standardEdit, with: UIMenu(options: .displayInline, children: [
        UICommand(title: "Copy", action: #selector(UIResponder.copy(_:)))
      ]))
    }
  }

  override func copy(_ sender: Any?) {
    if shouldUseWKCopyAndPaste() {
      super.copy(sender)
    } else {
      device?.view?.copy(sender)
    }
  }

  @objc func copyRaw(_ sender: Any?) {
    device?.view?.copyRaw(sender)
  }

  override func paste(_ sender: Any?) {
    if shouldUseWKCopyAndPaste() {
      super.paste(sender)
    } else {
      device?.view?.paste(sender)
    }
  }

  @objc func pasteSelection(_ sender: Any) {
    device?.view?.pasteSelection(sender)
  }
  
  @objc func googleSelection(_ sender: Any) {
    guard
      let deviceView = device?.view,
      let query = deviceView.selectedText?.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
      let url = URL(string: "https://google.com/search?q=\(query)")
    else {
        return
    }
    
    moshroom_openurl(url)
  }
  
  @objc func soSelection(_ sender: Any) {
    guard
      let deviceView = device?.view,
      let query = deviceView.selectedText?.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
      let url = URL(string: "https://stackoverflow.com/search?q=\(query)")
    else {
        return
    }
    
    moshroom_openurl(url)
  }
  
  @objc func shareSelection(_ sender: Any) {
    guard
      let vc = device?.delegate?.viewController(),
      let deviceView = device?.view,
      let text = deviceView.selectedText
    else {
        return
    }
    
    let ctrl = UIActivityViewController(activityItems: [text], applicationActivities: nil)
    ctrl.popoverPresentationController?.sourceView = deviceView
    ctrl.popoverPresentationController?.sourceRect = deviceView.selectionRect
    vc.present(ctrl, animated: true, completion: nil)
  }
}


extension SmarterTermInput: TermInput {
  var secureTextEntry: Bool {
    get {
      false
    }
    set(secureTextEntry) {
      
    }
  }

}
