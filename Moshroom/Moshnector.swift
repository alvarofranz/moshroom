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

enum MoshnectorMode {
  case ssh, mosh, tmux
  var command: String {
    switch self {
    case .ssh: return "ssh"
    case .mosh: return "mosh"
    case .tmux: return "tmux"
    }
  }
}


/// THE saved-host card — one builder for every host list (Quick Connect, the Moshxplore host
/// picker): red server glyph, bold alias, the optional gray description, generous padding.
/// Semantic colors — the app's one (dark) theme resolves them the same on every surface.
func moshHostCardButton(alias: String, description: String, icon: String = "server.rack") -> UIButton {
  var cfg = UIButton.Configuration.filled()
  cfg.baseBackgroundColor = .secondarySystemGroupedBackground
  cfg.baseForegroundColor = .label
  cfg.background.cornerRadius = Moshstyle.cardRadius
  cfg.background.strokeColor = .separator
  cfg.background.strokeWidth = 0.5
  cfg.image = UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))?
    .withTintColor(.moshroomTint, renderingMode: .alwaysOriginal)
  cfg.imagePadding = 12
  var attr = AttributeContainer()
  attr.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
  cfg.attributedTitle = AttributedString(alias, attributes: attr)
  if !description.isEmpty {
    var sub = AttributeContainer()
    sub.font = UIFont.systemFont(ofSize: 13)
    sub.foregroundColor = UIColor.secondaryLabel
    cfg.attributedSubtitle = AttributedString(description, attributes: sub)
    cfg.titlePadding = 2
  }
  cfg.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
  let b = UIButton(configuration: cfg)
  #if targetEnvironment(macCatalyst)
  b.preferredBehavioralStyle = .pad   // keep OUR card metrics, never the native Mac push-button
  #endif
  b.contentHorizontalAlignment = .leading
  b.translatesAutoresizingMaskIntoConstraints = false
  b.setContentCompressionResistancePriority(.required, for: .vertical)   // never squashed by a scroll
  return b
}

// Hosts and projects this device connected to lately, newest first. Written by noteConnection (a
// Quick Connect tap, or a typed `ssh`/`tmux`/`mosh <host> [project]`), read by Quick Connect's
// Recent row. Device-local on purpose: what you open on the phone is not what you open on the Mac.
enum MoshQuickRecents {
  struct Entry: Equatable {
    let alias: String
    /// The project's tmux session (its stable id across renames); nil = the host's own session.
    let session: String?
  }

  private static let key = "MoshroomQuickConnectRecents"
  private static let separator = "\u{1F}"
  private static let cap = 8

  static func note(alias: String, session: String?) {
    let entry = Entry(alias: alias, session: session)
    var list = all().filter { $0 != entry }
    list.insert(entry, at: 0)
    UserDefaults.standard.set(list.prefix(cap).map { $0.alias + separator + ($0.session ?? "") }, forKey: key)
  }

  /// Replaces the list (used to forget entries whose host or project is gone).
  static func keep(_ entries: [Entry]) {
    UserDefaults.standard.set(entries.prefix(cap).map { $0.alias + separator + ($0.session ?? "") }, forKey: key)
  }

  static func all() -> [Entry] {
    (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap { raw in
      let parts = raw.components(separatedBy: separator)
      guard parts.count == 2, !parts[0].isEmpty else { return nil }
      return Entry(alias: parts[0], session: parts[1].isEmpty ? nil : parts[1])
    }
  }
}

/// Something Quick Connect can dial: a host's own session (project nil) or one of its projects.
/// The header, the project tiles and the Recent tiles all carry one, so taps and the context menu
/// read the same thing.
protocol MoshQuickTarget: UIView {
  var alias: String { get }
  var project: MoshProject? { get }
}

/// Quick Connect's pressable surface: a flat fill that lightens under the pointer and under the
/// finger. Plain UIControl (no UIButton configuration), so the Mac never swaps in its push-button look.
class MoshQuickPressable: UIControl {
  var restFill: UIColor = .clear { didSet { _paint() } }
  var hoverFill: UIColor = UIColor(white: 1, alpha: 0.05)
  var pressFill: UIColor = UIColor(white: 1, alpha: 0.10)
  private var hovering = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerCurve = .continuous
    addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(_hover(_:))))
    isAccessibilityElement = true
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isHighlighted: Bool { didSet { _paint() } }

  @objc private func _hover(_ g: UIHoverGestureRecognizer) {
    hovering = g.state == .began || g.state == .changed
    _paint()
  }

  private func _paint() {
    backgroundColor = isHighlighted ? pressFill : (hovering ? hoverFill : restFill)
  }
}

/// A host's header inside its folder: the server glyph on a faint mushroom tile, the alias, the
/// optional description and `user@address` in monospace. A tap opens the host's own session.
final class MoshQuickHostHeader: MoshQuickPressable, MoshQuickTarget {
  let alias: String
  let project: MoshProject? = nil
  private let glyph = UIView()
  private let glyphImage = UIImageView()
  private let titleLabel = UILabel()
  private let descriptionLabel = UILabel()
  private let addressLabel = UILabel()
  private let go = UIImageView()
  private static let pad: CGFloat = 14
  private static let glyphSide: CGFloat = 42

