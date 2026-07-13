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

import Foundation
import UIKit

// Moshroom runs keyboard-less (`Moshroom.scratchOnly`): `SmarterTermInput` never becomes first
// responder, so this on-screen smart-keyboard accessory is never displayed. Its whole render path —
// the three `KBSection`s, the scrolling key views, per-device `KBLayout`/`KBSizes`, the repeat
// timers and the `KBKeyViewDelegate` plumbing — was dead code and has been removed (along with the
// `KBKey*` / `KBSection` / `KBLayout` / `KBSizes` files). What remains is only the minimal surface
// that `SmarterTermInput` / `KBProxy` / `KBAccessoryView` still touch on the never-shown `kbView`.
class KBView: UIView {

  weak var keyInput: SmarterTermInput? = nil
  var lang: String = ""
  var traits: KBTraits = .initial
  var kbDevice: KBDevice = .detect()
  var safeBarWidth: CGFloat = 0

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: 0)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func turnOffUntracked() {}
  func stopRepeats() {}
}
