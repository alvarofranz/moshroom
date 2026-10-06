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

// Moshify's UI: the progress line, the track row, the top-bar mini player and the music tab with
// its library picker.

import UIKit

import MoshroomConfig

// MARK: - Progress line

// A hand-rolled progress line: UIProgressView renders its fill GRAY under Mac Catalyst no matter
// what progressTintColor says, so the mushroom-red progress look is painted by us — a faint red
// track with a red fill whose width follows `progress`.
final class MoshifyProgressLine: UIView {
  private let fill = UIView()

  var progress: Float = 0 {
    didSet { setNeedsLayout() }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = UIColor.moshroomTint.withAlphaComponent(Moshstyle.faintTintAlpha)
    layer.cornerRadius = 2
    clipsToBounds = true
    fill.backgroundColor = .moshroomTint
    addSubview(fill)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func layoutSubviews() {
    super.layoutSubviews()
    let w = bounds.width * CGFloat(min(max(progress, 0), 1))
    fill.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
  }
}

// MARK: - Track row

/// One track: a card with the title, its length and size underneath, and the cached dot. A card
/// (not a bare table row) so rows have air between them and the playing one reads as a filled
/// mushroom pill — the same row language as Moshxplore's listings.
final class MoshifyTrackCell: UITableViewCell {

  static let reuseID = "MoshifyTrackCell"
  static let height: CGFloat = 68

  private let card = UIView()
  private let title = UILabel()
  private let meta = UILabel()
  private let dot = UIImageView()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none

    card.translatesAutoresizingMaskIntoConstraints = false
    card.layer.cornerRadius = Moshstyle.rowRadius
    contentView.addSubview(card)

    title.translatesAutoresizingMaskIntoConstraints = false
    title.font = .systemFont(ofSize: 15, weight: .regular)
    title.lineBreakMode = .byTruncatingMiddle
    meta.translatesAutoresizingMaskIntoConstraints = false
    meta.font = .systemFont(ofSize: 12)
    dot.translatesAutoresizingMaskIntoConstraints = false
    dot.contentMode = .center
    dot.setContentHuggingPriority(.required, for: .horizontal)

    let labels = UIStackView(arrangedSubviews: [title, meta])
    labels.axis = .vertical
    labels.spacing = 3
    labels.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(labels)
    card.addSubview(dot)

    NSLayoutConstraint.activate([
      // The 5pt inset IS the gap between rows.
      card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
      card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
      card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      labels.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
      labels.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      labels.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -10),
      dot.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
      dot.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 12),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func configure(title trackTitle: String, meta metaText: String, isCurrent: Bool, cached: Bool) {
    title.text = trackTitle
    title.font = .systemFont(ofSize: 15, weight: isCurrent ? .semibold : .regular)
    title.textColor = isCurrent ? .white : MoshxploreStyle.dark
    meta.text = metaText
    meta.textColor = isCurrent ? UIColor(white: 1, alpha: 0.85) : MoshxploreStyle.gray
    card.backgroundColor = isCurrent ? .moshroomTint : MoshxploreStyle.row
    dot.isHidden = !cached
    dot.image = UIImage(systemName: "circle.fill",
                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 7))?
      .withTintColor(isCurrent ? .white : UIColor.moshroomTint.withAlphaComponent(0.7),
                     renderingMode: .alwaysOriginal)
  }
}

// MARK: - Mini player (top bar of every other tab)

/// The music keeps playing when you leave its tab, so the chrome carries the controls: one compact
/// white capsule to the LEFT of the launcher key with play/pause, skip and the song's title. Tapping
/// the title jumps to the tab that owns the music. Sized to sit on one line next to the Tabs key and
/// the tab pill on a phone, with the title taking whatever room is left.
final class MoshifyMiniPlayer: UIView {

  private let playButton = moshButton()
  private let nextButton = moshButton()
  private let titleLabel = UILabel()
  var onOpen: (() -> Void)?

