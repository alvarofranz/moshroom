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
// row of separate buttons. It shows a card per destination (Moshxplore, Moshify, Moshvault, Settings) with a
// label and a one-line description. Full-width stacked cards on iPhone; a grid of square cards on
// iPad and Mac. Tapping a card dismisses the launcher and opens that destination (only one
// full-screen surface is ever up at a time).

struct MoshLauncherItem: Identifiable {
  let id: String
  let icon: String
  let motif: MoshArtMotif
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
    view.backgroundColor = .black   // opaque over the terminal (.overFullScreen); the view paints its own ground
    // Build the cards now that `space` is set (openMoshlauncher assigns it before presenting).
    rootView = MoshlauncherView(items: _items(), onClose: { [weak self] in self?.space?.dismissMoshlauncher() })
  }

  private func _items() -> [MoshLauncherItem] {
    [
      MoshLauncherItem(id: "moshxplore", icon: "folder", motif: .cluster, title: "Moshxplore",
                       subtitle: "Browse, preview and edit files on your servers.") { [weak space] in
        space?.openMoshxploreTab()
      },
      MoshLauncherItem(id: "moshify", icon: "music.note", motif: .sound, title: "Moshify",
                       subtitle: "Your music, played from your own server.") { [weak space] in
        space?.openMoshifyTab()
      },
      MoshLauncherItem(id: "moshvault", icon: "key.fill", motif: .keyhole, title: "Moshvault",
                       subtitle: "Your passwords and 2FA codes, synced securely.") { [weak space] in
        space?.openMoshvault()
      },
      MoshLauncherItem(id: "settings", icon: "gearshape.fill", motif: .gills, title: "Settings",
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

  var body: some View {
    // No NavigationStack / system nav bar on purpose: a nav bar makes Mac Catalyst grow the window
    // title bar, which shoves the traffic lights and title DOWN when the launcher opens (the chrome
    // "jumps" and the view looks less compact). Drawing our own in-content header keeps the title bar
    // exactly as compact as the terminal and Moshvault. The close ✕ sits top-RIGHT, the same spot as
    // the top-bar button that opened the launcher, so it reads as the same control toggling.
    VStack(spacing: 0) {
      HStack(spacing: 9) {
        MoshMushroomGlyph(style: .solid)
          .frame(width: 20, height: 22)
          .accessibilityHidden(true)
        Text("Moshroom")
          .font(.system(size: 17, weight: .semibold))
          .foregroundColor(.white)
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
            ForEach(items) { MoshLauncherCard(item: $0, compact: true) }
          }
          .padding(20)
          .frame(maxWidth: 640)
          .frame(maxWidth: .infinity)
        } else {
          // iPad / Mac: a TWO-column grid, always. An adaptive grid packed as many cards as fitted
          // and left the remainder dangling (three across, one alone underneath); two columns keep
          // every row balanced and the block centred, whatever the window width.
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 2), spacing: 18) {
            ForEach(items) { MoshLauncherCard(item: $0, compact: false) }
          }
          .padding(28)
          .frame(maxWidth: 760)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .background(MoshLauncherGround().ignoresSafeArea())
    .tint(.moshTint)
  }
}

// MARK: ART-BEGIN
// MARK: - The launcher's look
//
// One family for the four cards: a near-black ground that burns into the house red at one corner,
// white type, and a mushroom drawn in code (vector shapes, no image assets) sitting in that corner
// like a watermark. Each destination has its own motif on the same mushroom.

enum MoshArtMotif { case cluster, sound, keyhole, gills }

private enum MoshLauncherPalette {
  static let ember = Color(red: 0.878, green: 0.200, blue: 0.227)      // the house red
  static let deep = Color(red: 0.400, green: 0.055, blue: 0.075)
  static let coal = Color(red: 0.070, green: 0.066, blue: 0.070)
  static let night = Color(red: 0.035, green: 0.033, blue: 0.036)
}

/// The page behind the cards: black, with the red rising faintly from two corners.
struct MoshLauncherGround: View {
  var body: some View {
    ZStack {
      MoshLauncherPalette.night
      RadialGradient(colors: [MoshLauncherPalette.ember.opacity(0.20), .clear],
                     center: .topTrailing, startRadius: 0, endRadius: 520)
      RadialGradient(colors: [MoshLauncherPalette.deep.opacity(0.35), .clear],
                     center: .bottomLeading, startRadius: 0, endRadius: 460)
    }
  }
}

// The mushroom, in a unit box: a domed cap over a tapered stem with a soft bulb and a skirt.
struct MoshCapShape: Shape {
  func path(in r: CGRect) -> Path {
    let w = r.width, h = r.height, x = r.minX, y = r.minY
    var p = Path()
    p.move(to: CGPoint(x: x + 0.02 * w, y: y + 0.50 * h))
    p.addCurve(to: CGPoint(x: x + 0.50 * w, y: y + 0.03 * h),
               control1: CGPoint(x: x + 0.02 * w, y: y + 0.23 * h), control2: CGPoint(x: x + 0.23 * w, y: y + 0.03 * h))
    p.addCurve(to: CGPoint(x: x + 0.98 * w, y: y + 0.50 * h),
               control1: CGPoint(x: x + 0.77 * w, y: y + 0.03 * h), control2: CGPoint(x: x + 0.98 * w, y: y + 0.23 * h))
    p.addCurve(to: CGPoint(x: x + 0.02 * w, y: y + 0.50 * h),
               control1: CGPoint(x: x + 0.80 * w, y: y + 0.60 * h), control2: CGPoint(x: x + 0.20 * w, y: y + 0.60 * h))
    p.closeSubpath()
    return p
  }
}

struct MoshStemShape: Shape {
  func path(in r: CGRect) -> Path {
    let w = r.width, h = r.height, x = r.minX, y = r.minY
    var p = Path()
    p.move(to: CGPoint(x: x + 0.415 * w, y: y + 0.572 * h))
    p.addCurve(to: CGPoint(x: x + 0.355 * w, y: y + 0.90 * h),
               control1: CGPoint(x: x + 0.435 * w, y: y + 0.70 * h), control2: CGPoint(x: x + 0.355 * w, y: y + 0.79 * h))
    p.addCurve(to: CGPoint(x: x + 0.50 * w, y: y + 0.975 * h),
               control1: CGPoint(x: x + 0.355 * w, y: y + 0.95 * h), control2: CGPoint(x: x + 0.42 * w, y: y + 0.975 * h))
    p.addCurve(to: CGPoint(x: x + 0.645 * w, y: y + 0.90 * h),
               control1: CGPoint(x: x + 0.58 * w, y: y + 0.975 * h), control2: CGPoint(x: x + 0.645 * w, y: y + 0.95 * h))
    p.addCurve(to: CGPoint(x: x + 0.585 * w, y: y + 0.572 * h),
               control1: CGPoint(x: x + 0.645 * w, y: y + 0.79 * h), control2: CGPoint(x: x + 0.565 * w, y: y + 0.70 * h))
    p.closeSubpath()
    return p
  }
}

struct MoshSkirtShape: Shape {
  func path(in r: CGRect) -> Path {
    let w = r.width, h = r.height, x = r.minX, y = r.minY
    var p = Path()
    p.move(to: CGPoint(x: x + 0.425 * w, y: y + 0.645 * h))
    p.addQuadCurve(to: CGPoint(x: x + 0.575 * w, y: y + 0.645 * h), control: CGPoint(x: x + 0.50 * w, y: y + 0.668 * h))
    p.addLine(to: CGPoint(x: x + 0.625 * w, y: y + 0.722 * h))
    p.addQuadCurve(to: CGPoint(x: x + 0.375 * w, y: y + 0.722 * h), control: CGPoint(x: x + 0.50 * w, y: y + 0.690 * h))
    p.closeSubpath()
    return p
  }
}

/// The cap's spots: flatter towards the rim, the way they sit on a dome.
struct MoshSpotsShape: Shape {
  func path(in r: CGRect) -> Path {
    let w = r.width, h = r.height
    let spots: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [   // centre x, centre y, radius x, radius y
      (0.50, 0.150, 0.070, 0.050), (0.285, 0.275, 0.070, 0.058), (0.715, 0.265, 0.078, 0.064),
      (0.505, 0.355, 0.062, 0.054), (0.135, 0.435, 0.040, 0.046), (0.865, 0.430, 0.038, 0.044),
      (0.325, 0.470, 0.046, 0.034), (0.690, 0.468, 0.044, 0.032),
    ]
    var p = Path()
    for s in spots {
      p.addEllipse(in: CGRect(x: r.minX + (s.0 - s.2) * w, y: r.minY + (s.1 - s.3) * h,
                              width: 2 * s.2 * w, height: 2 * s.3 * h))
    }
    return p
  }
}

struct MoshKeyholeShape: Shape {
  func path(in r: CGRect) -> Path {
    let w = r.width, h = r.height, x = r.minX, y = r.minY
    var p = Path()
    let radius = 0.072 * w
    let centre = CGPoint(x: x + 0.50 * w, y: y + 0.245 * h)
    p.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
    p.move(to: CGPoint(x: centre.x - 0.034 * w, y: centre.y + 0.030 * h))
    p.addLine(to: CGPoint(x: centre.x + 0.034 * w, y: centre.y + 0.030 * h))
    p.addLine(to: CGPoint(x: centre.x + 0.058 * w, y: y + 0.455 * h))
    p.addLine(to: CGPoint(x: centre.x - 0.058 * w, y: y + 0.455 * h))
    p.closeSubpath()
    return p
  }
}

/// A cap seen from underneath: the ring of gills around the cut stem. Reads as a dial.
struct MoshGillsShape: Shape {
  var count = 36
  func path(in r: CGRect) -> Path {
    let c = CGPoint(x: r.midX, y: r.midY)
    let outer = min(r.width, r.height) / 2
    var p = Path()
    p.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: 2 * outer, height: 2 * outer))
    p.addEllipse(in: CGRect(x: c.x - outer * 0.86, y: c.y - outer * 0.86, width: outer * 1.72, height: outer * 1.72))
    p.addEllipse(in: CGRect(x: c.x - outer * 0.20, y: c.y - outer * 0.20, width: outer * 0.40, height: outer * 0.40))
    for i in 0..<count {
      let a = CGFloat(i) / CGFloat(count) * 2 * .pi
      // Every other gill is short, as on a real cap.
      let inner = outer * (i % 2 == 0 ? 0.27 : 0.52)
      p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
      p.addLine(to: CGPoint(x: c.x + cos(a) * outer * 0.83, y: c.y + sin(a) * outer * 0.83))
    }
    return p
  }
}

