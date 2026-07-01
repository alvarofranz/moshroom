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
// Moshxplore: browse a saved host's filesystem and pull files (or whole folders) down
// to the iPhone — no tab, no shell, no `ls`/`scp` typed by hand.
//
// A floating card (the Quick-Connect look) that runs over any tab: pick a saved host, walk
// its directories (name + size + date, parsed structurally over SFTP — the robust equivalent
// of `ls -lsa`), and tap download to copy a file or a whole folder into `Documents/Moshxplore/`,
// visible in Files.app. Everything reuses the proven Combine SSH/SFTP stack from CopyFiles.swift
// (the same one Moshdrop uploads with), driven on its own run-loop thread — the remote needs
// nothing installed, and downloading "acts as scp" because it *is* an SFTP transfer.
//
////////////////////////////////////////////////////////////////////////////////

import Combine
import Foundation
import UIKit

import MoshroomConfig
import MoshroomFiles
import SSH

// MARK: - Model

// One parsed remote directory entry: just what the browser shows + needs to descend/download.
struct MoshxploreEntry {
  let name: String
  let isDirectory: Bool
  let isSymlink: Bool
  let size: UInt64
  let modified: Date?

  init?(attrs: FileAttributes) {
    guard let name = attrs[.name] as? String, !name.isEmpty else { return nil }
    self.name = name
    let type = attrs[.type] as? FileAttributeType
    self.isDirectory = type == .typeDirectory
    self.isSymlink = type == .typeSymbolicLink
    self.size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
    self.modified = attrs[.modificationDate] as? Date
  }
}

enum MoshxploreError: LocalizedError {
  case notConnected
  var errorDescription: String? { "Not connected." }
}

// Where downloads land on the phone. Files.app already shows this app's container as "Moshroom", so we
// group saves *by host* inside it (`Moshroom › <host> › file`) rather than nesting another "Moshroom".
// A separate throwaway cache holds a file fetched just to preview it.
enum MoshxploreDownloads {
  static func directory(host: String) -> URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let folder = sanitized(host)
    let dir = docs.appendingPathComponent(folder.isEmpty ? "downloads" : folder, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func previewCache() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moshxplore-preview", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  // Make a host alias safe as a single folder name (strip path separators and other illegal chars).
  private static func sanitized(_ name: String) -> String {
    let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
    return name.components(separatedBy: illegal).joined(separator: "-")
      .trimmingCharacters(in: .whitespaces)
  }
}

// What a tapped file can show inline before downloading: an image, readable text/code, or nothing.
enum MoshxplorePreview {
  enum Kind { case image, text, none }

  static let imageMaxBytes: UInt64 = 8 * 1024 * 1024
  static let textMaxBytes: UInt64 = 1 * 1024 * 1024

  private static let imageExt: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff"]
  private static let textExt: Set<String> = [
    "txt", "md", "markdown", "log", "csv", "json", "yml", "yaml", "xml", "toml", "ini", "conf", "cfg",
    "swift", "c", "h", "m", "mm", "cpp", "cc", "hpp", "py", "js", "mjs", "ts", "jsx", "tsx", "go", "rs",
    "rb", "java", "kt", "sh", "bash", "zsh", "fish", "pl", "php", "sql", "html", "htm", "css", "scss", "rtf"]
  private static let textLeaf: Set<String> = [
    ".env", ".gitignore", ".gitattributes", ".editorconfig", ".npmrc", ".dockerignore", "dockerfile",
    "makefile", "readme", "license"]

  static func kind(for entry: MoshxploreEntry) -> Kind {
    if entry.isDirectory { return .none }
    let ext = (entry.name as NSString).pathExtension.lowercased()
    if imageExt.contains(ext) { return entry.size <= imageMaxBytes ? .image : .none }
    if textExt.contains(ext) || textLeaf.contains(entry.name.lowercased()) {
      return entry.size <= textMaxBytes ? .text : .none
    }
    return .none
  }

  // Is this a previewable *type* regardless of size? (Distinguishes "too large" from "can't preview".)
  static func isPreviewableType(_ entry: MoshxploreEntry) -> Bool {
    if entry.isDirectory { return false }
    let ext = (entry.name as NSString).pathExtension.lowercased()
    return imageExt.contains(ext) || textExt.contains(ext) || textLeaf.contains(entry.name.lowercased())
  }
}

// MARK: - SFTP engine

// One persistent SFTP connection for a browse session, on its own run-loop thread (mirroring
// MoshdropUploader / CopyFiles). `connect` once, then `list`/`download` reuse the same channel;
// `stop` tears it all down. Every callback is delivered on the main queue.
final class MoshxploreSession {

  private var thread: Thread?
  private var runLoopRef: CFRunLoop?
  private let ready = DispatchSemaphore(value: 0)
  private var alive = false

  // The connected SFTP root. Touched only on the worker thread; we always walk a CLONE so it
  // stays a stable anchor for absolute-path navigation.
  private var root: Translator?
  private var connectC: AnyCancellable?
  private var listC: AnyCancellable?
  private var downloadC: AnyCancellable?

  private func start() {
    guard thread == nil else { return }
    let t = Thread { [weak self] in
      guard let self else { return }
      // Keep the run loop alive while libssh2 attaches its socket source to it.
      let keepAlive = Port()
      RunLoop.current.add(keepAlive, forMode: .default)
      self.runLoopRef = CFRunLoopGetCurrent()
      self.alive = true
      self.ready.signal()
      while self.alive {
        RunLoop.current.run(mode: .default, before: .distantFuture)
      }
      RunLoop.current.remove(keepAlive, forMode: .default)
    }
    t.name = "moshxplore.sftp"
    t.stackSize = 2 << 20
    thread = t
    t.start()
    ready.wait()   // block until the worker's run loop ref is published (sub-millisecond)
  }

