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


// Model-based terminal selection: native controller, handles and the copy pill.
//
// The page keeps the selection on hterm's row model and paints the highlight (see "Selection" in
// term.js). This side owns everything the user touches: which gesture starts or moves a selection,
// the two handles and the copy pill on iOS, the right-click menu on the Mac, auto-scroll at the
// edges, haptics and the clipboard. It is renderer-independent on purpose: all it ever sees is
// web-view points and absolute row numbers, in the geometry every page call returns.

import UIKit
import WebKit

/// The selection as the page reports it, in web-view points.
struct TerminalSelectionGeometry {
  enum State: String {
    case none, active, clip
  }

  struct Endpoint {
    var x: CGFloat
    var y: CGFloat
    var h: CGFloat
    var row: Int
    var visible: Bool
  }

  var seq = 0
  var state = State.none
  var mode = "linear"
  var gran = "char"
  var rows = 0
  var start: Endpoint? = nil
  var end: Endpoint? = nil
  var bounds: CGRect? = nil
  var view: CGRect? = nil
  var swapped = false

  init() {}

  init?(_ any: Any?) {
    guard let d = any as? [String: Any] else { return nil }
    seq = (d["seq"] as? NSNumber)?.intValue ?? 0
    state = State(rawValue: d["state"] as? String ?? "none") ?? .none
    mode = d["mode"] as? String ?? "linear"
    gran = d["gran"] as? String ?? "char"
    rows = (d["rows"] as? NSNumber)?.intValue ?? 0
    start = Self._endpoint(d["start"])
    end = Self._endpoint(d["end"])
    bounds = Self._rect(d["bounds"])
    view = Self._rect(d["view"])
    swapped = d["swapped"] as? Bool ?? false
  }

  private static func _num(_ any: Any?) -> CGFloat {
    CGFloat((any as? NSNumber)?.doubleValue ?? 0)
  }

  private static func _endpoint(_ any: Any?) -> Endpoint? {
    guard let d = any as? [String: Any] else { return nil }
    return Endpoint(x: _num(d["x"]), y: _num(d["y"]), h: _num(d["h"]),
                    row: (d["row"] as? NSNumber)?.intValue ?? 0, visible: d["visible"] as? Bool ?? false)
  }

  private static func _rect(_ any: Any?) -> CGRect? {
    guard let d = any as? [String: Any] else { return nil }
    return CGRect(x: _num(d["x"]), y: _num(d["y"]), width: _num(d["w"]), height: _num(d["h"]))
  }
}

@objc final class TerminalSelectionController: NSObject {

  enum HandleKind {
    case start, end

    var js: String { self == .start ? "start" : "end" }
    var other: HandleKind { self == .start ? .end : .start }
  }

  private enum Drag {
    case none
    case focus            // a long-press drag (iOS) or a mouse drag (Mac) moving the focus
    case handle(HandleKind)
  }

  private weak var _webView: WKWebView?
  private weak var _host: UIView?

  /// Called whenever `hasSelection` flips, so the device can tell the input layer.
  @objc var onSelectionStateChange: (() -> Void)?

  private(set) var geometry = TerminalSelectionGeometry()

  /// A selection exists: one on screen, or a clip whose text was rewritten but can still be copied.
  @objc private(set) var hasSelection = false

  // One page call in flight at a time; a drag step replaces a queued step of the same kind instead of
  // piling up behind it, so the selection follows the finger, not a backlog (the scroll path's rule).
  // The script is built when the call actually goes out, not when it is queued: a handle step
  // must name the handle as it is THEN (a step before it may have swapped the two).
  private struct Call {
    var js: () -> String
    var coalesce: String?
    var done: ((TerminalSelectionGeometry?) -> Void)?
  }
  private var _queue: [Call] = []
  private var _inFlight = false

  private var _drag = Drag.none
  private var _dragPoint = CGPoint.zero
  private var _handleOffset = CGPoint.zero

  // Edge auto-scroll while dragging.
  private var _displayLink: CADisplayLink?
  private var _autoScrollCarry: CGFloat = 0
  private var _lastTick: CFTimeInterval = 0

