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

enum Moshkeys {
  static func install(in sc: SpaceController) {
    // Pad cluster — bottom-left.
    let bar = MoshkeysBar(spaceController: sc)
    bar.translatesAutoresizingMaskIntoConstraints = false
    sc.view.addSubview(bar)

    // Standalone compose button — bottom-right, on its own, same size as every other quick-key.
    let compose = moshkeyRoundButton()
    compose.setMoshIcon("square.and.pencil")
    compose.translatesAutoresizingMaskIntoConstraints = false
    compose.addAction(UIAction { [weak sc] _ in sc?.openMoshkitor() }, for: .touchUpInside)
    sc.view.addSubview(compose)

    // Arrow-mode Enter — sits in the compose spot (far bottom-right), shown only while ↕ arrow mode is
    // on. One tap sends Return AND drops back to the normal key bar.
    let arrowEnter = moshkeyRoundButton()
    arrowEnter.setTitle("⏎", for: .normal)
    arrowEnter.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
    arrowEnter.translatesAutoresizingMaskIntoConstraints = false
    arrowEnter.isHidden = true
    arrowEnter.addAction(UIAction { [weak bar] _ in bar?.arrowModeEnter() }, for: .touchUpInside)
    sc.view.addSubview(arrowEnter)

    // Top bar — mirrors the bottom one (no background, just round buttons): Tabs on the
    // left, Settings on the right.
    let tabs = moshkeyRoundButton()
    tabs.setMoshIcon("rectangle.stack")
    tabs.translatesAutoresizingMaskIntoConstraints = false
    tabs.addAction(UIAction { [weak sc] _ in sc?.openMoshtabs() }, for: .touchUpInside)
    sc.view.addSubview(tabs)

    let settings = moshkeyRoundButton()
    settings.setMoshIcon("gearshape")
    settings.translatesAutoresizingMaskIntoConstraints = false
    settings.addAction(UIAction { [weak sc] _ in sc?.openSettings() }, for: .touchUpInside)
    sc.view.addSubview(settings)

    // Moshxplore — the remote file explorer. Sits just left of Settings, opens over any tab.
    let xplore = moshkeyRoundButton()
    xplore.setMoshIcon("folder")
    xplore.translatesAutoresizingMaskIntoConstraints = false
    xplore.addAction(UIAction { [weak sc] _ in sc?.openMoshxplore() }, for: .touchUpInside)
    sc.view.addSubview(xplore)

    bar.chrome = [compose, tabs, settings, xplore, arrowEnter]   // kept tappable above the dismiss overlay
    bar.composeButton = compose                      // stepped aside while the ↕ arrow mode is active
    bar.arrowEnterButton = arrowEnter                // takes the compose spot during arrow mode

    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
      bar.bottomAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
      compose.trailingAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
      compose.bottomAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
      arrowEnter.trailingAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
      arrowEnter.bottomAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
      tabs.leadingAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
      tabs.topAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.topAnchor, constant: 10),
      settings.trailingAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
      settings.topAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.topAnchor, constant: 10),
      xplore.trailingAnchor.constraint(equalTo: settings.leadingAnchor, constant: -10),
      xplore.centerYAnchor.constraint(equalTo: settings.centerYAnchor),
    ])
    sc.view.bringSubviewToFront(bar)
    sc.view.bringSubviewToFront(compose)
    sc.view.bringSubviewToFront(tabs)
    sc.view.bringSubviewToFront(settings)
    sc.view.bringSubviewToFront(xplore)
    sc.view.bringSubviewToFront(arrowEnter)
  }
}

// Shared style for the floating round buttons — the Moshroom house style, reused by the
// Moshkitor control bar so everything matches.
/// A UIButton that renders the same on iOS and Mac Catalyst. On Mac, a `.system` button adopts
/// the native Mac chrome (a bordered capsule + washed-out icons) that clashes with our iOS-style
/// custom buttons; `.custom` keeps the app looking like its iPhone/iPad self.
func moshButton() -> UIButton {
  #if targetEnvironment(macCatalyst)
  return UIButton(type: .custom)
  #else
  return UIButton(type: .system)
  #endif
}

