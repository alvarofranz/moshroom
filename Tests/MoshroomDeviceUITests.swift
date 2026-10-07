// Copyright (C) 2026 Moshroom. Licensed under GPLv3; see COPYING.

import XCTest
import UIKit

// Run the Moshroom Devices scheme on a trusted iPhone or iPad. The empty-host tour fixture
// disables setup actions and never marks the tour seen. Keyboard checks create a local tab,
// identify it by its new UUID, then close only that tab and restore the previous typing mode.
// They neither select a saved host nor send input to a restored terminal.
final class MoshroomDeviceUITests: XCTestCase {
  private let app = XCUIApplication()
  private var originalOrientation = UIDeviceOrientation.unknown
  private var originalMode: String?
  private var originalTab: String?
  private var localTab: String?

  override func setUpWithError() throws {
    continueAfterFailure = false
    originalOrientation = XCUIDevice.shared.orientation
    if app.state == .runningForeground {
      XCUIDevice.shared.press(.home)
      XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5),
                    "Let the app save its sessions before the test relaunches it")
    }
  }

  override func tearDownWithError() throws {
    if originalMode != nil || localTab != nil { restoreLocalTestState() }
    if app.buttons["tour.skip"].isHittable { app.buttons["tour.skip"].tap() }
    if originalOrientation != .unknown { XCUIDevice.shared.orientation = originalOrientation }
    // Background normally so existing sessions can save their state.
    XCUIDevice.shared.press(.home)
  }

  func testSoftwareKeyboardOnLocalTab() throws {
    app.launchArguments = ["-moshroom-welcome-tour", "-moshroom-tour-no-hosts"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    try tap("tour.next", timeout: 30)
    try tap("tour.next")
    try tap("tour.next")
    let choices = app.segmentedControls["tour.typing"]
    XCTAssertTrue(choices.waitForExistence(timeout: 5))
    originalMode = try XCTUnwrap(choices.buttons.allElementsBoundByIndex.first {
      ($0.value as? String) == "1" || $0.isSelected
    }?.label, "Save the existing mode before changing it")
    choices.buttons["Direct"].tap()
    try tap("tour.skip")
    try tap("navigation.tabs")
    let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tabs.select."))
    let existing = Set(tabs.allElementsBoundByIndex.map(\.identifier))
    originalTab = tabs.allElementsBoundByIndex.first { ($0.value as? String) == "Active" }?.identifier
    try tap("tabs.new")
    try tap("navigation.tabs")
    let created = Set(tabs.allElementsBoundByIndex.map(\.identifier)).subtracting(existing)
    XCTAssertEqual(created.count, 1, "Input must target exactly one newly created local shell")
    localTab = try XCTUnwrap(created.first)
    try tap(try XCTUnwrap(localTab))

    // The composer is reachable even on Quick Connect. Running local help dismisses that card
    // before any coordinate tap, so a terminal tap can never select one of the user's hosts.
    try tap("terminal.compose")
    let composer = app.textViews["composer.input"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.typeText("help")
    try tap("composer.send")
    XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))

    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      XCUIDevice.shared.orientation = orientation
      app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
      let keyboard = app.keyboards.firstMatch
      XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "The terminal tap must open the software keyboard")
      let input = app.textViews["terminal.input"]
      XCTAssertTrue(input.exists)
      XCTAssertGreaterThan(input.frame.height, 0)
      let hide = app.buttons["terminal.hideKeyboard"]
      let compose = app.buttons["terminal.openComposer"]
      let accessoryReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        hide.exists && hide.isHittable && compose.exists && compose.isHittable
      }, object: nil)
      let accessoryResult = XCTWaiter.wait(for: [accessoryReady], timeout: 5)
      let geometry = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      geometry.name = "keyboard-geometry-\(orientation == .portrait ? "portrait" : "landscape")"
      geometry.lifetime = .keepAlways
      add(geometry)
      XCTAssertEqual(accessoryResult, .completed, "Both accessory actions must be visible")
      XCTAssertTrue(hide.isHittable)
      XCTAssertTrue(compose.isHittable)
      XCTAssertLessThanOrEqual(input.frame.maxY, hide.frame.minY + 4,
                               "The terminal cursor must stay above the keyboard accessory")

      // Tap real on-screen keys: typeText can emulate hardware input and hide the accessory.
      for letter in ["h", "e", "l", "x"] { keyboard.keys[letter].tap() }
      keyboard.keys["delete"].tap()
      keyboard.keys["p"].tap()
      XCTAssertEqual(input.value as? String, "p", "Backspace creates a terminal editing barrier")
      let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      capture.name = "direct-keyboard-\(orientation == .portrait ? "portrait" : "landscape")"
      capture.lifetime = .keepAlways
      add(capture)

      compose.tap()
      XCTAssertTrue(composer.waitForExistence(timeout: 5))
      composer.typeText("draft only")
      XCTAssertEqual(composer.value as? String, "draft only")
      try tap("composer.close")
      XCTAssertTrue(hide.waitForExistence(timeout: 5), "Closing the composer must restore terminal focus")
      hide.tap()
      // This local tab is discarded below; the draft is deliberately never sent.
      if orientation == .portrait {
        try tap("terminal.compose")
        composer.tap()
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "draft only".count))
        try tap("composer.close")
      }
    }
  }

  func testWelcomeTourAccessibility() throws {
    try auditWelcomeTour(contentSize: nil)
  }

  func testWelcomeTourLargestText() throws {
    try auditWelcomeTour(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
  }

  private func auditWelcomeTour(contentSize: String?) throws {
    app.launchArguments = ["-moshroom-welcome-tour", "-moshroom-tour-no-hosts"]
    if let contentSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(app.staticTexts["tour.title"].waitForExistence(timeout: 30))
    for page in 1...6 {
      // The tour crossfades for 0.3 s. XCTest can report idle while SwiftUI's outgoing
      // accessibility nodes still exist; measure the settled page, including large text.
      Thread.sleep(forTimeInterval: 0.5)
      if contentSize != nil {
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "tour-largest-text-\(page)"
        capture.lifetime = .keepAlways
        add(capture)
      }
      try app.performAccessibilityAudit(for: [.dynamicType, .textClipped, .sufficientElementDescription])
      if page < 6 { try tap("tour.next") }
    }
  }

  func testStoreScreenshots() throws {
    XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
    for scene in ["terminal", "composer", "connect", "files", "tools", "typing"] {
      app.launchArguments = ["-moshroom-store-capture", "-moshroom-tour-no-hosts"]
      app.launchEnvironment = ["MOSHROOM_STORE_SCENE": scene]
      app.launch()
      XCTAssertTrue(app.otherElements["store.capture." + scene].waitForExistence(timeout: 30))
      if scene == "terminal" {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Ready"),
          object: app.otherElements["store.capture." + scene])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
      }
      if scene == "composer" { XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10)) }
      // Wait for native keyboard and WebKit rendering to reach their final presentation frame.
      Thread.sleep(forTimeInterval: 1.5)
      let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      capture.name = "store-" + scene
      capture.lifetime = .keepAlways
      add(capture)
      XCUIDevice.shared.press(.home)
    }
  }

  private func tap(_ identifier: String, timeout: TimeInterval = 5) throws {
    let button = app.buttons[identifier]
    XCTAssertTrue(button.waitForExistence(timeout: timeout), "Missing control: \(identifier)")
    XCTAssertTrue(button.isHittable, "Unreachable control: \(identifier)")
    button.tap()
  }

  private func restoreLocalTestState() {
    continueAfterFailure = true
    // No fallback coordinates or positional closes: only the UUID created by this test may close.
    if app.buttons["composer.close"].exists { app.buttons["composer.close"].tap() }
    if app.buttons["tour.skip"].exists { app.buttons["tour.skip"].tap() }
    if app.buttons["terminal.hideKeyboard"].isHittable { app.buttons["terminal.hideKeyboard"].tap() }
    if let localTab {
      if app.buttons["navigation.tabs"].isHittable { app.buttons["navigation.tabs"].tap() }
      let close = app.buttons[localTab.replacingOccurrences(of: "tabs.select.", with: "tabs.close.")]
      if close.waitForExistence(timeout: 3), close.isHittable { close.tap() }
      else { XCTFail("The local test tab still needs cleanup: \(localTab)") }
      if let originalTab, app.buttons[originalTab].isHittable { app.buttons[originalTab].tap() }
      else if app.buttons["Close"].isHittable { app.buttons["Close"].tap() }
    }
    var restoredMode = originalMode == nil
    if let originalMode, app.buttons["navigation.launcher"].isHittable {
      app.buttons["navigation.launcher"].tap()
      let settings = app.buttons["launcher.settings"]
      if settings.waitForExistence(timeout: 3), settings.isHittable {
        settings.tap()
        let picker = app.descendants(matching: .any).matching(identifier: "settings.typing").firstMatch
        if picker.waitForExistence(timeout: 3), picker.isHittable {
          picker.tap()
          let choice = app.buttons[originalMode]
          if choice.waitForExistence(timeout: 3), choice.isHittable {
            choice.tap()
            restoredMode = true
          }
        }
      }
    }
    XCTAssertTrue(restoredMode, "Restore the device typing preference to \(originalMode ?? "its initial value")")
  }

  func testWelcomeTourOnDevice() throws {
    app.launchArguments = ["-moshroom-welcome-tour", "-moshroom-tour-no-hosts"]
    app.launch()
    XCTAssertTrue(app.staticTexts["tour.title"].waitForExistence(timeout: 30),
                  "Unlock the device and complete any system trust or authentication prompts.")

    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      XCUIDevice.shared.orientation = orientation
      let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { [app] _, _ in
        let frame = app.windows.firstMatch.frame
        return frame.width > 0 && (frame.width > frame.height) == orientation.isLandscape
      }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 10), .completed,
                     "The app must actually rotate before checking its layout")
      for page in 1...6 {
        let title = app.staticTexts["tour.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertFalse(title.label.isEmpty)
        XCTAssertTrue(app.descendants(matching: .any).matching(
          NSPredicate(format: "label == %@", "Page \(page) of 6")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tour.skip"].isHittable, "The close control must remain reachable")
        XCTAssertTrue(app.buttons["tour.next"].isHittable, "The footer must fit the device")
        if page > 1 { XCTAssertTrue(app.buttons["tour.back"].isHittable) }

        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "tour-\(orientation == .portrait ? "portrait" : "landscape")-\(page)"
        capture.lifetime = .keepAlways
        add(capture)

        if page < 6 { app.buttons["tour.next"].tap() }
      }
      XCTAssertTrue(app.buttons["tour.add-host"].exists)
      XCTAssertFalse(app.buttons["tour.add-host"].isEnabled,
                     "The presentation-only empty fixture must not write to saved hosts")
      if orientation == .portrait {
        for _ in 0..<5 { app.buttons["tour.back"].tap() }
      }
    }
  }
}
