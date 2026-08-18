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
import WebKit

class UIScrollViewWithoutHitTest: UIScrollView {
  var isInfinit = false
  
  var reportedScroll: CGPoint? = nil
  
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let scrollBarWidth: CGFloat = 24
    if
      let result = super.hitTest(point, with: event),
      result !== self || point.x > self.bounds.size.width - scrollBarWidth {
      return result
    }
    return nil
  }
  
  override func layoutSubviews() {
    super.layoutSubviews()
    
    guard isInfinit
    else {
      return
    }
    
    let requiredSize = CGSize(width: bounds.width /* * 10 */, height: bounds.height * 10)
    if contentSize != requiredSize {
      contentSize = requiredSize
    }
    
    recenterIfNeeded(force: false)
  }
  
  func recenterIfNeeded(force: Bool = false) {
    var currentOffset = contentOffset
    
    let centerOffsetY = (contentSize.height - bounds.size.height) * 0.5;
    
    let distanceFromCenterY = abs(currentOffset.y - centerOffsetY);
    
    if force || distanceFromCenterY > (contentSize.height / 4.0) {
      currentOffset = CGPoint(x: currentOffset.x, y: centerOffsetY)
      reportedScroll = currentOffset
      contentOffset = currentOffset
    }
  }
}

// A tap on the terminal input line (the cursor row) is a typing intent — SpaceController
// observes this and opens the Moshkitor composer for the tapped web view.
let MoshroomTerminalInputTapNotification = "MoshroomTerminalInputTapNotification"

// The viewport left (or came back to) the live end of the transcript — posted with the terminal's
// web view as the object and ["tailing": Bool]. SpaceController shows the "back to live" chip off
// it, so a terminal parked up in its scrollback can never read as a frozen one.
let MoshroomTerminalTailingNotification = "MoshroomTerminalTailingNotification"

/**
 Gestures:

 - 1 finger tap - universal tap dispatch (term_tapAt: URL open / TUI click report / composer)
 - 1 finger long-press - select word → Copy
 - pan - terminal scroll (touch); on Mac Catalyst a left-drag is live text selection instead
 */

@objc class WKWebViewGesturesInteraction: NSObject, UIInteraction {
  var view: UIView? = nil
  private weak var _wkWebView: WKWebView? = nil
  private let _scrollView = UIScrollViewWithoutHitTest()
  private let _termScrollView = UIScrollViewWithoutHitTest()
  private let _jsScrollerPath: String
  private let _handlerName: String
  private let _longPressRecognizer = UILongPressGestureRecognizer()
  private let _tapRecognizer = UITapGestureRecognizer()
  #if targetEnvironment(macCatalyst)
  private let _mouseSelectRecognizer = UIPanGestureRecognizer()
  #endif
  private var _pointerInteraction: Any? = nil
  private var _characterSize: CGSize? = nil
  private var _scrollPoint: CGPoint? = nil

  // Which scroll view owns a swipe: _scrollView scrolls hterm's own content (smooth, with an
  // indicator), _termScrollView hands row-quantised deltas to the page's ladder (wheel reports, the
  // alternate screen's local history, cursor keys — see the Scrolling section in term.js). The page
  // reports both facts it needs: which screen is showing and whether the remote asked for the mouse.
  private var _isPrimaryScreen = true
  private var _mouseReportOn = false
  private var _pendingScrollModeApply = false

  /// The viewport is at the live end of the transcript. Read by TermView to skip a pointless
  /// scroll-to-bottom on every keystroke, and mirrored to SpaceController's "back to live" chip.
  @objc private(set) var isTailing = true

  @objc var focused: Bool = false;
  @objc var hasSelection: Bool = false {
    didSet {
      // While text is selected, a drag must not also scroll the terminal. On the Mac the scroll
      // pans ignore the pointer entirely (see init) and the selection IS a live drag — dropping
      // touches would cancel it mid-flight — so this guard is touch-only.
      #if !targetEnvironment(macCatalyst)
      if hasSelection {
        _scrollView.panGestureRecognizer.dropTouches()
        _termScrollView.panGestureRecognizer.dropTouches()
        view?.dropSuperViewTouches()
      }
      #endif
    }
  }
  