extension UIButton {
  /// Sets an SF Symbol with the tint BAKED into the image. On Mac Catalyst a `.custom` button
  /// doesn't reliably apply its `tintColor` to the image (it falls back to the app accent — red),
  /// so `.alwaysOriginal` guarantees the colour we want (dark by default, white when active) on
  /// every platform.
  func setMoshIcon(_ name: String, pointSize: CGFloat = 18,
                   weight: UIImage.SymbolWeight = .regular,
                   color: UIColor = UIColor(white: 0.12, alpha: 1)) {
    let cfg = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    setImage(UIImage(systemName: name, withConfiguration: cfg)?
      .withTintColor(color, renderingMode: .alwaysOriginal), for: .normal)
  }
}

func moshkeyRoundButton(diameter: CGFloat = 42) -> UIButton {
  let b = moshButton()
  b.tintColor = UIColor(white: 0.12, alpha: 1)
  b.setTitleColor(UIColor(white: 0.12, alpha: 1), for: .normal)
  b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
  b.backgroundColor = UIColor(white: 0.97, alpha: 0.92)
  b.layer.cornerRadius = diameter / 2
  b.layer.shadowColor = UIColor.black.cgColor
  b.layer.shadowOpacity = 0.18
  b.layer.shadowRadius = 4
  b.layer.shadowOffset = CGSize(width: 0, height: 1)
  b.translatesAutoresizingMaskIntoConstraints = false
  b.widthAnchor.constraint(equalToConstant: diameter).isActive = true
  b.heightAnchor.constraint(equalToConstant: diameter).isActive = true
  return b
}

final class MoshkeysBar: UIStackView {

  enum Kind { case special, numbers, letters }

  // Sibling Moshkeys views (e.g. Enter) to keep above the dismiss overlay.
  var chrome: [UIView] = []

  private weak var spaceController: SpaceController?
  private let pad = MoshkeysPad()
  private let padContainer = UIStackView()
  private let overlay = UIView()
  private var shownKind: Kind?

  // Bottom-bar buttons, kept as refs so the ↕ toggle can swap them out for inline arrow keys.
  private var specialBtn, numbersBtn, lettersBtn, arrowsBtn, enterBtn: UIButton!
  // Inline arrow keys shown only while ↕ is active: ← → to its left, ↓ ↑ to its right.
  private var arrowLeftBtn, arrowRightBtn, arrowDownBtn, arrowUpBtn: UIButton!
  // The compose button lives outside the bar (bottom-right); it steps aside while arrow mode is on.
  weak var composeButton: UIButton?
  // Takes the compose spot during arrow mode: sends Return and exits back to the normal bar.
  weak var arrowEnterButton: UIButton?
  private var arrowModeActive = false