  init(alias: String, description: String, address: String) {
    self.alias = alias
    super.init(frame: .zero)
    glyph.backgroundColor = UIColor.moshroomTint.withAlphaComponent(0.18)
    glyph.layer.cornerRadius = 11
    glyph.layer.cornerCurve = .continuous
    glyph.isUserInteractionEnabled = false
    glyphImage.image = UIImage(systemName: "server.rack",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    glyphImage.tintColor = .moshroomTint
    glyphImage.contentMode = .center
    glyph.addSubview(glyphImage)

    titleLabel.text = alias
    titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold), maximumPointSize: 28)
    titleLabel.textColor = .label
    titleLabel.lineBreakMode = .byTruncatingTail
    descriptionLabel.text = description
    descriptionLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 13), maximumPointSize: 22)
    descriptionLabel.textColor = .secondaryLabel
    descriptionLabel.numberOfLines = 2
    addressLabel.text = address
    addressLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular), maximumPointSize: 20)
    addressLabel.textColor = .tertiaryLabel
    addressLabel.lineBreakMode = .byTruncatingMiddle
    go.image = UIImage(systemName: "arrow.right.circle.fill",
                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
    go.tintColor = .tertiaryLabel
    go.contentMode = .center
    for v in [glyph, titleLabel, descriptionLabel, addressLabel, go] as [UIView] {
      v.isUserInteractionEnabled = false
      addSubview(v)
    }
    accessibilityIdentifier = alias
    accessibilityLabel = description.isEmpty ? alias : "\(alias), \(description)"
    accessibilityHint = "Opens the host's own session"
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var _lines: [UILabel] {
    [titleLabel, descriptionLabel, addressLabel].filter { !($0.text ?? "").isEmpty }
  }

  /// Lays the header out at this width and returns its height.
  @discardableResult
  func layout(width: CGFloat) -> CGFloat {
    let pad = Self.pad, side = Self.glyphSide
    let goSide: CGFloat = 24
    let textX = pad + side + 12
    let textW = max(40, width - textX - pad - goSide - 8)
    var y: CGFloat = 0
    var frames: [(UILabel, CGRect)] = []
    for (i, label) in _lines.enumerated() {
      if i > 0 { y += label === addressLabel ? 3 : 2 }
      let h = ceil(label.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude)).height)
      frames.append((label, CGRect(x: textX, y: y, width: textW, height: h)))
      y += h
    }
    let textH = y
    let height = max(side, textH) + pad * 2
    let textTop = (height - textH) / 2
    for (label, f) in frames { label.frame = f.offsetBy(dx: 0, dy: textTop) }
    for label in [titleLabel, descriptionLabel, addressLabel] where !_lines.contains(label) { label.frame = .zero }
    glyph.frame = CGRect(x: pad, y: (height - side) / 2, width: side, height: side)
    glyphImage.frame = glyph.bounds
    go.frame = CGRect(x: width - pad - goSide, y: (height - goSide) / 2, width: goSide, height: goSide)
    return height
  }
}

/// One tile in a grid: a project inside its host's folder, or a Recent entry (which also names the
/// host under the project).
final class MoshQuickTile: MoshQuickPressable, MoshQuickTarget {
  let alias: String
  let project: MoshProject?
  private let icon = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()

  init(alias: String, project: MoshProject?, title: String, subtitle: String?) {
    self.alias = alias
    self.project = project
    super.init(frame: .zero)
    layer.cornerRadius = 11
    // Explicit whites over the folder, so a tile reads the same on every elevation and platform.
    restFill = UIColor(white: 1, alpha: 0.07)
    hoverFill = UIColor(white: 1, alpha: 0.12)
    pressFill = UIColor(white: 1, alpha: 0.17)
    icon.image = UIImage(systemName: project == nil ? "server.rack" : "folder.fill",
                         withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
    icon.tintColor = .moshroomTint
    icon.contentMode = .center
    titleLabel.text = title
    titleLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .medium), maximumPointSize: 24)
    titleLabel.textColor = .label
    // Project names are often one long word (`visitcarlingford`): shrink a little first, and if it
    // still does not fit, cut the middle so the start and the end, which tell projects apart, stay.
    titleLabel.adjustsFontSizeToFitWidth = true
    titleLabel.minimumScaleFactor = 0.8
    titleLabel.lineBreakMode = .byTruncatingMiddle
    subtitleLabel.text = subtitle
    subtitleLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12), maximumPointSize: 20)
    subtitleLabel.textColor = .secondaryLabel
    subtitleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.isHidden = subtitle == nil
    for v in [icon, titleLabel, subtitleLabel] as [UIView] {
      v.isUserInteractionEnabled = false
      addSubview(v)
    }
    accessibilityIdentifier = project.map { "project:" + alias + ":" + $0.id } ?? alias
    accessibilityLabel = [title, subtitle].compactMap { $0 }.joined(separator: ", ")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The height every tile of a grid shares (one line, or two with a subtitle), at the current text size.
  func preferredHeight() -> CGFloat {
    var h = ceil(titleLabel.font.lineHeight)
    if !subtitleLabel.isHidden { h += 2 + ceil(subtitleLabel.font.lineHeight) }
    return max(44, h + 22)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let iconW: CGFloat = 20
    icon.frame = CGRect(x: 12, y: (bounds.height - iconW) / 2, width: iconW, height: iconW)
    let x = icon.frame.maxX + 9
    let w = max(10, bounds.width - x - 12)
    let titleH = ceil(titleLabel.font.lineHeight)
    if subtitleLabel.isHidden {
      titleLabel.frame = CGRect(x: x, y: (bounds.height - titleH) / 2, width: w, height: titleH)
    } else {
      let subH = ceil(subtitleLabel.font.lineHeight)
      let top = (bounds.height - titleH - 2 - subH) / 2
      titleLabel.frame = CGRect(x: x, y: top, width: w, height: titleH)
      subtitleLabel.frame = CGRect(x: x, y: top + titleH + 2, width: w, height: subH)
    }
  }
}

/// Lays tiles out in rows of equal columns, as many as fit `minWidth`, and returns the grid's height.
private func moshQuickGrid(_ tiles: [MoshQuickTile], origin: CGPoint, width: CGFloat,
                           minWidth: CGFloat, gap: CGFloat, maxColumns: Int = .max) -> CGFloat {
  guard !tiles.isEmpty else { return 0 }
  let columns = max(1, min(maxColumns, Int((width + gap) / (minWidth + gap))))
  let tileW = floor((width - gap * CGFloat(columns - 1)) / CGFloat(columns))
  let tileH = tiles.map { $0.preferredHeight() }.max() ?? 44
  for (i, tile) in tiles.enumerated() {
    let col = i % columns, row = i / columns
    tile.frame = CGRect(x: origin.x + CGFloat(col) * (tileW + gap), y: origin.y + CGFloat(row) * (tileH + gap),
                        width: tileW, height: tileH)
  }
  let rows = (tiles.count + columns - 1) / columns
  return CGFloat(rows) * tileH + CGFloat(rows - 1) * gap
}

/// A host as a folder: its header on a faint mushroom wash, then its projects as a grid of tiles.
final class MoshQuickHostCard: UIView {
  let header: MoshQuickHostHeader
  let tiles: [MoshQuickTile]
  private let wash = CAGradientLayer()
  private let divider = UIView()

