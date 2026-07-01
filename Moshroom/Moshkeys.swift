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
    compose.setImage(UIImage(systemName: "square.and.pencil"), for: .normal)
    compose.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 18), forImageIn: .normal)
    compose.translatesAutoresizingMaskIntoConstraints = false
    compose.addAction(UIAction { [weak sc] _ in sc?.openMoshkitor() }, for: .touchUpInside)
    sc.view.addSubview(compose)

    // Top bar — mirrors the bottom one (no background, just round buttons): Tabs on the
    // left, Settings on the right.
    let tabs = moshkeyRoundButton()
    tabs.setImage(UIImage(systemName: "rectangle.stack"), for: .normal)
    tabs.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 18), forImageIn: .normal)
    tabs.translatesAutoresizingMaskIntoConstraints = false
    tabs.addAction(UIAction { [weak bar] _ in bar?.showTabsPad() }, for: .touchUpInside)
    sc.view.addSubview(tabs)

    let settings = moshkeyRoundButton()
    settings.setImage(UIImage(systemName: "gearshape"), for: .normal)
    settings.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 18), forImageIn: .normal)
    settings.translatesAutoresizingMaskIntoConstraints = false
    settings.addAction(UIAction { [weak sc] _ in sc?.openSettings() }, for: .touchUpInside)
    sc.view.addSubview(settings)

    // Moshxplore — the remote file explorer. Sits just left of Settings, opens over any tab.
    let xplore = moshkeyRoundButton()
    xplore.setImage(UIImage(systemName: "folder"), for: .normal)
    xplore.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 18), forImageIn: .normal)
    xplore.translatesAutoresizingMaskIntoConstraints = false
    xplore.addAction(UIAction { [weak sc] _ in sc?.openMoshxplore() }, for: .touchUpInside)
    sc.view.addSubview(xplore)

    bar.chrome = [compose, tabs, settings, xplore]   // kept tappable above the dismiss overlay
    bar.composeButton = compose                      // stepped aside while the ↕ arrow mode is active

    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
      bar.bottomAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
      compose.trailingAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
      compose.bottomAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
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
  }
}

