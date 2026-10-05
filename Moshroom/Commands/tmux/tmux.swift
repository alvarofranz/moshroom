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


// The `tmux <host>` child session: SSH + tmux control mode, park, wake, kill.
//
// A tmux tab is a plain terminal tab whose local shell runs this child, exactly like mosh: MCPSession
// dispatches `tmux` natively and keeps the child marker ("tmux" + TmuxParams) for as long as the remote
// session is this tab's. Over one SSH exec channel it runs `tmux -u -C new-session -A -s <name>` and
// renders the pane's %output itself, so the terminal receives an ordinary byte stream: output banks in
// the local scrollback and scrolls locally, keys go back as `send-keys -H` (exact bytes), and the
// session lives on the host whatever happens to the app.
//
// Its life, in the order things happen:
// - CONNECT: the user's own `tmux <host>` (Quick Connect types it) is the only connect that may prompt
//   (unknown host key, password). Every other connect is the app's and is headless.
// - REFILL: tmux sends nothing about the past on attach, so each attach is followed by a resync
//   (TmuxResync): a full refill for an empty terminal, an overlap append for one that still shows
//   what it showed when the connection went away.
// - PARK: the app going to sleep (MCPSession.suspend) detaches the client cleanly and steps off the
//   network. MCPSession keeps the marker; waking runs a new child that re-attaches headless.
// - LOST: a dropped connection (heartbeat, network change, channel error) reconnects by itself with a
//   backoff, keys typed meanwhile are queued, and the refill catches the terminal up.
// - END: the session ending on the host (the shell exits) returns the tab to its local prompt. Closing
//   the tab kills the remote session.

import Combine
import Dispatch
import Foundation
import Network
import SSH
import ios_system

@objc public class MoshroomTmux: Session {
  private let mcpSession: MCPSession

  private enum Outcome {
    case parked
    case killed
    /// The session is over (the shell exited, or it no longer exists): back to the local prompt.
    case ended(String?)
    /// The connection went away; worth reconnecting.
    case lost(String)
    /// The host turned the connection down for a reason a retry cannot fix (authentication, host key).
    case refused(String)
    /// tmux is missing or too old: connect with plain SSH instead.
    case fallback(String)
  }

  private enum ResyncKind: Int, Comparable {
    case overlap = 0, full, fullKeepingScreen

    static func < (a: ResyncKind, b: ResyncKind) -> Bool { a.rawValue < b.rawValue }
  }

  // MARK: Session-thread state

  private var runLoop: CFRunLoop!
  private var gateway: TmuxGateway?
  private var outcome: Outcome?
  private var version = TmuxVersion(3, 2)
  private var sessionExisted = false
  private var preamble: [String] = []
  private var attached = false
  private var everAttached = false
  /// The first resync after an attach is done: pane output reaches the terminal.
  private var live = false
  private var resyncing = false
  private var pendingResync: ResyncKind?
  private var renderedPane: Int?
  private var keyQueue: [UInt8] = []
  private var modeTracker = TmuxModeTracker()
  private var titleFilter = TmuxTitleFilter()
  private var parking = false
  private var killing = false
  private var awaitingDevice = false
  private var sentSize: (Int, Int)?
  private var resizeDue: Date?
  private var foreignSize = false
  private var heartbeatSentAt: Date?
  private var heartbeatTimeout: TimeInterval = 10
  private var lastHeartbeatOK = Date()
  private var lastTick = Date()
  private var waitingForRetry = false
  private var retryNow = false
  private var splitNoted = false
  private var pendingCommandOnConnect: String?
  private var keyPump: DispatchInputStream?
  private var keyPumpCancellable: AnyCancellable?
  private var pathMonitor: NWPathMonitor?
  /// This child runs a typed `tmux <host>` (not a wake, not a relaunch) and has not painted yet.
  private var freshCommand = false
  /// Counts connections, so callbacks from one that is gone are recognised and ignored.
  private var connection = 0

  // MARK: Cross-thread state (under `lock`)

  private let lock = NSLock()
  private var isRunning = false
  private var killRequested = false
  private var parkRequested = false
  private var reconnectRequested = false
  private var repaintRequested = false
  private let parkAnswered = DispatchSemaphore(value: 0)

  /// The child detached because the app went to sleep: the session is still there, MCPSession keeps
  /// the marker and a later child re-attaches. Read once the child's thread has been joined.
  @objc private(set) var moshroomParked = false
  /// tmux cannot be used on the host (missing, too old): the command MCPSession runs instead.
  @objc private(set) var moshroomFallbackCommand: String?

  private var params: TmuxParams {
    // swiftlint:disable:next force_cast
    sessionParams as! TmuxParams
  }

  private static let historyLines = 1000
  private static let keyChunk = 300
  private static let keyQueueCap = 64 * 1024
  private static let backoff: [TimeInterval] = [0.5, 1, 2, 4, 8, 15]

  @objc init!(mcpSession: MCPSession, device: TermDevice!, andParams params: TmuxParams!) {
    self.mcpSession = mcpSession
    super.init(device: device, andParams: params)
  }

  // MARK: - Main

