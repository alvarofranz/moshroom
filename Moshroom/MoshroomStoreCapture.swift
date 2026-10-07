// Copyright (C) 2026 Moshroom. Licensed under GPLv3; see COPYING.

import UIKit
import SwiftUI

// A development-only, memory-only catalog of the real presentation components. No sessions,
// hosts, secrets, cloud observers or network clients are loaded for this launch mode.
@objc final class MoshroomStoreCaptureMode: NSObject {
  @objc static var enabled: Bool {
    #if MOSHROOM_PUBLISHING_OPTION_DEVELOPER
    return ProcessInfo.processInfo.arguments.contains("-moshroom-store-capture")
    #else
    return false
    #endif
  }
}

#if MOSHROOM_PUBLISHING_OPTION_DEVELOPER
final class MoshroomStoreCaptureController: UIViewController {
  private var terminal: TermView?
  private var readyTimer: Timer?
  private let device = TermDevice()
  private let inertOwner = SpaceController()
  private let sceneName = ProcessInfo.processInfo.environment["MOSHROOM_STORE_SCENE"] ?? "terminal"
  private var installed = false
  override var prefersStatusBarHidden: Bool { true }
  override var prefersHomeIndicatorAutoHidden: Bool { true }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    view.backgroundColor = .moshroomBackground
    view.accessibilityIdentifier = "store.capture." + sceneName
    if sceneName == "composer" || sceneName == "tools" || sceneName == "typing" { return }
    let area = installChrome(terminal: sceneName == "terminal")
    if sceneName == "connect" {
      let card = MoshnectorView()
      card.storeProjects = ["atlas": [
        MoshProject(name: "Orbit", folder: "~/projects/orbit", command: "opencode", session: "orbit"),
        MoshProject(name: "Website", folder: "~/projects/website", command: "", session: "website")
      ]]
      card.reload(hosts: [("atlas", "Development · projects & agents"), ("studio", "Creative tools & media")])
      card.isUserInteractionEnabled = false
      view.addSubview(card)
      let width = card.widthAnchor.constraint(equalTo: area.widthAnchor, constant: -28)
      width.priority = .defaultHigh
      NSLayoutConstraint.activate([card.centerXAnchor.constraint(equalTo: area.centerXAnchor),
        card.centerYAnchor.constraint(equalTo: area.centerYAnchor), width,
        card.widthAnchor.constraint(lessThanOrEqualToConstant: 480)])
    } else if sceneName == "files" {
      let files = MoshxploreView()
      area.addSubview(files)
      pin(files, in: area)
      files.showStoreCapture()
    } else {
      let state = TermUIState()
      state.themeName = "Default"
      state.fontName = "JetBrains Mono"
      state.fontSize = UIDevice.current.userInterfaceIdiom == .phone ? 13 : 16
      let term = TermView(frame: .zero, termUIState: state)
      terminal = term
      term.translatesAutoresizingMaskIntoConstraints = false
      area.addSubview(term)
      pin(term, in: area)
      device.attachView(term)
      term.load()
      readyTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
        guard let self, term.isReady else { return }
        timer.invalidate()
        term.write(Self.transcript)
        term.setCursorBlink(false)
        self.view.accessibilityValue = "Ready"
      }
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !installed else { return }
    installed = true
    if sceneName == "composer" {
      let composer = MoshkitorComposer(device: device, tabKey: nil, seed: "Improve the Orbit dashboard.\n\n• Make the navigation easier to use.\n• Add a clear empty state.\n• Keep the layout responsive.\n\nRun the tests and summarize your changes.")
      embed(composer)
    } else if sceneName == "tools" {
      embed(MoshlauncherController())
    } else if sceneName == "typing" {
      let model = MoshtourModel(countHosts: { 0 })
      model.step = 3
      embed(MoshtourController(model: model))
    }
  }

  private func embed(_ controller: UIViewController) {
    addChild(controller)
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controller.view)
    pin(controller.view, in: view)
    controller.didMove(toParent: self)
    // The catalog is for rendering only. Its controls must never open private data or write.
    controller.view.isUserInteractionEnabled = false
  }

  private func pin(_ child: UIView, in parent: UIView) {
    NSLayoutConstraint.activate([child.topAnchor.constraint(equalTo: parent.topAnchor),
      child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
      child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
      child.trailingAnchor.constraint(equalTo: parent.trailingAnchor)])
  }

  private func installChrome(terminal: Bool) -> UIView {
    let tabs = moshkeyRoundButton()
    tabs.setMoshIcon("rectangle.stack")
    let launcher = moshkeyRoundButton()
    launcher.setMoshIcon("square.grid.2x2")
    let area = UIView()
    area.translatesAutoresizingMaskIntoConstraints = false
    [area, tabs, launcher].forEach(view.addSubview)
    let guide = view.safeAreaLayoutGuide
    #if targetEnvironment(macCatalyst)
    let bottom: CGFloat = 0
    #else
    let bottom: CGFloat = 56
    if sceneName != "files" {
      let compose = moshkeyRoundButton()
      compose.setMoshIcon("square.and.pencil")
      view.addSubview(compose)
      NSLayoutConstraint.activate([compose.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -14),
        compose.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -10)])
      if terminal {
        let keys = MoshkeysBar(spaceController: inertOwner)
        keys.translatesAutoresizingMaskIntoConstraints = false
        keys.isUserInteractionEnabled = false
        view.addSubview(keys)
        NSLayoutConstraint.activate([keys.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 14),
          keys.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -10)])
      }
    }
    #endif
    NSLayoutConstraint.activate([
      tabs.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 14),
      tabs.topAnchor.constraint(equalTo: guide.topAnchor, constant: 10),
      launcher.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -14),
      launcher.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
      area.topAnchor.constraint(equalTo: guide.topAnchor, constant: 76),
      area.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
      area.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
      area.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -bottom)
    ])
    if terminal {
      let label = MoshroomTabLabel()
      label.text = "atlas · orbit"
      label.isHidden = false
      label.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(label)
      NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: tabs.trailingAnchor, constant: 10),
        label.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
        label.trailingAnchor.constraint(lessThanOrEqualTo: launcher.leadingAnchor, constant: -8)])
    }
    return area
  }

  private static let transcript = "\u{1b}c\u{1b}[?25l" + [
    "\u{1b}[38;5;245mdev@atlas  ~/projects/orbit\u{1b}[0m", "",
    "\u{1b}[1;97m$ git status --short\u{1b}[0m",
    " \u{1b}[38;5;114mM\u{1b}[0m src/dashboard.tsx",
    " \u{1b}[38;5;114mM\u{1b}[0m src/components/navigation.tsx",
    " \u{1b}[38;5;114mA\u{1b}[0m tests/dashboard.test.ts", "",
    "\u{1b}[1;97m$ npm test\u{1b}[0m", "",
    "\u{1b}[38;5;114m PASS\u{1b}[0m  tests/dashboard.test.ts",
    "  ✓ renders the project overview",
    "  ✓ keeps navigation accessible",
    "  ✓ adapts to smaller screens", "",
    "\u{1b}[38;5;114m PASS\u{1b}[0m  tests/navigation.test.ts",
    "  ✓ switches between workspaces",
    "  ✓ restores the active project", "",
    "\u{1b}[38;5;245mTest files\u{1b}[0m  \u{1b}[38;5;114m2 passed\u{1b}[0m",
    "\u{1b}[38;5;245m     Tests\u{1b}[0m  \u{1b}[38;5;114m5 passed\u{1b}[0m", "",
    "\u{1b}[1;97m$ git diff --stat\u{1b}[0m",
    " dashboard.tsx    | 42 \u{1b}[38;5;114m++++++++\u{1b}[38;5;203m---\u{1b}[0m",
    " navigation.tsx   | 18 \u{1b}[38;5;114m++++\u{1b}[38;5;203m--\u{1b}[0m",
    " dashboard.test.ts| 36 \u{1b}[38;5;114m++++++++\u{1b}[0m", "",
    "\u{1b}[38;5;245mReady for your next idea.\u{1b}[0m", "",
    "\u{1b}[38;5;203m❯\u{1b}[0m "
  ].joined(separator: "\r\n")

  deinit { readyTimer?.invalidate(); terminal?.terminate() }
}
#endif
