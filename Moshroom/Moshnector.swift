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
  case ssh, mosh
  var command: String { self == .ssh ? "ssh" : "mosh" }
}

// The quick-connect card itself. Pure presentation — SpaceController owns the lifecycle.
final class MoshnectorView: UIView {

  var onConnect: ((MoshnectorMode, String) -> Void)?

  private var mode: MoshnectorMode = .mosh
  private let modeControl = UISegmentedControl(items: ["Mosh", "SSH"])
  private let rowsStack = UIStackView()
  private let emptyLabel = UILabel()
  private let scroll = UIScrollView()

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = UIColor(white: 0.97, alpha: 0.97)
    layer.cornerRadius = 18
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.22
    layer.shadowRadius = 12
    layer.shadowOffset = CGSize(width: 0, height: 4)

    let title = UILabel()
    title.text = "Quick Connect"
    title.textAlignment = .center
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    title.textColor = UIColor(white: 0.12, alpha: 1)

    modeControl.selectedSegmentIndex = 0
    // High-contrast mushroom-red selection (white text), so the chosen mode is unmistakable.
    modeControl.selectedSegmentTintColor = .moshroomTint
    modeControl.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 14, weight: .semibold)], for: .selected)
    modeControl.setTitleTextAttributes([.foregroundColor: UIColor(white: 0.28, alpha: 1)], for: .normal)
    modeControl.addAction(UIAction { [weak self] _ in
      self?.mode = self?.modeControl.selectedSegmentIndex == 1 ? .ssh : .mosh
    }, for: .valueChanged)

    rowsStack.axis = .vertical
    rowsStack.spacing = 7
    rowsStack.alignment = .fill
    rowsStack.translatesAutoresizingMaskIntoConstraints = false

    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.showsHorizontalScrollIndicator = false
    scroll.addSubview(rowsStack)

    let emptyPara = NSMutableParagraphStyle()
    emptyPara.alignment = .center
    emptyPara.lineSpacing = 7
    emptyLabel.attributedText = NSAttributedString(
      string: "No saved hosts yet.\nAdd one in Settings → Hosts.",
      attributes: [.paragraphStyle: emptyPara,
                   .font: UIFont.systemFont(ofSize: 13),
                   .foregroundColor: UIColor(white: 0.45, alpha: 1)])
    emptyLabel.numberOfLines = 0
    emptyLabel.isHidden = true

    let stack = UIStackView(arrangedSubviews: [title, modeControl, scroll, emptyLabel])
    stack.axis = .vertical
    stack.spacing = 12
    stack.alignment = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    // Shrink-wrap the scroll to its content, but at a LOW priority: it must never win against the
    // rows' compression resistance, or a list taller than the 260pt cap gets squashed into it (the
    // top rows collapse). Low priority → rows keep full height and the list scrolls instead.
    let scrollToContent = scroll.heightAnchor.constraint(equalTo: rowsStack.heightAnchor)
    scrollToContent.priority = .defaultLow

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),

      rowsStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      rowsStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      rowsStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      rowsStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      rowsStack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),

      scrollToContent,
      scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 260),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // Rebuild the host list: one card per saved host — alias plus its optional gray description.
  func reload(hosts: [(alias: String, description: String)]) {
    rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    let empty = hosts.isEmpty
    emptyLabel.isHidden = !empty
    scroll.isHidden = empty
    for host in hosts { rowsStack.addArrangedSubview(_hostRow(host.alias, description: host.description)) }
    // Always start at the first host (a rebuilt scroll can otherwise keep a stale offset).
    scroll.setContentOffset(.zero, animated: false)
  }

  // A host is a proper CARD, not a thin line: red server glyph, bold alias, the optional gray
  // description underneath, generous padding. The card keeps its fixed light look (this whole
  // overlay does), so the colours are constants, not semantic.
  private func _hostRow(_ alias: String, description: String) -> UIView {
    var cfg = UIButton.Configuration.filled()
    cfg.baseBackgroundColor = UIColor(white: 0.985, alpha: 1)
    cfg.baseForegroundColor = UIColor(white: 0.12, alpha: 1)
    cfg.background.cornerRadius = 14
    cfg.background.strokeColor = UIColor(white: 0.8, alpha: 1)
    cfg.background.strokeWidth = 0.5
    cfg.image = UIImage(systemName: "server.rack", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))?
      .withTintColor(.moshroomTint, renderingMode: .alwaysOriginal)
    cfg.imagePadding = 12
    var attr = AttributeContainer()
    attr.font = .systemFont(ofSize: 16, weight: .semibold)
    cfg.attributedTitle = AttributedString(alias, attributes: attr)
    if !description.isEmpty {
      var sub = AttributeContainer()
      sub.font = .systemFont(ofSize: 13)
      sub.foregroundColor = UIColor(white: 0.45, alpha: 1)
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
    // Never let the scroll's shrink-wrap squash a row below its natural height.
    b.setContentCompressionResistancePriority(.required, for: .vertical)
    b.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.onConnect?(self.mode, alias)
    }, for: .touchUpInside)
    return b
  }
}

