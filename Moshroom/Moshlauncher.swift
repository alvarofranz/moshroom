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

// Moshlauncher — one apps-grid button in the top bar (right side) opens this launcher instead of a
// row of separate buttons. It shows a card per destination (Moshxplore, Moshvault, Settings) with a
// label and a one-line description. Full-width stacked cards on iPhone; a grid of square cards on
// iPad and Mac. Tapping a card dismisses the launcher and opens that destination (only one
// full-screen surface is ever up at a time).

struct MoshLauncherItem: Identifiable {
  let id: String
  let icon: String
  let title: String
  let subtitle: String
  let action: () -> Void
}

final class MoshlauncherController: UIHostingController<MoshlauncherView> {
  weak var space: SpaceController?

  init() {
    super.init(rootView: MoshlauncherView(items: [], onClose: {}))
  }

  @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground   // opaque over the terminal (.overFullScreen)
    // Build the cards now that `space` is set (openMoshlauncher assigns it before presenting).
    rootView = MoshlauncherView(items: _items(), onClose: { [weak self] in self?.space?.dismissMoshlauncher() })
  }

  private func _items() -> [MoshLauncherItem] {
    [
      MoshLauncherItem(id: "moshxplore", icon: "folder", title: "Moshxplore",
                       subtitle: "Browse, preview and edit files on your servers.") { [weak space] in
        space?.openMoshxploreTab()
      },
      MoshLauncherItem(id: "moshify", icon: "music.note", title: "Moshify",
                       subtitle: "Your music, played from your own server.") { [weak space] in
        space?.openMoshifyTab()
      },
      MoshLauncherItem(id: "moshvault", icon: "key.fill", title: "Moshvault",
                       subtitle: "Your passwords and 2FA codes, synced securely.") { [weak space] in
        space?.openMoshvault()
      },
      MoshLauncherItem(id: "settings", icon: "gearshape.fill", title: "Settings",
                       subtitle: "Keys, hosts, terminal, security and iCloud sync.") { [weak space] in
        space?.openSettings()
      },
    ]
  }
}

struct MoshlauncherView: View {
  let items: [MoshLauncherItem]
  let onClose: () -> Void

  @Environment(\.horizontalSizeClass) private var hSize

  private var tint: Color { .moshTint }
  private var cardBackground: Color { Color(UIColor.secondarySystemGroupedBackground) }

  var body: some View {
    // No NavigationStack / system nav bar on purpose: a nav bar makes Mac Catalyst grow the window
    // title bar, which shoves the traffic lights and title DOWN when the launcher opens (the chrome
    // "jumps" and the view looks less compact). Drawing our own in-content header keeps the title bar
    // exactly as compact as the terminal and Moshvault. The close ✕ sits top-RIGHT, the same spot as
    // the top-bar button that opened the launcher, so it reads as the same control toggling.
    VStack(spacing: 0) {
      HStack {
        Text("Moshroom")
          .font(.system(size: 17, weight: .semibold))
          .foregroundColor(.primary)
        Spacer()
        Button(action: onClose) { MoshNavGlyph(systemName: "xmark") }
          .buttonStyle(.plain)
          .accessibilityLabel("Close")
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      ScrollView {
        if hSize == .compact {
          // iPhone: full-width cards, stacked.
          VStack(spacing: 14) {
            ForEach(items) { wideCard($0) }
          }
          .padding(20)
          .frame(maxWidth: 640)
          .frame(maxWidth: .infinity)
        } else {
          // iPad / Mac: a grid of square cards.
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 18)], spacing: 18) {
            ForEach(items) { squareCard($0) }
          }
          .padding(28)
          .frame(maxWidth: 900)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .tint(tint)
  }

  private func iconBadge(_ name: String) -> some View {
    Image(systemName: name)
      .font(.system(size: 22, weight: .semibold))
      .foregroundColor(.white)
      .frame(width: 48, height: 48)
      .background(tint)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func wideCard(_ item: MoshLauncherItem) -> some View {
    Button(action: item.action) {
      HStack(spacing: 16) {
        iconBadge(item.icon)
        VStack(alignment: .leading, spacing: 3) {
          Text(item.title).font(.headline).foregroundColor(.primary)
          Text(item.subtitle).font(.subheadline).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold)).foregroundColor(.secondary.opacity(0.6))
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(cardBackground)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private func squareCard(_ item: MoshLauncherItem) -> some View {
    Button(action: item.action) {
      VStack(alignment: .leading, spacing: 10) {
        iconBadge(item.icon)
        Spacer(minLength: 6)
        Text(item.title).font(.headline).foregroundColor(.primary)
        Text(item.subtitle).font(.subheadline).foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(20)
      .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
      .background(cardBackground)
      .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}

extension SpaceController {
  private var moshlauncherController: MoshlauncherController? {
    presentedViewController as? MoshlauncherController
  }

  // True while the launcher is on screen — Quick Connect checks this so the two never overlap.
  var moshroomMoshlauncherIsOpen: Bool { moshlauncherController != nil }

  // The topmost presented controller. A launcher destination is presented ON TOP of the launcher
  // (over this) instead of dismissing the launcher first — dismiss-then-present flashed the terminal
  // for a frame in between. Closing a destination dismisses the whole stack at once (see the closes).
  // Open the launcher full screen. Works on any tab; needs no shell/connection.
  func openMoshlauncher() {
    moshroomPresentFullScreen(from: self) {
      let ctrl = MoshlauncherController()
      ctrl.space = self
      return ctrl
    }
  }

  // Dismiss the launcher, then run `then` (used to open a chosen destination once the launcher is
  // gone — only one full-screen surface may be presented at a time). With no `then`, restore first
  // responder + Quick Connect like the other hubs do.
  func dismissMoshlauncher(then: (() -> Void)? = nil) {
    guard let ctrl = moshlauncherController else { then?(); return }
    ctrl.dismiss(animated: false) { [weak self] in
      guard let self else { return }
      if let then {
        then()
      } else if Moshroom.scratchOnly {
        self.becomeFirstResponder()
        self.showMoshnectorIfIdle()
      }
    }
  }
}
