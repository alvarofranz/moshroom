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
import UserNotifications
import AudioToolbox

@objc protocol TermControlDelegate: NSObjectProtocol {
  func terminalHangup(control: TermController)
  @objc optional func terminalDidResize(control: TermController)
}

private class ProxyView: UIView {
  var controlledView: UIView? = nil
  private var _cancelable: AnyCancellable? = nil
  private var _hasBeenPlaced: Bool = false  // Track if view has been placed
  private var _isTerminated: Bool = false   // Prevent re-placement after termination

  override func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)
    if superview == nil {
      _cancelable = nil
    }
  }

  override func didMoveToSuperview() {
    super.didMoveToSuperview()

    _cancelable = nil

    guard
      let parent = superview
    else {
      return
    }

    _cancelable = parent.publisher(for: \.frame).sink { [weak self] frame in
      guard let controlledView = self?.controlledView,
            controlledView.superview != nil
      else {
        return
      }
      controlledView.frame = frame
    }

    placeControlledView()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard
      let parent = superview,
      let controlledView = controlledView
    else {
      return
    }
    controlledView.frame = parent.frame
  }

  func removeControlledView() {
    // Hide instead of remove (for temporary switching)
    guard let controlledView = controlledView else { return }
    controlledView.isHidden = true
  }

  func destroyControlledView() {
    // Full removal for terminal termination
    guard let controlledView = controlledView else { return }
    controlledView.removeFromSuperview()
    _hasBeenPlaced = false
    _isTerminated = true  // Prevent any future re-placement
  }

  func prepareForWindowMove() {
    // Remove for window move but allow re-placement in new window
    guard let controlledView = controlledView else { return }
    controlledView.removeFromSuperview()
    _hasBeenPlaced = false
    // Note: Don't set _isTerminated - this is a move, not termination
  }

  func placeControlledView() {
    // Never place if terminal was terminated
    if _isTerminated { return }

    guard
      let parent = superview,
      let container = parent.superview,
      let controlledView = controlledView
    else {
      return
    }

    controlledView.frame = parent.frame

    // Place once per container, then just show/hide
    // If view is in a different container (window changed), we need to re-place
    if !_hasBeenPlaced || controlledView.superview !== container {
      container.addSubview(controlledView)
      _hasBeenPlaced = true
    } else {
      // Already placed: all terminals are siblings in the shared container, and the layout sweep
      // that hides the others runs async — bring this one to the front so a not-yet-hidden
      // sibling can never sit on top of the terminal being shown.
      container.bringSubviewToFront(controlledView)
    }

    // Show the view when placing
    controlledView.isHidden = false
  }
}

class TermController: UIViewController {
  private let _meta: SessionMeta

  private var _termDevice = TermDevice()
  private var _termView = TermView(frame: .zero, termUIState: TermUIState.withDefaults())
  private var _proxyView = ProxyView(frame: .zero)
  private var _bgColor: UIColor? = nil
  private var _fontSizeBeforeScaling: Int? = nil

  @objc public var viewIsLoaded: Bool = false

  @objc public var activityKey: String? = nil
  @objc public var termDevice: TermDevice { _termDevice }
  @objc weak var delegate: TermControlDelegate? = nil

  // Control whether terminal can become first responder (e.g., during Snips Input Mode)
  var shouldBlockFirstResponder: Bool = false {
    didSet {
      _termDevice.shouldBlockFirstResponder = shouldBlockFirstResponder
    }
  }
  @objc var bgColor: UIColor? {
    get { _bgColor }
    set { _bgColor = newValue }
  }
  
  // State Properties for Input Management
  var isReady: Bool {
    _termDevice.view?.isReady ?? false
  }
  
  var isAttached: Bool {
    KBTracker.shared.input == _termDevice.view?.webView
  }
  
  override var isFirstResponder: Bool {
    _termDevice.view?.webView.isFirstResponder ?? false
  }

  @objc var termView: TermView { _termView }

  private var _sessionPayload: TermSessionPayload? = nil
  private var _session: Session? { _sessionPayload?.session }

