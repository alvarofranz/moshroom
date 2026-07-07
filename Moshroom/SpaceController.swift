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

import SwiftUI


// MARK: UIViewController
class SpaceController: UIViewController {
  
  struct UIState: UserActivityCodable {
    var keys: [UUID] = []
    var currentKey: UUID? = nil
    var bgColor: CodableColor? = nil
    
    static var activityType: String { "space.ctrl.ui.state" }
  }

  final private lazy var _viewportsController = UIPageViewController(
    transitionStyle: .scroll,
    navigationOrientation: .horizontal
  )
  
  private var _viewportsKeys = [UUID]()
  private var _currentKey: UUID? = nil
  
  private var _overlay = UIView()
  private var _spaceControllerAnimating: Bool = false
  var stuckKeyCode: KeyCode? = nil

  private var _snippetsVC: SnippetsViewController? = nil

  // Snips Input Mode tracking
  private var _isSnipsInputModeActive: Bool = false {
    didSet {
      guard _isSnipsInputModeActive != oldValue else { return }
      _configureCapabilitiesForSnipsInputMode(_isSnipsInputModeActive)
    }
  }

  // Capability flags - independent state that controls what's allowed
  private var canTerminalBecomeFirstResponder: Bool = true {
    didSet {
      guard canTerminalBecomeFirstResponder != oldValue else { return }
      currentTerm()?.shouldBlockFirstResponder = !canTerminalBecomeFirstResponder
    }
  }

  private var canSwitchPages: Bool = true {
    didSet {
      guard canSwitchPages != oldValue else { return }
      _setPageViewControllerScrollEnabled(canSwitchPages)
    }
  }

  // Configure capabilities based on input mode
  private func _configureCapabilitiesForSnipsInputMode(_ active: Bool) {
    canTerminalBecomeFirstResponder = !active
    canSwitchPages = !active
  }

  private func _setPageViewControllerScrollEnabled(_ enabled: Bool) {
    // Find and enable/disable scroll gesture recognizers
    for view in _viewportsController.view.subviews {
      if let scrollView = view as? UIScrollView {
        scrollView.isScrollEnabled = enabled
      }
    }
  }
  
  public override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()

    // Moshroom: keep the reserved strips the same colour as the terminal (see below).
    _syncTerminalBackground()
    
    guard view.window != nil else {
      return
    }