  @objc var indicatorStyle: UIScrollView.IndicatorStyle {
    get { _scrollView.indicatorStyle }
    set { _scrollView.indicatorStyle = newValue }
  }
  
  var allRecognizers:[UIGestureRecognizer] {
    // Moshroom: two custom gestures — long-press (select word → Copy) and single tap (the
    // universal tap dispatch: OSC 8 / URL open, mouse-report click to the TUI, input-row →
    // composer; see term_tapAt) — plus the two scroll-view pans that drive terminal scroll.
    // On the Mac a pan translates the mouse drag into a live text selection (see
    // _onMouseSelectDrag) — WebKit-on-Catalyst never turns click-drags into WebCore drag
    // selection by itself (only dblclick word-select comes for free).
    #if targetEnvironment(macCatalyst)
    return [
      _longPressRecognizer,
      _tapRecognizer,
      _mouseSelectRecognizer,
      _scrollView.panGestureRecognizer,
      _termScrollView.panGestureRecognizer,
    ]
    #else
    return [
      _longPressRecognizer,
      _tapRecognizer,
      _scrollView.panGestureRecognizer,
      _termScrollView.panGestureRecognizer,
    ]
    #endif
  }
  
  func willMove(to view: UIView?) {
    if let webView = view as? WKWebView {
      webView.scrollView.delaysContentTouches = false;
      webView.scrollView.canCancelContentTouches = false;
      webView.scrollView.isScrollEnabled = false;
      webView.scrollView.panGestureRecognizer.isEnabled = false;
      
      
      _scrollView.frame = webView.bounds
      webView.addSubview(_scrollView)
      webView.addSubview(_termScrollView)
      webView.configuration.userContentController.add(self, name: _handlerName)
      
      for r in allRecognizers {
        webView.addGestureRecognizer(r)
      }

      let pointerInteraction = UIPointerInteraction(delegate: self)
      webView.addInteraction(pointerInteraction)
      _pointerInteraction = pointerInteraction

      _wkWebView = webView
    } else {
      _scrollView.removeFromSuperview()
      _termScrollView.removeFromSuperview()
      _wkWebView?.configuration.userContentController.removeScriptMessageHandler(forName: _handlerName)

      for r in allRecognizers {
        _wkWebView?.addGestureRecognizer(r)
      }

      if let interaction = _pointerInteraction as? UIPointerInteraction {
        _wkWebView?.removeInteraction(interaction)
        _pointerInteraction = nil
      }

      _wkWebView = nil
    }
  }
  
  func didMove(to view: UIView?) {
    self.view = view
  }
  
  @objc convenience init(jsScrollerPath: String) {
    self.init(jsScrollerPath: jsScrollerPath, handlerName: "wkScroller")
  }
  