  // True only for a FRESH local shell sitting idle at the moshroom> prompt — not a restored or
  // connected ssh/mosh session (those carry a childSessionType from the start, even before the
  // mosh reconnect lands). Used to decide whether the launch terminal reveals the Moshnector.
  @objc var moshroomIsFreshShell: Bool {
    guard let mcp = _session as? MCPSession, mcp.isRunningCmd() == false else { return false }
    return (mcp.sessionParams?.childSessionType ?? "").isEmpty
  }


  // The saved host THIS tab is connected to (via Quick Connect or a typed ssh/mosh) — Moshdrop's
  // upload target, per-tab so independent tabs never clobber each other. nil at the local prompt.
  var moshroomConnectedHost: String? = nil {
    didSet { if moshroomConnectedHost != nil { moshroomConnectedHostSetAt = Date() } }
  }
  // When the connection was noted. A just-tapped connect hasn't spawned its command yet, so the
  // shell still reads as fresh for a moment — the clear path uses this to not wipe it (Moshnector).
  var moshroomConnectedHostSetAt: Date? = nil

  // Once the user has sent any command in this tab (ls, ssh, connect…), the Quick Connect card stays
  // hidden — the terminal now has content and the card must not pop back over it. Per-tab; a fresh tab
  // (or a fresh restored shell) starts false, so the card still appears on a brand-new, untouched terminal.
  var moshroomUserHasInteracted = false

  required init(meta: SessionMeta? = nil) {
    _meta = meta ?? SessionMeta()
    super.init(nibName: nil, bundle: nil)
  }

  convenience init(sessionPayload: TermSessionPayload? = nil) {
    self.init(meta: nil)
    self._sessionPayload = sessionPayload
  }

  required public init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func placeToContainer() {
    _proxyView.placeControlledView()
  }

  func removeFromContainer() -> Bool {
    if KBTracker.shared.input == _termView.webView {
      return false
    }
    _proxyView.removeControlledView()
    return true
  }

  func prepareForWindowMove() {
    // Prepare terminal for move to different window
    _proxyView.prepareForWindowMove()
  }

  public override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    if !coordinator.isAnimated {
      return
    }

    super.viewWillTransition(to: size, with: coordinator)
  }

  public override func loadView() {
    super.loadView()
    _termDevice.delegate = self
    _termDevice.attachView(_termView)
    _termView.backgroundColor = _bgColor
    _termView.termController = self
    _proxyView.controlledView = _termView;
    _proxyView.isUserInteractionEnabled = false
    view = _proxyView
  }

  public override func viewDidLoad() {
    super.viewDidLoad()
    viewIsLoaded = true

    _termView.load()
  }

  public override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()

    guard let window = view.window,
      let windowScene = window.windowScene,
      windowScene.activationState == .foregroundActive
    else {
      return
    }
  }

  public override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    _termView.termUIState.viewSize = view.bounds.size
  }

  @objc public func terminate() {
    _proxyView.destroyControlledView()
    _termDevice.delegate = nil
    _termView.terminate()
    _session?.kill()
  }

  @objc public func scaleWithPich(_ pinch: UIPinchGestureRecognizer) {
    // Block font resize when layout is locked
    guard !_termView.termUIState.layoutLocked else {
      return
    }

    switch pinch.state {
    case .began: fallthrough
    case .ended:
      _fontSizeBeforeScaling = _termView.termUIState.fontSize
    case .changed:
      guard let initialSize = _fontSizeBeforeScaling else {
        return
      }
      let newSize = Int(round(CGFloat(initialSize) * pinch.scale))
      guard newSize != _termView.termUIState.fontSize else {
        return
      }
      _termView.setFontSize(newSize as NSNumber)
    default:  break
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    // Break ref-loop
    _session?.delegate = nil
  }
}

extension TermController: SessionDelegate {
  public func sessionFinished() {
    self.delegate?.terminalHangup(control: self)
  }
}

let _apiRoutes:[String: (MCPSession, String) -> AnyPublisher<String, Never>] = [
  "history.search": History.searchAPI,
  "completion.for": Complete.forAPI
]