    _snippetsVC?.view.frame = _overlay.frame
            
   
    DispatchQueue.main.async {
      self.forEachActive { t in
        if t.viewIsLoaded && t.view?.superview == nil {
          _ = t.removeFromContainer()
        }
      }
    }
  }
  
  private func forEachActive(block:(TermController) -> ()) {
    for key in _viewportsKeys {
      if let ctrl: TermController = SessionRegistry.shared.sessionFromIndexWith(key: key) {
        block(ctrl)
      }
    }
  }
  
  override var canBecomeFirstResponder: Bool {
    Moshroom.scratchOnly ? true : super.canBecomeFirstResponder
  }

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    // Moshroom: any hardware keystroke means the user is using the terminal — clear the
    // quick-connect card out of the way.
    if Moshroom.scratchOnly { dismissMoshnector() }
    // Moshroom: route hardware-keyboard input — a probe keystroke goes live to the agent,
    // typing more opens Moshkitor seeded with what's been typed.
    if Moshroom.scratchOnly, presentedViewController == nil,
       MoshroomKeyboard.handle(presses, device: currentDevice, openComposer: { [weak self] seed in self?.openMoshkitor(seed: seed) }) {
      return
    }
    super.pressesBegan(presses, with: event)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)

    // Moshroom: be the first responder so chain-dispatched command actions (config, etc.)
    // still reach SpaceController even though the terminal is keyboard-less.
    if Moshroom.scratchOnly {
      becomeFirstResponder()
      // Reveal the quick-connect card if the visible shell is a fresh idle prompt as we appear.
      showMoshnectorIfIdle()
    }
  }
  
  private func setupOverlayConstraints() {
    // Overlay positioning to wrap safe areas and keyboard.
    let keyboardGuide = view.keyboardLayoutGuide
    
    _overlay.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      _overlay.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      _overlay.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      _overlay.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      _overlay.bottomAnchor.constraint(equalTo: keyboardGuide.topAnchor)
    ])
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func _setupAppearance() {
    self.view.tintColor = .moshroomTint
    // Moshroom follows the system light/dark style.
    overrideUserInterfaceStyle = .unspecified
  }

  // Keep the strips reserved for the floating Moshkeys (and the hairline border around the
  // terminal) the same colour as the terminal, so they blend in instead of showing a black
  // band. The terminal's theme background only becomes known once its web view is ready, so
  // this is driven by layout passes, by tab changes, and by TermViewReadyNotificationKey.
  @objc private func _syncTerminalBackground() {
    guard Moshroom.scratchOnly,
          let termBg = currentTerm()?.termView.backgroundColor,
          termBg != .clear
    else { return }
    view.backgroundColor = termBg
    _viewportsController.view.backgroundColor = termBg
    view.window?.backgroundColor = termBg
  }

  // A terminal's web view just became ready: its theme background is now known. Sync the strip colour.
  // (The quick-connect card is NOT driven off the web view — it's driven off the shell printing its
  // prompt, see `_moshnectorPromptReady`, so there's no web-view-vs-session timing race to lose.)
  @objc private func _terminalDidBecomeReady() {
    _syncTerminalBackground()
    // The web view is ready and the session exists at the moshroom> prompt — reveal the quick-connect
    // card if this terminal is a fresh, idle, unconnected shell (kept hidden otherwise). This is the
    // trigger that has reliably worked; the prompt-ready notification is an extra, later re-check.
    if Moshroom.scratchOnly { showMoshnectorIfIdle() }
  }

  // The shell just printed its `moshroom>` prompt — i.e. it is sitting idle and unconnected right now.
  // That's the one unambiguous moment to reveal the quick-connect card, posted by MCPSession itself,
  // so no polling or web-view timing is involved: the card appears whenever the terminal is genuinely
  // at an idle local prompt, and `showMoshnectorIfIdle` keeps it hidden for a connected ssh/mosh session.
  @objc private func _moshnectorPromptReady() {
    guard Moshroom.scratchOnly else { return }
    // The shell just printed its moshroom> prompt — it is idle and unconnected right now. Re-evaluate
    // and reveal the quick-connect card (kept hidden for a connected ssh/mosh session).
    showMoshnectorIfIdle()
  }
  
  public override func viewDidLoad() {
    super.viewDidLoad()
    
    _setupAppearance()
    
    view.isOpaque = true
    
    _viewportsController.view.isOpaque = true
    _viewportsController.dataSource = self
    _viewportsController.delegate = self
    
    
    addChild(_viewportsController)
    
    if let v = _viewportsController.view {
      v.layoutMargins = .zero
      if Moshroom.scratchOnly {
        // Moshroom: the terminal fills the safe area, reserving a strip top and bottom for the
        // floating Moshkeys bars (Tabs/Settings up top, quick-keys below) so terminal text is
        // never hidden behind the round buttons — with extra breathing room up top.
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        NSLayoutConstraint.activate([
          v.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 76),
          v.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
          v.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
          v.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -56),
        ])
      } else {
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.frame = view.bounds
        view.addSubview(v)
      }
    }
    
    _viewportsController.didMove(toParent: self)
    
    _overlay.isUserInteractionEnabled = false
    view.addSubview(_overlay)
    
    _registerForNotifications()
    
    setupOverlayConstraints()
    
    if _viewportsKeys.isEmpty {
      _newShellAction(animated: false)
    } else if let key = _currentKey {
      let term: TermController = SessionRegistry.shared[key]
      term.delegate = self
      // term.layoutProvider = self
      term.bgColor = view.backgroundColor ?? .black
      _viewportsController.setViewControllers([term], direction: .forward, animated: false)
    }


    // Moshroom: floating Moshkeys quick-keys (special keys / numbers / letters).
    Moshkeys.install(in: self)

    // Moshroom: install the fresh-terminal quick-connect card; it's revealed from
    // viewDidAppear once the launch shell's session state has settled (showMoshnectorIfIdle).
    // (Moshxplore needs no install — it presents full screen from its top-bar button.)
    Moshnector.install(in: self)

  }
  
  
  func showAlert(msg: String) {
    let ctrl = UIAlertController(title: "Error", message: msg, preferredStyle: .alert)
    ctrl.addAction(UIAlertAction(title: "Ok", style: .default))
    self.present(ctrl, animated: true)
  }
  
  func _registerForNotifications() {
    let nc = NotificationCenter.default
    
    nc.addObserver(self,
                   selector: #selector(_didBecomeKeyWindow),
                   name: UIWindow.didBecomeKeyNotification,
                   object: nil)
    
    nc.addObserver(self, selector:#selector(_didBecomeKeyWindow), name: UIApplication.didBecomeActiveNotification, object: nil)
    
    nc.addObserver(self, selector: #selector(_setupAppearance),
                   name: NSNotification.Name(rawValue: MoshAppearanceChanged),
                   object: nil)

    // Moshroom: a terminal's web view becoming ready is the moment its theme background is
    // known AND its session has been created at the moshroom> prompt — drive both the strip
    // colour and the launch reveal of the quick-connect card off it.
    nc.addObserver(self, selector: #selector(_terminalDidBecomeReady),
                   name: NSNotification.Name(TermViewReadyNotificationKey), object: nil)

    // Moshroom: the shell printing its moshroom> prompt is the deterministic "fresh, idle, unconnected"
    // signal — reveal the quick-connect card off it (no web-view race, no poll).
    nc.addObserver(self, selector: #selector(_moshnectorPromptReady),
                   name: NSNotification.Name("MoshroomPromptReadyNotification"), object: nil)

    nc.addObserver(self, selector: #selector(_UISceneDidEnterBackgroundNotification(_:)),
                   name: UIScene.didEnterBackgroundNotification, object: nil)
    
    nc.addObserver(self, selector: #selector(_UISceneWillEnterForegroundNotification(_:)),
                   name: UIScene.willEnterForegroundNotification, object: nil)

  }
                   
  @objc func _UISceneDidEnterBackgroundNotification(_ n: Notification) {
    guard let scene = n.object as? UIWindowScene,
          view.window?.windowScene === scene
    else {
      return
    }
    
    let currentTerm = currentTerm()
    
    forEachActive { ctrl in
      if ctrl.viewIsLoaded && ctrl !== currentTerm {
        _ = ctrl.removeFromContainer()
      }
    }
  }
  
  @objc func _UISceneWillEnterForegroundNotification(_ n: Notification) {
    guard let scene = n.object as? UIWindowScene
    else {
      return
    }
    
    guard view.window?.windowScene === scene
    else {
      return
    }
    
    forEachActive { ctrl in
      if ctrl.viewIsLoaded {
        ctrl.placeToContainer()
      }
    }
   
    currentTerm()?.resumeIfNeeded()

    if view.window === KBTracker.shared.input?.window {
      KBTracker.shared.input?.reportStateWithSelection()
    }
  }
    
  @objc func _didBecomeKeyWindow() {
    guard
      presentedViewController == nil,
      let window = view.window,
      window.isKeyWindow
    else {
      currentDevice?.blur()
      return
    }
    
    _focusOnShell()
  }
  
  func _createTerminal(
    userActivity: NSUserActivity?,
    animated: Bool,
    sessionPayload: TermSessionPayload,
    completion: ((Bool) -> Void)? = nil)
  {
    let term = TermController(sessionPayload: sessionPayload)
    term.delegate = self
    //term.layoutProvider = self
    term.userActivity = userActivity
    term.bgColor = view.backgroundColor ?? .black
    
    if let currentKey = _currentKey,
      let idx = _viewportsKeys.firstIndex(of: currentKey)?.advanced(by: 1) {
      _viewportsKeys.insert(term.meta.key, at: idx)
    } else {
      _viewportsKeys.insert(term.meta.key, at: _viewportsKeys.count)
    }
    
    SessionRegistry.shared.track(session: term)
    
    _currentKey = term.meta.key
    
    _viewportsController.setViewControllers([term], direction: .forward, animated: animated) { (didComplete) in
      self._syncTerminalBackground()
      self._attachInputToCurrentTerm()
      completion?(didComplete)
    }
  }
  
  func _closeCurrentSpace() {
    currentTerm()?.terminate()
    _removeCurrentSpace()
  }
  
  private func _removeCurrentSpace(attachInput: Bool = true) {
    guard
      let currentKey = _currentKey,
      let idx = _viewportsKeys.firstIndex(of: currentKey)
    else {
      return
    }
    currentTerm()?.delegate = nil
    SessionRegistry.shared.remove(forKey: currentKey)
    _viewportsKeys.remove(at: idx)
    if _viewportsKeys.isEmpty {
      _newShellAction(animated: false)
      return
    }

    let direction: UIPageViewController.NavigationDirection
    let term: TermController
    
    if idx < _viewportsKeys.endIndex {
      direction = .forward
      term = SessionRegistry.shared[_viewportsKeys[idx]]
    } else {
      direction = .reverse
      term = SessionRegistry.shared[_viewportsKeys[idx - 1]]
    }
    term.bgColor = view.backgroundColor ?? .black
    
    self._currentKey = term.meta.key
    
    _spaceControllerAnimating = true
    _viewportsController.setViewControllers([term], direction: direction, animated: true) { (didComplete) in
      self._syncTerminalBackground()
      if attachInput {
        self._attachInputToCurrentTerm()
      }
      self._spaceControllerAnimating = false
    }
  }
  
  @objc func _focusOnShell() {
    _attachInputToCurrentTerm()
  }
  
  
  private func _attachInputToCurrentTerm() {
    // Check capability flag instead of mode directly
    guard canTerminalBecomeFirstResponder else {
      return
    }
    currentTerm()?.activateInput()
  }
  
  var currentDevice: TermDevice? {
    currentTerm()?.termDevice
  }
  
}