/// Rings leaving the cap: sound, or spores on the air.
struct MoshRingsShape: Shape {
  var index: Int
  func path(in r: CGRect) -> Path {
    var p = Path()
    let c = CGPoint(x: r.midX, y: r.maxY)
    let radius = r.width * (0.20 + 0.12 * CGFloat(index))
    p.addArc(center: c, radius: radius, startAngle: .degrees(-142), endAngle: .degrees(-38), clockwise: false)
    return p
  }
}

/// A drift of spores: fixed positions, so the card never changes between two renders.
struct MoshSporesShape: Shape {
  func path(in r: CGRect) -> Path {
    let dots: [(CGFloat, CGFloat, CGFloat)] = [
      (0.08, 0.30, 2.2), (0.19, 0.12, 1.4), (0.31, 0.42, 1.2), (0.44, 0.08, 1.8), (0.57, 0.26, 1.1),
      (0.70, 0.05, 1.5), (0.84, 0.20, 2.0), (0.93, 0.44, 1.2), (0.14, 0.62, 1.3), (0.02, 0.50, 1.0),
      (0.62, 0.50, 0.9), (0.38, 0.24, 0.9),
    ]
    var p = Path()
    for d in dots {
      p.addEllipse(in: CGRect(x: r.minX + d.0 * r.width - d.2, y: r.minY + d.1 * r.height - d.2,
                              width: 2 * d.2, height: 2 * d.2))
    }
    return p
  }
}

