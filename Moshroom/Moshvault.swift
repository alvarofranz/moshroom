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
import SwiftUI

// Moshvault — the credentials hub, opened from the key button in the top bar (between Moshxplore and
// Settings). Full screen over the current tab, like Moshxplore and Settings, and mutually exclusive
// with Quick Connect / Moshxplore (only one modal is ever up). Hosts the SwiftUI MoshvaultRootView.
final class MoshvaultController: UIHostingController<MoshvaultRootView> {
  weak var space: SpaceController?

  init() {
    super.init(rootView: MoshvaultRootView(onClose: {}))
    // The close handler needs `self`, so rebuild the root once it exists.
    rootView = MoshvaultRootView(onClose: { [weak self] in self?.space?.dismissMoshvault() })
  }

  @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    // Opaque background: presented .overFullScreen, so the terminal must not show through.
    view.backgroundColor = .systemGroupedBackground
  }
}

extension SpaceController {
  private var moshvaultController: MoshvaultController? {
    presentedViewController as? MoshvaultController
  }

  // True while Moshvault is on screen — Quick Connect checks this so the two never overlap.
  var moshroomMoshvaultIsOpen: Bool { moshvaultController != nil }

  // Open Moshvault full screen over the current tab. Works on any tab; needs no shell/connection.
  func openMoshvault() {
    guard presentedViewController == nil else { return }
    dismissMoshnector()
    view.subviews.compactMap({ $0 as? MoshkeysBar }).first?.closeIfOpen()
    let ctrl = MoshvaultController()
    ctrl.space = self
    // .overFullScreen keeps the terminal in the window (see openMoshkitor).
    ctrl.modalPresentationStyle = .overFullScreen
    present(ctrl, animated: false)   // instant, no slide (see SpaceController.dismiss)
  }

  func dismissMoshvault() {
    guard let ctrl = moshvaultController else { return }
    ctrl.dismiss(animated: true) { [weak self] in
      guard let self, Moshroom.scratchOnly else { return }
      // Reclaim first responder for hardware-keyboard routing (same restore Moshxplore/Moshkitor do),
      // then let Quick Connect reappear if this is a fresh idle prompt.
      self.becomeFirstResponder()
      self.showMoshnectorIfIdle()
    }
  }
}