  init(alias: String, description: String, address: String, projects: [MoshProject]) {
    header = MoshQuickHostHeader(alias: alias, description: description, address: address)
    tiles = projects.map {
      MoshQuickTile(alias: alias, project: $0, title: $0.name.isEmpty ? $0.session : $0.name, subtitle: nil)
    }
    super.init(frame: .zero)
    backgroundColor = UIColor(white: 1, alpha: 0.055)
    layer.cornerRadius = Moshstyle.cardRadius + 2
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    layer.borderColor = UIColor(white: 1, alpha: 0.07).cgColor
    clipsToBounds = true
    // The folder's "tab": a mushroom wash fading out across the header, so each host reads as one
    // object at a glance even in a wall of them.
    wash.colors = [UIColor.moshroomTint.withAlphaComponent(0.22).cgColor, UIColor.moshroomTint.withAlphaComponent(0).cgColor]
    wash.startPoint = CGPoint(x: 0, y: 0)
    wash.endPoint = CGPoint(x: 1, y: 1)
    layer.addSublayer(wash)
    addSubview(header)
    divider.backgroundColor = UIColor(white: 1, alpha: 0.08)
    divider.isHidden = tiles.isEmpty
    addSubview(divider)
    tiles.forEach(addSubview)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// Lays the folder out at this width and returns its height.
  func layout(width: CGFloat) -> CGFloat {
    let headerH = header.layout(width: width)
    header.frame = CGRect(x: 0, y: 0, width: width, height: headerH)
    CATransaction.begin()
    CATransaction.setDisableActions(true)   // the wash moves WITH the card, never trails it
    wash.frame = CGRect(x: 0, y: 0, width: width, height: headerH)
    CATransaction.commit()
    guard !tiles.isEmpty else { return headerH }
    divider.frame = CGRect(x: 14, y: headerH, width: width - 28, height: 1 / UIScreen.main.scale)
    let gridH = moshQuickGrid(tiles, origin: CGPoint(x: 12, y: headerH + 12), width: width - 24, minWidth: 140, gap: 8)
    return headerH + 12 + gridH + 12
  }
}

/// What a connection that ended right away printed last, shown at the top of Quick Connect: the
/// terminal is wiped when a connection ends (the page comes back clean), and without this a failed
/// connect read as "tap, flash, back where I was" with the reason gone.
final class MoshQuickNotice: UIView {
  let close = MoshQuickPressable()
  private let title = UILabel()
  private let body = UILabel()
  private let closeImage = UIImageView(image: UIImage(systemName: "xmark",
    withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)))

  init(host: String, lines: [String]) {
    super.init(frame: .zero)
    backgroundColor = UIColor.moshroomTint.withAlphaComponent(0.12)
    layer.cornerRadius = Moshstyle.cardRadius
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    layer.borderColor = UIColor.moshroomTint.withAlphaComponent(0.4).cgColor
    title.text = "The connection to \(host) ended"
    title.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold), maximumPointSize: 24)
    title.textColor = .label
    title.numberOfLines = 0
    body.text = lines.joined(separator: "\n")
    body.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular), maximumPointSize: 20)
    body.textColor = .secondaryLabel
    body.numberOfLines = 0
    closeImage.tintColor = .secondaryLabel
    closeImage.contentMode = .center
    closeImage.isUserInteractionEnabled = false
    close.layer.cornerRadius = 14
    close.accessibilityLabel = "Dismiss"
    close.addSubview(closeImage)
    [title, body, close].forEach(addSubview)
    isAccessibilityElement = false
    accessibilityElements = [title, body, close]
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func layout(width: CGFloat) -> CGFloat {
    let pad: CGFloat = 14
    let textW = max(40, width - pad * 2 - 32)
    let titleH = ceil(title.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude)).height)
    title.frame = CGRect(x: pad, y: pad, width: textW, height: titleH)
    var y = title.frame.maxY
    if !(body.text ?? "").isEmpty {
      let bodyH = ceil(body.sizeThatFits(CGSize(width: width - pad * 2, height: .greatestFiniteMagnitude)).height)
      body.frame = CGRect(x: pad, y: y + 6, width: width - pad * 2, height: bodyH)
      y = body.frame.maxY
    } else {
      body.frame = .zero
    }
    close.frame = CGRect(x: width - pad - 24, y: pad - 4, width: 28, height: 28)
    closeImage.frame = close.bounds
    return y + pad
  }
}

/// A scroll view whose pressable children never pin it: a drag that starts on a tile scrolls.
private final class MoshQuickScrollView: UIScrollView {
  override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

// Quick Connect: the page a fresh terminal shows. Pure presentation — SpaceController owns the
// lifecycle. It fills the whole terminal area: the SSH/Mosh switcher, a Recent row once there is
// enough to choose from, and every saved host as a folder of its projects, in as many columns as the
// width holds (one on a phone, up to four on a Mac), stacked like masonry so a host with many
// projects never leaves holes next to a host with none.
final class MoshnectorView: UIView {
  #if MOSHROOM_PUBLISHING_OPTION_DEVELOPER
  var storeProjects: [String: [MoshProject]]?
  var storeAddresses: [String: String]?
  var storeRecents: [MoshQuickRecents.Entry]?
  #endif

  /// A host (project nil: its own session) or one of its projects, in the mode to use.
  var onConnect: ((MoshnectorMode, String, MoshProject?) -> Void)?

  // SSH first: it is the default way in (in tmux, unless the host turns that off).
  private var mode: MoshnectorMode = .ssh
  private var hosts: [(alias: String, description: String)] = []
  private let modeControl = UISegmentedControl(items: ["SSH", "Mosh"])
  private let scroll = MoshQuickScrollView()
  private let emptyLabel = UILabel()
  private let recentCaption = UILabel()
  private let hostsCaption = UILabel()
  private var cards: [MoshQuickHostCard] = []
  private var recentTiles: [MoshQuickTile] = []
  /// Fades the content out under the top bar once the page is scrolled (at rest nothing is faded).
  private let topFade = CAGradientLayer()

  /// Recent shows up only once there are more ways in than fit at a glance.
  private static let recentThreshold = 6

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    // The page sits on the backdrop (the terminal's own ground); the folders carry the colour.
    backgroundColor = .clear