enum Moshnector {
  static func install(in sc: SpaceController) {
    let card = MoshnectorView()
    card.isHidden = true
    card.onConnect = { [weak sc] mode, alias in
      guard let sc else { return }
      sc.currentDevice?.write("\(mode.command) \(alias)\r")
      // Remember where we connected — Moshdrop uploads attachments to this host.
      sc.noteConnection(toHost: alias)
      // The terminal now has content (a connection) → keep Quick Connect from popping back over it.
      sc.currentTerm()?.moshroomUserHasInteracted = true
      sc.dismissMoshnector()
    }
    sc.view.addSubview(card)

    // Refresh the host list live when hosts change — local saves in Settings AND iCloud pulls —
    // so a visible Quick Connect card never shows a stale list.
    for name in [HostsCloudMirror.didSaveNotification, HostsCloudMirror.didChangeNotification] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak sc] _ in
        guard let sc,
              let card = sc.view.subviews.compactMap({ $0 as? MoshnectorView }).first,
              !card.isHidden else { return }
        card.reload(hosts: sc.moshroomSavedHostCards)
      }
    }

    NSLayoutConstraint.activate([
      // Pin near the top — just below the Tabs/Settings bar, at the terminal-body top — so opening the
      // Tabs or keys pads never collides with it. Full width minus a comfortable margin on the phone
      // (the 750-priority fill binds there); on big screens (iPad / Mac) a centered 640pt column,
      // exactly matching Moshxplore.
      card.topAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.topAnchor, constant: 76),
      card.centerXAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.centerXAnchor),
      card.leadingAnchor.constraint(greaterThanOrEqualTo: sc.view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      {
        let fill = card.leadingAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.leadingAnchor, constant: 16)
        fill.priority = .init(750)
        return fill
      }(),
      card.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
      // Never past the bottom bar, whatever the host list grows to.
      card.bottomAnchor.constraint(lessThanOrEqualTo: sc.view.safeAreaLayoutGuide.bottomAnchor, constant: -72),
    ])
  }
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
    card.reload(hosts: moshroomSavedHostCards)
    card.isHidden = false
    view.bringSubviewToFront(card)
  }

  // Hide it — called the moment the user types, taps a key, switches tab, or connects.
  func dismissMoshnector() {
    view.subviews.compactMap({ $0 as? MoshnectorView }).first?.isHidden = true
  }

  // Reveal the card only for a fresh, unconnected shell; keep it hidden for a restored or
  // still-connected ssh/mosh session (so reopening into a live mosh shows no card).
  func showMoshnectorIfIdle() {
    // Never compete with Moshxplore — while the file explorer is open, Quick Connect stays hidden.
    if moshroomMoshxploreIsOpen { dismissMoshnector(); return }
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
        if term?.moshroomConnectedHost != nil {
          term?.termView.write("\u{1B}c\u{1B}[H\u{1B}[2J\u{1B}[0m")
          term?.moshroomUserHasInteracted = false
        }
        term?.moshroomConnectedHost = nil
      }
      // Only reveal on a brand-new, untouched terminal. Once a command has run here, the shell is still
      // "fresh" (local prompt) but now has content on screen — don't pop the card back over it.
      if term?.moshroomUserHasInteracted == true {
        dismissMoshnector()
      } else {
        showMoshnector()
      }
    } else {
      dismissMoshnector()
    }
  }

  // The single place a connection's host is recorded as Moshdrop's upload target. Only saved hosts
  // qualify (an upload reuses the host's keys/config); an unknown host is ignored, never an error.
  func noteConnection(toHost alias: String) {
    if moshroomSavedHostAliases.contains(alias) {
      let term = currentTerm()
      term?.moshroomConnectedHost = alias
      term?.meta.connectedHost = alias          // persisted → the tab name survives an app relaunch
      SessionRegistry.shared.persistMetaIndex()
    }
  }

  // A command sent from the local prompt may be an `ssh <host>` / `mosh <host>` connect — if so,
  // record its host. Robust by design: rather than parse ssh's flag grammar, it picks the argument
  // that matches a saved host, so flags and their values are skipped and ad-hoc hosts simply aren't
  // tracked. Gated on the local prompt, so a prompt typed to a remote agent is never mistaken for a
  // connect — and routed through noteConnection, so there is one validate-and-store path.
  func noteConnectionCommand(_ command: String) {
    guard currentTerm()?.moshroomIsFreshShell == true else { return }
    let words = command.split(whereSeparator: { " \t\n".contains($0) }).map(String.init)
    guard let verb = words.first, verb == "ssh" || verb == "mosh" else { return }
    if let alias = words.dropFirst().first(where: moshroomSavedHostAliases.contains) {
      noteConnection(toHost: alias)
    }
  }
}