/// Types of supported notifications
@objc enum MoshNotificationType: NSInteger {
  case bell = 0
  case osc = 1
}

// MARK: - TermDeviceDelegate methods
extension TermController: TermDeviceDelegate {

  /**
   When a `ring-bell` notification has been received on `TermView` react to it by sounding a bell if the terminal that sent it
   is in focus and if it's not send a notification. Tapping the notification opens the session that sent it.

   Only reproduce haptic feedback on iPhones and if it's enabled.

   Enable/Disable standard OSC sequences & iTerm2 notifications
   */
  func viewDidReceiveBellRing() {

    if MoshroomDefaults.isPlaySoundOnBellOn() && _termView.isFocused() {
      AudioServicesPlaySystemSound(1103);
    }

    viewNotify(["title": "🔔 \(_termView.title ?? "")", "type": MoshNotificationType.bell.rawValue])

    // Haptic feedback is only visible from iPhones
    if UIDevice.current.userInterfaceIdiom == .phone && !MoshroomDefaults.hapticFeedbackOnBellOff() {
      UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
  }

  /**
   Presents a UserNotification with the `title` & `body` values passed on `data`. Tapping on the notification opens the terminal that originated the notification. Also triggered when the terminal receives a standard `OSC` sequence & iTerm2-like notification.

   - Parameters:
    - data: Set the `title` and `body` String values to display those values in the notification banner. Set the `type`'s rawValue of `MoshNotificationType` to identify the type of notification used.
   */
  func viewNotify(_ data: [AnyHashable : Any]!) {

    guard let notificationTypeRaw = data["type"] as? Int, let notificationType = MoshNotificationType(rawValue: notificationTypeRaw) else {
      return
    }

    if notificationType  == .bell && (_termView.isFocused() || !MoshroomDefaults.isNotificationOnBellUnfocusedOn())
        || notificationType == .osc && !MoshroomDefaults.isOscNotificationsOn() {
       return
    }

    let content = UNMutableNotificationContent()
    content.title = (data["title"] as? String) ?? title ?? "Moshroom"
    content.body = (data["body"] as? String) ?? ""
    content.sound = .default
    content.threadIdentifier = meta.key.uuidString
    content.targetContentIdentifier = "moshroom://open-scene/\(view?.window?.windowScene?.session.persistentIdentifier ?? "")"

    let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { (granted, error) in
      if granted {
        center.add(req, withCompletionHandler: nil)
      }
    }
  }

  func apiCall(_ api: String!, andRequest request: String!) {
    guard
      let session = _session as? MCPSession,
      let api = api,
      let call = _apiRoutes[api]
    else {
      return
    }

    weak var termView = _termView

   _ = call(session, request)
     .receive(on: RunLoop.main)
     .sink { termView?.apiResponse(api, response: $0) }
  }

  public func deviceIsReady() {
    if _sessionPayload != nil {
      _startSession()
    } else {
      resumeIfNeeded()
    }

    guard _sessionPayload != nil else {
      print("Session Payload is nil")
      return
    }

    // Input progression. When device becomes ready, check if we need to become first responder
    if isAttached {
      _becomeFirstResponder()
    }
  }

  
  func activateInput() {
    // Don't activate input if blocked (e.g., during Snips Input Mode)
    guard !shouldBlockFirstResponder else {
      return
    }

    if !isAttached {
      _attachInput()
    }

    if isReady {
      _becomeFirstResponder()
    }
    // If not ready, wait for isReady call to trigger _becomeFirstResponder()
  }

  func resignInput() {
    guard isAttached && isReady else {
      return
    }

    guard let deviceView = _termDevice.view else { return }

    deviceView.webView.reportFocus(false)

    // It is key to reset here so when attached again, settings are synced and the keyboard state is properly reset.
    KBTracker.shared.attach(input: nil)

    _ = _termDevice.view?.webView.resignFirstResponder()
  }
  
  private func _attachInput() {
    guard let deviceView = _termDevice.view else { return }
    
    KBTracker.shared.attach(input: deviceView.webView)
    _termDevice.attachInput(deviceView.webView)
  }
  
  private func _becomeFirstResponder() {
    guard let deviceView = _termDevice.view else { return }

    // Don't become first responder if blocked (e.g., during Snips Input Mode)
    guard !shouldBlockFirstResponder else { return }

    if !isAttached && !isReady{ return }

    deviceView.webView.reportFocus(true)
    _termDevice.focus()

    let input = KBTracker.shared.input

    if input != KBTracker.shared.input {
      input?.reportFocus(false)
    }

    _ = _termDevice.view?.webView.becomeFirstResponder()
  }
    
  public func deviceSizeChanged() {
    delegate?.terminalDidResize?(control: self)
    _session?.sigwinch()
  }

  public func viewFontSizeChanged(_ size: Int) {
    _termDevice.input?.reset()
  }

  public func deviceFocused() {
    view.setNeedsLayout()
  }

  public func viewController() -> UIViewController! {
    return self
  }
}

extension TermController: SuspendableSession {