// MARK: UIStateRestorable
extension SpaceController: UIStateRestorable {
  func restore(withState state: UIState) {
    _viewportsKeys = state.keys
    _currentKey = state.currentKey
    if let bgColor = UIColor(codableColor: state.bgColor) {
      view.backgroundColor = bgColor
    }
  }
  
  func dumpUIState() -> UIState {
    return UIState(keys: _viewportsKeys,
            currentKey: _currentKey,
            bgColor: CodableColor(uiColor: view.backgroundColor)
    )
  }
  
  @objc static func onDidDiscardSceneSessions(_ sessions: Set<UISceneSession>) {
    let registry = SessionRegistry.shared
    sessions.forEach { session in
      guard
        let uiState = UIState(userActivity: session.stateRestorationActivity)
      else {
        return
      }
      
      uiState.keys.forEach { registry.remove(forKey: $0) }
    }
  }
}

// MARK: UIPageViewControllerDelegate
extension SpaceController: UIPageViewControllerDelegate {
  public func pageViewController(
    _ pageViewController: UIPageViewController,
    didFinishAnimating finished: Bool,
    previousViewControllers: [UIViewController],
    transitionCompleted completed: Bool) {
    guard completed else {
      return
    }

    guard let termController = pageViewController.viewControllers?.first as? TermController
    else {
      return
    }
    termController.resumeIfNeeded()
    _currentKey = termController.meta.key
    _syncTerminalBackground()
    _attachInputToCurrentTerm()

  }
}