/// One mushroom. `glass` is the watermark on a card (white, translucent, hairline edges); `solid` is
/// the mark itself (red cap, white spots, pale stem).
struct MoshMushroomGlyph: View {
  enum Style { case glass, solid }
  var style: Style = .glass
  var keyhole = false

  var body: some View {
    GeometryReader { g in
      let line = max(0.75, g.size.width * 0.011)
      ZStack {
        switch style {
        case .glass:
          MoshStemShape().fill(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.04)],
                                              startPoint: .leading, endPoint: .trailing))
          MoshStemShape().stroke(Color.white.opacity(0.36), lineWidth: line)
          MoshSkirtShape().fill(Color.white.opacity(0.20))
          MoshCapShape().fill(LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.05)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
          Group {
            if keyhole { MoshKeyholeShape().fill(Color.white.opacity(0.62)) }
            else { MoshSpotsShape().fill(Color.white.opacity(0.36)) }
          }
          .clipShape(MoshCapShape())
          MoshCapShape().stroke(Color.white.opacity(0.48), lineWidth: line)
        case .solid:
          MoshStemShape().fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.80)],
                                              startPoint: .leading, endPoint: .trailing))
          MoshSkirtShape().fill(Color(white: 0.72))
          MoshCapShape().fill(LinearGradient(colors: [Color(red: 1.0, green: 0.36, blue: 0.38), Color(red: 0.74, green: 0.10, blue: 0.14)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
          MoshSpotsShape().fill(Color.white.opacity(0.95)).clipShape(MoshCapShape())
        }
      }
    }
    .aspectRatio(0.92, contentMode: .fit)
  }
}

