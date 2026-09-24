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
  // The loader over this terminal while it is not drawing yet (see moshroomBeginCatchUp).
  fileprivate let _catchUp = MoshroomCatchUp()

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

  /// An ssh/mosh child is running in this tab right now (as opposed to the local `moshroom>` prompt,
  /// with or without a local command running on it).
  var moshroomHasLiveChildSession: Bool {
    guard let mcp = _session as? MCPSession else { return false }
    return !(mcp.sessionParams?.childSessionType ?? "").isEmpty
  }

  /// The host this tab is ON right now: the connection recorded in THIS run, and failing that — while
  /// a child session is actually live — the host the tab is persisted as being on.
  ///
  /// The two differ after an app relaunch, which is the whole point: a mosh session survives it and
  /// comes back live, but the in-memory record does not, so attaching a file in a session that was
  /// plainly still there was refused with "Not connected" until the user quit the app and reconnected.
  /// The persisted name (`meta.connectedHost`, the same fact the tab is titled with) is the answer, and
  /// an upload needs nothing more: it opens its own SSH/SFTP connection to that alias.
  ///
  /// Nil whenever there is no live child, which is also what the tab pill keys off — one predicate, so
  /// "there is a host to upload to" and "there is a host worth naming" can never disagree.
  var moshroomUploadHost: String? {
    if let live = moshroomConnectedHost, !live.isEmpty { return live }
    guard moshroomHasLiveChildSession else { return nil }
    let persisted = (meta.connectedHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return persisted.isEmpty ? nil : persisted
  }

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

    // The session reaching its (invisible by design) local prompt ends a wait for it to draw.
    NotificationCenter.default.addObserver(self, selector: #selector(_moshroomSessionPromptReady(_:)),
                                           name: .moshroomPromptReady, object: nil)
    _termView.load()
    // A tab brought back from its archive (a relaunch): its page loads, then its session, before
    // there is anything to see.
    if meta.isSuspended {
      moshroomBeginCatchUp(expectOutput: true)
    }
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

  public func sessionCheckpointDidChange() {
    SessionRegistry.shared.persist(session: self)
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
    }
    // Idempotent (only a suspended tab resumes), and the one retry for a resume that was asked for
    // before the page was ready.
    resumeIfNeeded()

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

    _moshroomSessionDidGoLive()
  }

  /// A session just became live in this tab — freshly started or restored. Both paths owe the same
  /// three things: announce it (this is the first deterministic point where `moshroomIsFreshShell`
  /// can be true, so Quick Connect reveals off it rather than racing the web view), catch the pty up
  /// if the view resized while there was no session, and let the program write the clipboard once
  /// the terminal has settled.
  private func _moshroomSessionDidGoLive() {
    NotificationCenter.default.post(name: .moshroomPromptReady, object: nil)

    if view.bounds.size != _termView.termUIState.viewSize {
      _session?.sigwinch()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      self._termView.setClipboardWrite(true)
    }
  }

  func resumeIfNeeded() {
    // A hidden tab whose web content process was jettisoned waits for this moment (becoming the
    // shown tab / app foregrounding) to reload its terminal page (see TermView). Before the ready
    // check: a page that died before it EVER became ready would otherwise never be reloaded, never
    // report ready, and the tab would stay blank for good.
    _termView.moshroomReloadIfNeeded()
    guard _termDevice.isReady else { return }
    SessionRegistry.shared.resumeIfNeeded(session: self)
  }

  // The terminal's web view came back from a WebKit content-process jettison: hterm is rebuilt
  // but BLANK, while the session still believes the old screen is displayed.
  //
  // mosh holds the whole screen on this side, so it repaints it from its own copy, locally and
  // exactly. A resize does NOT do that reliably: the client only redraws everything when the
  // server's reply carries a new size, and on a network that is still waking up (or slower than
  // the 250ms below) both resizes reach the server together and the size never appears to change,
  // which left a blank screen with scattered characters.
  //
  // Anything else gets a real size wiggle: cols-1 now, the true size ~250ms later. The spacing
  // matters: back-to-back resizes coalesce at the remote pty and apps see "no change". Two
  // genuinely distinct SIGWINCHes make TUIs (vim/tmux/opencode) redraw and remote shell prompts
  // re-render via readline. A fresh idle local shell has nothing to repaint: its prompt is
  // reprinted instead (which also re-reveals the quick-connect card).
  @objc func moshroomTermViewDidRecover() {
    // The rebuilt page starts in its defaults: carriage-return translation on, whatever the session
    // running here had set. Say it again (the device remembers what it last asked for).
    _termDevice.autoCR = _termDevice.autoCR
    // ...and with program clipboard writes OFF (term.js): let them back in once the session has
    // redrawn, so a replayed copy from the old screen never lands on the iOS clipboard.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?._termView.setClipboardWrite(true)
    }
    // Whatever the page held while it was gone reaches it only now: a bell in there is from then.
    _termDevice.moshroomQuietReplay()
    // The page is back and the redraw is on its way: the loader has no business outlasting it by
    // more than a moment, whatever becomes of the reports it is waiting for.
    let token = _catchUp.token
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self, self._catchUp.active, self._catchUp.token == token else { return }
      self._endCatchUp()
    }
    if (_session as? MCPSession)?.moshroomRepaintMoshSession() == true {
      return
    }
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

  /// Asked by the rebuilt terminal view before it flushes what it held (see TermView): true when the
  /// session running here will redraw the whole screen itself, so the held output can be dropped.
  @objc func moshroomRecoveryRepaintsWholeScreen() -> Bool {
    (_session as? MCPSession)?.moshroomMoshCanRepaint() ?? false
  }

  /// A mosh session to a saved host is running or parked in this tab, so it can be reconnected in
  /// place (see moshroomReconnect).
  var moshroomReconnectHost: String? {
    guard let mcp = _session as? MCPSession, mcp.sessionParams?.childSessionType == "mosh" else { return nil }
    let host = (meta.connectedHost ?? moshroomConnectedHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !host.isEmpty, MoshHosts.withHost(host) != nil else { return nil }
    return host
  }

  /// Reconnect this tab's mosh session in place: what closing the tab and connecting again from Quick
  /// Connect does, without losing the tab. For a session whose server no longer answers (it rebooted,
  /// or the network in between blocks it): mosh itself never gives up on a server it has heard from.
  func moshroomReconnect() {
    guard let host = moshroomReconnectHost, let mcp = _session as? MCPSession else { return }
    moshroomConnectedHost = host
    mcp.moshroomReconnect(with: "mosh \(host)")
  }

  func resumeInPlace() -> Bool {
    guard let payload = _sessionPayload, payload.session != nil else { return false }
    // A parked mosh session is about to wake: nothing new is drawn until its client does.
    if let params = (payload.session as? MCPSession)?.sessionParams,
       params.childSessionType == "mosh", params.hasEncodedState() {
      MoshLog.log("session", "waking a parked mosh session")
      moshroomBeginCatchUp(expectOutput: true)
    }
    payload.resumeFromSuspended()
    _moshroomSessionDidGoLive()
    return true
  }

  func resume(with unarchiver: NSKeyedUnarchiver?) {
    // Restore the saved terminal UI state if present — a stale/empty archive (e.g. suspended before a
    // payload existed) must NOT abort the resume, or the terminal would come back with no live session.
    if let unarchiver,
       let termUIState: TermUIState = unarchiver.bk_decode(of: [TermUIState.self], for: ArchiveKey.termUIState) {
      _termView.applyTermUIState(termUIState)
    }

    if _sessionPayload == nil {
      // Restore the saved session, or, if there is no archive or it carries none, start a
      // brand-new shell so the terminal is always live (never a dead, sessionless prompt).
      _sessionPayload = unarchiver.flatMap { decodePayload(from: $0) } ?? MCPSessionPayload(params: MCPParams())
      _sessionPayload!.start(in: _termDevice, sessionKey: _meta.key.uuidString)
      _session?.delegate = self
    } else {
      _sessionPayload!.resumeFromSuspended()
    }

    _moshroomSessionDidGoLive()
  }

  func suspendSession(with archiver: NSKeyedArchiver) {
    guard let sessionPayload = _sessionPayload else { return }
    _termView.setClipboardWrite(false)

    sessionPayload.suspend()
    archiveSession(with: archiver)
  }

  @discardableResult func archiveSession(with archiver: NSKeyedArchiver) -> Bool {
    guard let sessionPayload = _sessionPayload else { return false }
    archiver.bk_encode(_termView.termUIState, for: ArchiveKey.termUIState)
    sessionPayload.encode(with: archiver)
    return true
  }
}