  // Click counting, native so a single tap keeps zero latency: each tap is dispatched at once, and
  // the second / third of a quick run in one place selects a word / a line.
  private var _tapCount = 0
  private var _lastTapTime: CFTimeInterval = 0
  private var _lastTapPoint = CGPoint.zero
  private var _multiClickAllowed = true

  #if targetEnvironment(macCatalyst)
  private let _multiClickInterval: CFTimeInterval = 0.5
  #else
  private let _multiClickInterval: CFTimeInterval = 0.35
  private let _startHandle = TerminalSelectionHandle(kind: .start)
  private let _endHandle = TerminalSelectionHandle(kind: .end)
  private let _pill = TerminalSelectionPill()
  private var _pillWanted = false
  private var _scrolling = false
  private var _pillTimer: Timer?
  private var _loupe: UITextLoupeSession?
  private let _impact = UIImpactFeedbackGenerator(style: .light)
  private let _tick = UISelectionFeedbackGenerator()
  private let _success = UINotificationFeedbackGenerator()
  #endif

  @objc init(webView: WKWebView, host: UIView) {
    _webView = webView
    _host = host
    super.init()
    #if targetEnvironment(macCatalyst)
    webView.addInteraction(UIContextMenuInteraction(delegate: self))
    #else
    for handle in [_startHandle, _endHandle] {
      handle.isHidden = true
      handle.pan.addTarget(self, action: #selector(_onHandlePan(_:)))
      host.addSubview(handle)
    }
    _pill.isHidden = true
    _pill.onAction = { [weak self] action in self?._pillAction(action) }
    host.addSubview(_pill)
    #endif
  }

  // MARK: - Page calls

  private func _call(_ js: String, coalesce: String? = nil, done: ((TerminalSelectionGeometry?) -> Void)? = nil) {
    _call(build: { js }, coalesce: coalesce, done: done)
  }

  private func _call(build: @escaping () -> String, coalesce: String? = nil,
                     done: ((TerminalSelectionGeometry?) -> Void)? = nil) {
    if let key = coalesce, let i = _queue.lastIndex(where: { $0.coalesce == key }), i == _queue.count - 1 {
      _queue[i] = Call(js: build, coalesce: key, done: done)
    } else {
      _queue.append(Call(js: build, coalesce: coalesce, done: done))
    }
    _pump()
  }

  private func _pump() {
    guard !_inFlight, !_queue.isEmpty else { return }
    guard let webView = _webView else {
      _queue.removeAll()
      return
    }
    let call = _queue.removeFirst()
    _inFlight = true
    webView.evaluateJavaScript(call.js()) { [weak self] result, _ in
      guard let self = self else { return }
      self._inFlight = false
      let geo = TerminalSelectionGeometry(result)
      if let geo = geo {
        self._apply(geo)
      }
      call.done?(geo)
      self._pump()
    }
  }

  private static func _n(_ v: CGFloat) -> String {
    v.isFinite ? String(format: "%.2f", Double(v)) : "0"
  }

  private static func _pt(_ p: CGPoint) -> String {
    "\(_n(p.x)), \(_n(p.y))"
  }

  /// A geometry from the page: a call's result or a page-initiated post. Older than the last one
  /// applied means it raced a newer one, and is dropped.
  private func _apply(_ geo: TerminalSelectionGeometry) {
    guard geo.seq >= geometry.seq else { return }
    let previous = geometry
    geometry = geo
    let has = geo.state != .none
    if has != hasSelection {
      hasSelection = has
      if !has {
        #if !targetEnvironment(macCatalyst)
        _pillWanted = false
        #endif
      }
      onSelectionStateChange?()
    }
    #if !targetEnvironment(macCatalyst)
    if case .none = _drag {
    } else if geo.state == .active, previous.state == .active,
              previous.start?.row != geo.start?.row || previous.start?.x != geo.start?.x ||
              previous.end?.row != geo.end?.row || previous.end?.x != geo.end?.x {
      _tick.selectionChanged()
      _tick.prepare()
    }
    _layoutChrome()
    #endif
  }

  /// The page posted a change it made itself (output rewrote the rows, a trim, a screen switch, a
  /// scroll).
  func pageDidPost(_ message: [String: Any]) {
    if let geo = TerminalSelectionGeometry(message) {
      _apply(geo)
    }
  }

  /// The terminal page was (re)built: whatever was selected lived in the page that is gone.
  @objc func pageDidReload() {
    _queue.removeAll()
    _stopAutoScroll()
    _drag = .none
    var reset = TerminalSelectionGeometry()
    reset.seq = 0
    geometry = reset
    if hasSelection {
      hasSelection = false
      onSelectionStateChange?()
    }
    #if !targetEnvironment(macCatalyst)
    _pillWanted = false
    _layoutChrome()
    #endif
  }

  // MARK: - Commands

  @objc func clear() {
    clear(reason: "cleared")
  }

  func clear(reason: String) {
    guard hasSelection else { return }
    _call("term_selClear('\(reason)');")
  }

  func selectWord(at p: CGPoint) {
    _begin()
    _call("term_selWordAt(\(Self._pt(p)));") { [weak self] _ in self?._settle(showPill: true) }
  }

  func selectLine(at p: CGPoint) {
    _begin()
    _call("term_selLineAt(\(Self._pt(p)));") { [weak self] _ in self?._settle(showPill: true) }
  }

  /// The selection's text, fetched on demand (it never travels with the geometry).
  @objc func fetchText(raw: Bool, oneLine: Bool, completion: @escaping (String?) -> Void) {
    guard hasSelection, let webView = _webView else {
      completion(nil)
      return
    }
    webView.evaluateJavaScript("term_selText({raw: \(raw), oneLine: \(oneLine)});") { result, _ in
      let text = result as? String
      completion(text?.isEmpty == false ? text : nil)
    }
  }

  /// Copy to the system clipboard. The one Copy there is gives ONE line: rows joined with a space,
  /// runs of blanks collapsed, a TUI's box borders dropped, because what gets copied out of an agent
  /// is a command, a path or a sentence that the terminal happened to wrap. `raw` (Cmd+Shift+C) is the
  /// escape hatch: the rows exactly as they are. On iOS the selection is done once copied; on the Mac
  /// it stays, like every desktop app.
  @objc func copy(raw: Bool) {
    fetchText(raw: raw, oneLine: !raw) { [weak self] text in
      guard let text = text else { return }
      UIPasteboard.general.string = text
      #if !targetEnvironment(macCatalyst)
      self?._success.notificationOccurred(.success)
      self?.clear(reason: "copied")
      #endif
    }
  }

  /// The selection's bounds in the host's coordinates (for anchoring a share sheet), or zero.
  @objc var selectionRect: CGRect {
    guard let bounds = geometry.bounds, let webView = _webView, let host = _host else { return .zero }
    return webView.convert(bounds, to: host)
  }

  // MARK: - Gestures

  enum TapOutcome {
    case handled     // the tap belonged to the selection (cleared it, toggled the pill, selected)
    case dispatch    // an ordinary tap: run the tap dispatch
  }

  /// Every tap on the terminal comes here first.
  func tap(at p: CGPoint, modifiers: UIKeyModifierFlags) -> TapOutcome {
    let now = CACurrentMediaTime()
    if now - _lastTapTime < _multiClickInterval, hypot(p.x - _lastTapPoint.x, p.y - _lastTapPoint.y) < 12 {
      _tapCount += 1
    } else {
      _tapCount = 1
      _multiClickAllowed = true
    }
    _lastTapTime = now
    _lastTapPoint = p

    if _tapCount >= 2, _multiClickAllowed {
      if _tapCount >= 3 {
        selectLine(at: p)
      } else {
        selectWord(at: p)
      }
      return .handled
    }

    // Shift-click extends the selection there is (Mac, or an iPad with a keyboard).
    if modifiers.contains(.shift), geometry.state == .active {
      _call("term_selBegin(\(Self._pt(p)), {extend: true});")
      return .handled
    }

    guard hasSelection else { return .dispatch }
    #if !targetEnvironment(macCatalyst)
    if geometry.state == .active, _contains(p) {
      _pillWanted.toggle()
      _layoutChrome()
      return .handled
    }
    #endif
    clear(reason: "tap")
    return .handled
  }

  /// What the tap dispatch did with a tap: a tap the program or a link took cannot become the first
  /// click of a double click.
  func tapDispatched(action: String, input: Bool) {
    if action != "none" || input {
      _multiClickAllowed = false
    }
  }

  /// Long press (iOS): select the smart word under the finger; keep dragging to extend by word.
  func longPress(_ state: UIGestureRecognizer.State, at p: CGPoint) {
    switch state {
    case .began:
      _begin()
      #if !targetEnvironment(macCatalyst)
      _impact.impactOccurred()
      _tick.prepare()
      #endif
      _drag = .focus
      _dragPoint = p
      _call("term_selBegin(\(Self._pt(p)), {gran: 'word'});")
    case .changed:
      _dragPoint = p
      _call("term_selExtendTo(\(Self._pt(p)));", coalesce: "extend")
      _updateAutoScroll()
    case .ended, .cancelled, .failed:
      _endDrag()
    default:
      break
    }
  }

  /// A mouse drag (Mac; also an iPad pointer): plain = select, Shift = extend from the anchor,
  /// Option = rectangular. A drag that starts right after a click selects by word (or by line after
  /// two clicks), like every desktop text view.
  func mouseDrag(_ state: UIGestureRecognizer.State, from start: CGPoint, to p: CGPoint, modifiers: UIKeyModifierFlags) {
    switch state {
    case .began:
      let now = CACurrentMediaTime()
      var gran = "char"
      if _multiClickAllowed, now - _lastTapTime < _multiClickInterval,
         hypot(start.x - _lastTapPoint.x, start.y - _lastTapPoint.y) < 12 {
        gran = _tapCount >= 2 ? "line" : "word"
      }
      let rect = modifiers.contains(.alternate)
      let extend = modifiers.contains(.shift) && geometry.state == .active
      _begin()
      _drag = .focus
      _dragPoint = p
      _call("term_selBegin(\(Self._pt(start)), {rect: \(rect), extend: \(extend), gran: '\(gran)'});")
      _call("term_selExtendTo(\(Self._pt(p)));", coalesce: "extend")
    case .changed:
      _dragPoint = p
      _call("term_selExtendTo(\(Self._pt(p)));", coalesce: "extend")
      _updateAutoScroll()
    case .ended, .cancelled, .failed:
      _endDrag()
    default:
      break
    }
  }

  /// The user is scrolling the terminal (or stopped). The selection is scroll-safe (it lives on the
  /// rows), so scrolling never clears it; the chrome only steps aside while things move.
  func scrollActivity(_ active: Bool) {
    #if !targetEnvironment(macCatalyst)
    guard active != _scrolling else { return }
    _scrolling = active
    if active {
      _layoutChrome()
    } else if hasSelection {
      _call("term_selGeometry();")
    }
    #endif
  }

  private func _begin() {
    #if !targetEnvironment(macCatalyst)
    _pillWanted = false
    _layoutChrome()
    #endif
  }

  private func _endDrag() {
    _stopAutoScroll()
    _drag = .none
    // The last step's result decides: a drag that ended on nothing leaves nothing behind.
    _call("term_selGeometry();") { [weak self] geo in
      guard let self = self else { return }
      if geo?.state == TerminalSelectionGeometry.State.none {
        self._call("term_selClear('empty');")
      }
      self._settle(showPill: true)
    }
  }

  private func _settle(showPill: Bool) {
    #if !targetEnvironment(macCatalyst)
    _pillWanted = showPill && hasSelection
    _layoutChrome()
    #endif
  }

  #if !targetEnvironment(macCatalyst)
  /// Whether a point (web-view coordinates) is inside the selection.
  private func _contains(_ p: CGPoint) -> Bool {
    guard let s = geometry.start, let e = geometry.end else { return false }
    if geometry.mode == "rect" {
      return p.x >= s.x && p.x <= e.x && p.y >= s.y && p.y <= e.y + e.h
    }
    guard p.y >= s.y, p.y <= e.y + e.h else { return false }
    if p.y < s.y + s.h, p.x < s.x { return false }
    if p.y >= e.y, p.x > e.x { return false }
    return true
  }
  #endif

  // MARK: - Auto-scroll

  /// How deep the drag point sits in the edge band (or past the edge): negative = top, positive =
  /// bottom, 0 = not in a band.
  private func _edgeDepth() -> CGFloat {
    guard let webView = _webView else { return 0 }
    let view = geometry.view ?? webView.bounds
    let rowH = max(geometry.start?.h ?? 16, 8)
    let band = rowH * 1.5
    let y = _dragPoint.y
    if y < view.minY + band {
      return -min((view.minY + band - y) / band, 3)
    }
    if y > view.maxY - band {
      return min((y - (view.maxY - band)) / band, 3)
    }
    return 0
  }

  private func _updateAutoScroll() {
    if _edgeDepth() == 0 {
      _stopAutoScroll()
      return
    }
    guard _displayLink == nil else { return }
    _autoScrollCarry = 0
    _lastTick = CACurrentMediaTime()
    let link = CADisplayLink(target: TerminalSelectionWeakTarget(self), selector: #selector(TerminalSelectionWeakTarget.tick))
    link.add(to: .main, forMode: .common)
    _displayLink = link
  }

  private func _stopAutoScroll() {
    _displayLink?.invalidate()
    _displayLink = nil
  }

  fileprivate func _autoScrollTick() {
    let now = CACurrentMediaTime()
    let dt = min(now - _lastTick, 0.1)
    _lastTick = now
    let depth = _edgeDepth()
    if depth == 0 {
      _stopAutoScroll()
      return
    }
    // Rows per second, growing with how far into the band (and past the edge) the finger is.
    let speed = 4 + 20 * depth * depth
    _autoScrollCarry += (depth < 0 ? -speed : speed) * CGFloat(dt)
    let rows = Int(_autoScrollCarry)
    guard rows != 0 else { return }
    _autoScrollCarry -= CGFloat(rows)
    let what: String
    switch _drag {
    case .handle(let kind): what = kind.js
    case .focus: what = "focus"
    case .none:
      _stopAutoScroll()
      return
    }
    let isHandle = what != "focus"
    _call(build: { [weak self] in
      let kind = isHandle ? (self?._draggedKind().js ?? what) : what
      return "term_selAutoScroll(\(rows), \(Self._pt(self?._targetPoint() ?? .zero)), '\(kind)');"
    }, coalesce: "auto") { [weak self] geo in
      self?._noteSwap(geo)
    }
  }

  private func _draggedKind() -> HandleKind {
    if case .handle(let kind) = _drag { return kind }
    return .end
  }

  #if targetEnvironment(macCatalyst)
  private func _noteSwap(_ geo: TerminalSelectionGeometry?) {}
  #endif

  /// The point a drag step selects at: the finger for a focus drag, the handle's text position (the
  /// finger plus where on the handle it grabbed) for a handle drag.
  private func _targetPoint() -> CGPoint {
    if case .handle = _drag {
      return CGPoint(x: _dragPoint.x + _handleOffset.x, y: _dragPoint.y + _handleOffset.y)
    }
    return _dragPoint
  }

  // MARK: - iOS chrome: handles and pill

  #if !targetEnvironment(macCatalyst)
  @objc private func _onHandlePan(_ pan: UIPanGestureRecognizer) {
    guard let handle = pan.view as? TerminalSelectionHandle, let webView = _webView, let host = _host else { return }
    let p = pan.location(in: webView)
    switch pan.state {
    case .began:
      // Grab offset: the text position is the boundary at mid-row, wherever on the 44pt target the
      // finger landed.
      let endpoint = handle.kind == .start ? geometry.start : geometry.end
      if let e = endpoint {
        _handleOffset = CGPoint(x: e.x - p.x, y: e.y + e.h * 0.5 - p.y)
      } else {
        _handleOffset = .zero
      }
      _drag = .handle(handle.kind)
      _dragPoint = p
      _tick.prepare()
      _pillWanted = false
      _layoutChrome()
      let target = _targetPoint()
      _loupe = UITextLoupeSession.begin(at: webView.convert(target, to: host), fromSelectionWidgetView: handle, in: host)
    case .changed:
      _dragPoint = p
      let target = _targetPoint()
      _call(build: { [weak self] in
        guard let self = self else { return "term_selGeometry();" }
        return "term_selMoveHandle('\(self._draggedKind().js)', \(Self._pt(self._targetPoint())));"
      }, coalesce: "handle") { [weak self] geo in
        self?._noteSwap(geo)
      }
      _updateAutoScroll()
      if let loupe = _loupe {
        let caret = CGRect(x: target.x - 1, y: target.y - (geometry.start?.h ?? 16) * 0.5,
                           width: 2, height: geometry.start?.h ?? 16)
        loupe.move(to: webView.convert(target, to: host), withCaretRect: webView.convert(caret, to: host), trackingCaret: true)
      }
    case .ended, .cancelled, .failed:
      _loupe?.invalidate()
      _loupe = nil
      _stopAutoScroll()
      _drag = .none
      _settle(showPill: true)
    default:
      break
    }
  }

  private func _noteSwap(_ geo: TerminalSelectionGeometry?) {
    guard let geo = geo, geo.swapped, case .handle(let kind) = _drag else { return }
    _drag = .handle(kind.other)
  }

  private func _pillAction(_ action: TerminalSelectionPill.Action) {
    switch action {
    case .copy: copy(raw: false)
    }
  }

  /// Places (or hides) the handles and the pill from the last geometry.
  private func _layoutChrome() {
    guard let webView = _webView, let host = _host else { return }
    let active = geometry.state == .active
    let dragging: Bool
    switch _drag {
    case .none: dragging = false
    default: dragging = true
    }

    // Handles: hidden while the terminal scrolls (they would trail the text by a bridge hop).
    for (handle, endpoint) in [(_startHandle, geometry.start), (_endHandle, geometry.end)] {
      guard active, !_scrolling, let e = endpoint, e.visible else {
        handle.isHidden = true
        continue
      }
      let top = webView.convert(CGPoint(x: e.x, y: e.y), to: host)
      handle.rowHeight = e.h
      handle.place(at: top)
      handle.isHidden = false
      host.bringSubviewToFront(handle)
    }

    // The pill: hidden while anything moves, back a beat after it stops.
    let show = hasSelection && _pillWanted && !_scrolling && !dragging
    _pillTimer?.invalidate()
    _pillTimer = nil
    guard show else {
      _pill.isHidden = true
      return
    }
    let size = _pill.fittingSize()
    let hostBounds = host.bounds
    var anchor: CGRect
    if let b = geometry.bounds {
      anchor = webView.convert(b, to: host)
    } else if geometry.state == .clip {
      anchor = CGRect(x: hostBounds.midX, y: hostBounds.midY, width: 0, height: 0)
    } else {
      _pill.isHidden = true
      return
    }
    // Above the selection, clear of the start handle's knob; below it when there is no room.
    let gap: CGFloat = 18
    var y = anchor.minY - gap - size.height
    if y < hostBounds.minY + 4 {
      y = anchor.maxY + gap
    }
    if y + size.height > hostBounds.maxY - 4 {
      y = max(hostBounds.minY + 4, min(anchor.midY - size.height * 0.5, hostBounds.maxY - 4 - size.height))
    }
    var x = anchor.midX - size.width * 0.5
    x = max(hostBounds.minX + 8, min(x, hostBounds.maxX - 8 - size.width))
    let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    let wasHidden = _pill.isHidden
    _pill.frame = frame
    host.bringSubviewToFront(_pill)
    if wasHidden {
      // A beat after the gesture or scroll that hid it, so it does not flash between steps.
      _pillTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
        guard let self = self, self.hasSelection, self._pillWanted else { return }
        self._pill.alpha = 0
        self._pill.isHidden = false
        UIView.animate(withDuration: 0.15) { self._pill.alpha = 1 }
      }
    }
  }
  #endif
}

/// CADisplayLink retains its target; this breaks the cycle.
private final class TerminalSelectionWeakTarget: NSObject {
  weak var owner: TerminalSelectionController?