  var meta: SessionMeta { _meta }

  private enum ArchiveKey: CodingKey { case termUIState }

  func _startSession() {
    guard let payload = _sessionPayload,
          _session == nil else { return }

    payload.start(in: _termDevice, sessionKey: meta.key.uuidString)
    _session?.delegate = self

    // Moshroom: the session now exists — this is the first deterministic point where
    // `moshroomIsFreshShell` can be true, so drive the quick-connect reveal off it (the web-view
    // readiness triggers race ahead of this).
    NotificationCenter.default.post(name: NSNotification.Name("MoshroomPromptReadyNotification"), object: nil)

    if view.bounds.size != _termView.termUIState.viewSize {
      _session?.sigwinch()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      self._termView.setClipboardWrite(true)
    }
  }

  func resumeIfNeeded() {
    guard _termDevice.isReady else { return }
    // A hidden tab whose web content process was jettisoned waits for this moment (becoming the
    // shown tab / app foregrounding) to reload its terminal page — see TermView.
    _termView.moshroomReloadIfNeeded()
    SessionRegistry.shared.resumeIfNeeded(session: self)
  }

  // The terminal's web view came back from a WebKit content-process jettison: hterm is rebuilt
  // but BLANK, while the session still believes the old screen is displayed. Nudge everything
  // into repainting with a real size wiggle — cols-1 now, the true size ~250ms later. The spacing
  // matters: back-to-back resizes coalesce at the remote pty and apps see "no change". Two
  // genuinely distinct SIGWINCHes make mosh resend its frame, TUIs (vim/tmux/opencode) redraw,
  // and remote shell prompts re-render via readline. A fresh idle local shell has nothing to
  // repaint — its prompt is reprinted instead (which also re-reveals the quick-connect card).
  @objc func moshroomTermViewDidRecover() {
    let state = _termView.termUIState
    if state.cols > 1 {
      let rows = UInt16(clamping: state.rows)
      _termDevice.viewWinSizeChanged(winsize(ws_row: rows, ws_col: UInt16(clamping: state.cols - 1), ws_xpixel: 0, ws_ypixel: 0))
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        guard let self else { return }
        let s = self._termView.termUIState
        self._termDevice.viewWinSizeChanged(winsize(ws_row: UInt16(clamping: s.rows), ws_col: UInt16(clamping: s.cols), ws_xpixel: 0, ws_ypixel: 0))
      }
    }
    (_session as? MCPSession)?.moshroomReprintPromptIfIdle()
  }

