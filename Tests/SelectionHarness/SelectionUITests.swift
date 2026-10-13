// Copyright (C) 2026 Moshroom. Licensed under GPLv3; see COPYING.
import XCTest

final class SelectionUITests: XCTestCase {
  let app = XCUIApplication()
  override func setUpWithError() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    if name.contains("History") { app.launchArguments = ["-history"] }
    app.launch()
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.state()["x"] != nil }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
  }
  override func tearDownWithError() throws {
    XCTAssertEqual(state()["sent"] as? Int, 0, "Selecting and reading must never send terminal input")
    XCUIDevice.shared.orientation = .portrait
  }
  func state() -> [String: Any] {
    let text = app.staticTexts["fixture.status"].value as? String ?? "{}"
    return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
  }
  func point(column: Double = 5, row: Double = 0) -> XCUICoordinate {
    let s = state()
    let x = (s["x"] as? Double ?? 0) + (column - 5) * (s["cw"] as? Double ?? 12)
    let y = (s["y"] as? Double ?? 0) + row * (s["ch"] as? Double ?? 24)
    return app.webViews.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
  }
  func testLongPressAndCopy() {
    point().press(forDuration: 0.8)
    let copy = app.buttons["Copy"]
    XCTAssertTrue(copy.waitForExistence(timeout: 5), "Long press must expose Copy: \(state())")
    XCTAssertEqual(state()["text"] as? String, "Select")
    copy.tap()
    let cleared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.state()["state"] as? String == "none" }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed, "Copy did not complete: \(state())")
    XCTAssertEqual(state()["copied"] as? String, "Select")
    XCTAssertFalse((state()["gestures"] as? [String] ?? []).contains("UITapGestureRecognizer:3"),
                   "The release of a long press must not also be a tap")
  }
  func testLongPressDrag() {
    let end = point(column: 22, row: 1)
    point().press(forDuration: 0.8, thenDragTo: end)
    XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
    XCTAssertEqual(state()["text"] as? String, "Select this paragraph and copy clean text.")
    let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    capture.name = "touch-selection"
    capture.lifetime = .keepAlways
    add(capture)
    app.buttons["Copy"].tap()
    expect("copied", "Select this paragraph and copy clean text.")
  }

  func expect(_ key: String, _ value: String) {
    let match = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.state()[key] as? String == value }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 5), .completed, "\(key): \(state())")
  }

  func testHandleExtensionAndDismissal() {
    point().press(forDuration: 0.8)
    XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
    let endpoint = state()["end"] as! [String: Any]
    let handle = app.webViews.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
      dx: endpoint["x"] as! Double, dy: (endpoint["y"] as! Double) + (endpoint["h"] as! Double) + 5))
    // Keep the grab offset from the knob to its caret; the finger sits below the selected row.
    let target = point(column: 22, row: 1).withOffset(CGVector(dx: 0, dy: (endpoint["h"] as! Double) * 0.5 + 5))
    handle.press(forDuration: 0.15, thenDragTo: target)
    XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
    XCTAssertTrue((state()["text"] as? String ?? "").contains("and copy"), "End handle must extend into the next row: \(state())")
    point(column: 25, row: 8).tap()
    expect("state", "none")
    XCTAssertFalse(app.buttons["Copy"].exists)
  }

  func testHistoryScrollThenSelection() {
    let top = state()["top"] as! Int
    app.webViews.firstMatch.swipeDown(velocity: .slow)
    let scrolled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (self.state()["top"] as? Int ?? top) < top }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [scrolled], timeout: 5), .completed)
    app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4)).press(forDuration: 0.8)
    XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
    XCTAssertFalse((state()["text"] as? String ?? "").isEmpty)
    app.buttons["Copy"].tap()
    expect("state", "none")
    XCTAssertFalse((state()["copied"] as? String ?? "").isEmpty)
  }

  func testLandscapeAndNormalTap() {
    XCUIDevice.shared.orientation = .landscapeLeft
    Thread.sleep(forTimeInterval: 0.5)
    point().press(forDuration: 0.8)
    XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
    app.buttons["Copy"].tap()
    expect("copied", "Select")
    point(column: 5, row: 5).tap()
    let tapped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.state()["inputTaps"] as? Int == 1 }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [tapped], timeout: 5), .completed, "Short taps must still reach the input row")
  }
}