  init(spaceController: SpaceController) {
    self.spaceController = spaceController
    super.init(frame: .zero)
    axis = .horizontal
    spacing = 10
    alignment = .center

    pad.onKey = { [weak self] bytes in
      guard let self else { return }
      self.spaceController?.dismissMoshnector()
      self.spaceController?.currentDevice?.write(bytes)
      self._closePad()
    }

    specialBtn = _padButton(.special, title: "⌃", systemImage: nil)
    numbersBtn = _padButton(.numbers, title: "123", systemImage: nil)
    lettersBtn = _padButton(.letters, title: "abc", systemImage: nil)
    enterBtn   = _enterButton()
    arrowsBtn  = moshkeyRoundButton()
    arrowsBtn.setMoshIcon("dpad")
    arrowsBtn.addAction(UIAction { [weak self] _ in self?._toggleArrowMode() }, for: .touchUpInside)
    arrowLeftBtn  = _arrowKeyButton("arrow.left",  "\u{1B}[D")
    arrowRightBtn = _arrowKeyButton("arrow.right", "\u{1B}[C")
    arrowDownBtn  = _arrowKeyButton("arrow.down",  "\u{1B}[B")
    arrowUpBtn    = _arrowKeyButton("arrow.up",    "\u{1B}[A")

    // ↕ sits third (centre of five) so it never shifts when arrow mode swaps the others out.
    [specialBtn, numbersBtn, arrowsBtn, lettersBtn, enterBtn].forEach { addArrangedSubview($0) }
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @discardableResult
  func closeIfOpen() -> Bool {
    if arrowModeActive { _exitArrowMode(); return true }
    guard shownKind != nil else { return false }
    _closePad()
    return true
  }

  private func _padButton(_ kind: Kind, title: String?, systemImage: String?) -> UIButton {
    let b = moshkeyRoundButton()
    if let systemImage, let img = UIImage(systemName: systemImage) {
      b.setImage(img, for: .normal)
    } else if let title {
      b.setTitle(title, for: .normal)
    }
    b.addAction(UIAction { [weak self] _ in self?._toggle(kind) }, for: .touchUpInside)
    return b
  }

  private func _enterButton() -> UIButton {
    let b = moshkeyRoundButton()
    b.setTitle("⏎", for: .normal)
    b.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
    b.addAction(UIAction { [weak self] _ in
      self?.spaceController?.dismissMoshnector()
      self?.spaceController?.currentDevice?.write("\r")
    }, for: .touchUpInside)
    return b
  }

  private func _toggle(_ kind: Kind) {
    if shownKind == kind { _closePad() } else { _showPad(kind) }
  }

  // A round arrow key (no pad — lives inline in the bar while arrow mode is on); sends its ANSI escape
  // and stays put.
  private func _arrowKeyButton(_ symbol: String, _ bytes: String) -> UIButton {
    let b = moshkeyRoundButton()
    b.setMoshIcon(symbol, pointSize: 16, weight: .semibold)
    b.addAction(UIAction { [weak self] _ in
      self?.spaceController?.dismissMoshnector()
      self?.spaceController?.currentDevice?.write(bytes)
    }, for: .touchUpInside)
    return b
  }

  private func _setArrowsActive(_ active: Bool) {
    arrowsBtn.backgroundColor = active ? .moshroomTint : UIColor(white: 0.97, alpha: 0.92)
    arrowsBtn.setMoshIcon("dpad", color: active ? .white : UIColor(white: 0.12, alpha: 1))
  }

  // The ↕ button toggles a focused arrow-keys mode: the rest of the bottom bar (and the compose button)
  // step aside, and four arrow keys flank the ↕ — ← → on its left, ↓ ↑ on its right — so they never
  // cover the terminal. Tap ↕ again to bring the normal bar back.
  private func _toggleArrowMode() {
    spaceController?.dismissMoshnector()
    arrowModeActive ? _exitArrowMode() : _enterArrowMode()
  }

  private func _enterArrowMode() {
    _closePad()
    arrowModeActive = true
    [specialBtn, numbersBtn, lettersBtn, enterBtn].forEach { removeArrangedSubview($0); $0.removeFromSuperview() }
    composeButton?.isHidden = true
    arrowEnterButton?.isHidden = false
    insertArrangedSubview(arrowLeftBtn, at: 0)
    insertArrangedSubview(arrowRightBtn, at: 1)
    addArrangedSubview(arrowDownBtn)
    addArrangedSubview(arrowUpBtn)
    _setArrowsActive(true)
  }

  private func _exitArrowMode() {
    arrowModeActive = false
    [arrowLeftBtn, arrowRightBtn, arrowDownBtn, arrowUpBtn].forEach { removeArrangedSubview($0); $0.removeFromSuperview() }
    insertArrangedSubview(specialBtn, at: 0)
    insertArrangedSubview(numbersBtn, at: 1)
    // arrowsBtn is already back at index 2 (centre); letters + enter follow it.
    addArrangedSubview(lettersBtn)
    addArrangedSubview(enterBtn)
    composeButton?.isHidden = false
    arrowEnterButton?.isHidden = true
    _setArrowsActive(false)
  }

  // The far-right Enter shown during arrow mode: fire Return, then drop back to the normal bar.
  func arrowModeEnter() {
    spaceController?.dismissMoshnector()
    spaceController?.currentDevice?.write("\r")
    if arrowModeActive { _exitArrowMode() }
  }

  // The pad floats centered in the viewport, a comfortable gap above the buttons. A
  // transparent overlay behind it dismisses the pad when the terminal is tapped.
  private func _installPad() {
    guard padContainer.superview == nil, let sv = superview else { return }

    overlay.translatesAutoresizingMaskIntoConstraints = false
    overlay.backgroundColor = .clear
    overlay.isHidden = true
    overlay.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(_overlayTapped)))
    sv.addSubview(overlay)