  init(_ owner: TerminalSelectionController) {
    self.owner = owner
  }

  @objc func tick() {
    owner?._autoScrollTick()
  }
}

// MARK: - Mac: the right-click menu

#if targetEnvironment(macCatalyst)
extension TerminalSelectionController: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                              configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
    let has = hasSelection
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      let copy = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc"),
                          attributes: has ? [] : .disabled) { _ in self?.copy(raw: false) }
      return UIMenu(children: [copy])
    }
  }
}
#endif

// MARK: - iOS: handle and pill views

#if !targetEnvironment(macCatalyst)
/// A selection handle: the mushroom-red lollipop at one end of the selection. A 44pt touch target
/// around a thin bar the height of a row, with the knob above the start and below the end. It lives
/// in the terminal view ABOVE the web view, so its drag never reaches the web view's recognizers.
final class TerminalSelectionHandle: UIView {
  let kind: TerminalSelectionController.HandleKind
  let pan = UIPanGestureRecognizer()
  var rowHeight: CGFloat = 16 {
    didSet { if rowHeight != oldValue { setNeedsLayout() } }
  }

  private let _bar = UIView()
  private let _knob = UIView()
  private static let knob: CGFloat = 11
  private static let width: CGFloat = 44

  init(kind: TerminalSelectionController.HandleKind) {
    self.kind = kind
    super.init(frame: .zero)
    backgroundColor = .clear
    _bar.backgroundColor = .moshroomTint
    _bar.isUserInteractionEnabled = false
    _knob.backgroundColor = .moshroomTint
    _knob.layer.cornerRadius = Self.knob * 0.5
    _knob.isUserInteractionEnabled = false
    addSubview(_bar)
    addSubview(_knob)
    pan.maximumNumberOfTouches = 1
    addGestureRecognizer(pan)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// `top` is the selection boundary's top in the superview: the bar starts there.
  func place(at top: CGPoint) {
    let h = rowHeight + Self.knob
    let y = kind == .start ? top.y - Self.knob : top.y
    frame = CGRect(x: top.x - Self.width * 0.5, y: y, width: Self.width, height: h)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let k = Self.knob
    let midX = bounds.midX
    if kind == .start {
      _knob.frame = CGRect(x: midX - k * 0.5, y: 0, width: k, height: k)
      _bar.frame = CGRect(x: midX - 1, y: k * 0.5, width: 2, height: rowHeight + k * 0.5)
    } else {
      _bar.frame = CGRect(x: midX - 1, y: 0, width: 2, height: rowHeight + k * 0.5)
      _knob.frame = CGRect(x: midX - k * 0.5, y: rowHeight, width: k, height: k)
    }
  }

  // A 44pt target, however short the row.
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    let extra = max(0, (44 - bounds.height) * 0.5)
    return bounds.insetBy(dx: 0, dy: -extra).contains(point)
  }
}