  private func onWorker(_ block: @escaping () -> Void) {
    guard let rl = runLoopRef else { return }
    CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, block)
    CFRunLoopWakeUp(rl)
  }

  // Connect + SFTP + resolve home. `completion` carries the absolute home path to list first.
  func connect(hostAlias: String, device: TermDevice,
               completion: @escaping (Result<String, Error>) -> Void) {
    start()
    onWorker { [weak self] in
      guard let self else { return }
      let resolved: (hostName: String, host: MoshSSHHost)
      let config: SSHClientConfig
      do {
        let command = try SSHCommand.parse([hostAlias])
        resolved = try command.resolveHost()
        config = try SSHClientConfigProvider.config(host: resolved.host, using: device)
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
        return
      }

      self.connectC = SSHClient.dial(resolved.hostName, with: config, withProxy: MoshroomSSH.executeProxyCommand)
        .flatMap { $0.requestSFTP() }
        .tryMap { try SFTPTranslator(on: $0) as Translator }
        .flatMap { $0.walkTo("~") }   // canonicalize to the login home directory
        .sink(receiveCompletion: { c in
          if case .failure(let e) = c { DispatchQueue.main.async { completion(.failure(e)) } }
        }, receiveValue: { [weak self] translator in
          self?.root = translator
          DispatchQueue.main.async { completion(.success(translator.current)) }
        })
    }
  }

  // List one absolute directory path. Entries are sorted dirs-first, then case-insensitive name.
  func list(path: String, completion: @escaping (Result<[MoshxploreEntry], Error>) -> Void) {
    onWorker { [weak self] in
      guard let self, let root = self.root else {
        DispatchQueue.main.async { completion(.failure(MoshxploreError.notConnected)) }
        return
      }
      self.listC = root.cloneWalkTo(path)
        .flatMap { $0.directoryFilesAndAttributes() }
        .sink(receiveCompletion: { c in
          if case .failure(let e) = c { DispatchQueue.main.async { completion(.failure(e)) } }
        }, receiveValue: { rows in
          let entries = rows.compactMap(MoshxploreEntry.init)
            .filter { $0.name != "." && $0.name != ".." }
            .sorted { a, b in
              a.isDirectory != b.isDirectory ? a.isDirectory
                : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
          DispatchQueue.main.async { completion(.success(entries)) }
        })
    }
  }

  // Download a single file into `destDir`. Used both to save (→ Documents/Moshroom) and to fetch a
  // file for inline preview (→ a temp cache). `progress` reports the 0…1 fraction; `completion` the
  // landed URL.
  func download(remotePath: String, name: String, into destDir: URL,
                progress: @escaping (Double) -> Void,
                completion: @escaping (Result<URL, Error>) -> Void) {
    onWorker { [weak self] in
      guard let self, let root = self.root else {
        DispatchQueue.main.async { completion(.failure(MoshxploreError.notConnected)) }
        return
      }
      let target = destDir.appendingPathComponent(name)
      // Re-downloading replaces a prior copy (always one of our own managed folders).
      try? FileManager.default.removeItem(at: target)

      let localDir = MoshroomFiles.Local().walkTo(destDir.path)
      let remote = root.cloneWalkTo(remotePath)

      // SFTP reports incremental bytes (`written`) against the file's `size` — accumulate for a true
      // fraction (never a faked one).
      var sent: UInt64 = 0
      self.downloadC = Publishers.Zip(localDir, remote)
        .flatMap { ldir, rfile in
          ldir.copy(from: [rfile], args: CopyArguments(preserve: CopyAttributesFlag([.timestamp]), checkTimes: false))
        }
        .sink(receiveCompletion: { c in
          switch c {
          case .finished: DispatchQueue.main.async { completion(.success(target)) }
          case .failure(let e): DispatchQueue.main.async { completion(.failure(e)) }
          }
        }, receiveValue: { info in
          guard info.size > 0 else { return }
          sent += info.written
          let frac = min(1.0, Double(sent) / Double(info.size))
          DispatchQueue.main.async { progress(frac) }
        })
    }
  }

  func cancelDownload() {
    onWorker { [weak self] in self?.downloadC = nil }
  }

  func stop() {
    guard let rl = runLoopRef else { return }
    CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
      self?.connectC = nil
      self?.listC = nil
      self?.downloadC = nil
      self?.root = nil
      self?.alive = false
      CFRunLoopStop(CFRunLoopGetCurrent())
    }
    CFRunLoopWakeUp(rl)
    runLoopRef = nil
    thread = nil
  }
}

// MARK: - Shared style

// One palette for the card and its rows (the Moshroom house look — matches Quick Connect).
enum MoshxploreStyle {
  static let dark = UIColor(white: 0.12, alpha: 1)
  static let gray = UIColor(white: 0.45, alpha: 1)
  static let stroke = UIColor(white: 0.82, alpha: 1)
}

// MARK: - Entry row

// One file/folder row: icon, name, size·date, chevron. Tapping a folder descends into it; tapping a
// file opens its detail view. The whole row is the tap target.
private final class MoshxploreEntryRow: UIControl {