  @objc init(jsScrollerPath: String, handlerName: String) {
    _jsScrollerPath = jsScrollerPath
    _handlerName = handlerName
    super.init()
    _scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    _scrollView.alwaysBounceVertical = false
    _scrollView.alwaysBounceHorizontal = false
    // No rubber band, ever. An over-drag at the top used to report a NEGATIVE offset, hterm answered
    // it by translating the rows down, and the gap that opened showed the bare page background: in a
    // shell that is invisible (same colour), but in any full-screen program painting its own canvas it
    // is a fat dark band appearing under the finger, which is the "black strip when scrolling up".
    // Measured on Catalyst with a phase-tagged scroll: 96pt of it. A transcript has nothing to gain
    // from elasticity, and the page clamps the offset too (see _moshroomScrollTop in term.js).
    _scrollView.bounces = false
    _scrollView.isDirectionalLockEnabled = true
    // iPad have dismiss button on keyboard
    if UIDevice.current.userInterfaceIdiom != .pad {
      _scrollView.keyboardDismissMode = .interactive
    }
    _scrollView.delaysContentTouches = false
    _scrollView.delegate = self
    
    
    _termScrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    _termScrollView.alwaysBounceVertical = false
    _termScrollView.alwaysBounceHorizontal = false
    _termScrollView.bounces = false
    _termScrollView.isDirectionalLockEnabled = true
    _termScrollView.keyboardDismissMode = _scrollView.keyboardDismissMode
    _termScrollView.delaysContentTouches = false
    _termScrollView.delegate = self
    _termScrollView.showsVerticalScrollIndicator = false
    _termScrollView.showsHorizontalScrollIndicator = false
    _termScrollView.isInfinit = true
    // A terminal starts on the normal screen with nothing asking for the mouse, so the local
    // scrollback owns the gesture. Only ONE of the two pans may ever be armed: with both live a
    // single swipe would scroll the transcript AND report a wheel to whatever is running.
    _termScrollView.panGestureRecognizer.isEnabled = false

    _longPressRecognizer.delegate = self
    _longPressRecognizer.addTarget(self, action: #selector(_onLongPress(_:)))
    _longPressRecognizer.isEnabled = true   // Moshroom: long-press = select word → Copy

    // Moshroom: single tap = the universal tap dispatch (term_tapAt). It must observe, never
    // own, the touch stream — cancelsTouchesInView would steal the events WebKit needs for its
    // native behaviours (Mac dblclick word-select, selection dismissal), and the selection /
    // scroll guards live in _onTap instead.
    _tapRecognizer.numberOfTapsRequired = 1
    _tapRecognizer.numberOfTouchesRequired = 1
    _tapRecognizer.cancelsTouchesInView = false
    _tapRecognizer.delegate = self
    _tapRecognizer.addTarget(self, action: #selector(_onTap(_:)))

    #if targetEnvironment(macCatalyst)
    // On the Mac a left-button DRAG selects text, like any terminal. The two scroll pans exist
    // for touch scrolling — on Catalyst they'd claim the click-drag — while actual Mac scrolling
    // (wheel / trackpad) arrives as DOM wheel events that hterm handles itself, never through
    // these pans. So the pans ignore the pointer entirely here (iOS behaviour untouched), and a
    // dedicated pan turns the drag into a live JS selection.
    _scrollView.panGestureRecognizer.allowedTouchTypes = []
    _termScrollView.panGestureRecognizer.allowedTouchTypes = []
    _mouseSelectRecognizer.maximumNumberOfTouches = 1
    _mouseSelectRecognizer.delegate = self
    _mouseSelectRecognizer.addTarget(self, action: #selector(_onMouseSelectDrag(_:)))
    #endif
  }

  #if targetEnvironment(macCatalyst)
  @objc func _onMouseSelectDrag(_ recognizer: UIPanGestureRecognizer) {
    guard focused else { return }
    let p = recognizer.location(in: recognizer.view)
    switch recognizer.state {
    case .began:
      // The selection about to be born must be page-painted (red CSS), never the UIKit overlay —
      // shed any first responder AppKit may have restored to the content view.
      (_wkWebView as? SmarterTermInput)?.deactivateSelectionUI()
      // Anchor at the true mouse-down point — by .began the pointer already moved past the
      // recognizer's hysteresis, so walk the translation back to the origin.
      let t = recognizer.translation(in: recognizer.view)
      let start = CGPoint(x: p.x - t.x, y: p.y - t.y)
      _wkWebView?.evaluateJavaScript(
        "term_startSelectionAt(\(start.x), \(start.y)); term_extendSelectionTo(\(p.x), \(p.y));",
        completionHandler: nil)
    case .changed:
      _wkWebView?.evaluateJavaScript("term_extendSelectionTo(\(p.x), \(p.y));", completionHandler: nil)
    case .ended, .cancelled, .failed:
      _wkWebView?.evaluateJavaScript("term_endSelection();", completionHandler: nil)
    default:
      break
    }
  }
  #endif
  
  // Moshroom: a single tap keeps the TUI interactive without giving up the transcript model —
  // term_tapAt (term.js) dispatches it through generic terminal mechanisms only: an OSC 8 or
  // plain-text URL opens on the device, a program that asked for mouse events (DECSET 1000/…)
  // gets a standard click report at the cell, and a tap on the cursor row (the program's input
  // line) opens the Moshkitor composer. A tap that lands mid-scroll is "stop the scroll", and a
  // tap while a selection is up is "dismiss it" — neither may click, open, or compose.
  @objc func _onTap(_ recognizer: UITapGestureRecognizer) {
    guard focused, recognizer.state == .ended else { return }
    guard !hasSelection,
          !_scrollView.isDecelerating, !_termScrollView.isDecelerating else { return }
    let point = recognizer.location(in: recognizer.view)
    _wkWebView?.evaluateJavaScript("term_tapAt(\(point.x), \(point.y));") { [weak self] result, _ in
      guard
        let webView = self?._wkWebView,
        let response = result as? [String: Any],
        response["input"] as? Bool == true
      else { return }
      NotificationCenter.default.post(
        name: NSNotification.Name(MoshroomTerminalInputTapNotification), object: webView)
    }
  }

  // MARK: - Scroll ownership

  /// The local scrollback takes the gesture only when it is the thing that can actually serve it:
  /// nothing asked for the mouse, the normal screen is showing, AND there is content to move. Any of
  /// those failing hands the gesture to the page's ladder, which is what fixes the case this rule was
  /// written for: an agent TUI rendering INLINE on the normal screen with mouse reporting on. "Normal
  /// screen" alone used to arm the local scrollback, an inline TUI leaves that empty, and the swipe
  /// died with nothing to move and no report sent, even though the program was listening.
  private var _localScrollWins: Bool {
    guard !_mouseReportOn, _isPrimaryScreen else { return false }
    return _scrollView.contentSize.height > _scrollView.bounds.height + 2
  }

  private func _applyScrollMode() {
    // Flipping a pan's isEnabled CANCELS the touches it is holding, and the messages that land here
    // arrive while a session prints (once per output line). Never re-arm under the user's finger:
    // remember it and apply the moment the gesture is over.
    if _scrollView.isDragging || _scrollView.isDecelerating ||
       _termScrollView.isDragging || _termScrollView.isDecelerating {
      _pendingScrollModeApply = true
      return
    }
    _pendingScrollModeApply = false
    let local = _localScrollWins
    if _scrollView.panGestureRecognizer.isEnabled != local {
      _scrollView.panGestureRecognizer.isEnabled = local
    }
    if _termScrollView.panGestureRecognizer.isEnabled == local {
      _termScrollView.panGestureRecognizer.isEnabled = !local
    }
    // The indicator belongs to the surface that actually moves. On the alternate screen the page
    // moves the viewport itself, a row at a time, so showing this bar being dragged would be a lie.
    _scrollView.showsVerticalScrollIndicator = local
    _updateTailing()
  }

  private func _updateTailing() {
    let bottom = max(_scrollView.contentSize.height - _scrollView.bounds.height, 0)
    // Same 2pt of slack as the resize handler: content height is a whole number of rows while the
    // viewport height is not, so a viewport truly at the end can sit fractionally short of it.
    let tailing = bottom <= 0 || _scrollView.contentOffset.y >= bottom - 2
    guard tailing != isTailing else { return }
    isTailing = tailing
    guard let webView = _wkWebView else { return }
    NotificationCenter.default.post(
      name: NSNotification.Name(MoshroomTerminalTailingNotification),
      object: webView,
      userInfo: ["tailing": tailing])
  }

  @objc func _onLongPress(_ recognizer: UILongPressGestureRecognizer) {
    guard focused, recognizer.state == .began else {
      return
    }
    // Moshroom: long-press selects the terminal word under the finger (rendered text, so it
    // works for any TUI) and a single Copy item follows. A swipe is a different gesture and
    // still scrolls — so this never fights the scroll.
    let point = recognizer.location(in: recognizer.view)
    _wkWebView?.evaluateJavaScript("term_selectWordAt(\(point.x), \(point.y));", completionHandler: nil)
  }

}

extension WKWebViewGesturesInteraction: UIGestureRecognizerDelegate {
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    return true
  }
}

extension WKWebViewGesturesInteraction: UIScrollViewDelegate {
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let offset = scrollView.contentOffset
    
    if scrollView === _scrollView {
      _wkWebView?.evaluateJavaScript("\(_jsScrollerPath).reportScroll(\(offset.x), \(offset.y));", completionHandler: nil)
      _updateTailing()
      return
    }
    
    
    
    if scrollView === _termScrollView {
      guard var reportedScroll = _termScrollView.reportedScroll
      else {
        return
      }
      
      let offsetY = max(offset.y, 0)
      
      let defaultFontSize = 20
      if _characterSize == .none || _characterSize == .zero {
        var size = MoshroomDefaults.selectedFontSize().intValue
        if size == 0 {
          size = defaultFontSize
        }
        // A character cell is TALLER and NARROWER than the font's point size (a monospace row is
        // roughly 1.2 em tall, 0.6 em wide). Using the point size as the row height made every
        // wheel step overshoot by a quarter until the first resize message brought real metrics.
        _characterSize = CGSize(width: CGFloat(size) * 0.6, height: CGFloat(size) * 1.2)
      }

      var charHeight: CGFloat = _characterSize?.height ?? CGFloat(defaultFontSize)
      if (charHeight <= 0) {
        charHeight = CGFloat(defaultFontSize)
      }

      let deltaY = offsetY - reportedScroll.y
      if abs(deltaY) < charHeight {
        return
      }
      // Whole rows only, and the remainder stays in reportedScroll for the next event, so a slow
      // drag never loses ground.
      let steps = Int(deltaY / charHeight)
      var dY = CGFloat(steps) * charHeight
      reportedScroll.y = reportedScroll.y + dY
      _termScrollView.reportedScroll = reportedScroll

      // Report the wheel where the finger actually is, so the TUI scrolls the region under
      // the touch (its main content) rather than a fixed origin that often lands on its input
      // box. Fall back to the drag-start point during momentum, when no touches are live.
      let point: CGPoint
      if _termScrollView.panGestureRecognizer.numberOfTouches > 0 {
        point = _termScrollView.panGestureRecognizer.location(in: view)
      } else {
        point = _scrollPoint ?? CGPoint(x: scrollView.bounds.size.width * 0.5, y: scrollView.bounds.size.height * 0.5)
      }

      if MoshroomDefaults.doInvertVerticalScroll() {
        dY *= -1.0;
      }

      // The ROW COUNT matters as much as the delta: hterm's VT encodes exactly one wheel report per
      // event, so a 3-row flick used to move the remote a single line. The page sends one report per
      // row instead. And when there is nothing to report to (no mouse reporting, no local history),
      // it falls back to cursor keys, which the user can switch off.
      let rows = min(abs(steps), 12)
      let allowArrows = MoshroomDefaults.isAltScrollArrowsOn()
      _wkWebView?.evaluateJavaScript(
        "term_reportWheelEvent(\"wheel\", \(point.x), \(point.y), \(0), \(dY), \(rows), \(allowArrows));",
        completionHandler: nil)
    }
  }
  
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    if scrollView == _termScrollView {
      if _termScrollView.panGestureRecognizer.numberOfTouches > 0 {
        _scrollPoint = _termScrollView.panGestureRecognizer.location(in: view)
      } else {
        _scrollPoint = nil
      }
      _termScrollView.reportedScroll = _termScrollView.contentOffset
    }
  }
  
  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    if scrollView == _termScrollView {
      _termScrollView.recenterIfNeeded(force: true)
    }
    if _pendingScrollModeApply {
      _applyScrollMode()
    }
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if scrollView == _termScrollView {
      if !decelerate {
        _termScrollView.recenterIfNeeded(force: true)
      }
    }
    // A mode change that arrived mid-gesture was deferred so it could not cancel the drag.
    if !decelerate, _pendingScrollModeApply {
      _applyScrollMode()
    }
  }
}