    // No title on purpose: the switcher and the folders say what this is.
    modeControl.selectedSegmentIndex = 0
    // Mushroom-red selection with white text — the house switcher, styled once for the whole
    // app in MoshstyleAppearance.install() (Moshvault's Passwords/2FA picker matches for free).
    modeControl.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.mode = self.modeControl.selectedSegmentIndex == 1 ? .mosh : .ssh
    }, for: .valueChanged)

    scroll.showsHorizontalScrollIndicator = false
    scroll.alwaysBounceVertical = false
    scroll.delaysContentTouches = false
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.delegate = self
    topFade.colors = [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
    // No edge effect: the page starts right under the top bar, which already has its own ground, and
    // the effect drew a hairline across the switcher.
    if #available(iOS 26.0, *) {
      scroll.topEdgeEffect.isHidden = true
      scroll.bottomEdgeEffect.isHidden = true
    }
    addSubview(scroll)
    scroll.addSubview(modeControl)

    let emptyPara = NSMutableParagraphStyle()
    emptyPara.alignment = .center
    emptyPara.lineSpacing = 7
    emptyLabel.attributedText = NSAttributedString(
      string: "No saved hosts yet.\nAdd one in Settings › Hosts.",
      attributes: [.paragraphStyle: emptyPara,
                   .font: UIFont.systemFont(ofSize: 15),
                   .foregroundColor: UIColor.secondaryLabel])
    emptyLabel.numberOfLines = 0
    emptyLabel.isHidden = true
    scroll.addSubview(emptyLabel)

    for (label, text) in [(recentCaption, "RECENT"), (hostsCaption, "HOSTS")] {
      label.attributedText = NSAttributedString(string: text, attributes: [
        .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: UIColor.secondaryLabel,
        .kern: 0.8,
      ])
      label.isHidden = true
      scroll.addSubview(label)
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// What the page was last built from. Quick Connect is re-shown on every foreground, window-key,
  /// modal close and iCloud pass: rebuilding each time would drop a finger already on a tile, the
  /// pointer's hover and the reader's scroll position, so the page is rebuilt only when this changes.
  private var builtFrom: String?
  /// The tab the page was last shown on: coming back to the same tab (a closed composer, Settings)
  /// keeps the scroll position, another tab starts at the top.
  var shownForTab: UUID?
  /// The tab a notice belongs to, and the notice (see MoshQuickNotice).
  private var notice: (tab: UUID?, view: MoshQuickNotice)?

  /// What the connection that just ended on `tab` printed last; shown while that tab is on screen.
  func showNotice(host: String, lines: [String], tab: UUID?) {
    notice?.view.removeFromSuperview()
    let view = MoshQuickNotice(host: host, lines: lines)
    view.close.addAction(UIAction { [weak self] _ in self?.clearNotice() }, for: .touchUpInside)
    scroll.addSubview(view)
    notice = (tab, view)
    setNeedsLayout()
  }

  func clearNotice() {
    notice?.view.removeFromSuperview()
    notice = nil
    setNeedsLayout()
  }

  /// Refresh the page: one folder per saved host, plus the Recent row. `fromTop` when the page is
  /// coming on screen (a page that was already showing keeps where the reader was).
  func reload(hosts: [(alias: String, description: String)], fromTop: Bool = true) {
    self.hosts = hosts
    let signature = _signature()
    if signature != builtFrom {
      builtFrom = signature
      _rebuild()
    }
    if fromTop { scroll.setContentOffset(.zero, animated: false) }
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory { _rebuild() }
  }

  private func _signature() -> String {
    var parts: [String] = []
    for host in hosts {
      parts.append([host.alias, host.description, _address(host.alias)].joined(separator: "\u{1F}"))
      parts += _projects(host.alias).map { "\($0.id)\u{1F}\($0.name)\u{1F}\($0.session)" }
      parts.append("\u{1E}")
    }
    parts += _recents().map { "\($0.alias)\u{1F}\($0.session ?? "")" }
    return parts.joined(separator: "\n")
  }

  private func _projects(_ alias: String) -> [MoshProject] {
    #if MOSHROOM_PUBLISHING_OPTION_DEVELOPER
    if let storeProjects { return storeProjects[alias] ?? [] }
    #endif
    return MoshHosts.withHost(alias)?.moshroomProjects ?? []
  }

  private func _address(_ alias: String) -> String {
    #if MOSHROOM_PUBLISHING_OPTION_DEVELOPER
    if let storeAddresses { return storeAddresses[alias] ?? "" }
    #endif
    guard let host = MoshHosts.withHost(alias) else { return "" }
    let name = host.hostName ?? ""
    guard !name.isEmpty else { return "" }
    let user = host.user ?? ""
    return user.isEmpty ? name : "\(user)@\(name)"
  }

  private func _recents() -> [MoshQuickRecents.Entry] {
    #if MOSHROOM_PUBLISHING_OPTION_DEVELOPER
    if let storeRecents { return storeRecents }
    #endif
    return MoshQuickRecents.all()
  }

  private func _rebuild() {
    cards.forEach { $0.removeFromSuperview() }
    recentTiles.forEach { $0.removeFromSuperview() }
    cards = []
    recentTiles = []
    emptyLabel.isHidden = !hosts.isEmpty

    var projectsByHost: [String: [MoshProject]] = [:]
    for host in hosts {
      let projects = _projects(host.alias)
      projectsByHost[host.alias] = projects
      let card = MoshQuickHostCard(alias: host.alias, description: host.description,
                                   address: _address(host.alias), projects: projects)
      _wire(card.header)
      card.tiles.forEach(_wire)
      cards.append(card)
      scroll.addSubview(card)
    }

    // Recent: only what still exists. A deleted host or project drops out, and is forgotten too, so
    // it cannot hold a slot or come back if its alias is ever reused.
    let recents = _recents()
    let alive = recents.filter { entry in
      guard let projects = projectsByHost[entry.alias] else { return false }
      return entry.session.map { s in projects.contains { $0.session == s } } ?? true
    }
    #if MOSHROOM_PUBLISHING_OPTION_DEVELOPER
    let storeData = storeRecents != nil
    #else
    let storeData = false
    #endif
    if !hosts.isEmpty, !storeData, alive.count < recents.count { MoshQuickRecents.keep(alive) }
    let targets = hosts.count + projectsByHost.values.reduce(0) { $0 + $1.count }
    if targets > Self.recentThreshold {
      for entry in alive {
        guard let projects = projectsByHost[entry.alias] else { continue }
        if let session = entry.session {
          guard let project = projects.first(where: { $0.session == session }) else { continue }
          recentTiles.append(MoshQuickTile(alias: entry.alias, project: project,
                                           title: project.name.isEmpty ? project.session : project.name,
                                           subtitle: entry.alias))
        } else {
          let description = hosts.first { $0.alias == entry.alias }?.description ?? ""
          recentTiles.append(MoshQuickTile(alias: entry.alias, project: nil, title: entry.alias,
                                           subtitle: description.isEmpty ? "Host session" : description))
        }
      }
    }
    recentTiles.forEach { tile in
      _wire(tile)
      tile.accessibilityIdentifier = "recent:" + (tile.accessibilityIdentifier ?? "")
      // Before the folders, so VoiceOver reads the page in the order it is drawn.
      if let first = cards.first { scroll.insertSubview(tile, belowSubview: first) } else { scroll.addSubview(tile) }
    }
    setNeedsLayout()
  }

  private func _wire(_ control: MoshQuickPressable & MoshQuickTarget) {
    control.addAction(UIAction { [weak self, weak control] _ in
      guard let self, let control else { return }
      self.clearNotice()
      self.onConnect?(self._tapMode(for: control.alias), control.alias, control.project)
    }, for: .touchUpInside)
    // A long press (a right click on the Mac) offers every way in, whatever the switcher says.
    control.addInteraction(UIContextMenuInteraction(delegate: self))
  }

  // What a tap on this host runs: in SSH mode a host opens in tmux (its session lives on the server)
  // unless its "Use tmux with SSH" setting is off.
  private func _tapMode(for alias: String) -> MoshnectorMode {
    if mode == .ssh, MoshHosts.withHost(alias)?.moshroomUsesTmux == true {
      return .tmux
    }
    return mode
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    scroll.frame = bounds
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    topFade.frame = bounds
    topFade.locations = [0, NSNumber(value: Double(min(1, 18 / max(bounds.height, 1)))), 1]
    CATransaction.commit()
    let width = bounds.width
    guard width > 0 else { return }
    let compact = width < 560
    let side: CGFloat = compact ? 16 : 28
    let contentW = min(width - side * 2, 1400)
    let x0 = floor((width - contentW) / 2)
    let gap: CGFloat = compact ? 12 : 16
    var y: CGFloat = compact ? 6 : 14

    modeControl.frame = CGRect(x: x0, y: y, width: compact ? contentW : min(280, contentW), height: 34)
    y = modeControl.frame.maxY + (compact ? 18 : 24)

    if let notice, notice.tab == shownForTab {
      notice.view.isHidden = false
      let h = notice.view.layout(width: min(contentW, 720))
      notice.view.frame = CGRect(x: x0, y: y, width: min(contentW, 720), height: h)
      y = notice.view.frame.maxY + (compact ? 18 : 24)
    } else {
      notice?.view.isHidden = true
    }

    if hosts.isEmpty {
      recentCaption.isHidden = true
      hostsCaption.isHidden = true
      let h = ceil(emptyLabel.sizeThatFits(CGSize(width: contentW, height: .greatestFiniteMagnitude)).height)
      emptyLabel.frame = CGRect(x: x0, y: y + 24, width: contentW, height: h)
      scroll.contentSize = CGSize(width: width, height: emptyLabel.frame.maxY + 24)
      return
    }

    // Masonry: as many columns as hold 300pt, each folder dropped into the shortest one, so reading
    // order stays roughly left to right, top to bottom.
    let hostColumns = max(1, min(4, Int((contentW + gap) / (300 + gap))))
    let showRecent = !recentTiles.isEmpty
    recentCaption.isHidden = !showRecent
    hostsCaption.isHidden = !showRecent
    if showRecent {
      recentCaption.sizeToFit()
      recentCaption.frame.origin = CGPoint(x: x0 + 4, y: y)
      y = recentCaption.frame.maxY + 8
      // Lined up with the folders' columns (two on a phone), at most two rows: Recent is a shortcut,
      // never a second list.
      let columns = max(2, hostColumns)
      let shown = Array(recentTiles.prefix(columns * (columns > 2 ? 1 : 2)))
      recentTiles.forEach { $0.isHidden = !shown.contains($0) }
      y += moshQuickGrid(shown, origin: CGPoint(x: x0, y: y), width: contentW, minWidth: 0, gap: gap,
                         maxColumns: columns)
      y += compact ? 22 : 28
      hostsCaption.sizeToFit()
      hostsCaption.frame.origin = CGPoint(x: x0 + 4, y: y)
      y = hostsCaption.frame.maxY + 8
    }

    let columnW = floor((contentW - gap * CGFloat(hostColumns - 1)) / CGFloat(hostColumns))
    var bottoms = Array(repeating: y, count: hostColumns)
    for card in cards {
      let col = bottoms.indices.min { bottoms[$0] < bottoms[$1] } ?? 0
      let h = card.layout(width: columnW)
      card.frame = CGRect(x: x0 + CGFloat(col) * (columnW + gap), y: bottoms[col], width: columnW, height: h)
      bottoms[col] = card.frame.maxY + gap
    }
    let bottom = (bottoms.max() ?? y) - gap + (compact ? 20 : 32)
    scroll.contentSize = CGSize(width: width, height: bottom)
    // A page that shrank under a reader scrolled down (a host deleted elsewhere) must not leave them
    // looking at empty space past its end.
    let maxOffset = max(0, bottom - scroll.bounds.height)
    if scroll.contentOffset.y > maxOffset { scroll.contentOffset.y = maxOffset }
  }
}