  static let height: CGFloat = 34

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = Moshstyle.chipFill
    layer.cornerRadius = Self.height / 2
    Moshstyle.applyChipShadow(layer)

    playButton.setMoshIcon("play.fill", pointSize: 12, weight: .semibold)
    playButton.addAction(UIAction { _ in MoshifyEngine.shared.togglePlayPause() }, for: .touchUpInside)
    nextButton.setMoshIcon("forward.end.fill", pointSize: 11, weight: .semibold)
    nextButton.addAction(UIAction { _ in MoshifyEngine.shared.next() }, for: .touchUpInside)

    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    titleLabel.textColor = Moshstyle.ink
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.isUserInteractionEnabled = true
    titleLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(_open)))

    let stack = UIStackView(arrangedSubviews: [playButton, nextButton, titleLabel])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      playButton.widthAnchor.constraint(equalToConstant: 16),
      nextButton.widthAnchor.constraint(equalToConstant: 16),
      // Long titles truncate instead of pushing the tab pill off the bar.
      titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  @objc private func _open() { onOpen?() }

  /// True when there is music to control. Reads the engine; the caller owns the visibility.
  @discardableResult
  func sync() -> Bool {
    let engine = MoshifyEngine.shared
    switch engine.state {
    case .playing(let t):
      titleLabel.text = t.title
      playButton.setMoshIcon("pause.fill", pointSize: 12, weight: .semibold)
      return true
    case .paused(let t):
      titleLabel.text = t.title
      playButton.setMoshIcon("play.fill", pointSize: 12, weight: .semibold)
      return true
    case .downloading(let t, _):
      titleLabel.text = t.title
      playButton.setMoshIcon("play.fill", pointSize: 12, weight: .semibold)
      return true
    default:
      return false
    }
  }
}

// MARK: - The Moshify tab

