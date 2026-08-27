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

// MARK: - Typed tabs

// What a tab IS. A tab used to be a terminal by definition; now the terminal is one kind among
// several (the music player, the file explorer, more later). The raw value is persisted in
// UIState, so renaming a case is a migration.
enum MoshroomTabKind: String {
  case term, moshify, explorer
}

// What every page inside the tabs page VC must answer: which tab key it is, what kind, and (for
// non-terminal kinds) a live display title. `moshroomTabWillClose` is the close hook — stop the
// engine, tear the connection down. TermController conforms below; non-terminal pages are plain
// UIViewControllers rebuilt fresh per run (whatever state they need survives elsewhere).
protocol MoshroomTabPage: UIViewController {
  var moshroomTabKey: UUID { get }
  var moshroomTabKind: MoshroomTabKind { get }
  var moshroomTabTitle: String? { get }
  func moshroomTabWillClose()
}

extension MoshroomTabPage {
  func moshroomTabWillClose() {}
}

extension TermController: MoshroomTabPage {
  var moshroomTabKey: UUID { meta.key }
  var moshroomTabKind: MoshroomTabKind { .term }
  var moshroomTabTitle: String? { nil }
}

// MARK: UIViewController
class SpaceController: UIViewController {

  struct UIState: UserActivityCodable {
    var keys: [UUID] = []
    var currentKey: UUID? = nil
    var bgColor: CodableColor? = nil
    // Kind per tab, keyed by uuidString, `.term` entries omitted. Optional ON PURPOSE: a UIState
    // written before typed tabs existed must keep decoding (an incompatible shape fails BOTH
    // restore branches and every tab is silently forgotten).
    var kinds: [String: String]? = nil

    static var activityType: String { "space.ctrl.ui.state" }
  }

  final private lazy var _viewportsController = UIPageViewController(
    transitionStyle: .scroll,
    navigationOrientation: .horizontal
  )
  
  private var _viewportsKeys = [UUID]()
  private var _currentKey: UUID? = nil

  // Typed tabs. `_tabKinds` answers "what is this key" (missing = .term, the historical default).
  // Non-terminal page controllers live HERE, never in the SessionRegistry: the registry's
  // fabricating subscript mints a phantom TermController for any key it is asked about, and a
  // phantom gets archived by suspend() and resumes as a real MCP shell.
  private var _tabKinds = [UUID: MoshroomTabKind]()
  private var _pageControllers = [UUID: UIViewController & MoshroomTabPage]()

  private var _overlay = UIView()
  private var _spaceControllerAnimating: Bool = false
  // The newest switch requested while a page transition was in flight — replayed (unanimated)
  // when the live transition ends, so a racing tap can never corrupt the page VC. See _installPage.
  private var _pendingMoveKey: UUID? = nil
  // Zero tabs is a real state: an empty-state install requested mid-transition replays when the
  // live transition ends, same discipline as _pendingMoveKey.
  private var _pendingEmptyInstall = false
  // True when this controller was rebuilt from a persisted UIState. Distinguishes "the user
  // closed every tab and that state was restored" (stay at zero tabs) from a launch with nothing
  // to restore (fresh install / discarded scene), which still starts the first shell.
  private var _restoredState = false
  // The red pill next to the Tabs button naming the tab on screen (created in Moshkeys.install).
  var moshroomTabLabel: MoshroomTabLabel?
  // The bottom quick-keys cluster (iOS only; created in Moshkeys.install): faded out while the
  // current tab is not a terminal — those keys type into the current TermDevice and a music or
  // explorer tab has none.
  var moshroomBottomKeys: [UIView] = []
  // The "back to live" chip (created in Moshkeys.install): shown only while the visible terminal's
  // viewport is parked up in its scrollback.
  var moshroomLiveButton: UIButton?
  // The music controls in the top bar, left of the launcher key (created in Moshkeys.install):
  // shown while something is playing and you are looking at some other tab.
  var moshroomMiniPlayer: MoshifyMiniPlayer?
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
  
