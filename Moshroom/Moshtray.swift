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
// Moshtray: the Moshkitor-side UI for the share tray (MoshroomShareTray). A grid of the images that
// were shared to Moshroom (via the system share sheet → the Moshroom share extension), waiting to be
// used. Tap a thumbnail to drop it inline in the composer (and it leaves the tray — a shared
// screenshot is a one-shot); tap the red ✕ on a thumbnail to discard it. The whole thing is
// independent of any connection: images live here until you want them, on whatever tab.
//
////////////////////////////////////////////////////////////////////////////////

import ImageIO
import UIKit

final class MoshtrayController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {

  private let onPick: (URL) -> Void        // insert this tray image into the composer
  private let onFinished: () -> Void       // let the composer refresh its tray button on dismiss
  private var items: [URL] = []
  private var collectionView: UICollectionView!

  init(onPick: @escaping (URL) -> Void, onFinished: @escaping () -> Void) {
    self.onPick = onPick
    self.onFinished = onFinished
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = MoshxploreStyle.screen
    items = MoshroomShareTray.items()

    // Compact in-content header (no system nav bar) — the launcher / Moshtabs pattern: title left,
    // close ✕ top-right, so the Mac window chrome stays put.
    let header = UIView()
    header.translatesAutoresizingMaskIntoConstraints = false
    let titleLabel = UILabel()
    titleLabel.text = "Shared images"
    titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
    titleLabel.textColor = .label
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    let close = moshkeyRoundButton(diameter: 34)
    close.layer.shadowOpacity = 0
    close.setMoshIcon("xmark", pointSize: 15, weight: .semibold)
    close.addTarget(self, action: #selector(_close), for: .touchUpInside)
    close.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(titleLabel)
    header.addSubview(close)
    view.addSubview(header)

    let layout = UICollectionViewFlowLayout()
    layout.minimumInteritemSpacing = 12
    layout.minimumLineSpacing = 12
    layout.sectionInset = UIEdgeInsets(top: 12, left: 16, bottom: 24, right: 16)
    collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.backgroundColor = .clear
    collectionView.alwaysBounceVertical = true
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.register(MoshtrayCell.self, forCellWithReuseIdentifier: MoshtrayCell.reuseID)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(collectionView)

    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      header.heightAnchor.constraint(equalToConstant: 58),
      titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
      titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
      close.centerYAnchor.constraint(equalTo: header.centerYAnchor),

      collectionView.topAnchor.constraint(equalTo: header.bottomAnchor),
      collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  // A modal sheet animates to its final width, so the FIRST layout pass sees a narrow bounds. Recompute
  // the grid whenever the width settles (sizeForItemAt does the actual math from the live width each
  // pass) — this is what fixes the tiny-thumbnail bug.
  private var _lastGridWidth: CGFloat = 0
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if collectionView.bounds.width != _lastGridWidth {
      _lastGridWidth = collectionView.bounds.width
      collectionView.collectionViewLayout.invalidateLayout()
    }
  }

  // Square cells ~116pt wide, at least two columns — the grid fills the width and breathes on iPad/Mac.
  func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
    let inset: CGFloat = 16, spacing: CGFloat = 12, target: CGFloat = 116
    let avail = cv.bounds.width - inset * 2
    guard avail > 0 else { return CGSize(width: target, height: target) }
    let cols = max(2, ((avail + spacing) / (target + spacing)).rounded(.down))
    let side = ((avail - (cols - 1) * spacing) / cols).rounded(.down)
    return CGSize(width: side, height: side)
  }

  // MARK: Data

  func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

  func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = cv.dequeueReusableCell(withReuseIdentifier: MoshtrayCell.reuseID, for: indexPath) as! MoshtrayCell
    let url = items[indexPath.item]
    cell.configure(url: url)
    cell.onDelete = { [weak self] in self?._delete(url) }
    return cell
  }

  func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    cv.deselectItem(at: indexPath, animated: false)
    guard indexPath.item < items.count else { return }
    _insert(items[indexPath.item])
  }

  // MARK: Actions

  // Insert AFTER the sheet is gone, so the composer is frontmost and first responder when the chip
  // lands. onPick removes the file from the tray; onFinished refreshes the composer's tray button.
  private func _insert(_ url: URL) {
    dismiss(animated: false) { [onPick, onFinished] in
      onPick(url)
      onFinished()
    }
  }

  private func _delete(_ url: URL) {
    MoshroomShareTray.remove(url)
    items = MoshroomShareTray.items()
    if items.isEmpty { _close() } else { collectionView.reloadData() }
  }

  @objc private func _close() {
    dismiss(animated: false) { [onFinished] in onFinished() }
  }
}