// MARK: UIPageViewControllerDataSource
extension SpaceController: UIPageViewControllerDataSource {
  private func _controller(controller: UIViewController, advancedBy: Int) -> UIViewController? {
    guard let ctrl = controller as? TermController else {
      return nil
    }
    let key = ctrl.meta.key
    guard
      let idx = _viewportsKeys.firstIndex(of: key)?.advanced(by: advancedBy),
      _viewportsKeys.indices.contains(idx)
    else {
      return nil
    }
    
    let newKey = _viewportsKeys[idx]
    let newCtrl: TermController = SessionRegistry.shared[newKey]
    newCtrl.delegate = self
    //newCtrl.layoutProvider = self
    newCtrl.bgColor = view.backgroundColor ?? .black
    return newCtrl
  }
  
  public func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
    _controller(controller: viewController, advancedBy: -1)
  }

  public func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
    _controller(controller: viewController, advancedBy: 1)
  }
  
}

// MARK: TermControlDelegate
extension SpaceController: TermControlDelegate {
  
  func terminalHangup(control: TermController) {
    if currentTerm() == control {
      _closeCurrentSpace()
    }
  }
}

// MARK: General tunning

extension SpaceController {
  public override var prefersStatusBarHidden: Bool { true }
  public override var prefersHomeIndicatorAutoHidden: Bool { true }
}


