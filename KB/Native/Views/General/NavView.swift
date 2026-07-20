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

class Nav: ObservableObject {
  let navController: UINavigationController
  
  init(navController: UINavigationController) {
    self.navController = navController
  }  
}

struct NavView<Content: View>: View {
  var content: () -> Content
  let nav: Nav

  init(navController: UINavigationController, content: @escaping () -> Content) {
    self.content = content
    self.nav = Nav(navController: navController)
  }

  var body: some View {
    content().environmentObject(nav)
  }
}

extension View {
  /// On Mac Catalyst a SwiftUI `Button`/`Menu` adopts the native macOS bordered chrome — a gray
  /// capsule with extra padding — that clashes with the flat, tinted glyphs the app uses on
  /// iPhone/iPad (see the Settings ▸ Keys / Host screens). `.borderless` restores the iOS look.
  /// No-op on iOS, where buttons are already borderless. Set on containers (it propagates through
  /// the environment) and directly on nav-bar buttons, which don't inherit it.
  @ViewBuilder func moshCatalystPlainButtons() -> some View {
    #if targetEnvironment(macCatalyst)
    self.buttonStyle(BorderlessButtonStyle())
    #else
    self
    #endif
  }
}

extension View {
  /// Caps full-screen list/form content at a readable column on big canvases (iPad 13", Mac) —
  /// the same 640pt column the launcher and Quick Connect use. The sides match the grouped-list
  /// background so the cap reads as margins, not bands.
  func moshReadableWidth() -> some View {
    self
      .frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
      .background(Color(UIColor.systemGroupedBackground))
  }
}

// MARK: - Moshroom nav-bar house style

/// The house style for every SwiftUI nav-bar button: a white round chip with near-black ink —
/// the same look as the floating quick keys (`moshkeyRoundButton` in Moshkeys.swift), so buttons
/// read identically on iOS and Mac.
enum MoshNavChip {
  static let fill = Color(Moshstyle.chipFill)
  static let ink = Color(Moshstyle.ink)
  static let diameter: CGFloat = 34
}

/// Circular white chip around a dark SF Symbol — for glyph nav-bar buttons (+, sort, ✕).
struct MoshNavGlyph: View {
  let systemName: String
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Image(systemName: systemName)
      .font(.system(size: 15, weight: .semibold))
      .foregroundColor(MoshNavChip.ink)
      .frame(width: MoshNavChip.diameter, height: MoshNavChip.diameter)
      .background(Circle().fill(MoshNavChip.fill))
      .opacity(isEnabled ? 1 : 0.4)
  }
}

/// White capsule around dark text — for text nav-bar buttons (Save, Cancel, Create…).
struct MoshNavLabel: View {
  let title: String
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Text(title)
      .font(.system(size: 15, weight: .semibold))
      .foregroundColor(MoshNavChip.ink)
      .padding(.horizontal, 14)
      .frame(height: MoshNavChip.diameter)
      .background(Capsule().fill(MoshNavChip.fill))
      .opacity(isEnabled ? 1 : 0.4)
  }
}

/// One nav-bar toolbar item that never gets the system's shared glass platter. Since the iOS 26
/// SDK, bare bar items are wrapped in a system capsule that renders mis-padded on Mac Catalyst
/// (glyphs pinned high inside a taller pill) — the house chips above carry their own background,
/// so the platter is hidden and the buttons draw the same everywhere. Also applies the Catalyst
/// borderless fix so Mac never adds its own bordered chrome on top.
struct MoshNavBarItem<Content: View>: ToolbarContent {
  let placement: ToolbarItemPlacement
  @ViewBuilder let content: () -> Content

  var body: some ToolbarContent {
    if #available(iOS 26.0, *) {
      ToolbarItem(placement: placement) { content().moshCatalystPlainButtons() }
        .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: placement) { content().moshCatalystPlainButtons() }
    }
  }
}

// MARK: - Full-screen hub chrome (in-content header, no system nav bar)
//
// Every full-screen surface (launcher, Moshtabs, Moshxplore, Moshvault, and all of Settings) drops the
// system navigation bar and draws a compact header IN the content. On Mac Catalyst a system nav bar
// grows the window title bar, so the traffic lights / title jump when a screen opens or pushes; keeping
// the chrome in-content keeps the title bar exactly as compact as the terminal, everywhere. Use
// `.moshHubChrome` (root, with a ✕ close) or `.moshHubChromeBack` (a pushed screen, with a ‹ back).

/// A back ‹ chip that pops the shared UIKit nav stack — the leading button for a pushed hub screen.
struct MoshHubBackButton: View {
  @EnvironmentObject private var nav: Nav
  var body: some View {
    Button { nav.navController.popViewController(animated: true) } label: {
      MoshNavGlyph(systemName: "chevron.left")
    }
    .buttonStyle(.plain)
    .moshCatalystPlainButtons()
    .accessibilityLabel("Back")
  }
}

/// The compact in-content header: a centred title, a leading button (✕ close on a root, ‹ back on a
/// pushed screen) and optional trailing actions (Save, +, sort…). Sits on the grouped background so it
/// blends with the list beneath it, exactly like the launcher / Moshvault headers.
struct MoshHubHeader<Leading: View, Trailing: View>: View {
  let title: String
  @ViewBuilder var leading: () -> Leading
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    ZStack {
      Text(title)
        .font(.system(size: 17, weight: .semibold))
        .foregroundColor(.primary)
        .lineLimit(1)
      HStack(spacing: 8) {
        leading()
        Spacer()
        trailing()
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity)
    .background(Color(UIColor.systemGroupedBackground))
  }
}

extension View {
  /// Hide this screen's system nav bar and dock a compact in-content header on top.
  func moshHubChrome<Leading: View, Trailing: View>(
    title: String,
    @ViewBuilder leading: @escaping () -> Leading,
    @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
  ) -> some View {
    self
      .navigationBarBackButtonHidden(true)
      .toolbar(.hidden, for: .navigationBar)
      .safeAreaInset(edge: .top, spacing: 0) {
        MoshHubHeader(title: title, leading: leading, trailing: trailing)
      }
  }

  /// A pushed hub screen: leading = ‹ back (pops the shared nav stack).
  func moshHubChromeBack<Trailing: View>(
    title: String,
    @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
  ) -> some View {
    moshHubChrome(title: title, leading: { MoshHubBackButton() }, trailing: trailing)
  }
}