    padContainer.axis = .horizontal
    padContainer.spacing = 14
    padContainer.alignment = .center
    padContainer.translatesAutoresizingMaskIntoConstraints = false
    sv.addSubview(padContainer)

    NSLayoutConstraint.activate([
      overlay.topAnchor.constraint(equalTo: sv.topAnchor),
      overlay.leadingAnchor.constraint(equalTo: sv.leadingAnchor),
      overlay.trailingAnchor.constraint(equalTo: sv.trailingAnchor),
      overlay.bottomAnchor.constraint(equalTo: sv.bottomAnchor),

      padContainer.centerXAnchor.constraint(equalTo: sv.centerXAnchor),
      padContainer.bottomAnchor.constraint(equalTo: topAnchor, constant: -64),
    ])
  }

  private func _showPad(_ kind: Kind) {
    pad.configure(rows: Self._rows(for: kind))
    _present([pad], kind: kind)
  }

  // Swap whatever the floating pad is showing for `views`, then bring it to the front.
  private func _present(_ views: [UIView], kind: Kind) {
    _installPad()
    shownKind = kind

    padContainer.arrangedSubviews.forEach {
      padContainer.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    views.forEach { padContainer.addArrangedSubview($0) }

    overlay.isHidden = false
    padContainer.isHidden = false
    if let sv = superview {
      sv.bringSubviewToFront(overlay)
      chrome.forEach { sv.bringSubviewToFront($0) }
      sv.bringSubviewToFront(self)
      sv.bringSubviewToFront(padContainer)
    }
  }

  private func _closePad() {
    shownKind = nil
    padContainer.isHidden = true
    overlay.isHidden = true
  }

  @objc private func _overlayTapped() { _closePad() }

  private static func _rows(for kind: Kind) -> [[(String, String)?]] {
    switch kind {
    case .numbers:
      return [
        [("0", "0"), ("1", "1"), ("2", "2"), ("3", "3"), ("4", "4")],
        [("5", "5"), ("6", "6"), ("7", "7"), ("8", "8"), ("9", "9")],
      ]
    case .letters:
      return [
        [("y", "y"), ("n", "n"), ("a", "a"), ("c", "c")],
        [("d", "d"), ("e", "e"), ("q", "q"), ("s", "s")],
        [("p", "p"), ("r", "r"), ("o", "o"), ("k", "k")],
        [("l", "l"), ("v", "v"), ("h", "h"), ("m", "m")],
      ]
    case .special:
      return [
        [("Esc", "\u{1B}"), ("Tab", "\t"), ("␣", " "), ("^C", "\u{03}")],
        [("^D", "\u{04}"), ("^R", "\u{12}"), ("^L", "\u{0C}"), ("^Z", "\u{1A}")],
        [("^A", "\u{01}"), ("^E", "\u{05}"), ("^K", "\u{0B}"), ("^U", "\u{15}")],
        [("^W", "\u{17}"), ("^P", "\u{10}"), ("^N", "\u{0E}"), ("^G", "\u{07}")],
      ]
    }
  }
}

// A clean box of real key buttons; each fires onKey live. A single rounded-rect grid
// layout for numbers / letters / special.
final class MoshkeysPad: UIView {

  var onKey: ((String) -> Void)?

  private let rowsStack = UIStackView()