// Shared style for the floating round buttons — the Moshroom house style, reused by the
// Moshkitor control bar so everything matches.
func moshkeyRoundButton(diameter: CGFloat = 42) -> UIButton {
  let b = UIButton(type: .system)
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

  enum Kind { case special, numbers, letters, tabs }

  // Sibling Moshkeys views (e.g. Enter) to keep above the dismiss overlay.
  var chrome: [UIView] = []

  private weak var spaceController: SpaceController?
  private let pad = MoshkeysPad()
  private let padContainer = UIStackView()
  private let overlay = UIView()
  private lazy var tabsPad: MoshkeysTabsPad = {
    let p = MoshkeysTabsPad()
    p.onSwitch = { [weak self] key in self?.spaceController?.moshroomSwitch(toTab: key); self?._closePad() }
    p.onNew = { [weak self] in self?.spaceController?.moshroomNewTab(); self?._closePad() }
    p.onClose = { [weak self] key in
      guard let self, let sc = self.spaceController else { return }
      // Closing the last tab spins up a fresh shell + shows Quick Connect — so get the pad out of
      // the way. If other tabs remain, keep the pad open (background switches) so you can keep
      // closing / hopping around.
      let wasLast = sc.moshroomTabs().count <= 1
      sc.moshroomClose(tab: key)
      if wasLast {
        self._closePad()
      } else {
        self.tabsPad.reload(tabs: sc.moshroomTabs())
      }
    }
    p.onRename = { [weak self] key in
      guard let self, let sc = self.spaceController else { return }
      sc.moshroomRename(tab: key) { self.tabsPad.reload(tabs: sc.moshroomTabs()) }
    }
    return p
  }()
  private var shownKind: Kind?

  // Bottom-bar buttons, kept as refs so the ↕ toggle can swap them out for inline arrow keys.
  private var specialBtn, numbersBtn, lettersBtn, arrowsBtn, enterBtn: UIButton!
  // Inline arrow keys shown only while ↕ is active: ← → to its left, ↓ ↑ to its right.
  private var arrowLeftBtn, arrowRightBtn, arrowDownBtn, arrowUpBtn: UIButton!
  // The compose button lives outside the bar (bottom-right); it steps aside while arrow mode is on.
  weak var composeButton: UIButton?
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
    arrowsBtn.setImage(UIImage(systemName: "dpad"), for: .normal)
    arrowsBtn.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 18), forImageIn: .normal)
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
    b.setImage(UIImage(systemName: symbol), for: .normal)
    b.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold), forImageIn: .normal)
    b.addAction(UIAction { [weak self] _ in
      self?.spaceController?.dismissMoshnector()
      self?.spaceController?.currentDevice?.write(bytes)
    }, for: .touchUpInside)
    return b
  }

  private func _setArrowsActive(_ active: Bool) {
    arrowsBtn.backgroundColor = active ? .moshroomTint : UIColor(white: 0.97, alpha: 0.92)
    arrowsBtn.tintColor = active ? .white : UIColor(white: 0.12, alpha: 1)
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
    _setArrowsActive(false)
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

  // The tabs pad lists the open terminal sessions; like every pad it opens above the
  // bottom bar and closes whatever else was open. Triggered by the top-left Tabs button.
  func showTabsPad() {
    guard let sc = spaceController else { return }
    tabsPad.reload(tabs: sc.moshroomTabs())
    _present([tabsPad], kind: .tabs)
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
    case .tabs:
      return []   // the tabs pad builds its own dynamic content
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
    let b = UIButton(type: .system)
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

// The Tabs pad: one row per open terminal session — tap to switch, × to close, plus a
// "New tab" row. Same white box as MoshkeysPad; the active tab is inverted (dark) so it
// reads at a glance. Built fresh on every open from SpaceController.moshroomTabs().
final class MoshkeysTabsPad: UIView {

  var onSwitch: ((UUID) -> Void)?
  var onClose: ((UUID) -> Void)?
  var onNew: (() -> Void)?
  var onRename: ((UUID) -> Void)?

  private let stack = UIStackView()
  private static let dark = UIColor(white: 0.12, alpha: 1)
  private static let hairline = UIColor(white: 0.82, alpha: 1)

  init() {
    super.init(frame: .zero)
    backgroundColor = UIColor(white: 0.97, alpha: 0.97)
    layer.cornerRadius = 18
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.22
    layer.shadowRadius = 9
    layer.shadowOffset = CGSize(width: 0, height: 3)

    stack.axis = .vertical
    stack.spacing = 7
    stack.alignment = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 340),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
    ])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func reload(tabs: [SpaceController.MoshroomTabInfo]) {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for (i, tab) in tabs.enumerated() { stack.addArrangedSubview(_tabRow(tab, number: i + 1)) }
    stack.addArrangedSubview(_newRow())
  }

  private func _tabRow(_ tab: SpaceController.MoshroomTabInfo, number: Int) -> UIView {
    let active = tab.isActive
    let row = UIView()
    row.backgroundColor = active ? Self.dark : .white
    row.layer.cornerRadius = 12
    row.layer.borderWidth = active ? 0 : 0.5
    row.layer.borderColor = Self.hairline.cgColor
    row.translatesAutoresizingMaskIntoConstraints = false
    // Grows with a long, wrapped title (min one comfortable line).
    row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

    let title = UIButton(type: .system)
    var tcfg = UIButton.Configuration.plain()
    var attr = AttributeContainer()
    attr.font = .systemFont(ofSize: 12.5, weight: active ? .semibold : .regular)
    tcfg.attributedTitle = AttributedString("\(number)  \(tab.title)", attributes: attr)
    // Show the whole tab title — small, wrapped over as many lines as it needs.
    tcfg.titleLineBreakMode = .byWordWrapping
    tcfg.baseForegroundColor = active ? .white : Self.dark
    tcfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 4)
    title.configuration = tcfg
    title.titleLabel?.numberOfLines = 0
    title.contentHorizontalAlignment = .leading
    title.translatesAutoresizingMaskIntoConstraints = false
    title.addAction(UIAction { [weak self] _ in self?.onSwitch?(tab.key) }, for: .touchUpInside)

    let close = UIButton(type: .system)
    close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)), for: .normal)
    close.tintColor = active ? UIColor(white: 0.85, alpha: 1) : UIColor(white: 0.5, alpha: 1)
    close.translatesAutoresizingMaskIntoConstraints = false
    close.widthAnchor.constraint(equalToConstant: 38).isActive = true
    close.addAction(UIAction { [weak self] _ in self?.onClose?(tab.key) }, for: .touchUpInside)

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

    // Long-press a tab to rename it (force a custom name).
    let rename = _TabLongPress(target: self, action: #selector(_rowLongPressed(_:)))
    rename.key = tab.key
    row.addGestureRecognizer(rename)

    return row
  }

  private func _newRow() -> UIView {
    let b = UIButton(type: .system)
    var cfg = UIButton.Configuration.plain()
    cfg.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
    cfg.imagePadding = 7
    var attr = AttributeContainer()
    attr.font = .systemFont(ofSize: 14, weight: .medium)
    cfg.attributedTitle = AttributedString("New tab", attributes: attr)
    cfg.baseForegroundColor = Self.dark
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
    b.configuration = cfg
    b.contentHorizontalAlignment = .leading
    b.translatesAutoresizingMaskIntoConstraints = false
    b.heightAnchor.constraint(equalToConstant: 40).isActive = true
    b.addAction(UIAction { [weak self] _ in self?.onNew?() }, for: .touchUpInside)
    return b
  }

  @objc private func _rowLongPressed(_ g: UILongPressGestureRecognizer) {
    guard g.state == .began, let key = (g as? _TabLongPress)?.key else { return }
    onRename?(key)
  }
}

// A long-press recognizer that remembers which tab row it belongs to, so the rename handler
// knows which session to rename.
private final class _TabLongPress: UILongPressGestureRecognizer {
  var key: UUID?
}
