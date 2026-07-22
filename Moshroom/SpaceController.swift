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
  // The newest switch requested while a page transition was in flight — replayed (unanimated)
  // when the live transition ends, so a racing tap can never corrupt the page VC. See _installTerm.
  private var _pendingMoveKey: UUID? = nil
  // Zero tabs is a real state: an empty-state install requested mid-transition replays when the
  // live transition ends, same discipline as _pendingMoveKey.
  private var _pendingEmptyInstall = false
  // True when this controller was rebuilt from a persisted UIState. Distinguishes "the user
  // closed every tab and that state was restored" (stay at zero tabs) from a launch with nothing
  // to restore (fresh install / discarded scene), which still starts the first shell.
  private var _restoredState = false
  // The red tab-switch toast next to the Tabs button (created in Moshkeys.install) + its hide timer.
  var moshroomTabToast: MoshroomTabToast?
  private var _tabToastHide: DispatchWorkItem?
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
    // Moshroom: a hardware keystroke means the user is using the terminal — clear the
    // quick-connect card out of the way. Only for presses that CARRY CHARACTERS: bare modifier
    // events (the Cmd of a Cmd+Tab app switch, a stray Shift) used to hide the card "on its own"
    // seconds after launch, with nothing re-evaluating it afterwards.
    if Moshroom.scratchOnly,
       presses.contains(where: { !($0.key?.characters ?? "").isEmpty }) {
      dismissMoshnector()
    }
    // Moshroom: the composer may be presented but its text view not yet first responder (the
    // present hand-off). Route the keystroke straight into it so Mac Catalyst never beeps on the
    // key that lands mid-transition.
    if Moshroom.scratchOnly,
       let composer = (presentedViewController as? UINavigationController)?.viewControllers.first as? MoshkitorComposer,
       composer.acceptHardwareKeyInTransition(presses) {
      return
    }
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

  // Every full-screen Moshroom modal presents as .overFullScreen (the terminal must STAY in the
  // window — see openMoshkitor), which also means viewDidAppear does NOT re-fire when a modal
  // dismisses. Restore what it owns here instead: first responder for hardware keys, and the
  // quick-connect reveal. (Idempotent, so incidental dismissals — alerts, menus — are harmless.)
  override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
    // Moshroom's full-screen surfaces (Settings, Moshxplore, Moshtabs, Moshvault, launcher, composer)
    // are all .overFullScreen — dismiss them INSTANTLY, never with the slide. The animated slide made
    // the floating white close chip look like it was flying over the terminal mid-transition. Anything
    // else routed here (alerts, sheets, system pickers) keeps its normal animation.
    let overFull = presentedViewController?.modalPresentationStyle == .overFullScreen
    let animated = overFull ? false : flag
    MoshLog.log("modal", "SpaceController.dismiss invoked (overFullScreen=\(overFull) flag=\(flag) → animated=\(animated))")
    super.dismiss(animated: animated) { [weak self] in
      completion?()
      guard let self, Moshroom.scratchOnly else { return }
      self.becomeFirstResponder()
      self.showMoshnectorIfIdle()
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
    // Moshroom has exactly ONE theme: dark. Info.plist pins UIUserInterfaceStyle app-wide;
    // this re-asserts it at the root VC so nothing presented from here can drift.
    overrideUserInterfaceStyle = .dark
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
    if Moshroom.scratchOnly {
      // A (re)loaded web view can grab first responder (AppKit hands it to the fresh WKContentView —
      // seen after the jettison-recovery reload): hardware keys would then type into the page instead
      // of reaching the composer probe. Take it back whenever the terminal is the frontmost thing.
      if presentedViewController == nil { becomeFirstResponder() }
      showMoshnectorIfIdle()
    }
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
        // On the Mac there ARE no bottom quick-keys (hardware keyboard + tap dispatch cover
        // everything), so no strip is reserved at all — the terminal runs to the bottom, kept
        // off the very edge only by LayoutConstraintManager's small uniform margin.
        #if targetEnvironment(macCatalyst)
        let bottomStrip: CGFloat = 0
        #else
        let bottomStrip: CGFloat = 56
        #endif
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        NSLayoutConstraint.activate([
          v.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 76),
          v.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
          v.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
          v.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -bottomStrip),
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
      if _restoredState {
        // The user closed every tab and that is the state that was persisted: honor it.
        // No auto-resurrected "shell": the empty state offers New tab instead.
        _installEmptyState()
      } else {
        _newShellAction(animated: false)
      }
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

    // Moshroom: a tap on the program's input line (the cursor row — posted by the terminal tap
    // dispatch with the tapped web view) is a typing intent: open the composer, exactly like
    // the compose key.
    nc.addObserver(self, selector: #selector(_terminalInputTapped(_:)),
                   name: NSNotification.Name(MoshroomTerminalInputTapNotification), object: nil)

    nc.addObserver(self, selector: #selector(_UISceneDidEnterBackgroundNotification(_:)),
                   name: UIScene.didEnterBackgroundNotification, object: nil)
    
    nc.addObserver(self, selector: #selector(_UISceneWillEnterForegroundNotification(_:)),
                   name: UIScene.willEnterForegroundNotification, object: nil)

  }
                   
  @objc func _terminalInputTapped(_ n: Notification) {
    // Only the visible terminal of THIS space may compose (the web-view identity check also
    // disambiguates multi-window iPad).
    guard let webView = n.object as? UIView,
          webView === currentDevice?.view?.webView,
          view.window != nil
    else {
      return
    }
    // On the Quick Connect / onboarding landing (a fresh, unconnected shell) a background tap must
    // NOT open the composer: there is nothing to send to yet, and a red caret over an idle
    // "not connected" screen is confusing. Connect via the card, or use the compose button / hardware
    // keyboard to type deliberately. Once connected or interacted, the card is gone and a tap composes.
    if _freshOverlayVisible { return }
    openMoshkitor()
  }

  // Quick Connect (MoshnectorView) or the first-run onboarding (MoshonboardView) is on screen — i.e.
  // a fresh, idle, unconnected shell. See Moshnector.
  private var _freshOverlayVisible: Bool {
    if let c = view.subviews.compactMap({ $0 as? MoshnectorView }).first, !c.isHidden { return true }
    if let o = view.subviews.compactMap({ $0 as? MoshonboardView }).first, !o.isHidden { return true }
    return false
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
    // Coming back to the app (Cmd+Tab, window switch) must re-evaluate the quick-connect card:
    // it is one more idempotent reveal trigger, same contract as viewDidAppear and prompt-ready.
    if Moshroom.scratchOnly { showMoshnectorIfIdle() }
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

    _installTerm(term, direction: .forward, animated: animated, completion: completion)
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
      // No tabs is a real state, never an auto-resurrected shell: the page VC gets the
      // empty-state placeholder and New tab (there, or in Moshtabs) brings the next terminal.
      _installEmptyState()
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

    _installTerm(term, direction: direction, animated: true, attachInput: attachInput)
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
    _restoredState = true
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
  // A user swipe is a live transition too — flag it so a programmatic switch that races it gets
  // queued (see _installTerm) instead of corrupting the .scroll page VC mid-flight.
  public func pageViewController(
    _ pageViewController: UIPageViewController,
    willTransitionTo pendingViewControllers: [UIViewController]) {
    _spaceControllerAnimating = true
  }

  public func pageViewController(
    _ pageViewController: UIPageViewController,
    didFinishAnimating finished: Bool,
    previousViewControllers: [UIViewController],
    transitionCompleted completed: Bool) {
    // The swipe ended (completed or cancelled) — always release the flag and replay any switch
    // that was requested while it was in flight.
    _spaceControllerAnimating = false
    if _pendingEmptyInstall {
      _pendingEmptyInstall = false
      if _viewportsKeys.isEmpty {
        _installEmptyState()
        return
      }
    }
    if let pendingKey = _pendingMoveKey {
      _pendingMoveKey = nil
      _moveToShell(key: pendingKey, animated: false)
      return
    }

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
    // A swipe just landed on this tab — flash its alias next to the Tabs button for 3 s.
    moshroomShowTabToast(moshroomTitle(for: termController.meta.key))
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
    // The Edit-menu clipboard key commands (Cmd+C / Cmd+Shift+C / Cmd+V) are registered app-wide with
    // priority over the system, so they fire here even when a modal (the Moshkitor composer, Settings,
    // Moshxplore…) is on screen — which used to silently drive the *terminal's* copy/paste behind it.
    // Route them to what's actually in front instead: the composer, another modal's text field, or —
    // with nothing presented — the terminal transcript.
    case .clipboardCopy:
      if presentedViewController != nil { _forwardEditAction(#selector(UIResponder.copy(_:))) }
      else { KBTracker.shared.input?.copy(self) }
    case .clipboardCopyRaw:
      if presentedViewController != nil { _forwardEditAction(#selector(UIResponder.copy(_:))) }
      else { KBTracker.shared.input?.copyRaw(self) }
    case .clipboardPaste:
      if let composer = _frontComposer {
        MoshLog.log("paste", "Cmd+V → composer.smartPaste (composer in front)")
        composer.smartPaste()
      } else if presentedViewController != nil {
        MoshLog.log("paste", "Cmd+V → forward paste: to first responder (other modal in front)")
        _forwardEditAction(#selector(UIResponder.paste(_:)))
      } else {
        MoshLog.log("paste", "Cmd+V → open Moshkitor + paste (no modal in front)")
        openMoshkitorPasting()
      }
    case .selectionGoogle: KBTracker.shared.input?.googleSelection(self)
    case .selectionStackOverflow: KBTracker.shared.input?.soSelection(self)
    case .selectionShare: KBTracker.shared.input?.shareSelection(self)
    case .zoomIn: currentTerm()?.termView.increaseFontSize()
    case .zoomOut: currentTerm()?.termView.decreaseFontSize()
    case .zoomReset: currentTerm()?.termView.resetFontSize()
    case .hideKeyboard: _ = KBTracker.shared.input?.resignFirstResponder()

    }
  }

  // The Moshkitor composer if it's the frontmost modal AND directly interactive (no picker/snips of
  // its own on top). nil otherwise — so a clipboard command falls through to the standard responder
  // chain or the terminal, never into a composer that a sub-sheet has covered.
  private var _frontComposer: MoshkitorComposer? {
    guard let nav = presentedViewController as? UINavigationController,
          let composer = nav.viewControllers.first as? MoshkitorComposer,
          composer.presentedViewController == nil else { return nil }
    return composer
  }

  // Send a standard edit action (copy:/paste:) to the first responder — i.e. let whatever text field
  // is in front handle it — instead of the terminal. `to: nil` walks the responder chain from the
  // first responder up; unhandled actions are simply dropped (better than mis-pasting into the shell).
  @discardableResult
  private func _forwardEditAction(_ action: Selector) -> Bool {
    UIApplication.shared.sendAction(action, to: nil, from: self, for: nil)
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
      // .overFullScreen keeps the terminal in the window (see openMoshkitor).
      navCtrl.modalPresentationStyle = .overFullScreen
      // Close dismisses the WHOLE modal stack (launcher + Settings) back to the terminal in one shot
      // (the SpaceController.dismiss override restores first responder + Quick Connect). No flash.
      let s = SettingsHostingController.createSettings(nav: navCtrl, onClose: {
        [weak self] in self?.dismiss(animated: false)
      })
      navCtrl.setViewControllers([s], animated: false)
      // Stack over the launcher instead of dismissing it first (which flashed the terminal).
      let presenter = self.moshroomTopPresenter
      guard presenter.presentedViewController == nil else { return }
      presenter.present(navCtrl, animated: false, completion: nil)
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

    _installTerm(term, direction: direction, animated: animated)
  }

  // The ONE serialized installer for every page-VC transition. A .scroll UIPageViewController
  // aborts a programmatic animated transition that races another animation (a modal dismiss, a
  // user swipe, a second switch) — the completion then reports didComplete == false while the OLD
  // page stays on screen, and `viewControllers` LIES (it reports the target). Trusting the intent
  // there is how a tab got "lost": _currentKey said B, the screen showed A, and the layout sweep
  // hid B for good. So: one transition at a time (later requests remember only the newest target
  // and replay when the live one ends), and a didComplete == false transition is unconditionally
  // re-issued without animation — which cannot be interrupted.
  private func _installTerm(
    _ term: TermController,
    direction: UIPageViewController.NavigationDirection,
    animated: Bool,
    attachInput: Bool = true,
    completion: ((Bool) -> Void)? = nil
  ) {
    if _spaceControllerAnimating {
      _pendingMoveKey = term.meta.key
      return
    }

    _spaceControllerAnimating = true
    _viewportsController.setViewControllers([term], direction: direction, animated: animated) { (didComplete) in
      if !didComplete {
        self._viewportsController.setViewControllers([term], direction: direction, animated: false)
      }
      term.resumeIfNeeded()
      self._currentKey = term.meta.key
      self._syncTerminalBackground()
      if attachInput {
        self._attachInputToCurrentTerm()
      }
      self._spaceControllerAnimating = false
      completion?(didComplete)

      if self._pendingEmptyInstall {
        self._pendingEmptyInstall = false
        if self._viewportsKeys.isEmpty {
          self._installEmptyState()
          return
        }
      }
      if let pendingKey = self._pendingMoveKey {
        self._pendingMoveKey = nil
        if pendingKey != term.meta.key {
          self._moveToShell(key: pendingKey, animated: false)
        }
      }
    }
  }

  // Zero tabs: install the empty-state placeholder page. Same serialized discipline as
  // _installTerm (an unanimated setViewControllers racing a live transition is exactly the
  // page-VC corruption _installTerm exists to prevent), so a request made mid-flight replays
  // when the live transition ends.
  private func _installEmptyState() {
    _currentKey = nil
    dismissMoshnector()
    if _spaceControllerAnimating {
      _pendingEmptyInstall = true
      return
    }
    _spaceControllerAnimating = true
    let empty = MoshroomNoTabsController()
    empty.onNewTab = { [weak self] in self?._newShellAction() }
    _viewportsController.setViewControllers([empty], direction: .forward, animated: false) { _ in
      self._spaceControllerAnimating = false
      // Same replay discipline as the other two completion sites: an empty-install requested
      // while this one was in flight re-runs (only meaningful if keys are still empty), and a
      // tab born while the placeholder was installing (New tab racing the close) replays
      // directly: _moveToShell would bail on the nil _currentKey of the empty state.
      if self._pendingEmptyInstall {
        self._pendingEmptyInstall = false
        if self._viewportsKeys.isEmpty {
          self._installEmptyState()
          return
        }
      }
      if let pendingKey = self._pendingMoveKey {
        self._pendingMoveKey = nil
        if self._viewportsKeys.contains(pendingKey) {
          let term: TermController = SessionRegistry.shared[pendingKey]
          self._installTerm(term, direction: .forward, animated: false)
        }
      }
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

  // A tab's display title: forced custom name, then the connected host's alias (a tab that is an
  // ssh/mosh session to "awesomehost" IS awesomehost to the user), then the program's own OSC title
  // (opencode / vim / ssh). An unconnected tab has no live title and says so honestly: it is the
  // quick-connect canvas, not a "shell" (that name read as a phantom session in the tab list).
  func moshroomTitle(for key: UUID) -> String {
    let term: TermController = SessionRegistry.shared[key]
    let custom = (term.meta.customName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let connected = (term.meta.connectedHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let osc = (term.termView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return !custom.isEmpty ? custom : !connected.isEmpty ? connected : (osc.isEmpty ? "not connected" : osc)
  }

  /// The open terminal tabs, in order, each with its display title and whether it is active.
  func moshroomTabs() -> [MoshroomTabInfo] {
    _viewportsKeys.map { MoshroomTabInfo(key: $0, title: moshroomTitle(for: $0), isActive: $0 == _currentKey) }
  }

  // Flash the red pill next to the Tabs button with the tab a swipe just landed on, then fade it out
  // after 3 s. Reschedules cleanly if another swipe lands within the window.
  func moshroomShowTabToast(_ title: String) {
    guard let toast = moshroomTabToast else { return }
    toast.text = title
    _tabToastHide?.cancel()
    view.bringSubviewToFront(toast)
    UIView.animate(withDuration: 0.2) { toast.alpha = 1 }
    let work = DispatchWorkItem { [weak toast] in
      UIView.animate(withDuration: 0.3) { toast?.alpha = 0 }
    }
    _tabToastHide = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
  }

  func moshroomSwitch(toTab key: UUID) {
    dismissMoshnector()
    dismissMoshxplore()
    guard key != _currentKey, let idx = _viewportsKeys.firstIndex(of: key) else { return }
    // The switch happens BEHIND the full-screen Moshtabs modal that is dismissing at this same
    // moment — animating the page VC here is invisible AND races the dismiss (the interrupted
    // transition was how a tab got "lost": state on B, screen stuck on A). Install directly.
    _moveToShell(idx: idx, animated: false)
  }

  // Unanimated on purpose: the new tab is born BEHIND the dismissing Moshtabs modal, and an
  // animated page-VC transition racing that dismiss is the documented "lost tab" corruption
  // (same reason moshroomSwitch installs with no animation).
  func moshroomNewTab() { _newShellAction(animated: false) }

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

// MARK: - Zero-tab empty state

// The page shown when the last tab closes (or a zero-tab state restores): the house empty-state
// look (MoshEmptyState's metrics) in plain UIKit, on a dark canvas. No tab is auto-resurrected:
// New tab (here, in Moshtabs, or Cmd+T) brings the next terminal through _createTerminal.
// UIKit on purpose: a UIHostingController child inside the page VC rendered nothing on Catalyst.
final class MoshroomNoTabsController: UIViewController {
  var onNewTab: (() -> Void)?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let icon = UIImageView(image: UIImage(
      systemName: "rectangle.stack",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)))
    icon.tintColor = .moshroomTint

    let title = UILabel()
    title.text = "No open tabs"
    title.font = .systemFont(ofSize: 20, weight: .semibold)
    title.textColor = .label

    let message = UILabel()
    message.text = "Open a tab to start a session."
    message.font = .preferredFont(forTextStyle: .callout)
    message.textColor = .secondaryLabel
    message.textAlignment = .center
    message.numberOfLines = 0

    let newTab = moshButton()
    var cfg = UIButton.Configuration.plain()
    cfg.image = UIImage(systemName: "plus",
                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
    cfg.imagePadding = 8
    var attr = AttributeContainer()
    attr.font = UIFont.preferredFont(forTextStyle: .headline)
    cfg.attributedTitle = AttributedString("New tab", attributes: attr)
    cfg.baseForegroundColor = .moshroomTint
    newTab.configuration = cfg
    newTab.tintColor = .moshroomTint
    #if targetEnvironment(macCatalyst)
    newTab.preferredBehavioralStyle = .pad
    #endif
    newTab.addAction(UIAction { [weak self] _ in self?.onNewTab?() }, for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [icon, title, message, newTab])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 14
    stack.setCustomSpacing(20, after: message)
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
    ])
  }
}