  init() {
    super.init(frame: .zero)
    backgroundColor = UIColor(white: 0.97, alpha: 0.97)
    layer.cornerRadius = 18
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.22
    layer.shadowRadius = 9
    layer.shadowOffset = CGSize(width: 0, height: 3)

    rowsStack.axis = .vertical
    rowsStack.spacing = 8
    rowsStack.alignment = .center
    rowsStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rowsStack)
    NSLayoutConstraint.activate([
      rowsStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func _reset() {
    rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
  }

  // Grid layout (rounded-rect box). `nil` cells are invisible spacers.
  func configure(rows: [[(String, String)?]]) {
    _reset()
    for row in rows {
      let rowStack = UIStackView()
      rowStack.axis = .horizontal
      rowStack.spacing = 8
      for cell in row {
        if let cell { rowStack.addArrangedSubview(_key(cell.0, cell.1)) }
        else { rowStack.addArrangedSubview(_spacer()) }
      }
      rowsStack.addArrangedSubview(rowStack)
    }
    setNeedsLayout()
  }

  private func _key(_ label: String, _ bytes: String) -> UIButton {
    let b = moshButton()
    b.setTitle(label, for: .normal)
    b.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
    b.titleLabel?.adjustsFontSizeToFitWidth = true
    b.titleLabel?.minimumScaleFactor = 0.6
    b.setTitleColor(UIColor(white: 0.1, alpha: 1), for: .normal)
    b.backgroundColor = .white
    b.layer.cornerRadius = 10
    b.layer.borderWidth = 0.5
    b.layer.borderColor = UIColor(white: 0.82, alpha: 1).cgColor
    b.translatesAutoresizingMaskIntoConstraints = false
    b.widthAnchor.constraint(equalToConstant: 46).isActive = true
    b.heightAnchor.constraint(equalToConstant: 46).isActive = true
    b.addAction(UIAction { [weak self] _ in self?.onKey?(bytes) }, for: .touchUpInside)
    return b
  }

  private func _spacer() -> UIView {
    let v = UIView()
    v.translatesAutoresizingMaskIntoConstraints = false
    v.widthAnchor.constraint(equalToConstant: 46).isActive = true
    v.heightAnchor.constraint(equalToConstant: 46).isActive = true
    return v
  }
}

// MARK: - Moshtabs: the full-screen tab manager
//
// Tabs joins Settings and Moshxplore as a real screen (the floating pads stay for keys, and
// Quick Connect stays a floating card): every open terminal session as a full-width row — the
// WHOLE title visible, never squeezed into a little pad — tap to switch, × to close, long-press
// to rename, plus a New Tab row. Adaptive colors (dark theme gets the black + mushroom-red look)
// and the same system ✕ Close as the other full screens.
final class MoshtabsController: UIViewController {

  weak var space: SpaceController?

  private let scroll = UIScrollView()
  private let stack = UIStackView()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = MoshxploreStyle.screen
    navigationItem.title = "Tabs"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close, target: self, action: #selector(_closeMoshtabs))

    stack.axis = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.alwaysBounceVertical = true
    scroll.addSubview(stack)
    view.addSubview(scroll)

    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
    ])