extension MoshnectorView: UIScrollViewDelegate {
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let faded = scrollView.contentOffset.y > 1
    if faded != (layer.mask != nil) { layer.mask = faded ? topFade : nil }
  }
}

extension MoshnectorView: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                              configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
    guard let target = interaction.view as? MoshQuickTarget else { return nil }
    let alias = target.alias
    let tapped = target.project
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      let ways: (MoshProject?) -> [UIAction] = { project in
        let item: (String, String, MoshnectorMode) -> UIAction = { title, icon, mode in
          UIAction(title: title, image: UIImage(systemName: icon)) { _ in
            self?.onConnect?(mode, alias, project)
          }
        }
        return [
          item("Connect (tmux)", "rectangle.stack", .tmux),
          item("Connect (plain SSH)", "terminal", .ssh),
          item("Connect (Mosh)", "antenna.radiowaves.left.and.right", .mosh),
        ]
      }
      // A project tile: that project's three ways in.
      if let tapped {
        return UIMenu(title: "\(alias) · \(tapped.name.isEmpty ? tapped.session : tapped.name)", children: ways(tapped))
      }
      // The host: its own session first, then each project with the same three ways in.
      let projects = (self?._projects(alias) ?? []).map { project in
        UIMenu(title: project.name.isEmpty ? project.session : project.name,
               image: UIImage(systemName: "folder"), children: ways(project))
      }
      var children: [UIMenuElement] = ways(nil)
      if !projects.isEmpty {
        children.append(UIMenu(title: "Projects", options: .displayInline, children: projects))
      }
      return UIMenu(title: alias, children: children)
    }
  }
}

// The first-run onboarding card — shown INSTEAD of Quick Connect on a fresh terminal when there are
// no saved hosts AND no keys yet, so a brand-new install has an obvious, friendly first step. Same
// dark card family as MoshnectorView, and the same visual language as MoshEmptyState (44pt mushroom
// icon, title, callout) so it feels of-a-piece with the rest of the app.
final class MoshonboardView: UIView {