  // The ONE place that makes the pixels agree with the state: every terminal's web view is a sibling
  // in a single shared container, so "which tab is visible" is pure hidden/front bookkeeping. The
  // current terminal is placed, unhidden and brought to the front; every other live terminal is
  // hidden. Any path that leaves two of them unhidden shows the user a tab that is NOT the one
  // receiving their input — which is indistinguishable from "my session vanished".
  private func _showOnlyCurrentTerminal() {
    let current = currentTerm()
    forEachActive { ctrl in
      guard ctrl.viewIsLoaded, ctrl !== current else { return }
      _ = ctrl.removeFromContainer()
    }
    current?.placeToContainer()
    // All of these are per tab, so they are re-read for the tab that just became visible.
    moshroomSyncLiveButton()
    moshroomUpdateTabLabel()
    moshroomSyncQuickKeysVisibility()
    moshroomSyncMoshifyMini()
  }

  // The bottom quick-keys cluster only makes sense over a terminal (its keys write into the
  // current TermDevice). Faded, not hidden: the arrow mode manages isHidden on its own members.
  private func moshroomSyncQuickKeysVisibility() {
    guard !moshroomBottomKeys.isEmpty else { return }
    let terminalTab = _currentKey.map { moshroomTabKind(for: $0) == .term } ?? true
    for v in moshroomBottomKeys {
      v.alpha = terminalTab ? 1 : 0
      v.isUserInteractionEnabled = terminalTab
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
    // typing more opens Moshkitor seeded with what's been typed. Terminal tabs (and the zero-tab
    // state, which keeps its historical behaviour) only: on a music/explorer tab the page's own
    // responders must see the keys — MoshroomKeyboard.handle would swallow them into a nil device.
    let terminalOwnsKeys = _currentKey.map { moshroomTabKind(for: $0) == .term } ?? true
    if Moshroom.scratchOnly, presentedViewController == nil, terminalOwnsKeys,
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

  /// The topmost thing on screen — a surface opened from inside another one (the launcher's rows)
  /// must present from there, or UIKit refuses ("already presenting").
  var moshroomTopPresenter: UIViewController {
    var vc: UIViewController = self
    while let presented = vc.presentedViewController { vc = presented }
    return vc
  }

  /// The quick-keys pad folds away whenever a full-screen surface takes over.
  func moshroomCloseQuickKeys() {
    view.subviews.compactMap({ $0 as? MoshkeysBar }).first?.closeIfOpen()
  }

  /// The one way a Moshroom full-screen surface goes up (launcher, Moshtabs, Moshxplore, Moshvault,
  /// the composer): fold the floating chrome away, then present INSTANTLY — the mirror of the
  /// instant dismiss above. `.overFullScreen`, never `.fullScreen`: the covered terminal must STAY
  /// in the window, because pulling the web view out and back re-latches WebKit's selection painting
  /// into a dead near-black box that no responder dance heals. `make` runs only once there is room
  /// for a surface, so a caller never builds a controller it cannot show; returning nil from it
  /// (nothing to show yet) reports false too.
  @discardableResult
  func moshroomPresentFullScreen(from presenter: UIViewController? = nil,
                                 _ make: () -> UIViewController?) -> Bool {
    let host = presenter ?? moshroomTopPresenter
    guard host.presentedViewController == nil else { return false }
    dismissMoshnector()
    moshroomCloseQuickKeys()
    guard let ctrl = make() else { return false }
    ctrl.modalPresentationStyle = .overFullScreen
    host.present(ctrl, animated: false)
    return true
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
  // With no terminal current (zero tabs, a non-terminal tab) the last terminal's colour — or
  // the house ground — is re-asserted on every surface, so the screen stays ONE flat shade
  // instead of the page painting a different black than the strips.
  @objc private func _syncTerminalBackground() {
    guard Moshroom.scratchOnly else { return }
    let termBg = currentTerm()?.termView.backgroundColor
    let bg = (termBg != nil && termBg != .clear) ? termBg!
      : (view.backgroundColor ?? .moshroomBackground)
    view.backgroundColor = bg
    _viewportsController.view.backgroundColor = bg
    view.window?.backgroundColor = bg
    (_viewportsController.viewControllers?.first as? MoshroomNoTabsController)?
      .view.backgroundColor = bg
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
      MoshLog.log("tabs", "bootstrap: current kind=\(moshroomTabKind(for: key).rawValue) kinds=\(_tabKinds.count) keys=\(_viewportsKeys.count)")
      if let page = _pageController(for: key) {
        _viewportsController.setViewControllers([page], direction: .forward, animated: false)
      } else {
        // A restored key whose page cannot be rebuilt (a kind this build no longer knows): drop
        // it rather than fabricating something, and land on the first tab that CAN be built.
        MoshLog.log("tabs", "restore: no page for current key, dropping it")
        _viewportsKeys.removeAll { $0 == key }
        _tabKinds[key] = nil
        if let fallback = _viewportsKeys.first, let page = _pageController(for: fallback) {
          _currentKey = fallback
          _viewportsController.setViewControllers([page], direction: .forward, animated: false)
        } else {
          _installEmptyState()
        }
      }
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
                   name: .moshroomPromptReady, object: nil)

    // Moshroom: a tap on the program's input line (the cursor row — posted by the terminal tap
    // dispatch with the tapped web view) is a typing intent: open the composer, exactly like
    // the compose key.
    nc.addObserver(self, selector: #selector(_terminalInputTapped(_:)),
                   name: NSNotification.Name(MoshroomTerminalInputTapNotification), object: nil)

    // Moshroom: the visible terminal left (or came back to) the live end of its transcript — show
    // or hide the "back to live" chip. A terminal parked in its scrollback while a session prints
    // below is indistinguishable from a frozen one without it.
    nc.addObserver(self, selector: #selector(_terminalTailingChanged(_:)),
                   name: NSNotification.Name(MoshroomTerminalTailingNotification), object: nil)

    // Moshroom: a program renamed its terminal (OSC 0/2) — the tab pill shows that name for a tab
    // with no host of its own, so it has to follow.
    nc.addObserver(self, selector: #selector(_terminalTitleChanged),
                   name: NSNotification.Name(TermViewTitleDidChangeNotificationKey), object: nil)

    // Moshroom: the music started, stopped, or changed hands — the top-bar controls follow it.
    nc.addObserver(self, selector: #selector(_moshifyDidChange),
                   name: .moshifyStateDidChange, object: nil)
    nc.addObserver(self, selector: #selector(_moshifyDidChange),
                   name: .moshifyOwnerDidChange, object: nil)

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

  @objc func _terminalTitleChanged() {
    moshroomUpdateTabLabel()
  }

  @objc func _moshifyDidChange() {
    moshroomSyncMoshifyMini()
  }

  @objc func _terminalTailingChanged(_ n: Notification) {
    // Only the terminal the user is looking at may drive the chip: a background tab receiving output
    // posts these too (the web-view identity check also disambiguates multi-window iPad).
    guard let webView = n.object as? UIView,
          webView === currentDevice?.view?.webView
    else {
      return
    }
    moshroomSyncLiveButton()
  }

  /// Show the chip exactly while the visible terminal is scrolled away from its live end. Called on
  /// every tailing change and after any tab switch (the new tab's state is its own).
  /// The top-bar music controls: visible while the engine has a track and you are looking at any tab
  /// OTHER than the one playing it — including another music tab, which shows its own picker and has
  /// no controls of its own. Called from the one place that knows the visible tab changed, plus the
  /// engine's own notifications.
  func moshroomSyncMoshifyMini() {
    guard let mini = moshroomMiniPlayer else { return }
    let onPlayingTab = (_currentKey != nil && _currentKey == MoshifyEngine.shared.ownerKey)
    let show = mini.sync() && !onPlayingTab
    if mini.isHidden != !show { mini.isHidden = !show }
    if show { view.bringSubviewToFront(mini.superview ?? mini) }
  }

  /// Bring the tab that owns the music on screen (tapping the title in the top bar).
  func moshroomOpenPlayingMusicTab() {
    guard let key = MoshifyEngine.shared.ownerKey else { return }
    moshroomSwitch(toTab: key)
  }

  func moshroomSyncLiveButton() {
    guard let button = moshroomLiveButton else { return }
    let show = !(currentDevice?.view?.moshroomIsTailing ?? true) && !_freshOverlayVisible
    if show {
      view.bringSubviewToFront(button)
      button.isHidden = false
      UIView.animate(withDuration: 0.15) { button.alpha = 1 }
    } else if !button.isHidden {
      UIView.animate(withDuration: 0.15) { button.alpha = 0 } completion: { _ in
        if button.alpha == 0 { button.isHidden = true }
      }
    }
  }

  /// The chip's action: back to the live end of the transcript, the same jump that sending input
  /// performs (see TermDevice.write / term_scrollToBottom).
  func moshroomScrollToLiveEnd() {
    currentDevice?.view?.moshroomScrollToBottom()
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

    // Only the CURRENT terminal may be shown. This used to call placeToContainer() on EVERY live
    // terminal, and that method ends in `isHidden = false` + bringSubviewToFront — so coming back to
    // the foreground unhid every tab's web view at once (they are all siblings in one shared
    // container) and left whichever was iterated last sitting on top. State, input focus and pixels
    // then disagreed: measured live, the page VC reported tab A, input went to tab A, and the user
    // was looking at tab B's session. Symmetric with the background handler, which already excludes
    // the current terminal.
    _showOnlyCurrentTerminal()

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
    term.bgColor = view.backgroundColor ?? .moshroomBackground
    
    if let currentKey = _currentKey,
      let idx = _viewportsKeys.firstIndex(of: currentKey)?.advanced(by: 1) {
      _viewportsKeys.insert(term.meta.key, at: idx)
    } else {
      _viewportsKeys.insert(term.meta.key, at: _viewportsKeys.count)
    }
    
    SessionRegistry.shared.track(session: term)
    _tabKinds[term.meta.key] = .term

    _currentKey = term.meta.key

    _installPage(term, direction: .forward, animated: animated, completion: completion)
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
    // Kind-aware close: a terminal leaves the registry; any other kind gets its close hook
    // (stop the music, tear the SFTP session down) and leaves the local page map.
    if moshroomTabKind(for: currentKey) == .term {
      currentTerm()?.delegate = nil
      SessionRegistry.shared.remove(forKey: currentKey)
    } else {
      _pageControllers[currentKey]?.moshroomTabWillClose()
      _pageControllers[currentKey] = nil
    }
    _tabKinds[currentKey] = nil
    _viewportsKeys.remove(at: idx)
    if _viewportsKeys.isEmpty {
      // No tabs is a real state, never an auto-resurrected shell: the page VC gets the
      // empty-state placeholder and New tab (there, or in Moshtabs) brings the next terminal.
      _installEmptyState()
      return
    }

    let direction: UIPageViewController.NavigationDirection
    let nextKey: UUID

    if idx < _viewportsKeys.endIndex {
      direction = .forward
      nextKey = _viewportsKeys[idx]
    } else {
      direction = .reverse
      nextKey = _viewportsKeys[idx - 1]
    }
    guard let page = _pageController(for: nextKey) else {
      MoshLog.log("tabs", "close: no page for next key, falling back to empty state")
      _installEmptyState()
      return
    }

    self._currentKey = nextKey

    _installPage(page, direction: direction, animated: true, attachInput: attachInput)
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

  // A live terminal device for an APP-initiated SSH connection (Moshify, the explorer): the
  // current tab's when it is a terminal, else the first materialized terminal tab's.
  // resolveTarget needs one for interactive auth prompts; key auth against a known host never
  // touches it. Nil only when no terminal tab is alive — the caller shows an honest error.
  var moshroomAnyTermDevice: TermDevice? {
    if let device = currentDevice { return device }
    // The subscript is safe here: the key's kind is verified .term, so materializing (the
    // restore path — e.g. a restored music tab is current and its terminal neighbour has not
    // been shown yet) builds a REAL terminal, never a phantom.
    for key in _viewportsKeys where moshroomTabKind(for: key) == .term {
      let ctrl: TermController = SessionRegistry.shared[key]
      return ctrl.termDevice
    }
    return nil
  }

}

// MARK: UIStateRestorable
extension SpaceController: UIStateRestorable {
  func restore(withState state: UIState) {
    MoshLog.log("tabs", "restore: keys=\(state.keys.count) kinds=\(state.kinds?.count ?? -1)")
    _restoredState = true
    _viewportsKeys = state.keys
    _currentKey = state.currentKey
    // Kinds BEFORE anything touches `view`: the bgColor line below forces viewDidLoad, whose
    // bootstrap resolves the current key's kind — with the map still empty, a music/explorer key
    // would read as .term and fabricate a phantom shell. (Keys and kinds must land together.)
    state.kinds?.forEach { id, raw in
      if let key = UUID(uuidString: id), let kind = MoshroomTabKind(rawValue: raw) {
        _tabKinds[key] = kind
      }
    }
    if let bgColor = UIColor(codableColor: state.bgColor) {
      view.backgroundColor = bgColor
    }
  }

  func dumpUIState() -> UIState {
    let kinds = Dictionary(uniqueKeysWithValues: _viewportsKeys.compactMap { key -> (String, String)? in
      let kind = moshroomTabKind(for: key)
      return kind == .term ? nil : (key.uuidString, kind.rawValue)
    })
    return UIState(keys: _viewportsKeys,
            currentKey: _currentKey,
            bgColor: CodableColor(uiColor: view.backgroundColor),
            kinds: kinds.isEmpty ? nil : kinds
    )
  }

  // Where the tab layout is kept for the Catalyst relaunch path (see moshroomRestore(from:)). It sits
  // next to the per-session archives so the two are cleaned up together.
  private static var _uiStateFileURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent("uistate.json")
  }

  // Mac Catalyst only: quitting the app DISCARDS its scene session, so the next launch is handed no
  // stateRestorationActivity at all and every tab was forgotten (measured: quit with three tabs, come
  // back to one). Keep our own snapshot of the layout — tab order and which one was current, which the
  // session index cannot express because it is a dictionary — and fall back to it at launch.
  // Deliberately not compiled on iOS: there, "no scene state" means the user swiped the app out of the
  // switcher, and forgetting the tabs is the correct answer.
  func moshroomPersistUIState() {
    #if targetEnvironment(macCatalyst)
    let url = Self._uiStateFileURL
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(dumpUIState()) else { return }
    try? data.write(to: url, options: .atomic)
    #endif
  }

  // The one entry point the scene uses to rebuild its tabs: the system's scene state when there is
  // some, our own snapshot when there is not (see moshroomPersistUIState).
  func moshroomRestore(from session: UISceneSession) {
    if let activity = session.stateRestorationActivity, UIState(userActivity: activity) != nil {
      MoshLog.log("tabs", "restore via scene activity")
      restoreWith(stateRestorationActivity: activity)
      return
    }
    MoshLog.log("tabs", "restore via uistate file")
    #if targetEnvironment(macCatalyst)
    guard
      let data = try? Data(contentsOf: Self._uiStateFileURL),
      let state = try? JSONDecoder().decode(UIState.self, from: data)
    else {
      return
    }
    restore(withState: state)
    #endif
  }
  
  // A scene session the system threw away: its tabs are gone for good, so drop their archives.
  //
  // EXCEPT the ones this run is using. On Mac Catalyst, quitting the app discards its scene session,
  // and the system reports that discard to the NEXT launch (seconds after it starts) — by which time
  // the app has restored the very same keys from the same UIState. Removing them here deleted each
  // restored tab's archive moments after it came back, which is why a relaunch always showed a single
  // tab and the persisted index ended up empty: three tabs open, `sessions/index.json` down to one
  // entry, and `[]` after a clean quit. Keys that this run does NOT hold are still genuinely orphaned
  // and are still removed, so nothing leaks.
  @objc static func onDidDiscardSceneSessions(_ sessions: Set<UISceneSession>) {
    let registry = SessionRegistry.shared
    let live = registry.liveSessionKeys
    sessions.forEach { session in
      guard
        let uiState = UIState(userActivity: session.stateRestorationActivity)
      else {
        return
      }

      uiState.keys
        .filter { !live.contains($0) }
        .forEach { registry.remove(forKey: $0) }
    }
  }
}

// MARK: UIPageViewControllerDelegate
extension SpaceController: UIPageViewControllerDelegate {
  // A user swipe is a live transition too — flag it so a programmatic switch that races it gets
  // queued (see _installPage) instead of corrupting the .scroll page VC mid-flight.
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

    guard let page = pageViewController.viewControllers?.first as? (UIViewController & MoshroomTabPage)
    else {
      return
    }
    // Landing on a non-terminal page: release the outgoing terminal's focus BEFORE _currentKey
    // moves (the focused terminal refuses to hide, and currentTerm() still names the old tab here).
    if page.moshroomTabKind != .term {
      currentTerm()?.resignInput()
    }
    (page as? TermController)?.resumeIfNeeded()
    _currentKey = page.moshroomTabKey
    _syncTerminalBackground()
    if page.moshroomTabKind == .term {
      _attachInputToCurrentTerm()
    }
    // A swipe just landed here: run the same "this tab is the visible one" pass an install does, so
    // the hidden/front bookkeeping, the tab label and the back-to-live chip all follow one path.
    _showOnlyCurrentTerminal()
  }
}

// MARK: UIPageViewControllerDataSource
extension SpaceController: UIPageViewControllerDataSource {
  private func _controller(controller: UIViewController, advancedBy: Int) -> UIViewController? {
    // Kind-blind: any tab page (terminal or not) can answer "who is my neighbour", so a music or
    // explorer tab is swipeable in both directions. The zero-tab placeholder is not a tab page
    // and stays un-swipeable, as before.
    guard let page = controller as? (UIViewController & MoshroomTabPage) else {
      return nil
    }
    let key = page.moshroomTabKey
    guard
      let idx = _viewportsKeys.firstIndex(of: key)?.advanced(by: advancedBy),
      _viewportsKeys.indices.contains(idx)
    else {
      return nil
    }

    return _pageController(for: _viewportsKeys[idx])
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
  
  // Called from AppDelegate as `moveToShellWithKey:` — the ObjC-bridged name, which is why a plain
  // grep for "moveToShell" does not find its caller.
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
      let idx = _viewportsKeys.firstIndex(of: key),
      let page = _pageController(for: key)
    else {
      return
    }

    let direction: UIPageViewController.NavigationDirection = currentIdx < idx ? .forward : .reverse

    _installPage(page, direction: direction, animated: animated)
  }

  // The ONE serialized installer for every page-VC transition. A .scroll UIPageViewController
  // aborts a programmatic animated transition that races another animation (a modal dismiss, a
  // user swipe, a second switch) — the completion then reports didComplete == false while the OLD
  // page stays on screen, and `viewControllers` LIES (it reports the target). Trusting the intent
  // there is how a tab got "lost": _currentKey said B, the screen showed A, and the layout sweep
  // hid B for good. So: one transition at a time (later requests remember only the newest target
  // and replay when the live one ends), and a didComplete == false transition is unconditionally
  // re-issued without animation — which cannot be interrupted.
  private func _installPage(
    _ page: UIViewController & MoshroomTabPage,
    direction: UIPageViewController.NavigationDirection,
    animated: Bool,
    attachInput: Bool = true,
    completion: ((Bool) -> Void)? = nil
  ) {
    if _spaceControllerAnimating {
      _pendingMoveKey = page.moshroomTabKey
      return
    }

    // A non-terminal page cannot go up while a terminal web view holds the input focus: the
    // focused terminal REFUSES to hide (removeFromContainer bails while KBTracker points at its
    // web view), so the page would render over a live terminal. Release the focus first —
    // _currentKey still names the outgoing tab here.
    if page.moshroomTabKind != .term {
      currentTerm()?.resignInput()
    }

    _spaceControllerAnimating = true
    _viewportsController.setViewControllers([page], direction: direction, animated: animated) { (didComplete) in
      if !didComplete {
        self._viewportsController.setViewControllers([page], direction: direction, animated: false)
      }
      (page as? TermController)?.resumeIfNeeded()
      self._currentKey = page.moshroomTabKey
      // Keep the on-disk tab layout current (Catalyst relaunch path, see moshroomPersistUIState).
      self.moshroomPersistUIState()
      // Assert the visible web view on every install. The page VC being right is not enough: the
      // terminals' web views are siblings in a shared container and a stale one left unhidden by any
      // other path would keep covering the tab just switched to.
      self._showOnlyCurrentTerminal()
      self._syncTerminalBackground()
      if attachInput, page.moshroomTabKind == .term {
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
        if pendingKey != page.moshroomTabKey {
          self._moveToShell(key: pendingKey, animated: false)
        }
      }
    }
  }

  // Zero tabs: install the empty-state placeholder page. Same serialized discipline as
  // _installPage (an unanimated setViewControllers racing a live transition is exactly the
  // page-VC corruption _installPage exists to prevent), so a request made mid-flight replays
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
      // Zero tabs is a real state the user chose — persist it too, so it survives a relaunch.
      self.moshroomPersistUIState()
      // Keep the page the same shade as the strips around it (last terminal theme or the
      // house ground) — currentTerm() is nil here, so the layout-driven sync alone would
      // land after a visible flash of the default.
      self._syncTerminalBackground()
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
        if self._viewportsKeys.contains(pendingKey),
           let page = self._pageController(for: pendingKey) {
          self._installPage(page, direction: .forward, animated: false)
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
  // Honest by kind: nil when the current tab is not a terminal, exactly like the zero-tab state
  // — the ~40 ambient callers (background sync, live chip, composer, quick keys, Moshnector...)
  // already handle nil gracefully because zero tabs exercises it. Indexing the registry with a
  // non-terminal key would fabricate a phantom TermController instead.
  @objc func currentTerm() -> TermController? {
    guard let currentKey = _currentKey, moshroomTabKind(for: currentKey) == .term else {
      return nil
    }
    return SessionRegistry.shared[currentKey]
  }

  /// What kind of tab a key is. Missing means `.term` — the historical default, and what every
  /// key restored from a pre-typed-tabs UIState is.
  func moshroomTabKind(for key: UUID) -> MoshroomTabKind {
    _tabKinds[key] ?? .term
  }

  /// The one page factory: key → the page controller for its kind. Terminals resolve through the
  /// SessionRegistry (the ONLY gate to its fabricating subscript); other kinds resolve to their
  /// live controller or are rebuilt fresh by `_makeTabPage`.
  private func _pageController(for key: UUID) -> (UIViewController & MoshroomTabPage)? {
    switch moshroomTabKind(for: key) {
    case .term:
      let term: TermController = SessionRegistry.shared[key]
      term.delegate = self
      term.bgColor = view.backgroundColor ?? .moshroomBackground
      return term
    case .moshify, .explorer:
      if let page = _pageControllers[key] { return page }
      guard let page = _makeTabPage(kind: moshroomTabKind(for: key), key: key) else { return nil }
      _pageControllers[key] = page
      return page
    }
  }

  /// Builds a fresh non-terminal page (restore path, or the first open). Pages paint themselves
  /// with the live root background (see _syncTerminalBackground) so they never cut a different
  /// black into the strips around the viewport.
  private func _makeTabPage(kind: MoshroomTabKind, key: UUID) -> (UIViewController & MoshroomTabPage)? {
    switch kind {
    case .term:
      return nil // terminals never come through here
    case .moshify:
      // A restored music tab comes back attached to the engine (config in UserDefaults).
      let ctrl = MoshifyTabController(key: key)
      ctrl.space = self
      return ctrl
    case .explorer:
      // A restored explorer tab comes back fresh, at its host picker.
      let ctrl = MoshxploreTabController(key: key)
      ctrl.space = self
      return ctrl
    }
  }

  /// Registers a freshly created non-terminal tab (key + kind + live controller) and installs it,
  /// inserting right after the current tab like a new terminal does. Used by the launcher flows.
  func moshroomOpenTabPage(_ page: UIViewController & MoshroomTabPage) {
    let key = page.moshroomTabKey
    _tabKinds[key] = page.moshroomTabKind
    _pageControllers[key] = page
    if let currentKey = _currentKey,
       let idx = _viewportsKeys.firstIndex(of: currentKey)?.advanced(by: 1) {
      _viewportsKeys.insert(key, at: idx)
    } else {
      _viewportsKeys.append(key)
    }
    _installPage(page, direction: .forward, animated: false)
  }

  /// The key of the first open tab of a kind, if any — the launcher uses it to focus a singleton
  /// tab (Moshify) instead of opening a second one.
  func moshroomFirstTab(ofKind kind: MoshroomTabKind) -> UUID? {
    _viewportsKeys.first { moshroomTabKind(for: $0) == kind }
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
    let kind: MoshroomTabKind
  }

  /// A tab's name when it HAS one. Terminals: forced custom name, then the connected host's alias
  /// (a tab that is an ssh/mosh session to "awesomehost" IS awesomehost to the user), then the
  /// program's own OSC title (opencode / vim / ssh); nil for none of those — the quick-connect
  /// canvas. Other kinds: whatever their live page reports (the explorer names its host).
  /// The one resolution both the Tabs list and the tab pill are built on.
  func moshroomTabName(for key: UUID) -> String? {
    switch moshroomTabKind(for: key) {
    case .term:
      let term: TermController = SessionRegistry.shared[key]
      for candidate in [term.meta.customName, term.meta.connectedHost, term.termView.title] {
        let name = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
      }
      return nil
    case .moshify, .explorer:
      return _pageControllers[key]?.moshroomTabTitle
    }
  }

  // The Tabs list needs a row label for every tab, so a nameless one says so honestly there: a
  // terminal with no name is the quick-connect canvas, not a "shell" (that name read as a phantom
  // session in the list); a non-terminal tab falls back to its feature's name.
  func moshroomTitle(for key: UUID) -> String {
    if let name = moshroomTabName(for: key) { return name }
    switch moshroomTabKind(for: key) {
    case .term: return "not connected"
    case .moshify: return "Moshify"
    case .explorer: return "Files"
    }
  }

  /// The open tabs, in order, each with its display title, kind and whether it is active.
  func moshroomTabs() -> [MoshroomTabInfo] {
    _viewportsKeys.map {
      MoshroomTabInfo(key: $0, title: moshroomTitle(for: $0),
                      isActive: $0 == _currentKey, kind: moshroomTabKind(for: $0))
    }
  }

  /// Put the name of the tab on screen into the red pill next to the Tabs button, and leave it there.
  /// The ONE place that writes it: it reads `moshroomTabName`, the same resolution the Tabs list is
  /// built on (custom name → connected host → the program's own title), so the pill can never
  /// disagree with the list. A tab with no name of its own shows NO pill — an empty canvas needs no
  /// label telling it so. Called from `_showOnlyCurrentTerminal` (every switch, install and return to
  /// the foreground), from a rename, from a recorded connection, and when a program changes its
  /// terminal title. Idempotent and cheap.
  func moshroomUpdateTabLabel() {
    guard let label = moshroomTabLabel else { return }
    // Only a tab with a LIVE session gets a pill. On a fresh local prompt the Quick Connect card is
    // offering to connect, and a pill naming the host that tab used last says the opposite of what
    // the rest of the screen says — so it shows nothing at all there.
    let name = _currentKey.flatMap { key -> String? in
      // The pill is a terminal thing: it names the host a session is on. A music or explorer
      // tab IS its whole screen — no label restating it.
      guard moshroomTabKind(for: key) == .term else { return nil }
      let term: TermController = SessionRegistry.shared[key]
      guard term.moshroomUploadHost != nil else { return nil }
      return moshroomTabName(for: key)
    }
    if let name {
      if label.text != name { label.text = name }
      label.isHidden = false
      view.bringSubviewToFront(label)
    } else {
      label.isHidden = true
    }
  }

  func moshroomSwitch(toTab key: UUID) {
    dismissMoshnector()
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
  // Terminal tabs only: custom names live in the SessionMeta, which other kinds don't have.
  func moshroomRename(tab key: UUID, onDone: @escaping () -> Void) {
    guard moshroomTabKind(for: key) == .term else { return }
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
    alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
      SessionRegistry.shared.renameSession(key, to: alert.textFields?.first?.text)
      self?.moshroomUpdateTabLabel()
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
    // The house ground, NOT .systemBackground: semantic black resolves to #000 while the strips
    // around the viewport wear the terminal theme's rgb(16,16,16) — the page must not cut a
    // darker rectangle into them. _syncTerminalBackground re-asserts the live colour on top.
    view.backgroundColor = .moshroomBackground

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