    reload()
  }

  private func reload() {
    guard let sc = space else { return }
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for (i, tab) in sc.moshroomTabs().enumerated() {
      stack.addArrangedSubview(_tabRow(tab, number: i + 1))
    }
    stack.addArrangedSubview(_newRow())
  }

  // One session row: number + full (wrapping) title, the active tab filled mushroom, × per row.
  private func _tabRow(_ tab: SpaceController.MoshroomTabInfo, number: Int) -> UIView {
    let active = tab.isActive
    let row = UIView()
    row.backgroundColor = active ? .moshroomTint : MoshxploreStyle.row
    row.layer.cornerRadius = 12
    row.translatesAutoresizingMaskIntoConstraints = false
    row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true

    let title = moshButton()
    var cfg = UIButton.Configuration.plain()
    var attr = AttributeContainer()
    attr.font = .systemFont(ofSize: 15, weight: active ? .semibold : .regular)
    cfg.attributedTitle = AttributedString("\(number)  \(tab.title)", attributes: attr)
    cfg.titleLineBreakMode = .byWordWrapping   // the whole title, however long
    cfg.baseForegroundColor = active ? .white : MoshxploreStyle.dark
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 4)
    title.configuration = cfg
    title.titleLabel?.numberOfLines = 0
    title.contentHorizontalAlignment = .leading
    title.translatesAutoresizingMaskIntoConstraints = false
    title.addAction(UIAction { [weak self] _ in self?._switch(to: tab.key) }, for: .touchUpInside)

    let close = moshButton()
    close.setMoshIcon("xmark", pointSize: 13, weight: .semibold, color: active ? UIColor(white: 1, alpha: 0.85) : MoshxploreStyle.gray)
    close.translatesAutoresizingMaskIntoConstraints = false
    close.widthAnchor.constraint(equalToConstant: 44).isActive = true
    close.addAction(UIAction { [weak self] _ in self?._close(tab: tab.key) }, for: .touchUpInside)

    row.addSubview(title)
    row.addSubview(close)
    NSLayoutConstraint.activate([
      title.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      title.topAnchor.constraint(equalTo: row.topAnchor),
      title.bottomAnchor.constraint(equalTo: row.bottomAnchor),
      close.leadingAnchor.constraint(equalTo: title.trailingAnchor),
      close.trailingAnchor.constraint(equalTo: row.trailingAnchor),
      close.topAnchor.constraint(equalTo: row.topAnchor),
      close.bottomAnchor.constraint(equalTo: row.bottomAnchor),
    ])

    let rename = _TabLongPress(target: self, action: #selector(_rowLongPressed(_:)))
    rename.key = tab.key
    row.addGestureRecognizer(rename)
    return row
  }

  private func _newRow() -> UIView {
    let b = moshButton()
    var cfg = UIButton.Configuration.plain()
    cfg.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
    cfg.imagePadding = 8
    var attr = AttributeContainer()
    attr.font = .systemFont(ofSize: 15, weight: .medium)
    cfg.attributedTitle = AttributedString("New tab", attributes: attr)
    cfg.baseForegroundColor = MoshxploreStyle.dark
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    b.configuration = cfg
    b.contentHorizontalAlignment = .leading
    b.translatesAutoresizingMaskIntoConstraints = false
    b.addAction(UIAction { [weak self] _ in
      self?.space?.moshroomNewTab()
      self?._dismiss()
    }, for: .touchUpInside)
    return b
  }

  // MARK: Actions

  private func _switch(to key: UUID) {
    space?.moshroomSwitch(toTab: key)
    _dismiss()
  }

  private func _close(tab key: UUID) {
    guard let sc = space else { return }
    // Closing the last tab spins up a fresh shell + Quick Connect — land the user there.
    let wasLast = sc.moshroomTabs().count <= 1
    sc.moshroomClose(tab: key)
    if wasLast { _dismiss() } else { reload() }
  }

  @objc private func _rowLongPressed(_ g: UILongPressGestureRecognizer) {
    guard g.state == .began, let key = (g as? _TabLongPress)?.key else { return }
    space?.moshroomRename(tab: key) { [weak self] in self?.reload() }
  }

  @objc private func _closeMoshtabs() { _dismiss() }

  private func _dismiss() {
    let space = self.space
    navigationController?.dismiss(animated: true) {
      guard let space, Moshroom.scratchOnly else { return }
      space.becomeFirstResponder()
      space.showMoshnectorIfIdle()
    }
  }
}

extension SpaceController {
  // Open the full-screen tab manager (top-left Tabs button).
  func openMoshtabs() {
    guard presentedViewController == nil else { return }
    dismissMoshnector()
    view.subviews.compactMap({ $0 as? MoshkeysBar }).first?.closeIfOpen()
    let ctrl = MoshtabsController()
    ctrl.space = self
    let nav = UINavigationController(rootViewController: ctrl)
    nav.modalPresentationStyle = .fullScreen
    present(nav, animated: true)
  }
}

// A long-press recognizer that remembers which tab row it belongs to, so the rename handler
// knows which session to rename.
private final class _TabLongPress: UILongPressGestureRecognizer {
  var key: UUID?
}