  var onAddHost: (() -> Void)?
  var onAddKey: (() -> Void)?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .systemGroupedBackground
    layer.cornerRadius = Moshstyle.overlayRadius
    Moshstyle.applyOverlayShadow(layer)

    let icon = UIImageView(image: UIImage(systemName: "server.rack",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .regular))?
      .withTintColor(.moshroomTint, renderingMode: .alwaysOriginal))
    icon.contentMode = .center
    icon.setContentHuggingPriority(.required, for: .vertical)

    let title = UILabel()
    title.text = "Welcome to Moshroom"
    title.font = .systemFont(ofSize: 20, weight: .semibold)
    title.textColor = .label
    title.textAlignment = .center
    title.numberOfLines = 0

    let message = UILabel()
    message.text = "To get started, add a server you can reach over SSH. Log in with a password or an SSH key."
    message.font = .systemFont(ofSize: 15)
    message.textColor = .secondaryLabel
    message.textAlignment = .center
    message.numberOfLines = 0

    let addHost = _primaryButton("Add your first host")
    addHost.addAction(UIAction { [weak self] _ in self?.onAddHost?() }, for: .touchUpInside)
    let addKey = _secondaryButton("Set up an SSH key")
    addKey.addAction(UIAction { [weak self] _ in self?.onAddKey?() }, for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [icon, title, message, addHost, addKey])
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = 12
    stack.setCustomSpacing(6, after: icon)
    stack.setCustomSpacing(22, after: message)
    stack.setCustomSpacing(8, after: addHost)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 28),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
    ])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // Filled mushroom-red primary — the one prominent action.
  private func _primaryButton(_ title: String) -> UIButton {
    var cfg = UIButton.Configuration.filled()
    cfg.baseBackgroundColor = .moshroomTint
    cfg.baseForegroundColor = .white
    cfg.background.cornerRadius = Moshstyle.cardRadius
    var attr = AttributeContainer(); attr.font = .systemFont(ofSize: 16, weight: .semibold)
    cfg.attributedTitle = AttributedString(title, attributes: attr)
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)
    let b = UIButton(configuration: cfg)
    #if targetEnvironment(macCatalyst)
    b.preferredBehavioralStyle = .pad   // never the native Mac push-button
    #endif
    b.translatesAutoresizingMaskIntoConstraints = false
    return b
  }

  // Subtle tinted secondary (matches MoshEmptyState's action).
  private func _secondaryButton(_ title: String) -> UIButton {
    var cfg = UIButton.Configuration.plain()
    cfg.baseForegroundColor = .moshroomTint
    var attr = AttributeContainer(); attr.font = .systemFont(ofSize: 15, weight: .semibold)
    cfg.attributedTitle = AttributedString(title, attributes: attr)
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
    let b = UIButton(configuration: cfg)
    #if targetEnvironment(macCatalyst)
    b.preferredBehavioralStyle = .pad
    #endif
    b.translatesAutoresizingMaskIntoConstraints = false
    return b
  }
}

/// What Quick Connect stands on: an opaque page over the terminal area, the ground colour of the
/// terminal. While the card is up there is no terminal to look at or to scroll: without it a swipe or a
/// wheel next to the card scrolled the idle shell underneath (haptic ticks, its cursor sliding by).
/// It takes every touch and wheel that is not the card's, and passes none through.
final class MoshnectorBackdrop: UIView {
  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isOpaque = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

enum Moshnector {
  static func install(in sc: SpaceController) {
    let backdrop = MoshnectorBackdrop()
    backdrop.isHidden = true
    sc.view.insertSubview(backdrop, aboveSubview: sc.moshroomTerminalArea)
    NSLayoutConstraint.activate([
      backdrop.topAnchor.constraint(equalTo: sc.moshroomTerminalArea.topAnchor),
      backdrop.bottomAnchor.constraint(equalTo: sc.moshroomTerminalArea.bottomAnchor),
      backdrop.leadingAnchor.constraint(equalTo: sc.moshroomTerminalArea.leadingAnchor),
      backdrop.trailingAnchor.constraint(equalTo: sc.moshroomTerminalArea.trailingAnchor),
    ])

    let card = MoshnectorView()
    card.isHidden = true
    card.onConnect = { [weak sc] mode, alias, project in
      guard let sc, let device = sc.currentDevice else { return }
      // A new try: the notice about the previous one has said what it had to say.
      sc.view.subviews.compactMap { $0 as? MoshnectorView }.first?.clearNotice()
      if let project {
        if mode == .ssh {
          // Plain SSH has no session to keep: into the folder, then the command, typed once it is up.
          MoshroomProjectHandoff.set(MoshProjectShell.typedStart(project), for: device)
          device.write("ssh \(alias)\r")
        } else {
          device.write("\(mode.command) \(alias) \(project.session)\r")
        }
      } else {
        device.write("\(mode.command) \(alias)\r")
      }
      // Remember where we connected — Moshdrop uploads attachments to this host.
      sc.noteConnection(toHost: alias, project: project?.session)
      // The terminal now has content (a connection) → keep Quick Connect from popping back over it.
      sc.currentTerm()?.moshroomUserHasInteracted = true
      sc.dismissMoshnector()
    }
    sc.view.addSubview(card)

    // Refresh the host list live when hosts change — local saves in Settings AND iCloud pulls —
    // so a visible Quick Connect card never shows a stale list.
    for name in [HostsCloudMirror.didSaveNotification, HostsCloudMirror.didChangeNotification] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak sc] _ in
        // A host changed (local save or iCloud pull): if a fresh-terminal overlay is up, re-pick
        // onboarding vs Quick Connect (the first host swaps the onboarding away) + refresh the list.
        sc?.refreshFreshOverlayIfVisible()
      }
    }

    NSLayoutConstraint.activate([
      // The whole terminal area, exactly what the backdrop covers: below the Tabs/Settings bar, above
      // the iOS quick keys, edge to edge. The page lays its folders out in as many columns as fit.
      card.topAnchor.constraint(equalTo: sc.moshroomTerminalArea.topAnchor),
      card.bottomAnchor.constraint(equalTo: sc.moshroomTerminalArea.bottomAnchor),
      card.leadingAnchor.constraint(equalTo: sc.moshroomTerminalArea.leadingAnchor),
      card.trailingAnchor.constraint(equalTo: sc.moshroomTerminalArea.trailingAnchor),
    ])

    // The first-run onboarding — same spot as Quick Connect, shown only when there are no hosts AND
    // no keys yet (see showMoshnectorIfIdle). One or the other is ever visible, never both. A touch
    // narrower than the host card since it's text-centric.
    let onboard = MoshonboardView()
    onboard.isHidden = true
    // Straight to the host editor or the key list, the same destinations as the welcome tour.
    onboard.onAddHost = { [weak sc] in sc?.moshroomOpenTourSetup(.addHost) }
    onboard.onAddKey = { [weak sc] in sc?.moshroomOpenTourSetup(.keys) }
    sc.view.addSubview(onboard)
    NSLayoutConstraint.activate([
      onboard.topAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.topAnchor, constant: 76),
      onboard.centerXAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.centerXAnchor),
      onboard.leadingAnchor.constraint(greaterThanOrEqualTo: sc.view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      {
        let fill = onboard.leadingAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.leadingAnchor, constant: 16)
        fill.priority = .init(750)
        return fill
      }(),
      onboard.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
      onboard.bottomAnchor.constraint(lessThanOrEqualTo: sc.view.safeAreaLayoutGuide.bottomAnchor, constant: -72),
    ])
  }
}