// A thin observer over the engine, plus the one-time setup flow (pick a host → pick a folder).
// Plain UIKit on purpose — a UIHostingController page renders nothing on Catalyst inside the
// tabs page VC. The page rests on the live root ground (the Part A rule) so it never cuts a
// different black into the strips around the viewport.
final class MoshifyTabController: UIViewController, MoshroomTabPage,
                                  UITableViewDataSource, UITableViewDelegate {

  let moshroomTabKey: UUID
  var moshroomTabKind: MoshroomTabKind { .moshify }
  /// The library this tab plays — host and folder name — because the row's music glyph already
  /// says what kind of tab it is. A tab still choosing (its picker is up, or another tab took the
  /// engine) has no library to name yet.
  var moshroomTabTitle: String? {
    let engine = MoshifyEngine.shared
    guard engine.ownerKey == moshroomTabKey,
          let host = Moshify.configuredHost,
          let folder = Moshify.configuredFolder
    else { return "Moshify" }
    return "\(host) · \(Moshify.folderName(folder))"
  }

  weak var space: SpaceController?

  private enum Step { case host, folder, player }
  private var step: Step = .player

  // Setup state: the folder step is the shared server-folder browser (MoshFolderBrowserView).
  private var setupBrowser: MoshFolderBrowserView?
  private var setupHost: String?
  private var hostsObserver: NSObjectProtocol?

  // Player chrome.
  private let table = UITableView(frame: .zero, style: .plain)
  private let statusLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let bottomBar = UIView()
  private let nowPlayingLabel = UILabel()
  private let progressBar = MoshifyProgressLine()
  private let shuffleButton = moshkeyRoundButton()
  private let playButton = moshkeyRoundButton(diameter: 56)
  private let nextButton = moshkeyRoundButton()

  // Setup chrome (built per step into `setupContainer`).
  private let setupContainer = UIView()
  private var observers: [NSObjectProtocol] = []
  /// The track the list is already centred on — see _centerCurrentTrack.
  private var _centeredKey: String?
  private var progressTimer: Timer?

  init(key: UUID = UUID()) {
    moshroomTabKey = key
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    if let hostsObserver { NotificationCenter.default.removeObserver(hostsObserver) }
    progressTimer?.invalidate()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = space?.view.backgroundColor ?? .moshroomBackground

    let engine = MoshifyEngine.shared

    _buildPlayerChrome()
    _buildSetupContainer()

    let nc = NotificationCenter.default
    observers = [
      nc.addObserver(forName: .moshifyStateDidChange, object: nil, queue: .main) { [weak self] _ in
        self?._syncControls()
      },
      nc.addObserver(forName: .moshifyLibraryDidChange, object: nil, queue: .main) { [weak self] _ in
        self?.table.reloadData()
        self?._syncControls()
      },
      nc.addObserver(forName: .moshifyProgressDidChange, object: nil, queue: .main) { [weak self] _ in
        self?._syncProgress()
      },
      // Another music tab took the engine: this one is no longer a player, so it goes back to its
      // picker instead of showing controls that would drive someone else's library.
      nc.addObserver(forName: .moshifyOwnerDidChange, object: nil, queue: .main) { [weak self] _ in
        guard let self, self.step == .player,
              MoshifyEngine.shared.ownerKey != self.moshroomTabKey else { return }
        self._show(step: .host)
      },
    ]

    // A music tab is its own thing: it ALWAYS opens on the picker (recents make that one tap),
    // never as a silent continuation of whatever played last. The one exception is the tab that
    // already owns the engine — switching back to it must find its player, not a wizard.
    if engine.ownerKey == moshroomTabKey, engine.isConfigured {
      _show(step: .player)
      if case .idle = engine.state { engine.refreshLibrary() }
    } else {
      _show(step: .host)
    }
    _syncControls()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // Coming back to this tab should show where the music IS, not wherever the list happened to be
    // left (a tab switch or a resize rebuilds the table and its offset). Forget what was centred so
    // the playing row is brought back to the middle.
    _centeredKey = nil
    _centerCurrentTrack()
  }

  func moshroomTabWillClose() {
    // Tab semantics: closing the tab stops the music — but only if this tab is the one playing.
    // Closing a music tab that had handed the engine over must not silence the tab that owns it.
    setupBrowser?.stop()
    setupBrowser = nil
    if MoshifyEngine.shared.ownerKey == moshroomTabKey {
      MoshifyEngine.shared.shutdown()
    }
  }

  // MARK: chrome building

  private func _buildPlayerChrome() {
    table.translatesAutoresizingMaskIntoConstraints = false
    table.backgroundColor = .clear
    table.separatorStyle = .none
    table.dataSource = self
    table.delegate = self
    table.register(MoshifyTrackCell.self, forCellReuseIdentifier: MoshifyTrackCell.reuseID)
    table.rowHeight = MoshifyTrackCell.height
    view.addSubview(table)

    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.backgroundColor = .clear
    view.addSubview(bottomBar)

    nowPlayingLabel.translatesAutoresizingMaskIntoConstraints = false
    nowPlayingLabel.font = .systemFont(ofSize: 14, weight: .medium)
    nowPlayingLabel.textColor = .secondaryLabel
    nowPlayingLabel.textAlignment = .center
    nowPlayingLabel.numberOfLines = 1
    bottomBar.addSubview(nowPlayingLabel)

    progressBar.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.addSubview(progressBar)

    shuffleButton.setMoshIcon("shuffle", pointSize: 17, weight: .semibold)
    shuffleButton.addAction(UIAction { _ in
      MoshifyEngine.shared.shuffle.toggle()
    }, for: .touchUpInside)
    playButton.setMoshIcon("play.fill", pointSize: 24, weight: .semibold)
    playButton.addAction(UIAction { _ in
      MoshifyEngine.shared.togglePlayPause()
    }, for: .touchUpInside)
    nextButton.setMoshIcon("forward.end.fill", pointSize: 17, weight: .semibold)
    nextButton.addAction(UIAction { _ in
      MoshifyEngine.shared.next()
    }, for: .touchUpInside)
    [shuffleButton, playButton, nextButton].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      bottomBar.addSubview($0)
    }

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.font = .preferredFont(forTextStyle: .callout)
    statusLabel.textColor = .secondaryLabel
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 0
    view.addSubview(statusLabel)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    view.addSubview(spinner)

    // No chrome row of its own: choosing another library is the folder key in the top bar (see
    // Moshkeys.install), which is where every other Moshroom control lives. And no clearance for
    // that bar either: this page already lives inside the viewport SpaceController pins BELOW the
    // floating chrome, so measuring the bar again here stacked two gaps and left a black band at the
    // top of the list.
    NSLayoutConstraint.activate([
      table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
      table.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      table.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      table.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

      bottomBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      bottomBar.heightAnchor.constraint(equalToConstant: 134),

      nowPlayingLabel.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 12),
      nowPlayingLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 24),
      nowPlayingLabel.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -24),

      progressBar.topAnchor.constraint(equalTo: nowPlayingLabel.bottomAnchor, constant: 14),
      progressBar.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 24),
      progressBar.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -24),
      progressBar.heightAnchor.constraint(equalToConstant: 4),

      playButton.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 18),
      playButton.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
      shuffleButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
      shuffleButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -34),
      nextButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
      nextButton.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 34),

      statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
      statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),
    ])
  }

  private func _buildSetupContainer() {
    setupContainer.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(setupContainer)
    NSLayoutConstraint.activate([
      setupContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      setupContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      setupContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      setupContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
    ])
    hostsObserver = NotificationCenter.default.addObserver(
      forName: HostsCloudMirror.didSaveNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self, self.step == .host else { return }
      self._buildHostStep()
    }
  }

  private func _show(step: Step) {
    self.step = step
    defer { space?.moshroomSyncMusicChrome() }   // the folder key hides while the picker is up
    let player = (step == .player)
    [table, bottomBar].forEach { $0.isHidden = !player }
    setupContainer.isHidden = player
    statusLabel.isHidden = !player
    if !player {
      // _syncControls only runs for the player, so the progress timer stops here.
      progressTimer?.invalidate()
      progressTimer = nil
      switch step {
      case .host: _buildHostStep()
      case .folder: _buildFolderStep()
      case .player: break
      }
    }
    _syncControls()
  }

  /// True while this tab shows its player. The top bar's folder key only makes sense then: with the
  /// picker already up there is nothing to change.
  var moshroomIsChoosingLibrary: Bool { step != .player }

  /// Choose another library from this tab (the folder key in the top bar).
  func moshroomChooseLibrary() { _startSetup() }

  private func _startSetup() {
    setupHost = nil
    setupBrowser?.stop()
    setupBrowser = nil
    _show(step: .host)
  }

  private func _clearSetupContainer() {
    setupContainer.subviews.forEach { $0.removeFromSuperview() }
  }

  private func _setupTitle(_ text: String) -> UILabel {
    let l = UILabel()
    l.translatesAutoresizingMaskIntoConstraints = false
    l.text = text
    l.font = .systemFont(ofSize: 20, weight: .semibold)
    l.textColor = .label
    return l
  }

  /// A quiet heading inside the setup list ("Recent", "Browse a host").
  private func _setupGroupLabel(_ text: String) -> UILabel {
    let l = UILabel()
    l.text = text.uppercased()
    l.font = .systemFont(ofSize: 12, weight: .semibold)
    l.textColor = .secondaryLabel
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
  }

  private func _buildHostStep() {
    _clearSetupContainer()
    let title = _setupTitle("Where does your music live?")
    let subtitle = UILabel()
    subtitle.translatesAutoresizingMaskIntoConstraints = false
    subtitle.text = "Pick a saved host, then the folder with your audio files."
    subtitle.font = .preferredFont(forTextStyle: .callout)
    subtitle.textColor = .secondaryLabel
    subtitle.numberOfLines = 0

    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)

    // Recents first: a library you have played before is one tap away, host AND folder, no
    // browsing. This is what makes "every music tab asks" cheap instead of tedious.
    let recents = Moshify.recents
    if !recents.isEmpty {
      stack.addArrangedSubview(_setupGroupLabel("Recent"))
      for recent in recents {
        let b = moshHostCardButton(alias: recent.host, description: recent.folderName, icon: "music.note")
        b.addAction(UIAction { [weak self] _ in
          self?._start(host: recent.host, folder: recent.folder)
        }, for: .touchUpInside)
        stack.addArrangedSubview(b)
      }
    }

    let cards = space?.moshroomSavedHostCards ?? []
    if cards.isEmpty {
      subtitle.text = recents.isEmpty
        ? "No saved hosts yet. Add one in Settings → Hosts first."
        : "Pick a recent library, or add a host in Settings → Hosts to browse a new one."
    }
    if !cards.isEmpty && !recents.isEmpty {
      stack.addArrangedSubview(_setupGroupLabel("Browse a host"))
    }
    for card in cards {
      let b = moshHostCardButton(alias: card.alias, description: card.description)
      b.addAction(UIAction { [weak self] _ in self?._pickHost(card.alias) }, for: .touchUpInside)
      stack.addArrangedSubview(b)
    }

    setupContainer.addSubview(title)
    setupContainer.addSubview(subtitle)
    setupContainer.addSubview(scroll)
    NSLayoutConstraint.activate([
      title.topAnchor.constraint(equalTo: setupContainer.topAnchor, constant: 18),
      title.leadingAnchor.constraint(equalTo: setupContainer.leadingAnchor, constant: 20),
      title.trailingAnchor.constraint(lessThanOrEqualTo: setupContainer.trailingAnchor, constant: -20),
      subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
      subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      subtitle.trailingAnchor.constraint(equalTo: setupContainer.trailingAnchor, constant: -20),
      scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
      scroll.leadingAnchor.constraint(equalTo: setupContainer.leadingAnchor, constant: 20),
      scroll.trailingAnchor.constraint(equalTo: setupContainer.trailingAnchor, constant: -20),
      scroll.bottomAnchor.constraint(equalTo: setupContainer.bottomAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
    ])
  }

  private func _pickHost(_ alias: String) {
    // A music tab stands on its own and connects HEADLESS, here and in the worker: a prompt it
    // cannot answer fails with a reason instead of waiting in a terminal tab nobody is looking at.
    // The browser is the shared one (MoshFolderBrowserView), the same a project's folder is picked in.
    setupHost = alias
    setupBrowser?.stop()
    let browser = MoshFolderBrowserView(title: "Pick the music folder")
    browser.onChangeHost = { [weak self] in self?._startSetup() }
    browser.onUse = { [weak self] folder in self?._start(host: alias, folder: folder) }
    setupBrowser = browser
    _show(step: .folder)
    browser.start(hostAlias: alias)
  }

  private func _buildFolderStep() {
    _clearSetupContainer()
    guard let browser = setupBrowser else { return }
    setupContainer.addSubview(browser)
    NSLayoutConstraint.activate([
      browser.topAnchor.constraint(equalTo: setupContainer.topAnchor),
      browser.leadingAnchor.constraint(equalTo: setupContainer.leadingAnchor),
      browser.trailingAnchor.constraint(equalTo: setupContainer.trailingAnchor),
      browser.bottomAnchor.constraint(equalTo: setupContainer.bottomAnchor),
    ])
  }

  /// Take the engine and play this library here. The one door into the player, from both the folder
  /// browser and a recents row.
  private func _start(host: String, folder: String) {
    setupBrowser?.stop()
    setupBrowser = nil
    setupHost = host
    _show(step: .player)
    MoshifyEngine.shared.configure(hostAlias: host, folder: folder, owner: moshroomTabKey)
    MoshLog.log("moshify", "library started in this tab")
  }

  // MARK: live sync

  private func _syncControls() {
    guard step == .player else { return }
    let engine = MoshifyEngine.shared
    let state = engine.state

    // The center status only speaks when the list has nothing to say.
    switch state {
    case .connecting:
      statusLabel.text = engine.tracks.isEmpty ? "Connecting…" : nil
      engine.tracks.isEmpty ? spinner.startAnimating() : spinner.stopAnimating()
    case .error(let message):
      statusLabel.text = message
      spinner.stopAnimating()
    case .ready where engine.tracks.isEmpty:
      statusLabel.text = "No audio files in this folder yet."
      spinner.stopAnimating()
    default:
      statusLabel.text = nil
      spinner.stopAnimating()
    }
    statusLabel.isHidden = (statusLabel.text == nil)

    switch state {
    case .playing(let t):
      nowPlayingLabel.text = t.title
      playButton.setMoshIcon("pause.fill", pointSize: 24, weight: .semibold)
    case .paused(let t):
      nowPlayingLabel.text = t.title
      playButton.setMoshIcon("play.fill", pointSize: 24, weight: .semibold)
    case .downloading(let t, _):
      nowPlayingLabel.text = "Fetching \(t.title)…"
      playButton.setMoshIcon("play.fill", pointSize: 24, weight: .semibold)
    default:
      nowPlayingLabel.text = " "
      playButton.setMoshIcon("play.fill", pointSize: 24, weight: .semibold)
    }

    // Shuffle ON = the one filled-red round key.
    if engine.shuffle {
      shuffleButton.backgroundColor = .moshroomTint
      shuffleButton.setMoshIcon("shuffle", pointSize: 17, weight: .semibold, color: .white)
    } else {
      shuffleButton.backgroundColor = Moshstyle.chipFill
      shuffleButton.setMoshIcon("shuffle", pointSize: 17, weight: .semibold)
    }

    _syncProgress()
    _syncProgressTimer()
    table.reloadData()
    _centerCurrentTrack()
  }

  /// Every song change (tapped, continued or shuffled) brings the playing row to the MIDDLE of the
  /// list, so the eye never has to hunt for where the music is. Only on an actual change of track:
  /// re-centering on every state tick would fight the user scrolling through the library.
  private func _centerCurrentTrack() {
    let engine = MoshifyEngine.shared
    guard let track = engine.currentTrack else { _centeredKey = nil; return }
    guard _centeredKey != track.cacheKey, let row = engine.currentIndex,
          engine.tracks.indices.contains(row) else { return }
    _centeredKey = track.cacheKey
    let path = IndexPath(row: row, section: 0)
    // After the reload above, so the row exists to scroll to.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.step == .player,
            self.table.numberOfRows(inSection: 0) > row else { return }
      self.table.scrollToRow(at: path, at: .middle, animated: true)
    }
  }

  private func _syncProgress() {
    let engine = MoshifyEngine.shared
    switch engine.state {
    case .downloading(_, let frac):
      progressBar.progress = Float(frac)
    case .playing, .paused:
      let d = engine.duration
      progressBar.progress = d > 0 ? Float(engine.elapsed / d) : 0
    default:
      progressBar.progress = 0
    }
  }

  private func _syncProgressTimer() {
    if case .playing = MoshifyEngine.shared.state {
      guard progressTimer == nil else { return }
      progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        self?._syncProgress()
      }
    } else {
      progressTimer?.invalidate()
      progressTimer = nil
    }
  }

  // MARK: table

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    MoshifyEngine.shared.tracks.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: MoshifyTrackCell.reuseID, for: indexPath)
    let engine = MoshifyEngine.shared
    guard let cell = cell as? MoshifyTrackCell,
          engine.tracks.indices.contains(indexPath.row) else { return cell }
    let track = engine.tracks[indexPath.row]
    cell.configure(title: track.title,
                   meta: Self._meta(for: track, engine: engine),
                   isCurrent: track == engine.currentTrack,
                   cached: engine.isCached(track))
    return cell
  }

  /// Length and size, with the length only when it is KNOWN (the file has been on the device) —
  /// a guessed time would be worse than none.
  private static func _meta(for track: MoshifyTrack, engine: MoshifyEngine) -> String {
    let size = ByteCountFormatter.string(fromByteCount: Int64(track.size), countStyle: .file)
    guard let seconds = engine.duration(of: track), seconds > 0 else { return size }
    return "\(_clock(seconds)) · \(size)"
  }

  private static func _clock(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let minutes = total / 60, secs = total % 60
    if minutes >= 60 {
      return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
  }

  func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell,
                 forRowAt indexPath: IndexPath) {
    // Reading a length costs a small header read, so only the rows on screen ask for one.
    let engine = MoshifyEngine.shared
    guard engine.tracks.indices.contains(indexPath.row) else { return }
    engine.ensureDuration(for: engine.tracks[indexPath.row])
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    MoshifyEngine.shared.play(at: indexPath.row)
  }

  // The one delete flow: confirm, unlink on the server, only then forget locally.
  private func _confirmDelete(_ track: MoshifyTrack, done: ((Bool) -> Void)? = nil) {
    let alert = UIAlertController(
      title: "Delete \"\(track.title)\"?",
      message: "The file is removed from the server. This cannot be undone.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done?(false) })
    alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
      MoshifyEngine.shared.deleteTrack(track) { [weak self] errorMessage in
        if let errorMessage {
          let oops = UIAlertController(title: "Could not delete", message: errorMessage, preferredStyle: .alert)
          oops.addAction(UIAlertAction(title: "OK", style: .default))
          self?.present(oops, animated: true)
        }
        done?(errorMessage == nil)
      }
    })
    present(alert, animated: true)
  }

  func tableView(_ tableView: UITableView,
                 trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    let engine = MoshifyEngine.shared
    guard engine.tracks.indices.contains(indexPath.row) else { return nil }
    let track = engine.tracks[indexPath.row]
    let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
      guard let self else { done(false); return }
      self._confirmDelete(track, done: done)
    }
    delete.backgroundColor = .moshroomTint   // destructive is mushroom red, never system red
    return UISwipeActionsConfiguration(actions: [delete])
  }

  // A mouse cannot reveal swipe actions on Mac Catalyst, so delete also lives in the row's
  // context menu (right-click on the Mac, long-press on iPhone).
  func tableView(_ tableView: UITableView,
                 contextMenuConfigurationForRowAt indexPath: IndexPath,
                 point: CGPoint) -> UIContextMenuConfiguration? {
    let engine = MoshifyEngine.shared
    guard engine.tracks.indices.contains(indexPath.row) else { return nil }
    let track = engine.tracks[indexPath.row]
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
      UIMenu(children: [
        UIAction(title: "Delete from server", image: UIImage(systemName: "trash"),
                 attributes: .destructive) { [weak self] _ in
          self?._confirmDelete(track)
        },
      ])
    }
  }
}

// MARK: - SpaceController glue

extension SpaceController {
  // Open a new music tab on its picker. The engine is a singleton, so only the tab that owns it
  // plays; every other music tab shows its picker (see MoshifyEngine.ownerKey).
  func openMoshifyTab() {
    if presentedViewController != nil { dismiss(animated: false) }
    // Always a NEW tab with its picker: tapping Moshify means "I want to open a library", and
    // jumping to the one already playing took that choice away (the playing tab is one tap away in
    // Tabs, or through the title in the top-bar controls).
    let ctrl = MoshifyTabController()
    ctrl.space = self
    moshroomOpenTabPage(ctrl)
  }
}
