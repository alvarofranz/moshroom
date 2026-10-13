// Copyright (C) 2026 Moshroom. Licensed under GPLv3; see COPYING.
import XCTest
import WebKit
@testable import SelectionHarness

// Hold bridge replies so a page reload can race them deterministically.
@MainActor private final class DelayedWebView: WKWebView {
  var replies: [(@MainActor @Sendable (Any?, Error?) -> Void)?] = []
  override func evaluateJavaScript(_ script: String, completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)? = nil) {
    replies.append(completionHandler)
  }
  func reply(_ index: Int, _ result: Any) { replies[index]?(result, nil) }
}

@MainActor final class SelectionLifecycleTests: XCTestCase {
  private func selected(_ seq: Int) -> [String: Any] {
    ["seq": seq, "state": "active", "rows": 1,
     "start": ["x": 10, "y": 100, "h": 20, "row": 0, "visible": true],
     "end": ["x": 100, "y": 100, "h": 20, "row": 0, "visible": true],
     "bounds": ["x": 10, "y": 100, "w": 90, "h": 20]]
  }

  func testReloadAcceptsNewCallsAndRejectsOldPageReply() {
    let web = DelayedWebView()
    let host = UIView()
    let controller = TerminalSelectionController(webView: web, host: host)
    controller.selectWord(at: .zero)
    controller.selectLine(at: .zero) // queued on the old page; must be discarded
    controller.pageDidReload()
    controller.selectWord(at: .zero)
    guard web.replies.count == 2 else { return XCTFail("Reload left the new page waiting on the old page") }
    controller.selectLine(at: .zero) // queued on the new page
    web.reply(0, selected(900))
    XCTAssertFalse(controller.hasSelection)
    XCTAssertEqual(web.replies.count, 2, "Old reply must not release the new page's in-flight call")
    web.reply(1, selected(1))
    XCTAssertTrue(controller.hasSelection)
    XCTAssertEqual(controller.geometry.seq, 1)
    XCTAssertEqual(web.replies.count, 3)
    web.reply(2, selected(2))
    XCTAssertEqual(controller.geometry.seq, 2)
  }

  func testReloadCancelsPendingCopyText() {
    let web = DelayedWebView()
    let host = UIView()
    let controller = TerminalSelectionController(webView: web, host: host)
    controller.pageDidPost(selected(10))
    var completions = 0
    controller.fetchText(raw: false, oneLine: true) { text in
      completions += 1
      XCTAssertNil(text, "Text from a destroyed page must not reach the clipboard")
    }
    controller.pageDidReload()
    controller.pageDidPost(selected(1))
    web.reply(0, "obsolete selection")
    XCTAssertEqual(completions, 1)
    XCTAssertEqual(controller.geometry.seq, 1)
  }

  func testCurrentPageCopyStillReturnsText() {
    let web = DelayedWebView()
    let host = UIView()
    let controller = TerminalSelectionController(webView: web, host: host)
    controller.pageDidPost(selected(1))
    var result: String?
    controller.fetchText(raw: false, oneLine: true) { result = $0 }
    web.reply(0, "current selection")
    XCTAssertEqual(result, "current selection")
  }

  func testReloadResetsClickCounting() {
    let web = DelayedWebView()
    let host = UIView()
    let controller = TerminalSelectionController(webView: web, host: host)
    XCTAssertEqual(controller.tap(at: .zero, modifiers: []), .dispatch)
    controller.pageDidReload()
    XCTAssertEqual(controller.tap(at: .zero, modifiers: []), .dispatch)
    XCTAssertTrue(web.replies.isEmpty)
  }

  func testReloadDuringScrollRestoresHandles() {
    let web = DelayedWebView()
    let host = UIView()
    let controller = TerminalSelectionController(webView: web, host: host)
    controller.scrollActivity(true)
    controller.pageDidReload()
    controller.pageDidPost(selected(1))
    let handles = host.subviews.compactMap { $0 as? TerminalSelectionHandle }
    XCTAssertEqual(handles.count, 2)
    XCTAssertTrue(handles.allSatisfy { !$0.isHidden })
  }

  func testDisposingControllerRemovesItsSelectionControls() {
    let web = DelayedWebView()
    let host = UIView()
    var controller: TerminalSelectionController? = TerminalSelectionController(webView: web, host: host)
    controller?.pageDidPost(selected(1))
    weak var released: TerminalSelectionController?
    released = controller
    controller = nil
    XCTAssertNil(released)
    XCTAssertTrue(host.subviews.isEmpty, "Closed terminals must not leave their copy controls behind")
  }
}
