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


// The one "pick a folder on a server" browser: Moshify's library setup and a project's folder both use
// it. It browses like `ls`: it starts in the login home, folders are tappable, files are shown dimmed
// so the user recognises the place, dotfiles are hidden, and a directory symlink is a folder (the
// listing already follows links, see MoshxploreSession.list). It connects HEADLESS, like every connect
// the app makes on the user's behalf, and nothing is ever typed. What a terminal would have asked (a
// server seen for the first time, a password nobody saved) it asks right here, then dials again with
// the answer: the user is never sent off to a terminal tab to make the browser work.

import SwiftUI
import UIKit

final class MoshFolderBrowserView: UIView, UITableViewDataSource, UITableViewDelegate {

  /// The folder the user settled on (absolute path on the server).
  var onUse: ((String) -> Void)?
  /// Set to show the server key next to the title (back to choosing a host), and the error's way out.
  var onChangeHost: (() -> Void)? {
    didSet { hostButton.isHidden = onChangeHost == nil }
  }
  /// A password the user typed here was accepted by the server. The caller decides whether to keep it
  /// (the host editor puts it in its password field); nothing here stores it.
  var onPasswordAccepted: ((String) -> Void)?

  var hostAlias: String? { target?.alias }
  private var target: MoshroomConnectTarget?
  private var startAt: String?
  private(set) var path = "/"
  private var home: String?
  private var folders: [MoshxploreEntry] = []
  private var files: [MoshxploreEntry] = []
  private var session: MoshxploreSession?
  /// Counts loads, so a slow answer for a folder the user already left is dropped.
  private var generation = 0
  // A connect or listing that never answers (the connection went silent) ends here instead of
  // spinning until the user backs out. Same budget as Moshxplore's.
  private var watchdog: DispatchWorkItem?
  private static let watchdogSeconds: TimeInterval = 45

  private let titleLabel = UILabel()
  private let upButton = moshkeyRoundButton(diameter: 34)
  private let homeButton = moshkeyRoundButton(diameter: 34)
  private let hostButton = moshkeyRoundButton(diameter: 34)
  private let crumbScroll = UIScrollView()
  private let crumbStack = UIStackView()
  private let table = UITableView(frame: .zero, style: .plain)
  private let useButton = moshButton()
  private let statusView = UIStackView()
  private let statusSpinner = UIActivityIndicatorView(style: .medium)
  private let statusLabel = UILabel()
  private let statusAction = moshButton()
  private var statusActionHandler: (() -> Void)?
  // The question the server raised (trust its key, a password): the field, and the answer button.
  private let answerField = UITextField()
  private let answerButton = moshButton()
  private var answerHandler: (() -> Void)?