// MARK: - Catch-up loader

extension TermController {
  /// The terminal may not be drawing for a moment: the app is coming back, a parked session is
  /// waking, a relaunched tab is restoring, or WebKit is rebuilding a page it threw away. A loader
  /// covers the wait, but only if it lasts (a quick return shows nothing at all), and it goes the
  /// moment the page reports it has drawn: right away, or, when `expectOutput`, once the session's
  /// next output is on screen. A newer call supersedes an older one.
  func moshroomBeginCatchUp(expectOutput: Bool) {
    // A wait for the session's own output is the stronger one: a "drawn now" request (coming back,
    // a window becoming key) must not cut it short, or the loader lifts before the session draws.
    if !expectOutput, _catchUp.active, _catchUp.expectOutput {
      return
    }
    let wasShown = _catchUp.active && _catchUp.shown
    _catchUp.token += 1
    let token = _catchUp.token
    _catchUp.active = true
    _catchUp.expectOutput = expectOutput
    _catchUp.startedAt = Date()
    // A loader already up stays up (and keeps turning) across a wait that supersedes it.
    _catchUp.shown = wasShown
    if expectOutput {
      _termView.moshroomNotifyPainted(afterNextOutput: token)
    } else {
      _termView.moshroomNotifyPaintedNow(token)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      guard let self, self._catchUp.active, self._catchUp.token == token else { return }
      self._showCatchUpLoader()
    }
    // Never for ever: whatever it was waiting for, the terminal is back in charge after this.
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
      guard let self, self._catchUp.active, self._catchUp.token == token else { return }
      MoshLog.log("session", "loader timed out")
      self._endCatchUp()
    }
  }

  /// The terminal was just put on screen: if a catch-up is still waiting, ask the page again (a page
  /// that was hidden never ran the frames that would have answered).
  func moshroomRecheckCatchUp() {
    guard _catchUp.active else { return }
    if _catchUp.expectOutput {
      _termView.moshroomRecheckPainted(afterOutput: _catchUp.token)
    } else {
      _termView.moshroomNotifyPaintedNow(_catchUp.token)
    }
  }

  /// The session reached its local prompt, which draws nothing by design: that IS the screen. (Posted
  /// from the command queue with the session as its object; hopped to main here.)
  @objc func _moshroomSessionPromptReady(_ n: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self._catchUp.active, let session = self._session,
            (n.object as AnyObject?) === session else { return }
      self._termView.moshroomNotifyPaintedNow(self._catchUp.token)
    }
  }

  @objc func moshroomTermViewDidPaint(_ token: NSNumber) {
    guard _catchUp.active, token.intValue == _catchUp.token else { return }
    _endCatchUp()
  }

  /// TermView is reloading its page after WebKit killed the renderer.
  @objc func moshroomTermViewWillRebuild() {
    moshroomBeginCatchUp(expectOutput: true)
  }

  private func _showCatchUpLoader() {
    let loader = _catchUpLoader()
    let alreadyUp = _catchUp.shown
    _catchUp.shown = true
    _termView.bringSubviewToFront(loader)
    loader.show(caption: _catchUpCaption, onLight: _termView.backgroundColor?.isLight ?? false)
    if !alreadyUp {
      MoshLog.log("session", "loader shown")
    }
  }

  private func _endCatchUp() {
    let elapsed = Int(Date().timeIntervalSince(_catchUp.startedAt) * 1000)
    if _catchUp.shown {
      MoshLog.log("session", "screen drawing again after \(elapsed) ms")
    }
    _catchUp.active = false
    _catchUp.shown = false
    _catchUp.loader?.hide()
  }

  private func _catchUpLoader() -> MoshroomCatchUpView {
    if let loader = _catchUp.loader { return loader }
    let loader = MoshroomCatchUpView()
    loader.translatesAutoresizingMaskIntoConstraints = false
    _termView.addSubview(loader)
    NSLayoutConstraint.activate([
      loader.leadingAnchor.constraint(equalTo: _termView.leadingAnchor),
      loader.trailingAnchor.constraint(equalTo: _termView.trailingAnchor),
      loader.topAnchor.constraint(equalTo: _termView.topAnchor),
      loader.bottomAnchor.constraint(equalTo: _termView.bottomAnchor),
    ])
    _termView.moshroomOverlay = loader
    _catchUp.loader = loader
    return loader
  }

  // What the wait is for: the host the session is on, when there is one (a tab still being restored
  // does not know yet, so it goes by the host it was persisted on).
  private var _catchUpCaption: String {
    let knowsHost = moshroomHasLiveChildSession || meta.isSuspended
    let host = knowsHost ? (meta.connectedHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
    if !host.isEmpty { return "Resuming \(host)" }
    // A brand-new tab whose page has never been up is starting, not resuming.
    if !_termDevice.isReady && !meta.isSuspended { return "Starting terminal" }
    return "Resuming session"
  }
}

