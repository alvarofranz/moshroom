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

import SwiftUI
import UIKit


class SettingsHostingController: UIHostingController<NavView<SettingsView>>, UIAdaptivePresentationControllerDelegate {
  private let onDismiss: (() -> Void)?

  private init(navController: UINavigationController, onDismiss: (() -> Void)? = nil) {
    self.onDismiss = onDismiss

    let rootView = NavView(navController: navController) {
      SettingsView()
    }

    super.init(rootView: rootView)

    navController.presentationController?.delegate = self
  }

  @MainActor @objc required dynamic init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    // The house white-chip ✕ — same close as every other full-screen hub.
    navigationItem.rightBarButtonItem = moshNavChipBarItem(
      icon: "xmark", target: self, action: #selector(_closeSettings))
  }

  // Not `_close`: that selector name collides with a private Apple API and App Store upload rejects it.
  @objc private func _closeSettings() {
    dismiss(animated: false) { [onDismiss] in onDismiss?() }   // instant, no slide (house style)
  }

  // Delegate method called when the modal is dismissed
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    onDismiss?()
  }

  static func createSettings(nav: UINavigationController, onDismiss: (() -> Void)? = nil) -> UIViewController {
    return SettingsHostingController(navController: nav, onDismiss: onDismiss)
  }
}