  init(title: String, useTitle: String = "Use this folder") {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    titleLabel.text = title
    titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
    titleLabel.textColor = .label
    titleLabel.numberOfLines = 0
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    for (button, icon) in [(upButton, "chevron.up"), (homeButton, "house"), (hostButton, "server.rack")] {
      button.layer.shadowOpacity = 0
      button.setMoshIcon(icon, pointSize: 14, weight: .semibold)
    }
    upButton.accessibilityLabel = "Up"
    homeButton.accessibilityLabel = "Home folder"
    hostButton.accessibilityLabel = "Choose another host"
    hostButton.isHidden = true
    upButton.addAction(UIAction { [weak self] _ in self?._goUp() }, for: .touchUpInside)
    homeButton.addAction(UIAction { [weak self] _ in
      guard let self, let home = self.home else { return }
      self._load(home)
    }, for: .touchUpInside)
    hostButton.addAction(UIAction { [weak self] _ in self?.onChangeHost?() }, for: .touchUpInside)
    let keys = UIStackView(arrangedSubviews: [upButton, homeButton, hostButton])
    keys.spacing = 10
    keys.translatesAutoresizingMaskIntoConstraints = false

    // The breadcrumb: every component of the path, each one a way straight back to it.
    crumbScroll.translatesAutoresizingMaskIntoConstraints = false
    crumbScroll.showsHorizontalScrollIndicator = false
    crumbStack.axis = .horizontal
    crumbStack.spacing = 2
    crumbStack.alignment = .center
    crumbStack.translatesAutoresizingMaskIntoConstraints = false
    crumbScroll.addSubview(crumbStack)

    table.translatesAutoresizingMaskIntoConstraints = false
    table.backgroundColor = .clear
    table.separatorStyle = .none
    table.dataSource = self
    table.delegate = self
    table.register(MoshFolderCell.self, forCellReuseIdentifier: MoshFolderCell.id)
    table.rowHeight = 52

    var useCfg = UIButton.Configuration.filled()
    useCfg.baseBackgroundColor = .moshroomTint
    useCfg.baseForegroundColor = .white
    useCfg.cornerStyle = .capsule
    var useAttr = AttributeContainer()
    useAttr.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    useCfg.attributedTitle = AttributedString(useTitle, attributes: useAttr)
    useCfg.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
    useCfg.imagePadding = 8
    useCfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 22)
    useButton.configuration = useCfg
    #if targetEnvironment(macCatalyst)
    useButton.preferredBehavioralStyle = .pad
    #endif
    useButton.translatesAutoresizingMaskIntoConstraints = false
    useButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.onUse?(self.path)
    }, for: .touchUpInside)

    statusLabel.font = .preferredFont(forTextStyle: .callout)
    statusLabel.textColor = .secondaryLabel
    statusLabel.numberOfLines = 0
    statusLabel.textAlignment = .center
    var actionCfg = UIButton.Configuration.plain()
    actionCfg.baseForegroundColor = .moshroomTint
    statusAction.configuration = actionCfg
    #if targetEnvironment(macCatalyst)
    statusAction.preferredBehavioralStyle = .pad
    #endif
    statusAction.addAction(UIAction { [weak self] _ in self?.statusActionHandler?() }, for: .touchUpInside)
    answerField.isSecureTextEntry = true
    answerField.placeholder = "Password"
    answerField.borderStyle = .none
    answerField.backgroundColor = .secondarySystemGroupedBackground
    answerField.layer.cornerRadius = Moshstyle.rowRadius
    answerField.layer.cornerCurve = .continuous
    answerField.autocorrectionType = .no
    answerField.autocapitalizationType = .none
    answerField.textContentType = .password
    answerField.returnKeyType = .go
    answerField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
    answerField.leftViewMode = .always
    answerField.translatesAutoresizingMaskIntoConstraints = false
    answerField.heightAnchor.constraint(equalToConstant: 44).isActive = true
    answerField.widthAnchor.constraint(equalToConstant: 280).isActive = true
    answerField.addAction(UIAction { [weak self] _ in self?.answerHandler?() }, for: .editingDidEndOnExit)
    var answerCfg = UIButton.Configuration.filled()
    answerCfg.baseBackgroundColor = .moshroomTint
    answerCfg.baseForegroundColor = .white
    answerCfg.cornerStyle = .capsule
    answerCfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20)
    answerButton.configuration = answerCfg
    #if targetEnvironment(macCatalyst)
    answerButton.preferredBehavioralStyle = .pad
    #endif
    answerButton.addAction(UIAction { [weak self] _ in self?.answerHandler?() }, for: .touchUpInside)
    statusView.axis = .vertical
    statusView.alignment = .center
    statusView.spacing = 12
    statusView.translatesAutoresizingMaskIntoConstraints = false
    [statusSpinner, statusLabel, answerField, answerButton, statusAction].forEach(statusView.addArrangedSubview)
    answerField.isHidden = true
    answerButton.isHidden = true

    [titleLabel, keys, crumbScroll, table, useButton, statusView].forEach(addSubview)
    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -12),
      keys.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      keys.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

      crumbScroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
      crumbScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      crumbScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      crumbScroll.heightAnchor.constraint(equalToConstant: 30),
      crumbStack.topAnchor.constraint(equalTo: crumbScroll.contentLayoutGuide.topAnchor),
      crumbStack.bottomAnchor.constraint(equalTo: crumbScroll.contentLayoutGuide.bottomAnchor),
      crumbStack.leadingAnchor.constraint(equalTo: crumbScroll.contentLayoutGuide.leadingAnchor),
      crumbStack.trailingAnchor.constraint(equalTo: crumbScroll.contentLayoutGuide.trailingAnchor),
      crumbStack.heightAnchor.constraint(equalTo: crumbScroll.frameLayoutGuide.heightAnchor),

      table.topAnchor.constraint(equalTo: crumbScroll.bottomAnchor, constant: 8),
      table.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      table.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      table.bottomAnchor.constraint(equalTo: useButton.topAnchor, constant: -12),

      useButton.centerXAnchor.constraint(equalTo: centerXAnchor),
      useButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),

      statusView.centerXAnchor.constraint(equalTo: table.centerXAnchor),
      statusView.centerYAnchor.constraint(equalTo: table.centerYAnchor),
      statusView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
      statusView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
    ])
    _render()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    session?.stop()
  }

  // MARK: Driving it

  /// Connect to `hostAlias` (headless) and show its home, or `startAt` when given (an existing pick).
  func start(hostAlias: String, startAt: String? = nil) {
    start(target: MoshroomConnectTarget(alias: hostAlias), startAt: startAt)
  }

  /// The same for any target, including a host the editor has not saved yet.
  func start(target: MoshroomConnectTarget, startAt: String? = nil) {
    session?.stop()
    let s = MoshxploreSession()
    session = s
    self.target = target
    self.startAt = startAt
    let hostAlias = target.alias
    home = nil
    folders = []
    files = []
    generation += 1
    let gen = generation
    _status(busy: "Connecting to \(hostAlias)\u{2026}")
    _armWatchdog(generation: gen, reopenAt: startAt)
    s.connect(target: target) { [weak self] result in
      guard let self, self.generation == gen else { return }
      self._disarmWatchdog()
      switch result {
      case .success(let home):
        self.answerField.text = ""
        if let password = target.answers.password, !password.isEmpty {
          self.onPasswordAccepted?(password)
        }
        self.home = home
        if let startAt, !startAt.isEmpty, startAt != home {
          // Open where the folder already is; if it is gone, fall back to home.
          self._load(Self._expand(startAt, home: home), fallback: home)
        } else {
          self._load(home)
        }
      case .failure(let e):
        if let need = e as? MoshroomHeadlessNeed, self._ask(need) { return }
        self._failed(e.localizedDescription) { [weak self] in self?.start(target: target, startAt: startAt) }
      }
    }
  }

  /// The server asked something a terminal would have asked: ask it here. False when it is not a
  /// question this place can settle (a CHANGED host key is reviewed in a terminal, on purpose).
  private func _ask(_ need: MoshroomHeadlessNeed) -> Bool {
    guard var target else { return false }
    let name = target.alias
    switch need {
    case .hostKey(let fingerprint, let changed):
      guard !changed else { return false }
      _question(
        "First connection to \(name). Its key fingerprint is\n\(fingerprint)\nTrust this server and continue?",
        answer: "Trust and continue", field: false
      ) { [weak self] in
        guard let self else { return }
        target.answers.trustedHostKey = fingerprint
        self.start(target: target, startAt: self.startAt)
      }
    case .password:
      // Only where the answer can be kept (the host editor): a password typed for a browse alone
      // would let the user pick a folder that every later connect then fails to reach.
      guard onPasswordAccepted != nil else { return false }
      let retried = !(target.answers.password ?? "").isEmpty
      _question(
        retried ? "\(name) did not accept that password. Try again." : "\(name) asks for a password.",
        answer: "Connect", field: true
      ) { [weak self] in
        guard let self else { return }
        let password = self.answerField.text ?? ""
        guard !password.isEmpty else { return }
        self.answerField.resignFirstResponder()
        target.answers.password = password
        self.start(target: target, startAt: self.startAt)
      }
    }
    return true
  }

  func stop() {
    generation += 1
    _disarmWatchdog()
    session?.stop()
    session = nil
  }

  private func _armWatchdog(generation gen: Int, reopenAt: String?) {
    watchdog?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == gen, let target = self.target else { return }
      // Abandon the silent session; a late answer is ignored by the generation bump. Retry dials anew.
      self.generation += 1
      self.session?.stop()
      self.session = nil
      self._failed("\(target.alias) is not answering. Try again in a moment.") { [weak self] in
        self?.start(target: target, startAt: reopenAt)
      }
    }
    watchdog = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchdogSeconds, execute: work)
  }

  private func _disarmWatchdog() {
    watchdog?.cancel()
    watchdog = nil
  }

  private static func _expand(_ path: String, home: String) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return (home as NSString).appendingPathComponent(String(path.dropFirst(2))) }
    return path
  }

  private func _goUp() {
    guard path != "/" else { return }
    let parent = (path as NSString).deletingLastPathComponent
    _load(parent.isEmpty ? "/" : parent)
  }

  private func _load(_ target: String, fallback: String? = nil) {
    guard let session else { return }
    generation += 1
    let gen = generation
    _status(busy: "Loading\u{2026}")
    _armWatchdog(generation: gen, reopenAt: target)
    session.list(path: target) { [weak self] result in
      guard let self, self.generation == gen else { return }
      self._disarmWatchdog()
      switch result {
      case .success(let entries):
        self.path = target
        // Like `ls`: no dotfiles. A link the listing did not get to resolve may well be a folder, so
        // it stays tappable (opening it tells).
        let visible = entries.filter { !$0.name.hasPrefix(".") }
        self.folders = visible.filter { $0.isDirectory || ($0.isSymlink && !$0.isResolved) }
        self.files = visible.filter { !($0.isDirectory || ($0.isSymlink && !$0.isResolved)) }
        self._render()
      case .failure(let e):
        if let fallback {
          self._load(fallback)
          return
        }
        let back = self.path
        self._failed(e.localizedDescription) { [weak self] in self?._load(back) }
      }
    }
  }

  // MARK: Rendering

  private func _status(busy text: String) {
    statusSpinner.startAnimating()
    statusSpinner.isHidden = false
    statusLabel.text = text
    statusAction.isHidden = true
    _hideAnswer()
    statusView.isHidden = false
    table.isHidden = true
    useButton.isEnabled = false
  }

  private func _hideAnswer() {
    answerField.isHidden = true
    answerButton.isHidden = true
    answerHandler = nil
  }

  /// A question with one answer (and the usual way out under it): a host key to trust, or a password.
  private func _question(_ message: String, answer: String, field: Bool, onAnswer: @escaping () -> Void) {
    // The usual failure layout first (label, way out), then the answer on top of it.
    _failed(message) { [weak self] in
      guard let self, let target = self.target else { return }
      self.start(target: target, startAt: self.startAt)
    }
    var cfg = answerButton.configuration ?? .filled()
    var attr = AttributeContainer()
    attr.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    cfg.attributedTitle = AttributedString(answer, attributes: attr)
    answerButton.configuration = cfg
    answerButton.isHidden = false
    answerField.text = ""
    answerField.isHidden = !field
    answerHandler = onAnswer
    // The way out under a question is going back, never "Try again" (that would ask the same thing).
    if onChangeHost == nil { statusAction.isHidden = true }
    if field { DispatchQueue.main.async { [weak self] in self?.answerField.becomeFirstResponder() } }
  }

  private func _failed(_ message: String, retry: @escaping () -> Void) {
    statusSpinner.stopAnimating()
    statusSpinner.isHidden = true
    statusLabel.text = message
    _hideAnswer()
    var cfg = statusAction.configuration ?? .plain()
    var attr = AttributeContainer()
    attr.font = UIFont.preferredFont(forTextStyle: .headline)
    if let onChangeHost {
      cfg.attributedTitle = AttributedString("Back to hosts", attributes: attr)
      statusActionHandler = onChangeHost
    } else {
      cfg.attributedTitle = AttributedString("Try again", attributes: attr)
      statusActionHandler = retry
    }
    statusAction.configuration = cfg
    statusAction.isHidden = false
    statusView.isHidden = false
    table.isHidden = true
    useButton.isEnabled = false
  }

  private func _render() {
    statusSpinner.stopAnimating()
    statusView.isHidden = true
    _hideAnswer()
    table.isHidden = false
    upButton.isEnabled = path != "/"
    upButton.alpha = upButton.isEnabled ? 1 : 0.4
    homeButton.isEnabled = home != nil && home != path
    homeButton.alpha = homeButton.isEnabled ? 1 : 0.4
    useButton.isEnabled = session != nil && home != nil
    _renderCrumbs()
    table.reloadData()
    if !folders.isEmpty || !files.isEmpty {
      table.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
    }
    if folders.isEmpty && files.isEmpty && home != nil {
      statusSpinner.isHidden = true
      statusLabel.text = "This folder is empty."
      statusAction.isHidden = true
      statusView.isHidden = false
    }
  }

  private func _renderCrumbs() {
    crumbStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    var parts: [(label: String, path: String)] = [("/", "/")]
    var built = ""
    for component in path.split(separator: "/") {
      built += "/" + component
      parts.append((String(component), built))
    }
    for (index, part) in parts.enumerated() {
      if index > 1 {
        let sep = UILabel()
        sep.text = "/"
        sep.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        sep.textColor = .tertiaryLabel
        sep.setContentHuggingPriority(.required, for: .horizontal)
        crumbStack.addArrangedSubview(sep)
      }
      let last = index == parts.count - 1
      var cfg = UIButton.Configuration.plain()
      var attr = AttributeContainer()
      attr.font = UIFont.monospacedSystemFont(ofSize: 13, weight: last ? .semibold : .regular)
      cfg.attributedTitle = AttributedString(part.label, attributes: attr)
      cfg.baseForegroundColor = last ? .label : .secondaryLabel
      cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
      let b = moshButton()
      b.configuration = cfg
      #if targetEnvironment(macCatalyst)
      b.preferredBehavioralStyle = .pad
      #endif
      // Each crumb is exactly as wide as its name (a stack in a scroll view would stretch them).
      b.setContentHuggingPriority(.required, for: .horizontal)
      b.setContentCompressionResistancePriority(.required, for: .horizontal)
      let target = part.path
      b.addAction(UIAction { [weak self] _ in
        guard let self, target != self.path else { return }
        self._load(target)
      }, for: .touchUpInside)
      crumbStack.addArrangedSubview(b)
    }
    // The end of the path is the part that matters: keep it in view.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.crumbScroll.layoutIfNeeded()
      let x = max(0, self.crumbScroll.contentSize.width - self.crumbScroll.bounds.width)
      self.crumbScroll.setContentOffset(CGPoint(x: x, y: 0), animated: false)
    }
  }

  // MARK: Table

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    folders.count + files.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    // swiftlint:disable:next force_cast
    let cell = tableView.dequeueReusableCell(withIdentifier: MoshFolderCell.id, for: indexPath) as! MoshFolderCell
    if indexPath.row < folders.count {
      let entry = folders[indexPath.row]
      cell.configure(name: entry.name, isFolder: true, isLink: entry.isSymlink)
    } else {
      let entry = files[indexPath.row - folders.count]
      cell.configure(name: entry.name, isFolder: false, isLink: entry.isSymlink)
    }
    return cell
  }

  func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
    indexPath.row < folders.count
  }

  func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
    indexPath.row < folders.count ? indexPath : nil
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: false)
    guard indexPath.row < folders.count else { return }
    let base = path == "/" ? "" : path
    _load(base + "/" + folders[indexPath.row].name)
  }
}