/// The catch-up loader's bookkeeping (see moshroomBeginCatchUp).
final class MoshroomCatchUp {
  var token = 0
  var active = false
  var expectOutput = false
  var shown = false
  var startedAt = Date()
  var loader: MoshroomCatchUpView?
}

/// The loader over a terminal that is not drawing yet: a mushroom-red arc turning on a faint ring,
/// and a line saying what it is waiting for. Touches pass through (the terminal stays usable), and it
/// fades in and out rather than popping.
final class MoshroomCatchUpView: UIView {
  private let spinner = UIView()
  private let ring = CAShapeLayer()
  private let arc = CAShapeLayer()
  private let caption = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isHidden = true
    alpha = 0
    isAccessibilityElement = true
    accessibilityTraits = .updatesFrequently

    spinner.translatesAutoresizingMaskIntoConstraints = false
    addSubview(spinner)
    for layer in [ring, arc] {
      layer.fillColor = UIColor.clear.cgColor
      layer.lineWidth = 3.5
      layer.lineCap = .round
      spinner.layer.addSublayer(layer)
    }
    ring.strokeColor = UIColor.white.withAlphaComponent(0.10).cgColor
    arc.strokeColor = UIColor.moshroomTint.cgColor
    arc.strokeEnd = 0.3

    caption.translatesAutoresizingMaskIntoConstraints = false
    caption.font = .systemFont(ofSize: 13, weight: .semibold)
    caption.textColor = UIColor.white.withAlphaComponent(0.7)
    caption.textAlignment = .center
    caption.lineBreakMode = .byTruncatingMiddle
    addSubview(caption)

    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -16),
      spinner.widthAnchor.constraint(equalToConstant: 40),
      spinner.heightAnchor.constraint(equalToConstant: 40),
      caption.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
      caption.centerXAnchor.constraint(equalTo: centerXAnchor),
      caption.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    let bounds = spinner.bounds
    let path = UIBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).cgPath
    // Standalone layers animate every property change: placed as they are, not slid into place.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for layer in [ring, arc] {
      layer.frame = bounds
      layer.path = path
    }
    CATransaction.commit()
  }

  /// `onLight`: the terminal's theme is light, so the ring and caption take dark ink.
  func show(caption text: String, onLight: Bool) {
    caption.text = text
    accessibilityLabel = text
    let ink: UIColor = onLight ? .black : .white
    caption.textColor = ink.withAlphaComponent(onLight ? 0.6 : 0.7)
    ring.strokeColor = ink.withAlphaComponent(0.10).cgColor
    isHidden = false
    _animate()
    UIView.animate(withDuration: 0.2) { self.alpha = 1 }
  }

  func hide() {
    guard !isHidden else { return }
    UIView.animate(withDuration: 0.25, animations: { self.alpha = 0 }) { _ in
      guard self.alpha == 0 else { return }
      self.isHidden = true
      self.arc.removeAllAnimations()
    }
  }

  // A steady turn, with the arc growing and shrinking as it goes: the classic indeterminate spinner.
  // Kept across trips to the background, and only added when missing, so a loader shown again never
  // jumps back to its starting angle.
  private func _animate() {
    guard arc.animation(forKey: "turn") == nil else { return }
    let turn = CABasicAnimation(keyPath: "transform.rotation.z")
    turn.fromValue = 0
    turn.toValue = 2 * Double.pi
    turn.duration = 0.9
    turn.repeatCount = .infinity
    turn.isRemovedOnCompletion = false
    arc.add(turn, forKey: "turn")
    let breathe = CABasicAnimation(keyPath: "strokeEnd")
    breathe.fromValue = 0.12
    breathe.toValue = 0.62
    breathe.duration = 0.9
    breathe.autoreverses = true
    breathe.repeatCount = .infinity
    breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    breathe.isRemovedOnCompletion = false
    arc.add(breathe, forKey: "breathe")
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