  init(entry: MoshxploreEntry, symbol: String, subtitle: String, onTap: @escaping () -> Void) {
    super.init(frame: .zero)
    self.onTap = onTap
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .white
    layer.cornerRadius = 12
    layer.borderWidth = 0.5
    layer.borderColor = MoshxploreStyle.stroke.cgColor

    let icon = UIImageView(image: UIImage(systemName: symbol))
    icon.tintColor = entry.isDirectory ? .moshroomTint : MoshxploreStyle.dark
    icon.contentMode = .scaleAspectFit
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.setContentHuggingPriority(.required, for: .horizontal)

    let name = UILabel()
    name.text = entry.name
    name.font = .systemFont(ofSize: 15, weight: .medium)
    name.textColor = MoshxploreStyle.dark
    name.lineBreakMode = .byTruncatingMiddle
    name.setContentCompressionResistancePriority(.required, for: .vertical)

    let meta = UILabel()
    meta.text = subtitle
    meta.font = .systemFont(ofSize: 12)
    meta.textColor = MoshxploreStyle.gray
    // Give the small subtitle its full line box — never squeezed/clipped by the row layout.
    meta.numberOfLines = 1
    meta.setContentCompressionResistancePriority(.required, for: .vertical)
    meta.setContentHuggingPriority(.required, for: .vertical)

    let labels = UIStackView(arrangedSubviews: [name, meta])
    labels.axis = .vertical
    labels.spacing = 3

    let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    chevron.tintColor = MoshxploreStyle.stroke
    chevron.contentMode = .scaleAspectFit
    chevron.setContentHuggingPriority(.required, for: .horizontal)

    let stack = UIStackView(arrangedSubviews: [icon, labels, chevron])
    stack.axis = .horizontal
    stack.spacing = 10
    stack.alignment = .center
    stack.isUserInteractionEnabled = false   // let taps fall through to the control
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 22),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 11),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
    ])

    addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var onTap: (() -> Void)?

  // A subtle press highlight, matching the house feel.
  override var isHighlighted: Bool {
    didSet { backgroundColor = isHighlighted ? UIColor(white: 0.94, alpha: 1) : .white }
  }
}

// MARK: - File detail

// The single-file view: name, metadata, an inline preview (image or text/code when it's small and
// readable), and one prominent Download button. Pure presentation — the card drives the fetch.
private final class MoshxploreDetailView: UIView {

  var onBack: (() -> Void)?
  var onDownload: (() -> Void)?

  private let titleLabel = UILabel()
  private let metaLabel = UILabel()
  private let previewBox = UIView()
  private let imageView = UIImageView()
  private let textView = UITextView()
  private let placeholderIcon = UIImageView()
  private let placeholderLabel = UILabel()
  private let placeholder = UIStackView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let downloadButton = UIButton(type: .system)

  init() {
    super.init(frame: .zero)

    let back = UIButton(type: .system)
    back.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
    back.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold), forImageIn: .normal)
    back.tintColor = MoshxploreStyle.dark
    back.setContentHuggingPriority(.required, for: .horizontal)
    back.widthAnchor.constraint(equalToConstant: 30).isActive = true
    back.heightAnchor.constraint(equalToConstant: 30).isActive = true
    back.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)

    titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    titleLabel.textColor = MoshxploreStyle.dark
    titleLabel.lineBreakMode = .byTruncatingMiddle

    let header = UIStackView(arrangedSubviews: [back, titleLabel])
    header.axis = .horizontal
    header.spacing = 8
    header.alignment = .center

    metaLabel.font = .systemFont(ofSize: 12)
    metaLabel.textColor = MoshxploreStyle.gray
    metaLabel.numberOfLines = 0

    previewBox.backgroundColor = UIColor(white: 0.99, alpha: 1)
    previewBox.layer.cornerRadius = 12
    previewBox.layer.borderWidth = 0.5
    previewBox.layer.borderColor = MoshxploreStyle.stroke.cgColor
    previewBox.clipsToBounds = true
    previewBox.translatesAutoresizingMaskIntoConstraints = false

    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.isHidden = true

    textView.isEditable = false
    textView.backgroundColor = .clear
    textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.textColor = MoshxploreStyle.dark
    textView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isHidden = true

    placeholderIcon.contentMode = .scaleAspectFit
    placeholderIcon.tintColor = MoshxploreStyle.stroke
    placeholderIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34)
    placeholderLabel.font = .systemFont(ofSize: 12)
    placeholderLabel.textColor = MoshxploreStyle.gray
    placeholderLabel.textAlignment = .center
    placeholderLabel.numberOfLines = 0
    placeholder.axis = .vertical
    placeholder.spacing = 8
    placeholder.alignment = .center
    placeholder.translatesAutoresizingMaskIntoConstraints = false
    placeholder.addArrangedSubview(placeholderIcon)
    placeholder.addArrangedSubview(placeholderLabel)
    placeholder.isHidden = true

    spinner.hidesWhenStopped = true
    spinner.color = MoshxploreStyle.gray
    spinner.translatesAutoresizingMaskIntoConstraints = false

    [imageView, textView, placeholder, spinner].forEach { previewBox.addSubview($0) }

    var cfg = UIButton.Configuration.filled()
    cfg.baseBackgroundColor = .moshroomTint
    cfg.baseForegroundColor = .white
    cfg.cornerStyle = .large
    cfg.image = UIImage(systemName: "arrow.down.to.line")
    cfg.imagePadding = 8
    var attr = AttributeContainer(); attr.font = .systemFont(ofSize: 16, weight: .semibold)
    cfg.attributedTitle = AttributedString("Download to Files", attributes: attr)
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)
    downloadButton.configuration = cfg
    downloadButton.addAction(UIAction { [weak self] _ in self?.onDownload?() }, for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [header, metaLabel, previewBox, downloadButton])
    stack.axis = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    let previewHeight = previewBox.heightAnchor.constraint(equalToConstant: 300)
    previewHeight.priority = .init(999)   // firm, but yields before breaking on a short screen

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      previewHeight,
      imageView.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 8),
      imageView.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -8),
      imageView.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 8),
      imageView.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -8),
      textView.topAnchor.constraint(equalTo: previewBox.topAnchor),
      textView.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor),
      textView.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
      placeholder.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
      placeholder.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
      placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: previewBox.leadingAnchor, constant: 16),
      placeholder.trailingAnchor.constraint(lessThanOrEqualTo: previewBox.trailingAnchor, constant: -16),
      spinner.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(name: String, meta: String) {
    titleLabel.text = name
    metaLabel.text = meta
  }

  func showPreviewLoading() {
    imageView.isHidden = true; imageView.image = nil
    textView.isHidden = true; textView.text = nil
    placeholder.isHidden = true
    spinner.startAnimating()
  }

  func showImage(_ image: UIImage) {
    spinner.stopAnimating()
    placeholder.isHidden = true; textView.isHidden = true
    imageView.image = image
    imageView.isHidden = false
  }

  func showText(_ text: String) {
    spinner.stopAnimating()
    placeholder.isHidden = true; imageView.isHidden = true
    textView.text = text
    textView.isHidden = false
    textView.setContentOffset(.zero, animated: false)
  }

  func showNoPreview(symbol: String, message: String) {
    spinner.stopAnimating()
    imageView.isHidden = true; textView.isHidden = true
    placeholderIcon.image = UIImage(systemName: symbol)
    placeholderLabel.text = message
    placeholder.isHidden = false
  }
}