  @objc public override func main(_ argc: Int32, argv: Argv) -> Int32 {
    mcpSession.setActiveSession()
    runLoop = CFRunLoopGetCurrent()

    let p = params
    let resuming = !(p.sessionName ?? "").isEmpty
    if !resuming {
      let args = Array(argv.args(count: argc).dropFirst())
      guard args.count == 1, let alias = args.first, !alias.hasPrefix("-"), !alias.isEmpty else {
        _say("usage: tmux <host>")
        _say("Opens a tmux session on a saved host over SSH. It survives the app closing, and comes back with its history.")
        return -1
      }
      p.hostAlias = alias
      p.sessionName = "moshroom-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
      pendingCommandOnConnect = Self._commandOnConnect(for: alias)
      // The tab's archive must know about the session from now on: a relaunch after a crash finds it.
      mcpSession.moshroomCheckpointDidChange()
    }
    guard let host = p.hostAlias, !host.isEmpty else { return -1 }
    modeTracker = TmuxModeTracker(TmuxTrackedModes(bracketedPaste: p.bracketedPaste, mouseAnyMotion: p.mouseAnyMotion))

    // Keeps the run loop alive between events and drives the heartbeat and the resize debounce.
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      self?._tick()
    }
    RunLoop.current.add(timer, forMode: .default)
    let originalRawMode = device.rawMode
    _startKeyPump()
    _startPathMonitor()
    lock.lock()
    isRunning = true
    lock.unlock()
    defer {
      lock.lock()
      isRunning = false
      lock.unlock()
      timer.invalidate()
      _stopKeyPump()
      pathMonitor?.cancel()
      pathMonitor = nil
      _setReconnecting(false)
      device.rawMode = originalRawMode
      // Whoever is waiting for this child to park is answered whatever happened.
      parkAnswered.signal()
    }

    if !resuming {
      freshCommand = true
      _say("Connecting to \(host)...")
    }