/// The corner illustration of a card, one per destination, in a square box.
struct MoshLauncherArt: View {
  let motif: MoshArtMotif

  var body: some View {
    GeometryReader { g in
      let s = min(g.size.width, g.size.height)
      ZStack {
        MoshSporesShape().fill(Color.white.opacity(0.30))
        switch motif {
        case .cluster:
          // Files: a cluster, the way they grow. Back to front.
          MoshMushroomGlyph().frame(height: s * 0.44).rotationEffect(.degrees(-13)).opacity(0.70)
            .position(x: s * 0.33, y: s * 0.71)
          MoshMushroomGlyph().frame(height: s * 0.84).rotationEffect(.degrees(6))
            .position(x: s * 0.60, y: s * 0.55)
          MoshMushroomGlyph().frame(height: s * 0.34).rotationEffect(.degrees(15)).opacity(0.85)
            .position(x: s * 0.93, y: s * 0.78)
        case .sound:
          ForEach(0..<3, id: \.self) { i in
            MoshRingsShape(index: i)
              .stroke(Color.white.opacity(0.34 - 0.09 * Double(i)),
                      style: StrokeStyle(lineWidth: max(1, s * 0.012), lineCap: .round))
              .frame(width: s * 0.98, height: s * 0.46)
              .position(x: s * 0.56, y: s * 0.23)
          }
          MoshMushroomGlyph().frame(height: s * 0.74).rotationEffect(.degrees(4))
            .position(x: s * 0.56, y: s * 0.63)
        case .keyhole:
          MoshMushroomGlyph(keyhole: true).frame(height: s * 0.92).rotationEffect(.degrees(-5))
            .position(x: s * 0.56, y: s * 0.56)
        case .gills:
          MoshGillsShape()
            .stroke(Color.white.opacity(0.34), style: StrokeStyle(lineWidth: max(0.75, s * 0.008), lineCap: .round))
            .background(Circle().fill(RadialGradient(colors: [.white.opacity(0.02), .white.opacity(0.14)],
                                                     center: .center, startRadius: 0, endRadius: s * 0.45)))
            .frame(width: s * 0.90, height: s * 0.90)
            .rotationEffect(.degrees(9))
            .position(x: s * 0.66, y: s * 0.60)
        }
      }
      .frame(width: s, height: s)
    }
    .aspectRatio(1, contentMode: .fit)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// A card answers a press (and the pointer, on the Mac) by lifting slightly.
private struct MoshLauncherPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.975 : 1)
      .brightness(configuration.isPressed ? 0.06 : 0)
      .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
  }
}

struct MoshLauncherCard: View {
  let item: MoshLauncherItem
  /// iPhone: a full-width row. Otherwise a tall tile in the two-column grid.
  let compact: Bool
  @State private var hovering = false

  private var radius: CGFloat { compact ? 20 : 24 }