// MARK: - Cell (thumbnail + center "add" cue + red delete)

final class MoshtrayCell: UICollectionViewCell {

  static let reuseID = "MoshtrayCell"

  private let imageView = UIImageView()
  private let addCircle = UIView()
  private let addGlyph = UIImageView()
  private let deleteButton = UIButton(type: .custom)
  var onDelete: (() -> Void)?
  private var loadToken = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.backgroundColor = UIColor(white: 1, alpha: 0.06)
    contentView.layer.cornerRadius = 14
    contentView.layer.cornerCurve = .continuous
    contentView.clipsToBounds = true

    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(imageView)

    // Center "add" cue: a translucent disc + white plus. Decorative — the whole cell taps to insert.
    addCircle.backgroundColor = UIColor.black.withAlphaComponent(0.32)
    addCircle.layer.cornerRadius = 19
    addCircle.isUserInteractionEnabled = false
    addCircle.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(addCircle)

    addGlyph.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold))
    addGlyph.tintColor = .white
    addGlyph.contentMode = .center
    addGlyph.translatesAutoresizingMaskIntoConstraints = false
    addCircle.addSubview(addGlyph)

    // Red delete, top-right. It handles its own tap, so the cell's select (= insert) never fires here.
    // preferredBehavioralStyle = .pad is CRUCIAL on Mac Catalyst: without it a UIButton adopts the
    // native .mac push-button style and IGNORES the frame / corner radius / fill — which rendered this
    // as a giant, mis-placed control with a hover-only red glyph. .pad keeps our exact round chip.
    deleteButton.preferredBehavioralStyle = .pad
    deleteButton.backgroundColor = .moshroomTint
    // Force a solid WHITE glyph (alwaysOriginal) so the × is white on every platform and always shown
    // (the default rendering tinted it red and only on hover).
    deleteButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))?
      .withTintColor(.white, renderingMode: .alwaysOriginal), for: .normal)
    deleteButton.layer.cornerRadius = 15
    deleteButton.layer.borderWidth = 1.5
    deleteButton.layer.borderColor = UIColor.white.cgColor          // white ring so it pops over any image
    deleteButton.layer.shadowColor = UIColor.black.cgColor
    deleteButton.layer.shadowOpacity = 0.35
    deleteButton.layer.shadowRadius = 3
    deleteButton.layer.shadowOffset = CGSize(width: 0, height: 1)
    deleteButton.translatesAutoresizingMaskIntoConstraints = false
    deleteButton.addTarget(self, action: #selector(_deleteTapped), for: .touchUpInside)
    contentView.addSubview(deleteButton)

    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
      imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      addCircle.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      addCircle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      addCircle.widthAnchor.constraint(equalToConstant: 38),
      addCircle.heightAnchor.constraint(equalToConstant: 38),
      addGlyph.leadingAnchor.constraint(equalTo: addCircle.leadingAnchor),
      addGlyph.trailingAnchor.constraint(equalTo: addCircle.trailingAnchor),
      addGlyph.topAnchor.constraint(equalTo: addCircle.topAnchor),
      addGlyph.bottomAnchor.constraint(equalTo: addCircle.bottomAnchor),

      deleteButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
      deleteButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
      deleteButton.widthAnchor.constraint(equalToConstant: 30),
      deleteButton.heightAnchor.constraint(equalToConstant: 30),
    ])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc private func _deleteTapped() { onDelete?() }

  func configure(url: URL) {
    loadToken += 1
    let token = loadToken
    imageView.image = nil
    DispatchQueue.global(qos: .userInitiated).async {
      let img = MoshtrayThumbs.thumbnail(url, maxPixel: 500)
      DispatchQueue.main.async {
        guard self.loadToken == token else { return }   // cell reused before the decode landed
        self.imageView.image = img
      }
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    loadToken += 1
    imageView.image = nil
    onDelete = nil
  }
}

// MARK: - Thumbnail decode (ImageIO, never the full image)

enum MoshtrayThumbs {
  static func thumbnail(_ url: URL, maxPixel: CGFloat) -> UIImage? {
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(200, maxPixel),
    ]
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return UIImage(cgImage: cg)
  }
}