// MARK: - The card

// Pure presentation + its own SFTP session. SpaceController only feeds it the saved hosts, the
// current device (for SSH config), and a close hook.
final class MoshxploreView: UIView {

  var savedHosts: (() -> [String])?
  var device: (() -> TermDevice?)?
  var onClose: (() -> Void)?
  var presentShare: ((URL) -> Void)?    // hand a saved file to the system share sheet

  private static let dark = MoshxploreStyle.dark
  private static let gray = MoshxploreStyle.gray
  private static let stroke = MoshxploreStyle.stroke

  private let titleLabel = UILabel()
  private let hostStep = UIStackView()
  private let hostsStack = UIStackView()
  private let hostsScroll = UIScrollView()
  private let hostsEmpty = UILabel()

  private let browserStep = UIStackView()
  private let upButton = UIButton(type: .system)
  private let hostsButton = UIButton(type: .system)
  private let pathLabel = UILabel()
  private let entriesStack = UIStackView()
  private let entriesScroll = UIScrollView()
  private let spinner = UIActivityIndicatorView(style: .medium)

  private let detailView = MoshxploreDetailView()

  private let errorLabel = UILabel()

  private let progressOverlay = UIView()
  private let progressTitle = UILabel()
  private let progressBar = UIProgressView(progressViewStyle: .default)
  private let cancelButton = UIButton(type: .system)
  private let openButton = UIButton(type: .system)
  private let doneButton = UIButton(type: .system)

  private var session: MoshxploreSession?
  private var hostAlias: String?
  private var currentPath = "/"
  private var detailEntry: MoshxploreEntry?
  private var previewURL: URL?      // a fetched temp copy, reused as the save source when present
  private var savedURL: URL?        // the last saved file, handed to the share sheet from "Open"

