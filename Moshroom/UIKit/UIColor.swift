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

extension UIColor {
  // Moshroom's accent — THE red-mushroom red (no blue/cyan anywhere in the app's own chrome).
  // One value everywhere: the asset is a single universal color, and this code fallback matches it.
  @objc class var moshroomTint: UIColor {
    return UIColor(named: "MoshroomColor") ??
    UIColor.init(displayP3Red: 0.878, green: 0.20, blue: 0.227, alpha: 1)
  }

  // The house near-black ground. MUST match the Default terminal theme's background
  // (Resources/Themes/Default.js: 'rgb(16, 16, 16)') — the strips around the viewport, the
  // zero-tabs empty state and every non-terminal tab page all rest on this value, so the
  // screen reads as ONE surface instead of bands meeting a different black.
  @objc class var moshroomBackground: UIColor {
    return UIColor(red: 16.0 / 255.0, green: 16.0 / 255.0, blue: 16.0 / 255.0, alpha: 1)
  }
}

extension Color {
  // The same accent for SwiftUI surfaces. ONE definition — never re-declare per file.
  static let moshTint = Color(UIColor.moshroomTint)
}

// The Moshroom house style, in one place. The app has exactly ONE theme (dark): full-screen
// surfaces use semantic colors (which always resolve dark), while the floating chrome —
// round quick keys, nav-bar chips, capsule buttons — is deliberately WHITE with near-black
// ink, the one bright accent over the dark app. These are the constants both worlds share.
enum Moshstyle {
  // The white chip: fill, ink and hairline — identical for every chip in the app.
  static let chipFill = UIColor(white: 0.97, alpha: 0.92)   // floating round buttons / nav chips
  static let padFill = UIColor(white: 0.97, alpha: 0.97)    // the bigger floating pads/cards
  static let chipFillOpaque = UIColor(white: 0.97, alpha: 1)
  static let ink = UIColor(white: 0.12, alpha: 1)
  static let hairline = UIColor(white: 0.8, alpha: 1)

  // Corner radius scale — pick by role, never a bare literal:
  // list rows (files, tracks, tabs) · tappable cards (hosts, launcher tiles) · floating overlays.
  static let rowRadius: CGFloat = 12
  static let cardRadius: CGFloat = 14
  static let overlayRadius: CGFloat = 18

  // The faint mushroom fill (progress tracks, inline chips) — one alpha everywhere.
  static let faintTintAlpha: CGFloat = 0.15

  // The house drop shadows: one for small floating chips, one for the bigger pads/overlays.
  static func applyChipShadow(_ layer: CALayer) {
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.18
    layer.shadowRadius = 4
    layer.shadowOffset = CGSize(width: 0, height: 1)
  }
  static func applyOverlayShadow(_ layer: CALayer) {
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.22
    layer.shadowRadius = 10
    layer.shadowOffset = CGSize(width: 0, height: 3)
  }
}

// Global appearance that can't be expressed per-view: the segmented switcher (Quick Connect's
// Mosh/SSH, Moshvault's Passwords/2FA, …) is mushroom-red with white text on the selected
// segment, everywhere, via the appearance proxy. Installed once from AppDelegate.
@objc final class MoshstyleAppearance: NSObject {
  @objc static func install() {
    let seg = UISegmentedControl.appearance()
    seg.selectedSegmentTintColor = .moshroomTint
    seg.setTitleTextAttributes([.foregroundColor: UIColor.white,
                                .font: UIFont.systemFont(ofSize: 14, weight: .semibold)],
                               for: .selected)
    seg.setTitleTextAttributes([.foregroundColor: UIColor.secondaryLabel], for: .normal)
  }
}