    var interactive = !resuming
    var failures = 0
    while true {
      if _killRequested {
        return 0
      }
      if _parkRequested || (mcpSession.moshroomSuspended && !interactive) {
        _park()
        return 0
      }

      let result = _connectOnce(host: host, interactive: interactive)
      interactive = false

      if !everAttached && !resuming {
        switch result {
        case .refused(let message), .lost(let message):
          // The user's own connect did not work: say why and give the prompt back.
          _say("Connection failed - \(message)")
          return -1
        default:
          break
        }
      }

      switch result {
      case .parked:
        _park()
        return 0
      case .killed:
        return 0
      case .ended(let message):
        _setReconnecting(false)
        if let message { _say(message) }
        return 0
      case .fallback(let message):
        _say(message)
        moshroomFallbackCommand = "ssh \(host)"
        return 0
      case .refused(let message):
        _setReconnecting(false)
        _say("\u{1b}[2mCouldn't reconnect to \(host): \(message)\u{1b}[0m")
        _say("\u{1b}[2mTap the tab name to try again.\u{1b}[0m")
        if !_waitForRetry() { return 0 }
        failures = 0
      case .lost(let message):
        if _skipBackoff {
          // The user asked for this reconnect: right away, and the count starts over.
          _skipBackoff = false
          failures = 0
          continue
        }
        failures += 1
        if failures > Self.backoff.count {
          _setReconnecting(false)
          MoshLog.log("tmux", "giving up after \(failures - 1) tries: \(message)")
          _say("\u{1b}[2mCouldn't reach \(host). Tap the tab name to retry.\u{1b}[0m")
          if !_waitForRetry() { return 0 }
          failures = 0
          continue
        }
        _setReconnecting(true)
        if !_wait(Self.backoff[failures - 1]) {
          continue
        }
      }
    }
  }

  /// The host's "Command on connect", unless it starts a session manager of its own. Such a command
  /// is there for mosh (`tmux new -A -s main` and friends): typed inside this tmux session it would
  /// nest, or grab and detach a session the user keeps for other clients.
  private static func _commandOnConnect(for alias: String) -> String? {
    guard let command = MoshHosts.withHost(alias)?.commandOnConnect?
      .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return nil }
    let first = command.split(whereSeparator: { " \t;&|".contains($0) }).first.map(String.init) ?? ""
    let program = (first as NSString).lastPathComponent
    if ["tmux", "screen", "byobu", "zellij", "abduco", "dtach"].contains(program) {
      return nil
    }
    return command
  }

  // MARK: - One connection

  private func _connectOnce(host: String, interactive: Bool) -> Outcome {
    outcome = nil
    attached = false
    live = false
    resyncing = false
    pendingResync = nil
    preamble = []
    sessionExisted = false
    sentSize = nil
    heartbeatSentAt = nil
    heartbeatTimeout = 10
    lastHeartbeatOK = Date()
    parking = false
    retryNow = false

    let target: (hostName: String, host: MoshSSHHost, config: SSHClientConfig)
    do {
      // Only the user's own connect may ask anything (a password, an unknown host key).
      target = try MoshroomSSH.resolveTarget(hostAlias: host, device: interactive ? device : nil)
    } catch {
      return .refused(Self._describe(error))
    }

    let p = params
    let name = p.sessionName ?? ""
    // Attach only to the session this tab created (an exact name, never a prefix match); before it
    // exists the same name creates it.
    let tmuxCommand = p.everAttached ? "attach-session -t =\(name)" : "new-session -A -s \(name)"
    let script = [
      "command -v tmux >/dev/null 2>&1 || PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin:/snap/bin\"",
      "command -v tmux >/dev/null 2>&1 || { echo MOSHROOM_TMUX_MISSING; exit 127; }",
      "v=\"$(tmux -V 2>/dev/null)\"",
      "echo \"MOSHROOM_TMUX_VERSION $v\"",
      "case \"$v\" in \"tmux 0.\"*|\"tmux 1.\"*|\"tmux 2.\"*) echo MOSHROOM_TMUX_OLD; exit 126;; esac",
      "tmux has-session -t =\(name) 2>/dev/null && echo MOSHROOM_TMUX_EXISTS",
      "exec tmux -u -C \(tmuxCommand) 2>&1",
    ].joined(separator: "; ")
    let command = "exec sh -c '\(script)'"

    let gw = TmuxGateway()
    gateway = gw
    connection += 1
    let thisConnection = connection
    gw.onEvent = { [weak self] event in
      guard let self, self.connection == thisConnection else { return }
      self._handle(event)
    }
    gw.onClosed = { [weak self] error in
      // A previous connection's late goodbye must not end this one.
      guard let self, self.connection == thisConnection else { return }
      self._closed(error)
    }
    gw.connect(hostName: target.hostName,
               config: target.config,
               command: command,
               proxy: { [weak self] command, sockIn, sockOut in
                 self?.mcpSession.setActiveSession()
                 MoshroomSSH.executeProxyCommand(command: command, sockIn: sockIn, sockOut: sockOut)
               },
               attached: { [weak self] reply in
                 self?._attached(reply)
               })

    // A park or a kill asked while nothing was running yet is picked up by the first tick.
    while outcome == nil {
      CFRunLoopRunInMode(.defaultMode, 0.5, false)
    }
    gateway = nil
    gw.close()
    // Let the gateway release its SSH objects before anything else starts.
    CFRunLoopRunInMode(.defaultMode, 0, true)
    attached = false
    live = false
    return outcome ?? .lost("closed")
  }

  private func _finish(_ result: Outcome) {
    if outcome == nil {
      outcome = result
    }
  }

  private func _attached(_ reply: TmuxReply) {
    if reply.skipped {
      // The connection went away before tmux answered (see _closed).
      return
    }
    if reply.isError {
      _finish(_classifyEarlyFailure(reply.text))
      return
    }
    attached = true
    let firstAttach = !everAttached
    everAttached = true
    let p = params
    let wasEverAttached = p.everAttached
    p.everAttached = true
    p.version = "\(version.major).\(version.minor)"
    if !wasEverAttached {
      mcpSession.moshroomCheckpointDidChange()
    }
    // From here every key goes to tmux.
    device.rawMode = true
    lastHeartbeatOK = Date()
    // A brand-new session gets the host's "Command on connect" once it is painted; an existing one
    // (a re-attach) never does.
    if !(firstAttach && !wasEverAttached && !sessionExisted) {
      pendingCommandOnConnect = nil
    }
    awaitingDevice = true
    _proceedWhenDeviceReady()
  }

  // The terminal's size is what the pane is set to, so nothing is asked of tmux until the page knows
  // its size (a relaunched tab connects while its page is still loading).
  private func _proceedWhenDeviceReady() {
    guard awaitingDevice, attached, outcome == nil else { return }
    guard device.cols > 0 && device.rows > 0 && device.isReady else { return }
    awaitingDevice = false
    if _takeRepaintRequest() {
      params.viewHoldsSession = false
    }
    let kind: ResyncKind
    if params.viewHoldsSession {
      // The terminal still shows the session as it was: only what it missed.
      kind = .overlap
    } else if freshCommand {
      // A fresh connect keeps the local transcript (pushed up into the scrollback).
      kind = .fullKeepingScreen
    } else {
      // A rebuilt or relaunched page has nothing to keep.
      kind = .full
    }
    _sendSize(force: true) { [weak self] in
      guard let self else { return }
      if self.version.hasFlowControl {
        // tmux discards a pane's queued output (and says %pause) rather than let it pile up for more
        // than this many seconds; the resync after %continue repaints what was dropped.
        self.gateway?.send("refresh-client -f pause-after=10")
      }
      self._resync(kind)
    }
  }

  private func _classifyEarlyFailure(_ text: String) -> Outcome {
    let lower = text.lowercased()
    if lower.contains("can't find session") || lower.contains("no server running") || lower.contains("no sessions") {
      let host = params.hostAlias ?? "the host"
      return .ended("\u{1b}[2mThe tmux session on \(host) has ended.\u{1b}[0m")
    }
    return .lost(text.isEmpty ? "tmux did not start" : text)
  }

  private func _closed(_ error: Error?) {
    guard outcome == nil else { return }
    if parking {
      _finish(.parked)
      return
    }
    if killing {
      _finish(.killed)
      return
    }
    if !attached {
      if let error, Self._isDefinitive(error) {
        _finish(.refused(Self._describe(error)))
        return
      }
      let text = preamble.joined(separator: "\n")
      if !text.isEmpty {
        _finish(_classifyEarlyFailure(text))
        return
      }
      _finish(.lost(error.map(Self._describe) ?? "The connection closed before tmux started."))
      return
    }
    _finish(.lost(error.map(Self._describe) ?? "The connection closed."))
  }

  // MARK: - Events

  private func _handle(_ event: TmuxEvent) {
    switch event {
    case .output(let pane, let bytes):
      guard live, !resyncing, pane == renderedPane else { return }
      let bytes = titleFilter.filter(bytes)
      let before = modeTracker.modes
      modeTracker.scan(bytes)
      if modeTracker.modes != before {
        params.bracketedPaste = modeTracker.modes.bracketedPaste
        params.mouseAnyMotion = modeTracker.modes.mouseAnyMotion
      }
      _write(bytes)
    case .pause(let pane):
      // tmux dropped this pane's output that was waiting too long (a slow link): let it flow again
      // and paint what was dropped.
      gateway?.send("refresh-client -A '%\(pane):continue'")
      if pane == renderedPane {
        _resync(.overlap)
      }
    case .exit(let reason):
      if parking {
        _finish(.parked)
      } else if killing {
        _finish(.killed)
      } else if let reason, reason.contains("too far behind") {
        _finish(.lost(reason))
      } else {
        // Unasked: the session is over (its last window closed) or someone else detached this client.
        _finish(.ended(nil))
      }
    case .layoutChange(_, let width, let height):
      if let sent = sentSize, width > 0, height > 0, (width, height) != sent {
        // Another client holds the window at its own size: claim it back on the next key.
        foreignSize = true
      } else {
        foreignSize = false
      }
    case .windowPaneChanged, .sessionWindowChanged:
      if live {
        _resync(.fullKeepingScreen)
      }
    case .sessionChanged(_, let name):
      if attached, let ours = params.sessionName, name != ours {
        // This client was moved to another session: it is not this tab's any more.
        gateway?.send("detach-client")
        _finish(.ended("\u{1b}[2mDetached: the client was switched to another tmux session.\u{1b}[0m"))
      }
    case .text(let line):
      _preambleLine(line)
    case .reply, .resume, .windowAdd, .windowClose, .paneModeChanged, .notification:
      break
    }
  }

  private func _preambleLine(_ line: String) {
    if line.hasPrefix("MOSHROOM_TMUX_VERSION") {
      let text = String(line.dropFirst("MOSHROOM_TMUX_VERSION".count))
      if let v = TmuxVersion(text) {
        version = v
      }
      return
    }
    let host = params.hostAlias ?? "the host"
    switch line {
    case "MOSHROOM_TMUX_MISSING":
      _finish(.fallback("tmux isn't installed on \(host), connecting with plain SSH (install tmux to keep sessions alive)."))
    case "MOSHROOM_TMUX_OLD":
      _finish(.fallback("tmux on \(host) is too old (3.0 or newer is needed), connecting with plain SSH."))
    case "MOSHROOM_TMUX_EXISTS":
      sessionExisted = true
    default:
      if !attached && !line.isEmpty {
        preamble.append(line)
      }
    }
  }

  // MARK: - Resync

  private func _resync(_ kind: ResyncKind) {
    guard let gw = gateway, attached, outcome == nil else { return }
    if resyncing {
      pendingResync = max(pendingResync ?? kind, kind)
      return
    }
    resyncing = true
    if kind == .overlap {
      _readLocalTail { [weak self] tail in
        self?._sendFence(kind, tail: tail)
      }
    } else {
      _sendFence(kind, tail: nil)
    }
    _ = gw
  }

  private func _sendFence(_ kind: ResyncKind, tail: TmuxLocalTail?) {
    guard let gw = gateway, attached, outcome == nil else {
      resyncing = false
      return
    }
    // No usable tail (the page could not say): only a full refill can be trusted.
    let overlap = kind == .overlap && tail != nil
    let commands = TmuxResync.fence(historyLines: Self.historyLines, overlap: overlap, version: version)
    var replies: [TmuxReply] = []
    gw.send(commands.map { command in
      (command, { [weak self] reply in
        replies.append(reply)
        if replies.count == commands.count {
          self?._applyFence(replies, kind: kind, overlapFence: overlap, tail: tail)
        }
      })
    })
  }

  private func _applyFence(_ replies: [TmuxReply], kind: ResyncKind, overlapFence: Bool, tail: TmuxLocalTail?) {
    defer {
      resyncing = false
      if outcome == nil, let next = pendingResync {
        pendingResync = nil
        _resync(next)
      }
    }
    guard outcome == nil else { return }
    guard let snap = TmuxResync.snapshot(from: replies, overlap: overlapFence) else {
      if replies.contains(where: { $0.skipped }) {
        // The connection went away under it: the reconnect resyncs again.
        return
      }
      MoshLog.log("tmux", "resync answer unreadable")
      live = true
      _flushKeys()
      return
    }

    let p = params
    let rows = device.rows > 0 ? device.rows : snap.state.height
    let modes = modeTracker.modes
    let bytes: [UInt8]
    switch kind {
    case .full:
      bytes = TmuxResync.fullRefill(snap, rows: rows, modes: modes, marker: nil)
    case .fullKeepingScreen:
      bytes = TmuxResync.fullRefill(snap, rows: rows, modes: modes, marker: "")
    case .overlap:
      bytes = _overlapBytes(snap, tail: overlapFence ? tail : nil, rows: rows, modes: modes)
    }
    freshCommand = false
    _write(bytes)

    if renderedPane != snap.state.paneId, let old = renderedPane, version.hasFlowControl {
      // A pane we no longer show stops sending.
      gateway?.send("refresh-client -A '%\(old):off'")
      gateway?.send("refresh-client -A '%\(snap.state.paneId):on'")
    }
    renderedPane = snap.state.paneId
    let changed = p.sessionCreated != snap.state.sessionCreated || p.lastCols != snap.state.width || p.paneId != snap.state.paneId
    p.sessionCreated = snap.state.sessionCreated
    p.paneId = snap.state.paneId
    p.lastCols = snap.state.width
    p.lastHistorySize = snap.state.historySize
    p.viewHoldsSession = true
    if changed {
      mcpSession.moshroomCheckpointDidChange()
    }
    if snap.state.inMode {
      // Copy mode entered from another client would catch the first keys typed here.
      gateway?.send("send-keys -t %\(snap.state.paneId) -X cancel")
    }
    if snap.state.windowPanes > 1 {
      _quietOtherPanes(active: snap.state.paneId)
    }
    let wasLive = live
    live = true
    _setReconnecting(false)
    _flushKeys()
    if !wasLive, let onConnect = pendingCommandOnConnect, !onConnect.isEmpty {
      pendingCommandOnConnect = nil
      _sendKeys(Array((onConnect + "\r").utf8))
    }
    pendingCommandOnConnect = nil
  }

  private func _overlapBytes(_ snap: TmuxSnapshot, tail: TmuxLocalTail?, rows: Int, modes: TmuxTrackedModes) -> [UInt8] {
    let p = params
    if let created = p.sessionCreated, !created.isEmpty, created != snap.state.sessionCreated {
      return TmuxResync.fullRefill(snap, rows: rows, modes: modes, marker: "\u{2500}\u{2500} new session \u{2500}\u{2500}")
    }
    let reconnected = "\u{2500}\u{2500} reconnected \u{2500}\u{2500}"
    guard let tail else {
      return TmuxResync.fullRefill(snap, rows: rows, modes: modes, marker: reconnected)
    }
    if !tail.primary {
      // The terminal is on its alternate screen: a full-screen program, which banks no history.
      if snap.state.alternateOn {
        return TmuxResync.alternateRepaint(snap, rows: rows, modes: modes)
      }
      return TmuxResync.fullRefill(snap, rows: rows, modes: modes, marker: reconnected, leaveAlternate: true)
    }
    if p.lastCols > 0, p.lastCols != snap.state.width {
      // tmux reflowed its history to another width: lines no longer compare.
      return TmuxResync.fullRefill(snap, rows: rows, modes: modes, marker: reconnected)
    }
    if snap.history.isEmpty {
      // Nothing has scrolled off on the host: the screen is all there is to paint.
      return TmuxResync.overlapAppend(snap, newFrom: 0, rows: rows, modes: modes)
    }
    if let start = TmuxResync.newHistoryStart(localTail: tail.lines, remotePlain: snap.plainHistory ?? []) {
      return TmuxResync.overlapAppend(snap, newFrom: start, rows: rows, modes: modes)
    }
    if p.lastHistorySize == 0 {
      // The host had no history at the last paint, so this terminal's scrollback holds only what came
      // before the session (the connect line): everything the host banked since is new here.
      return TmuxResync.overlapAppend(snap, newFrom: 0, rows: rows, modes: modes)
    }
    return TmuxResync.fullRefill(snap, rows: rows, modes: modes, marker: reconnected)
  }

  private func _quietOtherPanes(active: Int) {
    guard let gw = gateway else { return }
    gw.send("list-panes -F '#{pane_id}'") { [weak self] reply in
      guard let self, !reply.isError else { return }
      let others = reply.text.split(separator: "\n").compactMap { TmuxControlParser._paneNumber(String($0)) }.filter { $0 != active }
      if self.version.hasFlowControl {
        for pane in others {
          self.gateway?.send("refresh-client -A '%\(pane):off'")
        }
      }
      if !self.splitNoted && !others.isEmpty {
        self.splitNoted = true
        MoshLog.log("tmux", "window has \(others.count + 1) panes, showing the active one")
      }
    }
  }

  /// The last lines the terminal banked in its scrollback, read from the page (term.js). Nil when the
  /// page cannot say (not ready, an older page without the reader).
  private func _readLocalTail(_ done: @escaping (TmuxLocalTail?) -> Void) {
    let loop = runLoop!
    // Answered once: by the page, or by the timeout (a page whose renderer died never answers).
    var answered = false
    let finish: (TmuxLocalTail?) -> Void = { tail in
      guard !answered else { return }
      answered = true
      done(tail)
    }
    _after(2.0) {
      finish(nil)
    }
    let deliver: (TmuxLocalTail?) -> Void = { tail in
      CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
        finish(tail)
      }
      CFRunLoopWakeUp(loop)
    }
    let device = self.device
    DispatchQueue.main.async {
      guard let webView = device?.view?.webView, device?.view?.isReady == true else {
        deliver(nil)
        return
      }
      webView.evaluateJavaScript("term_moshroomScrollbackTail(8)") { result, _ in
        guard let json = result as? String,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let primary = object["primary"] as? Bool,
              let lines = object["lines"] as? [String] else {
          deliver(nil)
          return
        }
        deliver(TmuxLocalTail(primary: primary, lines: lines))
      }
    }
  }

  // MARK: - Size

  private func _sendSize(force: Bool, then: (() -> Void)? = nil) {
    guard let gw = gateway, attached else {
      then?()
      return
    }
    let cols = device.cols > 0 ? device.cols : 80
    let rows = device.rows > 0 ? device.rows : 24
    if !force, let sent = sentSize, sent == (cols, rows), !foreignSize {
      then?()
      return
    }
    sentSize = (cols, rows)
    foreignSize = false
    gw.send("refresh-client -C \(cols)x\(rows)") { _ in
      then?()
    }
  }

  // MARK: - Keys

  private func _startKeyPump() {
    guard let input = stream.in else { return }
    let fd = dup(fileno(input))
    guard fd >= 0 else { return }
    let pump = DispatchInputStream(stream: fd, closesDescriptor: true)
    keyPump = pump
    let loop = runLoop!
    keyPumpCancellable = pump.writeTo(TmuxKeysWriter { [weak self] bytes in
      CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
        self?._keys(bytes)
      }
      CFRunLoopWakeUp(loop)
    })
    .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
  }

  private func _stopKeyPump() {
    keyPumpCancellable = nil
    keyPump?.close()
    keyPump = nil
  }

  private func _keys(_ bytes: [UInt8]) {
    if waitingForRetry {
      // Any key is "try again" (Ctrl-C / Ctrl-D give up instead), and is not typed anywhere.
      if bytes.contains(0x03) || bytes.contains(0x04) {
        _giveUp = true
      }
      retryNow = true
      return
    }
    guard live, !resyncing, gateway != nil, outcome == nil else {
      keyQueue += bytes
      if keyQueue.count > Self.keyQueueCap {
        keyQueue.removeFirst(keyQueue.count - Self.keyQueueCap)
      }
      return
    }
    _sendKeys(bytes)
  }

  private var _giveUp = false

  private func _flushKeys() {
    guard !keyQueue.isEmpty else { return }
    let queued = keyQueue
    keyQueue = []
    _sendKeys(queued)
  }

  private func _sendKeys(_ bytes: [UInt8]) {
    guard let gw = gateway, let pane = renderedPane, !bytes.isEmpty else {
      keyQueue += bytes
      return
    }
    if foreignSize {
      _sendSize(force: true)
    }
    // One literal byte per argument: tmux writes exactly these bytes to the pane (UTF-8, mouse
    // reports and paste markers included), with no key-name lookup in between.
    var i = 0
    while i < bytes.count {
      let end = min(i + Self.keyChunk, bytes.count)
      var command = "send-keys -t %\(pane) -H"
      command.reserveCapacity(24 + (end - i) * 3)
      for b in bytes[i..<end] {
        command += b < 16 ? " 0" + String(b, radix: 16) : " " + String(b, radix: 16)
      }
      gw.send(command)
      i = end
    }
  }

  // MARK: - Heartbeat, network

  private func _tick() {
    let now = Date()
    // A long gap means this thread was busy (a big refill) or the app was frozen: the clock that
    // decides "no answer" restarts instead of blaming the connection for it.
    if now.timeIntervalSince(lastTick) > 3, heartbeatSentAt != nil {
      heartbeatSentAt = now
    }
    lastTick = now

    if _killRequested && !killing {
      _beginKill()
    }
    if _parkRequested && !parking && outcome == nil {
      _beginPark()
    }
    // While connected the tick answers a reconnect request; between connections the waits do.
    if gateway != nil, outcome == nil, _takeReconnectRequest() {
      _skipBackoff = true
      _finish(.lost("reconnect"))
    }
    if _peekRepaintRequest(), live, outcome == nil, !awaitingDevice {
      _ = _takeRepaintRequest()
      params.viewHoldsSession = false
      _resync(.full)
    }
    if awaitingDevice {
      _proceedWhenDeviceReady()
    }

    guard attached, outcome == nil, let gw = gateway else { return }
    if let sent = heartbeatSentAt {
      if now.timeIntervalSince(sent) > heartbeatTimeout {
        MoshLog.log("tmux", "heartbeat unanswered after \(Int(heartbeatTimeout)) s")
        _finish(.lost("The connection stopped answering."))
      }
    } else if now.timeIntervalSince(lastHeartbeatOK) > 15 {
      heartbeatSentAt = now
      gw.send("display -p 1") { [weak self] reply in
        guard let self, !reply.skipped else { return }
        self.heartbeatSentAt = nil
        self.heartbeatTimeout = 10
        self.lastHeartbeatOK = Date()
      }
    }
    if let due = resizeDue, now >= due {
      resizeDue = nil
      if live {
        _sendSize(force: false)
      }
    }
  }

  private var _skipBackoff = false

  private func _startPathMonitor() {
    let monitor = NWPathMonitor()
    var first = true
    let loop = runLoop!
    monitor.pathUpdateHandler = { [weak self] _ in
      if first {
        first = false
        return
      }
      CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
        // The network changed under the connection (Wi-Fi to cellular, a VPN): ask right away, with a
        // short timeout, instead of waiting for the next heartbeat.
        guard let self, self.attached, self.outcome == nil else { return }
        self.heartbeatTimeout = 5
        self.lastHeartbeatOK = .distantPast
        self.heartbeatSentAt = nil
      }
      CFRunLoopWakeUp(loop)
    }
    monitor.start(queue: DispatchQueue(label: "moshroom.tmux.path"))
    pathMonitor = monitor
  }

  // MARK: - Waiting

  /// Runs the loop for `seconds`. False when something asked to stop waiting (park, kill, retry).
  private func _wait(_ seconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if _killRequested || _parkRequested || mcpSession.moshroomSuspended { return false }
      if _skipBackoff || _takeReconnectRequest() {
        _skipBackoff = false
        return true
      }
      CFRunLoopRunInMode(.defaultMode, min(0.25, max(0.01, deadline.timeIntervalSinceNow)), false)
    }
    return true
  }

  /// After giving up: wait for a reason to try again (a key, a tap on the tab name, the app coming
  /// back). False when the child should stop instead (closed, parked, or the user gave up).
  private func _waitForRetry() -> Bool {
    waitingForRetry = true
    retryNow = false
    _giveUp = false
    defer { waitingForRetry = false }
    while !retryNow {
      if _killRequested { return false }
      if _parkRequested || mcpSession.moshroomSuspended {
        _park()
        return false
      }
      if _takeReconnectRequest() { break }
      CFRunLoopRunInMode(.defaultMode, 0.25, false)
    }
    if _giveUp {
      let host = params.hostAlias ?? "the host"
      _say("\u{1b}[2mLeft the tmux session on \(host) running.\u{1b}[0m")
      return false
    }
    return true
  }

  // MARK: - Park, kill, let go

  private func _beginPark() {
    parking = true
    guard let gw = gateway, attached else {
      _finish(.parked)
      return
    }
    // Detach cleanly: a client that just vanishes keeps pinning the window size and collecting output
    // on the host until tmux gives up on it.
    gw.send("detach-client")
    _after(1.0) { [weak self] in
      self?._finish(.parked)
    }
  }

  private func _park() {
    let p = params
    p.bracketedPaste = modeTracker.modes.bracketedPaste
    p.mouseAnyMotion = modeTracker.modes.mouseAnyMotion
    lock.lock()
    moshroomParked = true
    lock.unlock()
    mcpSession.moshroomCheckpointDidChange()
    parkAnswered.signal()
  }

  private func _beginKill() {
    killing = true
    let name = params.sessionName ?? ""
    guard let gw = gateway, attached, !name.isEmpty else {
      _finish(.killed)
      // Between connections: the session is still on the host, close it from a connection of its own.
      if let host = params.hostAlias, !name.isEmpty, params.everAttached {
        Self.killRemoteSession(hostAlias: host, sessionName: name)
      }
      return
    }
    gw.send("kill-session -t =\(name)") { [weak self] _ in
      self?._finish(.killed)
    }
    _after(1.5) { [weak self] in
      self?._finish(.killed)
    }
  }

  private func _after(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
    let timer = Timer(timeInterval: seconds, repeats: false) { _ in block() }
    RunLoop.current.add(timer, forMode: .default)
  }

  private func _wake() {
    guard let loop = runLoop else { return }
    CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {}
    CFRunLoopWakeUp(loop)
  }

  /// The tab is closing: kill the remote session (it is this tab's alone) and stop.
  @objc public override func kill() {
    lock.lock()
    killRequested = true
    let running = isRunning
    lock.unlock()
    if running {
      _wake()
    }
  }

  /// The app is going to sleep: detach and step off the network. Blocks for at most two seconds.
  @objc public override func suspend() {
    lock.lock()
    guard isRunning, !moshroomParked, !killRequested else {
      lock.unlock()
      return
    }
    parkRequested = true
    lock.unlock()
    _wake()
    _ = parkAnswered.wait(timeout: .now() + 2)
  }

  /// The user asked to reconnect (the tab pill): drop whatever connection there is and attach again
  /// now, to the same session.
  @objc func moshroomReconnectNow() {
    lock.lock()
    reconnectRequested = true
    lock.unlock()
    _wake()
  }

  /// The terminal page was rebuilt and shows nothing: paint everything again.
  @objc func moshroomRepaintRebuiltView() -> Bool {
    lock.lock()
    repaintRequested = true
    let running = isRunning
    lock.unlock()
    if running {
      _wake()
    }
    return true
  }

  /// A rebuilt page would be painted by this child (it is attached and showing the pane).
  @objc var moshroomCanRepaint: Bool {
    lock.lock()
    defer { lock.unlock() }
    return isRunning && !moshroomParked && !killRequested
  }

  @objc public override func sigwinch() {
    guard let loop = runLoop else { return }
    CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
      // Coalesced: a window being dragged sends a burst of these.
      self?.resizeDue = Date().addingTimeInterval(0.05)
    }
    CFRunLoopWakeUp(loop)
  }

  @objc public override func handleControl(_ control: String!) {
  }

  private var _killRequested: Bool {
    lock.lock(); defer { lock.unlock() }
    return killRequested
  }

  private var _parkRequested: Bool {
    lock.lock(); defer { lock.unlock() }
    return parkRequested
  }

  private func _takeReconnectRequest() -> Bool {
    lock.lock(); defer { lock.unlock() }
    let asked = reconnectRequested
    reconnectRequested = false
    return asked
  }

  private func _peekRepaintRequest() -> Bool {
    lock.lock(); defer { lock.unlock() }
    return repaintRequested
  }

  private func _takeRepaintRequest() -> Bool {
    lock.lock(); defer { lock.unlock() }
    let asked = repaintRequested
    repaintRequested = false
    return asked
  }

  // MARK: - Output

  private func _write(_ bytes: [UInt8]) {
    guard !bytes.isEmpty, !_killRequested, let out = stream.out else { return }
    bytes.withUnsafeBufferPointer { buf in
      _ = fwrite(buf.baseAddress, 1, buf.count, out)
    }
  }

  private func _say(_ text: String) {
    _write(Array((text + "\r\n").utf8))
  }

  private func _setReconnecting(_ on: Bool) {
    guard on != _reconnectingShown else { return }
    _reconnectingShown = on
    let host = params.hostAlias ?? ""
    let mcp = mcpSession
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .moshroomTmuxReconnecting, object: mcp,
                                      userInfo: ["reconnecting": on, "host": host])
    }
  }

  private var _reconnectingShown = false

  private static func _isDefinitive(_ error: Error) -> Bool {
    if let ssh = error as? SSHError {
      switch ssh {
      case .authFailed, .authError: return true
      default: return false
      }
    }
    return error is CommandError
  }

  static func _describe(_ error: Error) -> String {
    if let ssh = error as? SSHError {
      return ssh.description
    }
    return error.localizedDescription
  }

  // MARK: - Closing a parked tab

  /// Kill a tab's remote session when no child is attached to it (the tab was parked, or between
  /// reconnects). Best effort and headless: a host that cannot be reached keeps its session.
  @objc static func killRemoteSession(hostAlias: String, sessionName: String) {
    let thread = Thread {
      guard let target = try? MoshroomSSH.resolveTarget(hostAlias: hostAlias, device: nil) else { return }
      var done = false
      var stream: SSH.Stream? = nil
      var cancellable: AnyCancellable? = SSHClient.dial(target.hostName, with: target.config, withProxy: MoshroomSSH.executeProxyCommand)
        .flatMap { $0.requestExec(command: "tmux kill-session -t =\(sessionName) 2>/dev/null; true") }
        .flatMap { s -> AnyPublisher<DispatchData, Error> in
          stream = s
          return s.read(max: 4096)
        }
        .sink(receiveCompletion: { _ in done = true }, receiveValue: { _ in })
      let timer = Timer(timeInterval: 0.25, repeats: true) { _ in }
      RunLoop.current.add(timer, forMode: .default)
      let deadline = Date().addingTimeInterval(15)
      while !done && Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.25, false)
      }
      timer.invalidate()
      cancellable = nil
      stream = nil
      _ = cancellable
      _ = stream
      MoshLog.log("tmux", done ? "closed a parked session" : "could not reach the host to close a parked session")
    }
    thread.start()
  }
}

/// What the page reported about its own scrollback (term_moshroomScrollbackTail).
struct TmuxLocalTail {
  /// The page is on its primary screen (the only one that banks history).
  let primary: Bool
  /// The last lines it scrolled off, oldest first, trailing blanks trimmed.
  let lines: [String]
}

extension Notification.Name {
  /// A tmux tab lost its connection and is reconnecting (userInfo "reconnecting": Bool, "host":
  /// String), object = the tab's MCPSession. Posted on the main queue.
  static let moshroomTmuxReconnecting = Notification.Name("MoshroomTmuxReconnectingNotification")
}

/// The terminal's keys as they arrive on the child's stdin.
private final class TmuxKeysWriter: Writer {
  private let onBytes: ([UInt8]) -> Void

  init(_ onBytes: @escaping ([UInt8]) -> Void) {
    self.onBytes = onBytes
  }

  func write(_ buf: DispatchData, max length: Int) -> AnyPublisher<Int, Error> {
    onBytes([UInt8](buf))
    return Just(length).setFailureType(to: Error.self).eraseToAnyPublisher()
  }
}