extension Notification.Name {
  /// A tab's session went live, or its local shell printed its `moshroom>` prompt — the deterministic
  /// moments when Quick Connect may need to reveal itself. Posted by TermController (session start /
  /// restore) and by MCPSession, which is ObjC and posts the same string on the wire.
  static let moshroomPromptReady = Notification.Name("MoshroomPromptReadyNotification")
}

extension SpaceController {
  // Saved SSH host aliases — the only hosts Moshdrop can upload to (each reuses its own keys/config).
  // One source of truth for the card list and for validating a connection's host.
  var moshroomSavedHostAliases: [String] {
    MoshHosts.allHosts().compactMap { (host: MoshHosts) -> String? in
      guard let alias = host.host as String?, !alias.isEmpty else { return nil }
      return alias
    }
  }

  // The card rows also show each host's optional gray description.
  var moshroomSavedHostCards: [(alias: String, description: String)] {
    MoshHosts.allHosts().compactMap { (host: MoshHosts) -> (String, String)? in
      guard let alias = host.host as String?, !alias.isEmpty else { return nil }
      return (alias, host.hostDescription ?? "")
    }
  }

  // Show the quick-connect card for the current (idle) terminal, refreshing the host list.
  func showMoshnector() {
    guard let card = view.subviews.compactMap({ $0 as? MoshnectorView }).first else { return }
    view.subviews.compactMap({ $0 as? MoshonboardView }).first?.isHidden = true   // mutually exclusive
    let tab = currentTerm()?.meta.key
    card.reload(hosts: moshroomSavedHostCards, fromTop: card.shownForTab != tab)
    card.shownForTab = tab
    card.isHidden = false
    view.bringSubviewToFront(card)
    _moshroomSyncFreshOverlayPage()
  }

  /// Quick Connect or the onboarding is on screen (the fresh-terminal overlay).
  var moshroomFreshOverlayIsVisible: Bool {
    let cardVisible = !(view.subviews.compactMap { $0 as? MoshnectorView }.first?.isHidden ?? true)
    let onboardVisible = !(view.subviews.compactMap { $0 as? MoshonboardView }.first?.isHidden ?? true)
    return cardVisible || onboardVisible
  }

  // The overlay is a page of its own: the backdrop hides the idle terminal under it (and takes its
  // gestures), and the quick keys step aside except compose. Re-read whenever the overlay changes.
  private func _moshroomSyncFreshOverlayPage() {
    let visible = moshroomFreshOverlayIsVisible
    if let backdrop = view.subviews.compactMap({ $0 as? MoshnectorBackdrop }).first {
      backdrop.backgroundColor = view.backgroundColor ?? .moshroomBackground
      backdrop.isHidden = !visible
    }
    moshroomSyncQuickKeysVisibility()
  }

  // True when a brand-new install has nothing set up yet — no saved hosts AND no keys. On a fresh
  // terminal we then show the onboarding instead of Quick Connect (which would just be empty).
  var moshroomHasNoHostsNorKeys: Bool {
    moshroomSavedHostAliases.isEmpty && MoshPubKey.all().isEmpty
  }

  // Show the first-run onboarding (hides Quick Connect); the two are mutually exclusive.
  func showMoshboard() {
    guard let onboard = view.subviews.compactMap({ $0 as? MoshonboardView }).first else { return }
    view.subviews.compactMap({ $0 as? MoshnectorView }).first?.isHidden = true
    onboard.isHidden = false
    view.bringSubviewToFront(onboard)
    _moshroomSyncFreshOverlayPage()
  }

  // A host/key change landed (local save or iCloud pull): if a fresh-terminal overlay is showing,
  // re-pick onboarding vs Quick Connect (adding the first host swaps the onboarding away).
  func refreshFreshOverlayIfVisible() {
    guard moshroomFreshOverlayIsVisible else { return }
    if moshroomHasNoHostsNorKeys { showMoshboard() } else { showMoshnector() }
  }

  // Hide it — called the moment the user types, taps a key, switches tab, or connects. The
  // onboarding rides along (both are the fresh-terminal overlay; only one is ever visible).
  func dismissMoshnector() {
    view.subviews.compactMap({ $0 as? MoshnectorView }).first?.isHidden = true
    view.subviews.compactMap({ $0 as? MoshonboardView }).first?.isHidden = true
    _moshroomSyncFreshOverlayPage()
  }