/// One row of the browser: a folder is a card with a red folder glyph and a chevron; a file is the same
/// row, dimmed and inert, there only so the user recognises where they are.
private final class MoshFolderCell: UITableViewCell {
  static let id = "MoshFolderCell"
  private let card = UIView()
  private let icon = UIImageView()
  private let nameLabel = UILabel()
  private let chevron = UIImageView(image: UIImage(systemName: "chevron.right",
    withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none
    card.translatesAutoresizingMaskIntoConstraints = false
    card.layer.cornerRadius = Moshstyle.rowRadius
    card.layer.cornerCurve = .continuous
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.contentMode = .scaleAspectFit
    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    nameLabel.lineBreakMode = .byTruncatingMiddle
    chevron.translatesAutoresizingMaskIntoConstraints = false
    chevron.tintColor = .tertiaryLabel
    contentView.addSubview(card)
    [icon, nameLabel, chevron].forEach(card.addSubview)
    NSLayoutConstraint.activate([
      card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
      card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
      card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
      card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
      icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
      icon.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 20),
      nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
      nameLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
      chevron.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
      chevron.centerYAnchor.constraint(equalTo: card.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func setHighlighted(_ highlighted: Bool, animated: Bool) {
    super.setHighlighted(highlighted, animated: animated)
    card.alpha = highlighted ? 0.7 : 1
  }

  func configure(name: String, isFolder: Bool, isLink: Bool) {
    nameLabel.text = name
    // A linked folder is a folder like any other here (it opens); only its glyph says it is a link.
    let symbol = !isFolder ? "doc" : (isLink ? "arrow.turn.down.right" : "folder.fill")
    icon.image = UIImage(systemName: symbol,
                         withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))?
      .withTintColor(isFolder ? .moshroomTint : .tertiaryLabel, renderingMode: .alwaysOriginal)
    if isFolder {
      card.backgroundColor = .secondarySystemGroupedBackground
      nameLabel.font = .systemFont(ofSize: 15, weight: .medium)
      nameLabel.textColor = .label
      chevron.isHidden = false
    } else {
      card.backgroundColor = .clear
      nameLabel.font = .systemFont(ofSize: 14)
      nameLabel.textColor = .tertiaryLabel
      chevron.isHidden = true
    }
  }
}

// MARK: - SwiftUI: the project folder picker

/// The browser as a full-screen page of its own (presented with fullScreenCover, so its close and the
/// browser's buttons take taps on the Mac too): the in-content header, then the browser.
struct MoshFolderPickerScreen: View {
  let target: MoshroomConnectTarget
  var startAt: String? = nil
  var onPasswordAccepted: ((String) -> Void)? = nil
  let onPick: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      MoshSheetHeader(title: "Choose a folder", onClose: { dismiss() })
      MoshFolderBrowserRepresentable(target: target, startAt: startAt, onPasswordAccepted: onPasswordAccepted) { path in
        onPick(path)
        dismiss()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(.systemGroupedBackground).ignoresSafeArea())
  }
}

private struct MoshFolderBrowserRepresentable: UIViewRepresentable {
  let target: MoshroomConnectTarget
  let startAt: String?
  let onPasswordAccepted: ((String) -> Void)?
  let onUse: (String) -> Void

  func makeUIView(context: Context) -> MoshFolderBrowserView {
    let view = MoshFolderBrowserView(title: "On \(target.alias)")
    // SwiftUI places a representable by its frame: Auto Layout sizing would leave it collapsed.
    view.translatesAutoresizingMaskIntoConstraints = true
    view.onUse = onUse
    view.onPasswordAccepted = onPasswordAccepted
    view.start(target: target, startAt: startAt)
    return view
  }

  // The browser takes whatever room it is given (it has no size of its own to offer).
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: MoshFolderBrowserView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 320, height: proposal.height ?? 480)
  }

  func updateUIView(_ view: MoshFolderBrowserView, context: Context) {
    view.onUse = onUse
    view.onPasswordAccepted = onPasswordAccepted
  }

  static func dismantleUIView(_ view: MoshFolderBrowserView, coordinator: ()) {
    view.stop()
  }
}