// MARK: Commands

extension SpaceController {
  
  var foregroundActive: Bool {
    view.window?.windowScene?.activationState == UIScene.ActivationState.foregroundActive
  }
  
  public override var keyCommands: [UIKeyCommand]? {
    guard
      let input = KBTracker.shared.input,
      foregroundActive
    else {
      return nil
    }
    
    if let keyCode = stuckKeyCode {
      return [UIKeyCommand(input: "", modifierFlags: keyCode.modifierFlags, action: #selector(onStuckOpCommand))]
    }
    
    return input.moshroomKeyCommands
  }
  
  @objc func onStuckOpCommand() {
    stuckKeyCode = nil
    presentedViewController?.dismiss(animated: true)
    _focusOnShell()
  }
  
  @objc func _onMoshroomCommand(_ cmd: MoshroomCommand) {
    guard foregroundActive,
          let input = currentDevice?.view?.webView else {
      return
    }
    
//    input.reportStateReset()
    switch cmd.bindingAction {
    case .hex(let hex, stringInput: _, comment: _):
      input.reportHex(hex)
    case .press(let keyCode, mods: let mods):
      input.reportPress(UIKeyModifierFlags(rawValue: mods), keyId: keyCode.id)
    case .command(let c):
      _onCommand(c)
    default:
      break;
    }
  }
  
  @objc func _onShortcut(_ event: UICommand) {
    guard
      let propertyList = event.propertyList as? [String:String],
      let cmd = Command(rawValue: propertyList["Command"]!)
    else {
      return
    }
    _onCommand(cmd)
  }
  
  func _onCommand(_ cmd: Command) {
    guard foregroundActive else {
      return
    }

    switch cmd {
    case .configShow: showConfigAction()
    case .snippetsShow: showSnippetsAction()
    case .scratchShow: showScratchAction()
    case .toggleQuickActions: toggleQuickActionsAction()
    case .tab1: _moveToShell(idx: 0)
    case .tab2: _moveToShell(idx: 1)
    case .tab3: _moveToShell(idx: 2)
    case .tab4: _moveToShell(idx: 3)
    case .tab5: _moveToShell(idx: 4)
    case .tab6: _moveToShell(idx: 5)
    case .tab7: _moveToShell(idx: 6)
    case .tab8: _moveToShell(idx: 7)
    case .tab9: _moveToShell(idx: 8)
    case .tab10: _moveToShell(idx: 9)
    case .tab11: _moveToShell(idx: 10)
    case .tab12: _moveToShell(idx: 11)
    case .tabClose: _closeCurrentSpace()
    case .tabMoveToOtherWindow: _moveToOtherWindowAction()
    case .tabNew: _newShellAction()
    case .tabNext: _advanceShell(by: 1)
    case .tabPrev: _advanceShell(by: -1)
    case .tabNextCycling: _advanceShellCycling(by: 1)
    case .tabPrevCycling: _advanceShellCycling(by: -1)
    case .tabLast: _moveToLastShell()
    case .windowClose: _closeWindowAction()
    case .windowFocusOther: _focusOtherWindowAction()
    case .windowNew: _newWindowAction()
    case .clipboardCopy: KBTracker.shared.input?.copy(self)
    case .clipboardCopyRaw: KBTracker.shared.input?.copyRaw(self)
    case .clipboardPaste: KBTracker.shared.input?.paste(self)
    case .selectionGoogle: KBTracker.shared.input?.googleSelection(self)
    case .selectionStackOverflow: KBTracker.shared.input?.soSelection(self)
    case .selectionShare: KBTracker.shared.input?.shareSelection(self)
    case .zoomIn: currentTerm()?.termView.increaseFontSize()
    case .zoomOut: currentTerm()?.termView.decreaseFontSize()
    case .zoomReset: currentTerm()?.termView.resetFontSize()
    case .hideKeyboard: _ = KBTracker.shared.input?.resignFirstResponder()

    }
  }
  
  @objc func focusOnShellAction() {
    KBTracker.shared.input?.reset()
    _focusOnShell()
  }
  
  @objc public func scaleWithPich(_ pinch: UIPinchGestureRecognizer) {
    currentTerm()?.scaleWithPich(pinch)
  }
  
  private func _newShellAction(command: String = "", animated: Bool = true) {
    let params = MCPParams()
    if !command.isEmpty {
      params.initialCommand = command
    }
    let payload = MCPSessionPayload(params: params)
    _createTerminal(userActivity: nil, animated: animated, sessionPayload: payload)
    // A plain new shell lands at the moshroom> prompt — offer quick-connect. A shell opened
    // to run a command (non-empty `command`) is about to be busy, so skip it.
    if command.isEmpty { showMoshnector() }
  }

  private func _focusOtherWindowAction() {

    let sessions = _activeSessions()
    
    guard
      sessions.count > 1,
      let session = view.window?.windowScene?.session,
      let idx = sessions.firstIndex(of: session)?.advanced(by: 1)
    else  {
      if currentTerm()?.termView.isFocused() == true {
        currentTerm()?.resignInput()
      } else {
        _focusOnShell()
      }
      return
    }

    let nextSession: UISceneSession
    if idx < sessions.endIndex {
      nextSession = sessions[idx]
    } else {
      nextSession = sessions[0]
    }

    if
      let scene = nextSession.scene as? UIWindowScene,
      let delegate = scene.delegate as? SceneDelegate,
      let window = delegate.window,
      let spaceCtrl = window.rootViewController as? SpaceController {

      if window.isKeyWindow {
        spaceCtrl._focusOnShell()
      } else {
        window.makeKeyAndVisible()
      }
    } else {
      UIApplication.shared.requestSceneSessionActivation(nextSession, userActivity: nil, options: nil, errorHandler: nil)
    }
  }
  
  private func _moveToOtherWindowAction() {
    let sessions = _activeSessions()
    
    guard
      sessions.count > 1,
      let session = view.window?.windowScene?.session,
      let idx = sessions.firstIndex(of: session)?.advanced(by: 1),
      let term = currentTerm(),
      _spaceControllerAnimating == false
    else  {
        return
    }
    
    let nextSession: UISceneSession
    if idx < sessions.endIndex {
      nextSession = sessions[idx]
    } else {
      nextSession = sessions[0]
    }

    guard
      let nextScene = nextSession.scene as? UIWindowScene,
      let delegate = nextScene.delegate as? SceneDelegate,
      let nextWindow = delegate.window,
      let nextSpaceCtrl = nextWindow.rootViewController as? SpaceController,
      nextSpaceCtrl._spaceControllerAnimating == false
    else {
      return
    }


    term.prepareForWindowMove()
    _removeCurrentSpace(attachInput: false)
    nextSpaceCtrl._addTerm(term: term)
    nextWindow.makeKey()
  }
  
  func _activeSessions() -> [UISceneSession] {
    Array(UIApplication.shared.openSessions)
      .filter({ $0.scene?.activationState == .foregroundActive || $0.scene?.activationState == .foregroundInactive })
      .sorted(by: { $0.persistentIdentifier < $1.persistentIdentifier })
  }
  
  @objc func _newWindowAction() {
    let options = UIWindowScene.ActivationRequestOptions()
    options.requestingScene = self.view.window?.windowScene
    
    UIApplication
      .shared
      .requestSceneSessionActivation(nil,
                                     userActivity: nil,
                                     options: options,
                                     errorHandler: nil)
  }
  
  @objc func _closeWindowAction() {
    guard
      let session = view.window?.windowScene?.session,
      session.role == .windowApplication // Can't close windows on external monitor
    else {
      return
    }
    
    // try to focus on other session before closing
    _focusOtherWindowAction()
    
    UIApplication
      .shared
      .requestSceneSessionDestruction(session,
                                      options: nil,
                                      errorHandler: nil)
  }
  
  @objc func showConfigAction() {
    DispatchQueue.main.async {
      self.currentTerm()?.resignInput()
      let navCtrl = UINavigationController()
      navCtrl.navigationBar.prefersLargeTitles = true
      // Settings takes the full screen on every device, matching the composer — use the canvas.
      navCtrl.modalPresentationStyle = .fullScreen
      let s = SettingsHostingController.createSettings(nav: navCtrl, onDismiss: {
        [weak self] in self?.focusOnShellAction()
      })
      navCtrl.setViewControllers([s], animated: false)
      self.present(navCtrl, animated: true, completion: nil)
    }
  }
  
  
  @objc func showSnippetsAction() {
    if let _ = _snippetsVC {
      return
    }
    self.presentSnippetsController()
  }

  @objc func showScratchAction() {
    if let _ = _snippetsVC {
      return
    }
    self.presentSnippetsControllerWithScratch()
  }

  
  func _interactiveSpaceController() -> SpaceController {
    return self
  }
  
  @objc func toggleQuickActionsAction() {
    // Quick-actions menu removed — tabs now live in the Moshkeys tabs pad.
  }
  
  
  
  
  private func _addTerm(term: TermController, animated: Bool = true) {
    SessionRegistry.shared.track(session: term)
    term.delegate = self
    _viewportsKeys.append(term.meta.key)
    _moveToShell(key: term.meta.key, animated: animated)
  }
  
  private func _moveToShell(idx: Int, animated: Bool = true) {
    guard _viewportsKeys.indices.contains(idx) else {
      return
    }

    let key = _viewportsKeys[idx]
    
    _moveToShell(key: key, animated: animated)
  }
  
  private func _moveToLastShell(animated: Bool = true) {
    _moveToShell(idx: _viewportsKeys.count - 1)
  }
  
  @objc func moveToShell(key: String?) {
    guard
      let key = key,
      let uuidKey = UUID(uuidString: key)
    else {
      return
    }
    _moveToShell(key: uuidKey, animated: true)
  }
  
  private func _moveToShell(key: UUID, animated: Bool = true) {
    guard
      let currentKey = _currentKey,
      let currentIdx = _viewportsKeys.firstIndex(of: currentKey),
      let idx = _viewportsKeys.firstIndex(of: key)
    else {
      return
    }
    
    let term: TermController = SessionRegistry.shared[key]
    let direction: UIPageViewController.NavigationDirection = currentIdx < idx ? .forward : .reverse

    _spaceControllerAnimating = true
    _viewportsController.setViewControllers([term], direction: direction, animated: animated) { (didComplete) in
      term.resumeIfNeeded()
      self._currentKey = term.meta.key
      self._syncTerminalBackground()
      self._attachInputToCurrentTerm()
      self._spaceControllerAnimating = false
    }
  }
  
  private func _advanceShell(by: Int, animated: Bool = true) {
    guard
      let currentKey = _currentKey,
      let idx = _viewportsKeys.firstIndex(of: currentKey)?.advanced(by: by)
    else {
      return
    }
        
    _moveToShell(idx: idx, animated: animated)
  }
  
  private func _advanceShellCycling(by: Int, animated: Bool = true) {
    guard
      let currentKey = _currentKey,
      _viewportsKeys.count > 1
    else {
      return
    }
    
    if let idx = _viewportsKeys.firstIndex(of: currentKey)?.advanced(by: by),
      idx >= 0 && idx < _viewportsKeys.count {
      _moveToShell(idx: idx, animated: animated)
      return
    }
    
    _moveToShell(idx: by > 0 ? 0 : _viewportsKeys.count - 1, animated: animated)
  }
  
}

// MARK: Current term
extension SpaceController {
  @objc func currentTerm() -> TermController? {
    if let currentKey = _currentKey {
      return SessionRegistry.shared[currentKey]
    }
    return nil
  }
}

// MARK: SnippetContext

extension SpaceController: SnippetContext {
  
  func _presentSnippetsController(receiver: SpaceController, openScratch: Bool = false) {
    do {
      self.view.window?.makeKeyAndVisible()
      let ctrl = try SnippetsViewController.create(context: receiver, transitionFrame: nil)
      ctrl.pendingOpenScratch = openScratch
      DispatchQueue.main.async {
        ctrl.view.frame = self.view.bounds
        ctrl.willMove(toParent: self)
        self.view.addSubview(ctrl.view)
        self.addChild(ctrl)
        ctrl.didMove(toParent: self)
        self._snippetsVC = ctrl
        self._isSnipsInputModeActive = true
      }
    } catch {
      self.showAlert(msg: "Could not display Snips: \(error)")
    }
  }

  func presentSnippetsController() {
    _interactiveSpaceController()._presentSnippetsController(receiver: self)
  }

  func presentSnippetsControllerWithScratch() {
    _interactiveSpaceController()._presentSnippetsController(receiver: self, openScratch: true)
  }
  
  func _dismissSnippetsController(ctrl: SpaceController) {
    ctrl.presentedViewController?.dismiss(animated: true)
    ctrl._snippetsVC?.willMove(toParent: nil)
    ctrl._snippetsVC?.view.removeFromSuperview()
    ctrl._snippetsVC?.removeFromParent()
    ctrl._snippetsVC?.didMove(toParent: nil)
    ctrl._snippetsVC = nil
    ctrl._isSnipsInputModeActive = false
  }
  
  func dismissSnippetsController() {
    _dismissSnippetsController(ctrl: _interactiveSpaceController())
    self.focusOnShellAction()
  }
  
  func providerSnippetReceiver() -> (any SnippetReceiver)? {
    self.focusOnShellAction()
    return self.currentDevice
  }

}

// MARK: SceneIntent handlers
extension SpaceController {
  @objc func runShellSessionIntent(command: String = "") {
    // Reached both from background-thread intent/URL handlers (which need main.sync) and
    // from the on-screen Quick Actions menu, which already runs on the main thread — where
    // main.sync would deadlock and crash. Run directly when we're already on main.
    if Thread.isMainThread {
      _newShellAction(command: command)
    } else {
      DispatchQueue.main.sync {
        self._newShellAction(command: command)
      }
    }
  }

}

// MARK: - Moshroom tabs (consumed by the Moshkeys tabs pad)

extension SpaceController {
  struct MoshroomTabInfo {
    let key: UUID
    let title: String
    let isActive: Bool
  }

  /// The open terminal tabs, in order, each with its display title and whether it is active.
  func moshroomTabs() -> [MoshroomTabInfo] {
    _viewportsKeys.map { key in
      let term: TermController = SessionRegistry.shared[key]
      let custom = (term.meta.customName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      // Title priority: a forced custom name, then the connected host's alias (a tab that is an
      // ssh/mosh session to "awesomehost" IS awesomehost to the user), then the program's own OSC
      // title (claude / vim / ssh). Unloaded, unconnected tabs have no live title, so "shell".
      let connected = (term.meta.connectedHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let osc = (term.termView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let name = !custom.isEmpty ? custom
               : !connected.isEmpty ? connected
               : (osc.isEmpty ? "shell" : osc)
      return MoshroomTabInfo(key: key, title: name, isActive: key == _currentKey)
    }
  }

  func moshroomSwitch(toTab key: UUID) {
    dismissMoshnector()
    dismissMoshxplore()
    guard key != _currentKey, let idx = _viewportsKeys.firstIndex(of: key) else { return }
    _moveToShell(idx: idx)
  }

  func moshroomNewTab() { _newShellAction() }

  // Rename a tab. On save, persist the forced name and call `onDone` so the caller can refresh
  // the Tabs pad. An empty name clears the override (back to the program's own title).
  func moshroomRename(tab key: UUID, onDone: @escaping () -> Void) {
    let term: TermController = SessionRegistry.shared[key]
    let current = term.meta.customName ?? (term.termView.title ?? "")
    let alert = UIAlertController(title: "Rename tab", message: "Leave empty to use the session's own name.", preferredStyle: .alert)
    alert.addTextField { tf in
      tf.text = current
      tf.placeholder = "Tab name"
      tf.clearButtonMode = .whileEditing
      tf.autocapitalizationType = .none
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
      SessionRegistry.shared.renameSession(key, to: alert.textFields?.first?.text)
      onDone()
    })
    // The rename can be asked for from the full-screen Tabs modal — present from the top.
    (presentedViewController ?? self).present(alert, animated: true)
  }

  func moshroomClose(tab key: UUID) {
    guard let idx = _viewportsKeys.firstIndex(of: key) else { return }
    if key != _currentKey { _moveToShell(idx: idx, animated: false) }
    _closeCurrentSpace()
  }
}