  private static let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter(); f.countStyle = .file; return f
  }()
  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
  }()

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = UIColor(white: 0.97, alpha: 0.97)
    layer.cornerRadius = 18
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.22
    layer.shadowRadius = 12
    layer.shadowOffset = CGSize(width: 0, height: 4)

    titleLabel.text = "Moshxplore"
    titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
    titleLabel.textColor = Self.dark

    let close = UIButton(type: .system)
    close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
    close.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 20), forImageIn: .normal)
    close.tintColor = Self.gray
    close.setContentHuggingPriority(.required, for: .horizontal)
    close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

    let header = UIStackView(arrangedSubviews: [titleLabel, close])
    header.axis = .horizontal
    header.alignment = .center

    // --- Host step ---
    let hostSubtitle = UILabel()
    hostSubtitle.text = "Choose a host to browse"
    hostSubtitle.font = .systemFont(ofSize: 13)
    hostSubtitle.textColor = Self.gray

    hostsStack.axis = .vertical
    hostsStack.spacing = 7
    hostsStack.translatesAutoresizingMaskIntoConstraints = false
    hostsScroll.translatesAutoresizingMaskIntoConstraints = false
    hostsScroll.showsHorizontalScrollIndicator = false
    hostsScroll.addSubview(hostsStack)

    let emptyPara = NSMutableParagraphStyle()
    emptyPara.alignment = .center; emptyPara.lineSpacing = 7
    hostsEmpty.attributedText = NSAttributedString(
      string: "No saved hosts yet.\nAdd one in Settings → Hosts.",
      attributes: [.paragraphStyle: emptyPara, .font: UIFont.systemFont(ofSize: 13), .foregroundColor: Self.gray])
    hostsEmpty.numberOfLines = 0
    hostsEmpty.isHidden = true

    hostStep.axis = .vertical
    hostStep.spacing = 12
    hostStep.addArrangedSubview(hostSubtitle)
    hostStep.addArrangedSubview(hostsScroll)
    hostStep.addArrangedSubview(hostsEmpty)

    // --- Browser step ---
    Self.style(iconButton: upButton, systemName: "chevron.backward")
    upButton.addAction(UIAction { [weak self] _ in self?.goUp() }, for: .touchUpInside)
    Self.style(iconButton: hostsButton, systemName: "rectangle.stack")
    hostsButton.addAction(UIAction { [weak self] _ in self?.backToHosts() }, for: .touchUpInside)

    pathLabel.font = .systemFont(ofSize: 13, weight: .medium)
    pathLabel.textColor = Self.dark
    pathLabel.lineBreakMode = .byTruncatingHead
    pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let pathBar = UIStackView(arrangedSubviews: [upButton, pathLabel, hostsButton])
    pathBar.axis = .horizontal
    pathBar.spacing = 8
    pathBar.alignment = .center

    entriesStack.axis = .vertical
    entriesStack.spacing = 6
    entriesStack.translatesAutoresizingMaskIntoConstraints = false
    entriesScroll.translatesAutoresizingMaskIntoConstraints = false
    entriesScroll.showsHorizontalScrollIndicator = false
    entriesScroll.addSubview(entriesStack)

    browserStep.axis = .vertical
    browserStep.spacing = 10
    browserStep.isHidden = true
    browserStep.addArrangedSubview(pathBar)
    browserStep.addArrangedSubview(entriesScroll)

    spinner.hidesWhenStopped = true
    spinner.color = Self.gray

    // --- Detail step ---
    detailView.isHidden = true
    detailView.onBack = { [weak self] in self?.closeDetail() }
    detailView.onDownload = { [weak self] in self?.saveDetailFile() }

    errorLabel.font = .systemFont(ofSize: 12, weight: .medium)
    errorLabel.textColor = .moshroomTint
    errorLabel.numberOfLines = 0
    errorLabel.isHidden = true

    let content = UIStackView(arrangedSubviews: [header, hostStep, browserStep, detailView, spinner, errorLabel])
    content.axis = .vertical
    content.spacing = 12
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)

    // Low priority so these shrink-wrap constraints never win against a row's compression resistance
    // (a tie squashes the top rows when the list exceeds the scroll cap — see Moshnector).
    let hostsToContent = hostsScroll.heightAnchor.constraint(equalTo: hostsStack.heightAnchor)
    hostsToContent.priority = .defaultLow
    let entriesToContent = entriesScroll.heightAnchor.constraint(equalTo: entriesStack.heightAnchor)
    entriesToContent.priority = .defaultLow

    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: topAnchor, constant: 16),
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),

      hostsStack.topAnchor.constraint(equalTo: hostsScroll.contentLayoutGuide.topAnchor),
      hostsStack.bottomAnchor.constraint(equalTo: hostsScroll.contentLayoutGuide.bottomAnchor),
      hostsStack.leadingAnchor.constraint(equalTo: hostsScroll.contentLayoutGuide.leadingAnchor),
      hostsStack.trailingAnchor.constraint(equalTo: hostsScroll.contentLayoutGuide.trailingAnchor),
      hostsStack.widthAnchor.constraint(equalTo: hostsScroll.frameLayoutGuide.widthAnchor),
      hostsToContent,
      hostsScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 260),

      entriesStack.topAnchor.constraint(equalTo: entriesScroll.contentLayoutGuide.topAnchor),
      entriesStack.bottomAnchor.constraint(equalTo: entriesScroll.contentLayoutGuide.bottomAnchor),
      entriesStack.leadingAnchor.constraint(equalTo: entriesScroll.contentLayoutGuide.leadingAnchor),
      entriesStack.trailingAnchor.constraint(equalTo: entriesScroll.contentLayoutGuide.trailingAnchor),
      entriesStack.widthAnchor.constraint(equalTo: entriesScroll.frameLayoutGuide.widthAnchor),
      entriesToContent,
      entriesScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 380),
    ])

    _buildProgressOverlay()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: Entry points (from SpaceController)

  // Open the card. If `preferredHost` is a saved host (e.g. the current tab is connected to it),
  // jump straight into browsing it; otherwise show the host picker.
  func present(preferredHost: String?) {
    errorLabel.isHidden = true
    hideProgress()
    if let host = preferredHost, (savedHosts?() ?? []).contains(host) {
      connect(to: host)
    } else {
      showHostStep()
    }
  }

  // Disconnect and reset — called when the card closes or the tab switches.
  func teardown() {
    session?.stop()
    session = nil
    hostAlias = nil
    clearDetail()
    hideProgress()
  }

  // MARK: Steps

  // Exactly one of the three steps is visible at a time (or none, while a spinner runs).
  private func showStep(host: Bool = false, browser: Bool = false, detail: Bool = false) {
    hostStep.isHidden = !host
    browserStep.isHidden = !browser
    detailView.isHidden = !detail
  }

  private func showHostStep() {
    session?.stop(); session = nil
    hostAlias = nil
    clearDetail()
    spinner.stopAnimating()
    showStep(host: true)
    errorLabel.isHidden = true
    _reloadHostRows()
  }

  // Refresh the saved-host list live when hosts are added/edited/deleted (mirrors Quick Connect),
  // but only while the picker is actually on screen — never yank a browse session out from under you.
  func reloadHostsIfVisible() {
    guard !isHidden, !hostStep.isHidden else { return }
    _reloadHostRows()
  }

  private func _reloadHostRows() {
    let aliases = savedHosts?() ?? []
    hostsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    hostsEmpty.isHidden = !aliases.isEmpty
    hostsScroll.isHidden = aliases.isEmpty
    for alias in aliases { hostsStack.addArrangedSubview(_hostRow(alias)) }
    hostsScroll.setContentOffset(.zero, animated: false)
  }

  private func backToHosts() { showHostStep() }

  private func connect(to alias: String) {
    guard let device = device?() else { showError("No terminal device available."); return }
    hostAlias = alias
    clearDetail()
    showStep()           // all hidden while the SFTP connection comes up
    errorLabel.isHidden = true
    spinner.startAnimating()

    let session = MoshxploreSession()
    self.session = session
    session.connect(hostAlias: alias, device: device) { [weak self] result in
      guard let self, self.hostAlias == alias else { return }
      switch result {
      case .success(let home): self.enter(path: home)
      case .failure(let error):
        self.spinner.stopAnimating()
        self.showHostStep()
        self.showError(self.message(for: error))
      }
    }
  }

  private func enter(path: String) {
    currentPath = path
    pathLabel.text = path
    upButton.isEnabled = path != "/"
    upButton.alpha = upButton.isEnabled ? 1 : 0.35
    clearDetail()
    spinner.startAnimating()
    errorLabel.isHidden = true

    session?.list(path: path) { [weak self] result in
      guard let self, self.currentPath == path else { return }
      self.spinner.stopAnimating()
      switch result {
      case .success(let entries):
        self.showStep(browser: true)
        self.renderEntries(entries)
      case .failure(let error):
        self.showError(self.message(for: error))
      }
    }
  }

  private func goUp() {
    guard currentPath != "/" else { return }
    let parent = (currentPath as NSString).deletingLastPathComponent
    enter(path: parent.isEmpty ? "/" : parent)
  }

  private func renderEntries(_ entries: [MoshxploreEntry]) {
    entriesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    if entries.isEmpty {
      let empty = UILabel()
      empty.text = "Empty folder"
      empty.font = .systemFont(ofSize: 13)
      empty.textColor = Self.gray
      empty.textAlignment = .center
      entriesStack.addArrangedSubview(empty)
      return
    }
    for entry in entries { entriesStack.addArrangedSubview(_entryRow(entry)) }
    entriesScroll.setContentOffset(.zero, animated: false)
  }

  // MARK: Rows

  private func _hostRow(_ alias: String) -> UIView {
    var cfg = UIButton.Configuration.plain()
    cfg.image = UIImage(systemName: "server.rack", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14))
    cfg.imagePadding = 9
    var attr = AttributeContainer(); attr.font = .systemFont(ofSize: 15, weight: .medium)
    cfg.attributedTitle = AttributedString(alias, attributes: attr)
    cfg.baseForegroundColor = Self.dark
    cfg.background.backgroundColor = .white
    cfg.background.cornerRadius = 12
    cfg.background.strokeColor = Self.stroke
    cfg.background.strokeWidth = 0.5
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)

    let b = UIButton(configuration: cfg)
    b.contentHorizontalAlignment = .leading
    b.translatesAutoresizingMaskIntoConstraints = false
    b.setContentCompressionResistancePriority(.required, for: .vertical)   // never squashed by the scroll
    b.addAction(UIAction { [weak self] _ in self?.connect(to: alias) }, for: .touchUpInside)
    return b
  }

  private func _entryRow(_ entry: MoshxploreEntry) -> UIView {
    MoshxploreEntryRow(
      entry: entry,
      symbol: Self.symbol(for: entry),
      subtitle: subtitle(for: entry),
      onTap: { [weak self] in
        guard let self else { return }
        // A folder opens; a file goes to its detail view (preview + download).
        if entry.isDirectory { self.enter(path: self.childPath(entry.name)) }
        else { self.openDetail(entry) }
      })
  }

  // MARK: File detail (preview + download)

  private func openDetail(_ entry: MoshxploreEntry) {
    clearDetail()
    detailEntry = entry
    detailView.configure(name: entry.name, meta: detailMeta(for: entry))
    showStep(detail: true)
    errorLabel.isHidden = true

    switch MoshxplorePreview.kind(for: entry) {
    case .image, .text:
      detailView.showPreviewLoading()
      fetchPreview(entry)
    case .none:
      detailView.showNoPreview(symbol: Self.symbol(for: entry), message: previewUnavailableMessage(for: entry))
    }
  }

  private func closeDetail() {
    clearDetail()
    showStep(browser: true)   // entries are still rendered — no need to re-list
    errorLabel.isHidden = true
  }

  // Drop the detail state and bin any temp preview copy.
  private func clearDetail() {
    detailEntry = nil
    savedURL = nil
    session?.cancelDownload()   // stop an in-flight preview fetch when leaving the detail view
    if let url = previewURL { try? FileManager.default.removeItem(at: url); previewURL = nil }
  }

  // Fetch the file into a temp cache and render it; the copy is reused as the save source.
  private func fetchPreview(_ entry: MoshxploreEntry) {
    session?.download(remotePath: childPath(entry.name), name: entry.name, into: MoshxploreDownloads.previewCache(),
      progress: { _ in },
      completion: { [weak self] result in
        guard let self, self.detailEntry?.name == entry.name else { return }
        switch result {
        case .success(let url): self.previewURL = url; self.renderPreview(entry: entry, url: url)
        case .failure: self.detailView.showNoPreview(symbol: Self.symbol(for: entry), message: "Couldn't load a preview.")
        }
      })
  }

  // Decode the fetched file off-main, then hand the image/text to the detail view.
  private func renderPreview(entry: MoshxploreEntry, url: URL) {
    let kind = MoshxplorePreview.kind(for: entry)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      var image: UIImage?
      var text: String?
      switch kind {
      case .image: image = UIImage(contentsOfFile: url.path)
      case .text:  text = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
      case .none:  break
      }
      DispatchQueue.main.async {
        guard let self, self.detailEntry?.name == entry.name else { return }
        if let image { self.detailView.showImage(image) }
        else if let text { self.detailView.showText(text) }
        else { self.detailView.showNoPreview(symbol: Self.symbol(for: entry), message: "Couldn't load a preview.") }
      }
    }
  }

  // The Download button — save into Documents/<host>/ (shown in Files.app as Moshroom › host › file).
  private func saveDetailFile() {
    guard let entry = detailEntry else { return }
    let host = hostAlias ?? "downloads"
    let dest = MoshxploreDownloads.directory(host: host)
    let target = dest.appendingPathComponent(entry.name)

    // Already fetched for preview? Copy it across instantly rather than downloading twice.
    if let preview = previewURL, FileManager.default.fileExists(atPath: preview.path) {
      showProgress(title: "Saving \(entry.name)…", fraction: 1)
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        try? FileManager.default.removeItem(at: target)
        let ok = (try? FileManager.default.copyItem(at: preview, to: target)) != nil
        DispatchQueue.main.async {
          guard let self else { return }
          if ok { self.showSaved(host: host, url: target) }
          else { self.hideProgress(); self.showError("Couldn't save the file.") }
        }
      }
      return
    }

    // Otherwise fetch it straight into the host folder with a progress bar.
    showProgress(title: "Downloading \(entry.name)…", fraction: 0)
    session?.download(remotePath: childPath(entry.name), name: entry.name, into: dest,
      progress: { [weak self] frac in self?.showProgress(title: "Downloading \(entry.name)…", fraction: frac) },
      completion: { [weak self] result in
        guard let self else { return }
        switch result {
        case .success: self.showSaved(host: host, url: target)
        case .failure(let error): self.hideProgress(); self.showError(self.message(for: error))
        }
      })
  }

  private func _buildProgressOverlay() {
    progressOverlay.translatesAutoresizingMaskIntoConstraints = false
    progressOverlay.backgroundColor = UIColor(white: 0.97, alpha: 0.98)
    progressOverlay.layer.cornerRadius = 18
    progressOverlay.isHidden = true
    addSubview(progressOverlay)

    progressTitle.font = .systemFont(ofSize: 14, weight: .medium)
    progressTitle.textColor = Self.dark
    progressTitle.numberOfLines = 2
    progressTitle.textAlignment = .center
    progressTitle.lineBreakMode = .byTruncatingMiddle

    progressBar.progressTintColor = .moshroomTint
    progressBar.trackTintColor = Self.stroke

    cancelButton.setTitle("Cancel", for: .normal)
    cancelButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    cancelButton.tintColor = Self.gray
    cancelButton.addAction(UIAction { [weak self] _ in
      self?.session?.cancelDownload()
      self?.hideProgress()
    }, for: .touchUpInside)

    // After a save: Open (share sheet) + Done.
    var openCfg = UIButton.Configuration.filled()
    openCfg.baseBackgroundColor = .moshroomTint
    openCfg.baseForegroundColor = .white
    openCfg.cornerStyle = .large
    openCfg.image = UIImage(systemName: "square.and.arrow.up")
    openCfg.imagePadding = 8
    var openAttr = AttributeContainer(); openAttr.font = .systemFont(ofSize: 15, weight: .semibold)
    openCfg.attributedTitle = AttributedString("Open", attributes: openAttr)
    openCfg.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
    openButton.configuration = openCfg
    openButton.isHidden = true
    openButton.addAction(UIAction { [weak self] _ in
      guard let self, let url = self.savedURL else { return }
      self.presentShare?(url)
    }, for: .touchUpInside)

    doneButton.setTitle("Done", for: .normal)
    doneButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    doneButton.tintColor = Self.gray
    doneButton.isHidden = true
    doneButton.addAction(UIAction { [weak self] _ in self?.hideProgress() }, for: .touchUpInside)

    let buttonRow = UIStackView(arrangedSubviews: [cancelButton, openButton, doneButton])
    buttonRow.axis = .horizontal
    buttonRow.spacing = 12
    buttonRow.distribution = .fillEqually

    let stack = UIStackView(arrangedSubviews: [progressTitle, progressBar, buttonRow])
    stack.axis = .vertical
    stack.spacing = 16
    stack.alignment = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    progressOverlay.addSubview(stack)

    NSLayoutConstraint.activate([
      progressOverlay.topAnchor.constraint(equalTo: topAnchor),
      progressOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
      progressOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
      progressOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.leadingAnchor.constraint(equalTo: progressOverlay.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(equalTo: progressOverlay.trailingAnchor, constant: -28),
      stack.centerYAnchor.constraint(equalTo: progressOverlay.centerYAnchor),
      progressBar.heightAnchor.constraint(equalToConstant: 6),
    ])
  }

  private func showProgress(title: String, fraction: Double) {
    progressTitle.text = title
    progressBar.isHidden = false
    progressBar.setProgress(Float(fraction), animated: true)
    cancelButton.isHidden = false
    openButton.isHidden = true
    doneButton.isHidden = true
    progressOverlay.isHidden = false
    bringSubviewToFront(progressOverlay)
  }

  // The saved confirmation: name the host folder it landed in, and offer Open (share sheet) / Done.
  private func showSaved(host: String, url: URL) {
    savedURL = url
    progressTitle.text = "Saved to Files → \(host)"
    progressBar.isHidden = true
    cancelButton.isHidden = true
    openButton.isHidden = false
    doneButton.isHidden = false
    progressOverlay.isHidden = false
    bringSubviewToFront(progressOverlay)
  }

  private func hideProgress() {
    progressOverlay.isHidden = true
    progressBar.setProgress(0, animated: false)
  }

  // MARK: Helpers

  private func childPath(_ name: String) -> String {
    (currentPath as NSString).appendingPathComponent(name)
  }

  private func subtitle(for entry: MoshxploreEntry) -> String {
    var parts: [String] = []
    if !entry.isDirectory { parts.append(Self.byteFormatter.string(fromByteCount: Int64(entry.size))) }
    if let date = entry.modified { parts.append(Self.dateFormatter.string(from: date)) }
    if entry.isSymlink { parts.insert("link", at: 0) }
    return parts.joined(separator: " · ")
  }

  // Richer two-line metadata for the detail view: size · date on top, the full remote path below.
  private func detailMeta(for entry: MoshxploreEntry) -> String {
    var parts: [String] = [Self.byteFormatter.string(fromByteCount: Int64(entry.size))]
    if let date = entry.modified { parts.append(Self.dateFormatter.string(from: date)) }
    if entry.isSymlink { parts.append("symlink") }
    return parts.joined(separator: "  ·  ") + "\n" + childPath(entry.name)
  }

  private func previewUnavailableMessage(for entry: MoshxploreEntry) -> String {
    MoshxplorePreview.isPreviewableType(entry)
      ? "Too large to preview here.\nDownload to open it."
      : "No inline preview.\nDownload to open it in Files."
  }

  private func showError(_ text: String) {
    errorLabel.text = text
    errorLabel.isHidden = false
  }

  private func message(for error: Error) -> String {
    if case let FileError.Fail(msg) = error { return msg }
    return error.localizedDescription
  }

  private static func symbol(for entry: MoshxploreEntry) -> String {
    if entry.isDirectory { return "folder.fill" }
    if entry.isSymlink { return "arrow.up.right.square" }
    switch (entry.name as NSString).pathExtension.lowercased() {
    case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff": return "photo"
    case "pdf": return "doc.richtext"
    case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar": return "archivebox"
    case "mp4", "mov", "mkv", "avi", "webm": return "film"
    case "mp3", "wav", "flac", "aac", "m4a", "ogg": return "music.note"
    case "json", "yml", "yaml", "xml", "toml", "ini", "conf": return "curlybraces"
    case "md", "txt", "log", "rtf": return "doc.text"
    case "swift", "c", "h", "m", "cpp", "py", "js", "ts", "go", "rs", "rb", "java", "sh": return "chevron.left.forwardslash.chevron.right"
    default: return "doc"
    }
  }

  private static func style(iconButton b: UIButton, systemName: String) {
    b.setImage(UIImage(systemName: systemName), for: .normal)
    b.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold), forImageIn: .normal)
    b.tintColor = dark
    b.translatesAutoresizingMaskIntoConstraints = false
    b.setContentHuggingPriority(.required, for: .horizontal)
    b.widthAnchor.constraint(equalToConstant: 30).isActive = true
    b.heightAnchor.constraint(equalToConstant: 30).isActive = true
  }
}