  var body: some View {
    Button(action: item.action) {
      Group {
        if compact { row } else { tile }
      }
      .background(ground)
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(LinearGradient(colors: [.white.opacity(hovering ? 0.42 : 0.24), .white.opacity(0.03),
                                                MoshLauncherPalette.ember.opacity(hovering ? 0.85 : 0.45)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
      )
      .shadow(color: MoshLauncherPalette.ember.opacity(hovering ? 0.34 : 0.16), radius: hovering ? 26 : 18, x: 0, y: 10)
      .shadow(color: .black.opacity(0.55), radius: 10, x: 0, y: 6)
      .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
    .buttonStyle(MoshLauncherPressStyle())
    .onHover { inside in withAnimation(.easeOut(duration: 0.18)) { hovering = inside } }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("launcher." + item.id)
  }

  /// Near-black that burns into red at the far corner, with the mushroom sitting in the glow.
  private var ground: some View {
    GeometryReader { g in
      let art = compact ? g.size.height * 1.25 : min(g.size.width * 0.60, g.size.height * 0.96)
      ZStack {
        LinearGradient(stops: [.init(color: MoshLauncherPalette.coal, location: 0),
                               .init(color: Color(red: 0.115, green: 0.050, blue: 0.058), location: 0.46),
                               .init(color: MoshLauncherPalette.deep, location: 0.84),
                               .init(color: Color(red: 0.640, green: 0.115, blue: 0.145), location: 1)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        RadialGradient(colors: [MoshLauncherPalette.ember.opacity(hovering ? 0.62 : 0.46), .clear],
                       center: .bottomTrailing, startRadius: 0, endRadius: max(g.size.width, g.size.height) * 0.72)
        // A soft sheen along the top edge, as on glass.
        LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .top, endPoint: .center)
        MoshLauncherArt(motif: item.motif)
          .frame(width: art, height: art)
          .position(x: g.size.width - art * (compact ? 0.34 : 0.37),
                    y: g.size.height - art * (compact ? 0.38 : 0.42))
      }
    }
  }

  private var badge: some View {
    Image(systemName: item.icon)
      .font(.system(size: 20, weight: .semibold))
      .foregroundColor(.white)
      .frame(width: 46, height: 46)
      .background(
        RoundedRectangle(cornerRadius: 13, style: .continuous)
          .fill(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
      )
      .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
  }

  private var tile: some View {
    VStack(alignment: .leading, spacing: 8) {
      badge
      Spacer(minLength: 10)
      Text(item.title)
        .font(.system(.title2, design: .rounded).weight(.bold))
        .foregroundColor(.white)
      Text(item.subtitle)
        .font(.subheadline)
        .foregroundColor(.white.opacity(0.74))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 190, minHeight: 38, alignment: .topLeading)
    }
    .padding(22)
    .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
  }

  private var row: some View {
    HStack(spacing: 16) {
      badge
      VStack(alignment: .leading, spacing: 3) {
        Text(item.title)
          .font(.system(.headline, design: .rounded).weight(.bold))
          .foregroundColor(.white)
        Text(item.subtitle)
          .font(.subheadline)
          .foregroundColor(.white.opacity(0.74))
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 76)
    }
    .padding(18)
    .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
  }
}
// MARK: ART-END

extension SpaceController {
  private var moshlauncherController: MoshlauncherController? {
    presentedViewController as? MoshlauncherController
  }

  // True while the launcher is on screen — Quick Connect checks this so the two never overlap.
  var moshroomMoshlauncherIsOpen: Bool { moshlauncherController != nil }

  // Open the launcher full screen. Works on any tab; needs no shell/connection.
  func openMoshlauncher() {
    moshroomPresentFullScreen(from: self) {
      let ctrl = MoshlauncherController()
      ctrl.space = self
      return ctrl
    }
  }

  // Close the launcher, then restore the keyboard owner + Quick Connect like the other hubs do.
  func dismissMoshlauncher() {
    guard let ctrl = moshlauncherController else { return }
    ctrl.dismiss(animated: false) { [weak self] in
      guard let self, Moshroom.scratchOnly else { return }
      self.moshroomRestoreKeyboardOwner()
      self.showMoshnectorIfIdle()
    }
  }
}