  func resume(with unarchiver: NSKeyedUnarchiver) {
    // Restore the saved terminal UI state if present — a stale/empty archive (e.g. suspended before a
    // payload existed) must NOT abort the resume, or the terminal would come back with no live session.
    if let termUIState: TermUIState = unarchiver.bk_decode(of: [TermUIState.self], for: ArchiveKey.termUIState) {
      _termView.applyTermUIState(termUIState)
    }

    if _sessionPayload == nil {
      // Restore the saved session, or — if the archive carries none — start a brand-new shell so the
      // terminal is always live (never a dead, sessionless prompt).
      _sessionPayload = decodePayload(from: unarchiver) ?? MCPSessionPayload(params: MCPParams())
      _sessionPayload!.start(in: _termDevice, sessionKey: _meta.key.uuidString)
      _session?.delegate = self
    } else {
      _sessionPayload!.resumeFromSuspended()
    }

    // Moshroom: session is live again after a restore — reveal the quick-connect card if idle.
    NotificationCenter.default.post(name: NSNotification.Name("MoshroomPromptReadyNotification"), object: nil)

    if view.bounds.size != _termView.termUIState.viewSize {
      _session?.sigwinch()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      self._termView.setClipboardWrite(true)
    }
  }

  func suspendSession(with archiver: NSKeyedArchiver) {
    guard let sessionPayload = _sessionPayload else { return }
    _termView.setClipboardWrite(false)

    sessionPayload.suspend()

    archiver.bk_encode(_termView.termUIState, for: ArchiveKey.termUIState)
    sessionPayload.encode(with: archiver)
  }
}

// MARK: - TermUIState

@objc class TermUIState: NSObject, NSSecureCoding {
  @objc var viewSize: CGSize = .zero
  @objc var rows: Int = 0
  @objc var cols: Int = 0
  @objc var themeName: String? = nil
  @objc var fontName: String? = nil
  @objc var fontSize: Int = 16
  @objc var layoutMode: Int = 0
  @objc var boldAsBright: Bool = false
  @objc var enableBold: UInt = 0
  @objc var layoutLocked: Bool = false
  @objc var layoutLockedFrame: CGRect = .zero

  private enum Key: CodingKey {
    case viewSize, rows, cols, themeName, fontName, fontSize
    case layoutMode, boldAsBright, enableBold, layoutLocked, layoutLockedFrame
  }

  override init() { super.init() }

  required init?(coder: NSCoder) {
    super.init()
    self.viewSize = coder.bk_decode(for: Key.viewSize)
    self.rows = coder.bk_decode(for: Key.rows)
    self.cols = coder.bk_decode(for: Key.cols)
    self.themeName = coder.bk_decode(for: Key.themeName)
    self.fontName = coder.bk_decode(for: Key.fontName)
    self.fontSize = coder.bk_decode(for: Key.fontSize)
    self.layoutMode = coder.bk_decode(for: Key.layoutMode)
    self.boldAsBright = coder.bk_decode(for: Key.boldAsBright)
    self.enableBold = coder.bk_decode(for: Key.enableBold)
    self.layoutLocked = coder.bk_decode(for: Key.layoutLocked)
    self.layoutLockedFrame = coder.bk_decode(for: Key.layoutLockedFrame)
  }

  func encode(with coder: NSCoder) {
    coder.bk_encode(viewSize, for: Key.viewSize)
    coder.bk_encode(rows, for: Key.rows)
    coder.bk_encode(cols, for: Key.cols)
    coder.bk_encode(themeName, for: Key.themeName)
    coder.bk_encode(fontName, for: Key.fontName)
    coder.bk_encode(fontSize, for: Key.fontSize)
    coder.bk_encode(layoutMode, for: Key.layoutMode)
    coder.bk_encode(boldAsBright, for: Key.boldAsBright)
    coder.bk_encode(enableBold, for: Key.enableBold)
    coder.bk_encode(layoutLocked, for: Key.layoutLocked)
    coder.bk_encode(layoutLockedFrame, for: Key.layoutLockedFrame)
  }

  static var supportsSecureCoding: Bool { true }

  @objc static func withDefaults() -> TermUIState {
    let state = TermUIState()
    state.fontSize = MoshroomDefaults.selectedFontSize()?.intValue ?? 16
    state.fontName = MoshroomDefaults.selectedFontName()
    state.themeName = MoshroomDefaults.selectedThemeName()
    state.enableBold = UInt(MoshroomDefaults.enableBold())
    state.boldAsBright = MoshroomDefaults.isBoldAsBright()
    state.layoutMode = MoshroomDefaults.layoutMode().rawValue
    return state
  }
}