extension WKWebViewGesturesInteraction: WKScriptMessageHandler {
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard
      let msg = message.body as? [String: Any],
      let op = msg["op"] as? String
    else {
      return
    }
    
    switch op {
    case "resize":
      let contentSize = NSCoder.cgSize(for: msg["contentSize"] as? String ?? "")
      let characterSize = NSCoder.cgSize(for: msg["characterSize"] as? String ?? "")
      let isPrimary = msg["isPrimary"] as? Bool ?? true

      // This message arrives on EVERY content-height change — which, while a session is printing,
      // is once per new line. Unconditionally parking the offset at the new bottom (what this did)
      // meant a terminal receiving output could not be scrolled back AT ALL: the swipe moved the
      // viewport and the very next line snapped it to the end, so reading history while an agent
      // streamed was impossible and the terminal read as if it were fighting the finger. Assigning
      // contentOffset also fires scrollViewDidScroll → reportScroll, so this reached hterm on every
      // platform, pan gesture enabled or not.
      // Follow the end only when the viewport was ALREADY there (the ordinary "tailing the output"
      // case); otherwise leave the user's position alone, and merely clamp when the content shrank
      // out from under it (hterm trims the scrollback in chunks). The 2pt of slack is deliberate,
      // not an exact compare: content height is a whole number of character rows while the view
      // height is not, so a viewport at the true bottom can sit fractionally short of it, and
      // misreading that as "scrolled up" would stop the terminal following its own output.
      let previousBottom = max(_scrollView.contentSize.height - _scrollView.bounds.height, 0)
      let wasTailing = _scrollView.contentOffset.y >= previousBottom - 2

      _characterSize = characterSize
      _scrollView.contentSize = contentSize

      let bottom = CGPoint(x: 0, y: max(contentSize.height - _scrollView.bounds.height, 0))
      if wasTailing || _scrollView.contentOffset.y > bottom.y {
        _scrollView.contentOffset = bottom
      }

      _isPrimaryScreen = isPrimary
      _applyScrollMode()
      _updateTailing()


    case "scrollTo":
      let animated = msg["animated"] as? Bool == true
      let isPrimary = msg["isPrimary"] as? Bool ?? true

      let x: CGFloat = msg["x"] as? CGFloat ?? 0
      let y: CGFloat = msg["y"] as? CGFloat ?? 0
      let offset = CGPoint(x: x, y: y)

      _isPrimaryScreen = isPrimary
      _applyScrollMode()

      if (offset == _scrollView.contentOffset) {
        _updateTailing()
        return
      }
      // Applied immediately, never debounced: this is the hterm → native SYNC direction, and the
      // scroll view is the mirror the touch path measures its deltas against (see
      // scrollViewDidScroll / reportedScroll). Delaying it would let a gesture arriving in between
      // compute against a stale offset and drift the two apart. The rate is already bounded: the JS
      // bridge only posts scrollTo when its own position actually changed, and the equality check
      // above drops the rest.
      _scrollView.setContentOffset(offset, animated: animated)
      _updateTailing()


    // Moshroom: mouse reporting (or the screen) changed, so who can use a swipe may have changed with
    // it. Posted by the page on every relevant DEC mode change, on RIS, on a return to the local
    // prompt, and once when the terminal comes up — see the Scrolling section in term.js.
    case "scrollmode":
      _isPrimaryScreen = msg["isPrimary"] as? Bool ?? true
      _mouseReportOn = msg["mouseReport"] as? Bool ?? false
      _applyScrollMode()


    default: break
    }
  }
}

extension WKWebViewGesturesInteraction: UIPointerInteractionDelegate {
  func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest, defaultRegion: UIPointerRegion) -> UIPointerRegion? {
    return defaultRegion
  }

  func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
    return nil
  }
}