// MARK: - Install + SpaceController glue

enum Moshxplore {
  static func install(in sc: SpaceController) {
    let card = MoshxploreView()
    card.isHidden = true
    card.savedHosts = { [weak sc] in sc?.moshroomSavedHostAliases ?? [] }
    card.device = { [weak sc] in sc?.currentDevice }
    card.onClose = { [weak sc] in sc?.dismissMoshxplore() }
    // Hand a saved file to the system share sheet (Save to Files, Quick Look, open-in apps…).
    card.presentShare = { [weak sc, weak card] url in
      guard let sc else { return }
      let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      share.popoverPresentationController?.sourceView = card ?? sc.view
      sc.present(share, animated: true)
    }
    sc.view.addSubview(card)

    // Keep the host picker live when hosts change in Settings (same as Quick Connect), but only while
    // it's the visible step — an active browse session is left untouched.
    NotificationCenter.default.addObserver(forName: Notification.Name("MoshroomHostsDidSave"),
                                           object: nil, queue: .main) { [weak sc] _ in
      guard let sc, let card = sc.view.subviews.compactMap({ $0 as? MoshxploreView }).first else { return }
      card.reloadHostsIfVisible()
    }

    NSLayoutConstraint.activate([
      // Same top inset as Quick Connect so the two cards open at exactly the same height.
      card.topAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.topAnchor, constant: 76),
      // Stretched to the safe area with a comfortable lateral margin (same as Quick Connect) so the
      // browser is as wide as the screen allows rather than a narrow centred box.
      card.leadingAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      card.trailingAnchor.constraint(equalTo: sc.view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      card.bottomAnchor.constraint(lessThanOrEqualTo: sc.view.safeAreaLayoutGuide.bottomAnchor, constant: -72),
    ])
  }
}

extension SpaceController {
  private var moshxploreCard: MoshxploreView? {
    view.subviews.compactMap { $0 as? MoshxploreView }.first
  }

  // True while the file explorer is on screen — Quick Connect checks this so the two never overlap.
  var moshroomMoshxploreIsOpen: Bool {
    guard let card = moshxploreCard else { return false }
    return !card.isHidden
  }

  // Open Moshxplore over the current tab. Defaults to the tab's connected host (if it's a saved
  // one) so a connected session browses itself with one tap; otherwise it shows the host picker.
  func openMoshxplore() {
    guard let card = moshxploreCard else { return }
    dismissMoshnector()
    card.present(preferredHost: currentTerm()?.moshroomConnectedHost)
    card.isHidden = false
    view.bringSubviewToFront(card)
  }

  func dismissMoshxplore() {
    guard let card = moshxploreCard, !card.isHidden else { return }
    card.teardown()
    card.isHidden = true
    // Back to the terminal — let Quick Connect reappear if this is a fresh idle prompt.
    showMoshnectorIfIdle()
  }
}