  // Reveal the card only for a fresh, unconnected shell; keep it hidden for a restored or
  // still-connected ssh/mosh session (so reopening into a live mosh shows no card).
  func showMoshnectorIfIdle() {
    // This is the app's "the session state changed" trigger (a prompt printed, a session started or
    // ended, a modal closed), so it is also where the tab pill is re-read: a connection that just
    // ended must take its name off the top bar.
    defer { moshroomUpdateTabLabel() }
    // Never compete with a full-screen hub — while the launcher or Moshvault is open, Quick
    // Connect stays hidden. (The explorer is a TAB now: currentTerm() is nil there, so the
    // fresh-shell check below keeps the card away on its own.)
    if moshroomMoshlauncherIsOpen || moshroomMoshvaultIsOpen {
      dismissMoshnector(); return
    }
    let term = currentTerm()
    if term?.moshroomIsFreshShell == true {
      // Back at the local prompt — this tab has no active connection to upload to. Grace window:
      // a connect tapped moments ago hasn't spawned its command yet (the shell still reads as
      // fresh), so a reveal-trigger racing the spawn must not wipe what noteConnection just set.
      let justConnected = (term?.moshroomConnectedHostSetAt).map { Date().timeIntervalSince($0) < 3 } ?? false
      if !justConnected {
        // A connection just ENDED here (`exit` back to the local prompt): reset the tab to its
        // fresh-start look — wipe the dead connect transcript (the same full reset the `clear`
        // builtin prints) and let Quick Connect come back — instead of stranding the user on
        // stale "Connecting to…" scrollback with nothing tappable.
        if let ended = term, let host = ended.moshroomConnectedHost {
          let wipe = { [weak ended] in ended?.termView.write("\u{1B}c\u{1B}[H\u{1B}[2J\u{1B}[0m") }
          // Ended within 15 s of starting: most likely it never really worked (a refused key, a host
          // that is down, a startup command that fails). Keep what it printed last, for the page.
          if let started = ended.moshroomConnectedHostSetAt, Date().timeIntervalSince(started) < 15 {
            let tab = ended.meta.key
            ended.termView.webView.evaluateJavaScript(Self.moshroomNoticeScript) { [weak self] value, _ in
              let lines = Self.moshroomNoticeLines((value as? String) ?? "")
              self?.view.subviews.compactMap { $0 as? MoshnectorView }.first?.showNotice(host: host, lines: lines, tab: tab)
              wipe()
            }
          } else {
            wipe()
          }
          ended.moshroomUserHasInteracted = false
        }
        term?.moshroomConnectedHost = nil
        // The persisted name goes too, or the Tabs list keeps naming a host this tab left.
        if let meta = term?.meta, meta.connectedHost != nil || meta.connectedProject != nil {
          meta.connectedHost = nil
          meta.connectedProject = nil
          SessionRegistry.shared.persistMetaIndex()
        }
      }
      // Only reveal on a brand-new, untouched terminal. Once a command has run here, the shell is still
      // "fresh" (local prompt) but now has content on screen — don't pop the card back over it.
      if term?.moshroomUserHasInteracted == true {
        if moshroomFreshOverlayIsVisible { MoshLog.log("quick", "hidden: this tab already has content") }
        dismissMoshnector()
      } else if moshroomHasNoHostsNorKeys {
        showMoshboard()          // fresh install: onboarding instead of an empty Quick Connect
      } else {
        showMoshnector()
      }
    } else {
      if moshroomFreshOverlayIsVisible { MoshLog.log("quick", "hidden: \(term == nil ? "no terminal on screen" : "not a fresh shell")") }
      dismissMoshnector()
    }
  }

  /// The text of both screens, alternate first: what a mosh session printed (a mosh-server that
  /// could not start, say) lives on the alternate screen, which the normal screen hides again as soon
  /// as mosh exits. Rows are hterm records (`nodes[].txt`, the same shape term.js's selection reads).
  static let moshroomNoticeScript = #"""
  (function () {
    function text(rec) { var s = '', n = rec && rec.nodes; if (!n) return ''; for (var i = 0; i < n.length; i++) s += (n[i].txt || ''); return s; }
    var out = [];
    try { if (t.alternateScreen_ && t.alternateScreen_ !== t.screen_) out = out.concat(t.alternateScreen_.rowsArray.map(text)); } catch (e) {}
    try { out = out.concat(t.screen_.rowsArray.map(text)); } catch (e) {}
    return out.join('\n');
  })()
  """#

  /// The last few meaningful lines (blank lines, invisible joiners, our own "Connecting to …" line
  /// and the connect command itself left out).
  static func moshroomNoticeLines(_ text: String) -> [String] {
    let lines = text.replacingOccurrences(of: "\u{2060}", with: "")
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { line in
        !line.isEmpty && !line.hasPrefix("Connecting to ")
          && !["ssh ", "mosh ", "tmux "].contains { line.hasPrefix($0) && !line.contains(":") }
      }
    return Array(lines.suffix(4)).map { $0.count > 220 ? String($0.prefix(220)) + "…" : $0 }
  }

  // The single place a connection's host is recorded as Moshdrop's upload target. Only saved hosts
  // qualify (an upload reuses the host's keys/config); an unknown host is ignored, never an error.
  // `project` is the project's session name when the connection is to one of the host's projects.
  func noteConnection(toHost alias: String, project: String? = nil) {
    if moshroomSavedHostAliases.contains(alias) {
      MoshQuickRecents.note(alias: alias, session: project)
      let term = currentTerm()
      term?.moshroomConnectedHost = alias
      term?.meta.connectedHost = alias          // persisted → the tab name survives an app relaunch
      term?.meta.connectedProject = project
      SessionRegistry.shared.persistMetaIndex()
      moshroomUpdateTabLabel()                  // the tab is this host now — say so in the pill
    }
  }

  // A command sent from the local prompt may be an `ssh <host>` / `mosh <host>` / `tmux <host>` connect: if so,
  // record its host. Robust by design: rather than parse ssh's flag grammar, it picks the argument
  // that matches a saved host, so flags and their values are skipped and ad-hoc hosts simply aren't
  // tracked. Gated on the local prompt, so a prompt typed to a remote agent is never mistaken for a
  // connect — and routed through noteConnection, so there is one validate-and-store path.
  func noteConnectionCommand(_ command: String) {
    guard currentTerm()?.moshroomIsFreshShell == true else { return }
    let words = command.split(whereSeparator: { " \t\n".contains($0) }).map(String.init)
    guard let verb = words.first, verb == "ssh" || verb == "mosh" || verb == "tmux" else { return }
    guard let index = words.indices.dropFirst().first(where: { moshroomSavedHostAliases.contains(words[$0]) }) else { return }
    let alias = words[index]
    // Quick Connect already recorded this connect (host AND project) moments ago and is now seeing its
    // own `ssh <host>` come back as a typed line: a plain-SSH project connect would otherwise be
    // re-recorded as the bare host, in Recent and in the tab's name.
    if let term = currentTerm(), term.moshroomConnectedHost == alias,
       let at = term.moshroomConnectedHostSetAt, Date().timeIntervalSince(at) < 3 {
      return
    }
    // `tmux <host> <project>` / `mosh <host> <project>`: the words after the host name a project.
    var project: String? = nil
    if verb != "ssh", index + 1 < words.count {
      project = MoshHosts.withHost(alias)?.moshroomProject(matching: Array(words[(index + 1)...]))?.session
    }
    noteConnection(toHost: alias, project: project)
  }
}
