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
//
// The Moshroom share extension. It does ONE thing: take the image(s) you shared and drop them into
// the Moshroom share tray (a folder in the shared App Group container — see MoshroomShareTray). It
// never opens the app, never touches a connection, never interferes with whatever you're doing —
// the images simply wait in the tray until, on any tab, you open Moshkitor and insert one.
//
// It shows a tiny confirmation and closes itself. That's the whole job.
//
////////////////////////////////////////////////////////////////////////////////

import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

  private let card = UIView()
  private let iconView = UIImageView()
  private let label = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)

  override func viewDidLoad() {
    super.viewDidLoad()
    // A dark, unobtrusive confirmation card centred on a dimmed backdrop — no compose sheet, no
    // buttons, nothing to fill in. It appears, confirms, and dismisses on its own.
    view.backgroundColor = UIColor.black.withAlphaComponent(0.35)

    card.backgroundColor = UIColor(white: 0.11, alpha: 1)
    card.layer.cornerRadius = 18
    card.layer.cornerCurve = .continuous
    card.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(card)

    iconView.image = UIImage(systemName: "tray.and.arrow.down.fill")
    iconView.tintColor = UIColor(red: 224/255.0, green: 51/255.0, blue: 58/255.0, alpha: 1)  // mushroom red
    iconView.contentMode = .scaleAspectFit
    iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.setContentHuggingPriority(.required, for: .vertical)

    label.text = "Adding to Moshroom…"
    label.textColor = .white
    label.font = .systemFont(ofSize: 16, weight: .medium)
    label.textAlignment = .center
    label.numberOfLines = 0
    label.translatesAutoresizingMaskIntoConstraints = false

    spinner.color = .white
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.startAnimating()

    let stack = UIStackView(arrangedSubviews: [iconView, label, spinner])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)

    NSLayoutConstraint.activate([
      card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      card.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
      card.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.85),

      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    _process()
  }

  // MARK: Save the shared images into the tray

  private func _process() {
    let providers = ((extensionContext?.inputItems as? [NSExtensionItem]) ?? [])
      .compactMap { $0.attachments }
      .flatMap { $0 }

    let imageUTI = UTType.image.identifier
    let imageProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(imageUTI) }
    guard !imageProviders.isEmpty else { _finish(saved: 0); return }

    let group = DispatchGroup()
    let lock = NSLock()
    var saved = 0

    for provider in imageProviders {
      // Prefer a concrete image type (public.png / public.jpeg) so the tray file keeps a real
      // extension; fall back to the generic image UTI.
      let concrete = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true } ?? imageUTI
      group.enter()
      provider.loadFileRepresentation(forTypeIdentifier: concrete) { url, _ in
        // The provided URL is temporary and reclaimed the moment this block returns — copy it into
        // the tray synchronously, right here, before leaving the group.
        defer { group.leave() }
        guard let url else { return }
        let ext = url.pathExtension.isEmpty ? (UTType(concrete)?.preferredFilenameExtension ?? "img") : url.pathExtension
        if MoshroomShareTray.add(fileAt: url, preferredExtension: ext) != nil {
          lock.lock(); saved += 1; lock.unlock()
        }
      }
    }

    group.notify(queue: .main) { [weak self] in self?._finish(saved: saved) }
  }

  // MARK: Confirm + close

  private func _finish(saved: Int) {
    spinner.stopAnimating()
    spinner.isHidden = true
    if saved > 0 {
      iconView.image = UIImage(systemName: "checkmark.circle.fill")
      label.text = saved == 1 ? "Added to Moshroom" : "Added \(saved) to Moshroom"
    } else {
      iconView.image = UIImage(systemName: "exclamationmark.triangle.fill")
      iconView.tintColor = .systemOrange
      label.text = "Nothing to add"
    }
    // Let the confirmation register, then dismiss the extension cleanly.
    DispatchQueue.main.asyncAfter(deadline: .now() + (saved > 0 ? 0.7 : 1.1)) { [weak self] in
      self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
  }
}
