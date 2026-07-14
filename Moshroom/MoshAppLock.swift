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

// Optional app lock: when "Require Face ID / passcode" is on (Settings › Security), a cover is shown
// whenever the app leaves the foreground — so its contents never appear in the app switcher — and
// Face ID / passcode is required to get back in (and once at launch). Off by default. Built on the
// same LocalAuth (deviceOwnerAuthentication = biometry OR passcode) that already gates key reveals,
// so a device without biometrics falls back to the passcode automatically.
@objc final class MoshAppLock: NSObject {
  @objc static let shared = MoshAppLock()

  private var coverWindow: UIWindow?
  private var locked = false
  private var authenticating = false

  private var isEnabled: Bool { MoshroomDefaults.isRequireBiometricUnlock() }

  @objc func install() {
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(_willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
    nc.addObserver(self, selector: #selector(_didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    nc.addObserver(self, selector: #selector(_didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    if isEnabled { locked = true; _showCover() }
  }

  @objc private func _willResignActive() {
    if isEnabled { _showCover() }          // hide contents from the app switcher snapshot
  }

  @objc private func _didEnterBackground() {
    if isEnabled { locked = true; _showCover() }
  }

  @objc private func _didBecomeActive() {
    guard isEnabled else { _hideCover(); return }
    if locked { _authenticate() } else { _hideCover() }
  }

  private func _authenticate() {
    guard !authenticating else { return }
    authenticating = true
    _showCover()
    LocalAuth.shared.authenticate(callback: { [weak self] ok in
      guard let self else { return }
      self.authenticating = false
      if ok {
        self.locked = false
        self._hideCover()
      }
      // On failure/cancel we stay locked; the cover shows an "Unlock" button to try again.
    }, reason: "to unlock Moshroom.")
  }

  // MARK: - Cover window

  private func _showCover() {
    guard coverWindow == nil,
          let scene = _activeScene() else { return }
    let window = UIWindow(windowScene: scene)
    window.windowLevel = .alert + 1
    window.rootViewController = MoshLockScreen { [weak self] in self?._authenticate() }
    window.isHidden = false
    coverWindow = window
  }

  private func _hideCover() {
    coverWindow?.isHidden = true
    coverWindow = nil
  }

  private func _activeScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes
    return (scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)
        ?? (scenes.first { $0.activationState == .foregroundInactive } as? UIWindowScene)
        ?? (scenes.first as? UIWindowScene)
  }
}

// The lock cover: a blurred backdrop, the Moshroom mark, and an Unlock button (shown so a cancelled
// Face ID can be retried without leaving the app).
private final class MoshLockScreen: UIViewController {
  private let onUnlock: () -> Void
  init(onUnlock: @escaping () -> Void) { self.onUnlock = onUnlock; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    blur.frame = view.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(blur)

    let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
    icon.tintColor = .moshroomTint
    icon.contentMode = .scaleAspectFit
    icon.translatesAutoresizingMaskIntoConstraints = false

    let title = UILabel()
    title.text = "Moshroom is locked"
    title.font = .systemFont(ofSize: 18, weight: .semibold)
    title.textColor = .label
    title.translatesAutoresizingMaskIntoConstraints = false

    var config = UIButton.Configuration.filled()
    config.title = "Unlock"
    config.baseBackgroundColor = .moshroomTint
    config.cornerStyle = .large
    let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onUnlock() })
    button.preferredBehavioralStyle = .pad   // Catalyst: honor the configured look (see CLAUDE.md)
    button.translatesAutoresizingMaskIntoConstraints = false

    let stack = UIStackView(arrangedSubviews: [icon, title, button])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 18
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)

    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 46),
      icon.heightAnchor.constraint(equalToConstant: 46),
      stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
  }
}
