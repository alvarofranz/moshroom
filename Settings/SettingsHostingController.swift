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


class SettingsHostingController: UIHostingController<NavView<SettingsView>> {
  private let onClose: () -> Void
  private let navController: UINavigationController

  private init(navController: UINavigationController, onClose: @escaping () -> Void) {
    self.onClose = onClose
    self.navController = navController

    let rootView = NavView(navController: navController) {
      SettingsView(onClose: {})
    }

    super.init(rootView: rootView)
  }

  @MainActor @objc required dynamic init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    // No system nav bar / UIKit close button: Settings draws its own in-content header (the house ✕
    // lives there). Closing dismisses the whole modal stack (launcher + Settings) back to the terminal
    // in one shot, no flash — `onClose` is wired to SpaceController.dismiss in showConfigAction.
    rootView = NavView(navController: navController) {
      SettingsView(onClose: { [weak self] in self?.onClose() })
    }
  }

  static func createSettings(nav: UINavigationController, onClose: @escaping () -> Void) -> UIViewController {
    return SettingsHostingController(navController: nav, onClose: onClose)
  }
}