/// The copy pill: the house white chip with near-black ink, floating over the selection.
final class TerminalSelectionPill: UIView {
  enum Action {
    case copy
  }

  var onAction: ((Action) -> Void)?

  private let _stack = UIStackView()
  private var _buttons: [(Action, UIButton)] = []
  private static let height: CGFloat = 38

  init() {
    super.init(frame: .zero)
    backgroundColor = Moshstyle.chipFillOpaque
    layer.cornerRadius = Self.height * 0.5
    layer.borderWidth = 0.5
    layer.borderColor = Moshstyle.hairline.cgColor
    Moshstyle.applyChipShadow(layer)
    _stack.axis = .horizontal
    _stack.alignment = .fill
    _stack.spacing = 0
    _stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(_stack)
    NSLayoutConstraint.activate([
      _stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      _stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      _stack.topAnchor.constraint(equalTo: topAnchor),
      _stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    for (action, title) in [(Action.copy, "Copy")] {
      var config = UIButton.Configuration.plain()
      config.title = title
      config.baseForegroundColor = Moshstyle.ink
      config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
      config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
        var out = attrs
        out.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        return out
      }
      let button = UIButton(configuration: config)
      button.preferredBehavioralStyle = .pad
      button.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
      _stack.addArrangedSubview(button)
      _buttons.append((action, button))
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func fittingSize() -> CGSize {
    let width = _stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + 12
    return CGSize(width: ceil(width), height: Self.height)
  }
}
#endif
