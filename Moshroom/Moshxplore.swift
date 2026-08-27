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
// of `ls -lsa`), and tap download to copy a file into `Documents/<host>/`, visible in Files.app.
// Text files that decode cleanly can also be **edited in place**: Edit turns the preview into
// the editor, Save writes the bytes back over the same SFTP connection in the file's original
// form (encoding, BOM, line endings). Everything reuses the proven Combine SSH/SFTP stack from
// CopyFiles.swift (the same one Moshdrop uploads with), driven on its own run-loop thread — the
// remote needs nothing installed, and every transfer "acts as scp" because it *is* SFTP.
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

  // Rebuild an entry with the post-save size/date (a struct of lets — no mutation).
  init(name: String, isDirectory: Bool, isSymlink: Bool, size: UInt64, modified: Date?) {
    self.name = name
    self.isDirectory = isDirectory
    self.isSymlink = isSymlink
    self.size = size
    self.modified = modified
  }
}

// MARK: - Symlink resolution

extension Translator {
  /// What a directory entry REALLY is. `sftp_readdir` answers with lstat semantics, so every symlink
  /// arrives typed as a link: a link to a directory then sorts, draws and taps like a file, which is
  /// exactly why a linked folder could not be opened. One stat (which DOES follow the link) settles
  /// it, and brings the target's real size and date along while it is there — a link's own size is
  /// the length of the path string it holds, never what the user means by "how big is this".
  /// nil means the link is broken or unreadable, and then the entry must stay exactly as it came so
  /// it can never pretend to be a folder. `join` costs nothing (no round trip), `stat` costs one.
  /// This is the one place either surface asks "link to what?" — Moshxplore's browser and Moshify's
  /// library scan both come here.
  func moshroomStatFollowingLinks(child name: String, in dirPath: String) -> AnyPublisher<FileAttributes?, Error> {
    guard let target = try? clone().join((dirPath as NSString).appendingPathComponent(name)) else {
      return Just(nil).setFailureType(to: Error.self).eraseToAnyPublisher()
    }
    return target.stat()
      .map { Optional($0) }
      .replaceError(with: nil)
      .setFailureType(to: Error.self)
      .eraseToAnyPublisher()
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

// What a tapped file can show inline before downloading. Images and known-binary formats are
// recognized by extension; EVERYTHING else within the size gate is treated as candidate text —
// scripts, configs, logs, json/jsonl/ndjson, code, extensionless dotfiles, Makefiles… The fetched
// bytes make the final call (a NUL byte marks binary, strict decode gates editing), so no list of
// text formats ever needs maintaining and none is left out.
enum MoshxplorePreview {
  enum Kind { case image, text, none }

  static let imageMaxBytes: UInt64 = 8 * 1024 * 1024
  static let textMaxBytes: UInt64 = 1 * 1024 * 1024

  private static let imageExt: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff"]
  // Certainly-not-text formats — never fetched for a text preview.
  private static let binaryExt: Set<String> = [
    "pdf", "zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz4", "br", "7z", "rar", "jar",
    "mp3", "wav", "flac", "aac", "m4a", "ogg", "mp4", "mov", "mkv", "avi", "webm",
    "ttf", "otf", "woff", "woff2", "eot", "ico", "icns", "psd",
    "exe", "dll", "dylib", "so", "a", "o", "class", "pyc", "wasm",
    "sqlite", "sqlite3", "db", "realm", "pack", "idx",
    "dmg", "iso", "img", "bin", "apk", "ipa", "deb", "rpm"]

  static func kind(for entry: MoshxploreEntry) -> Kind {
    if entry.isDirectory { return .none }
    let ext = (entry.name as NSString).pathExtension.lowercased()
    if imageExt.contains(ext) { return entry.size <= imageMaxBytes ? .image : .none }
    if binaryExt.contains(ext) { return .none }
    return entry.size <= textMaxBytes ? .text : .none
  }

  // Is this a previewable *type* regardless of size? (Distinguishes "too large" from "can't preview".)
  static func isPreviewableType(_ entry: MoshxploreEntry) -> Bool {
    if entry.isDirectory { return false }
    return !binaryExt.contains((entry.name as NSString).pathExtension.lowercased())
  }
}

// A text file decoded for the inline editor, remembering enough of its on-disk form (encoding,
// UTF-8 BOM, CRLF line endings) to write edits back byte-faithfully. `decode` is strict — bytes
// that aren't clean UTF-8 (or Latin-1, whose byte↔scalar map round-trips losslessly) make the
// file preview-only, so a save can never corrupt content the editor couldn't fully represent.
struct MoshxploreTextFile {
  let text: String          // display form: BOM stripped, line endings normalized to \n
  let encoding: String.Encoding
  let hadBOM: Bool
  let usesCRLF: Bool

  static func decode(_ data: Data) -> MoshxploreTextFile? {
    guard !data.contains(0) else { return nil }   // NUL never appears in text — binary (or UTF-16)
    var body = data
    var hadBOM = false
    if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3); hadBOM = true }

    let encoding: String.Encoding
    let raw: String
    if let utf8 = String(data: body, encoding: .utf8) { encoding = .utf8; raw = utf8 }
    else if let latin1 = String(data: body, encoding: .isoLatin1) { encoding = .isoLatin1; raw = latin1 }
    else { return nil }

    // UITextView types \n, so edit on \n and restore CRLF at save (a mixed-endings file
    // comes back uniformly CRLF — the least surprising repair).
    let usesCRLF = raw.contains("\r\n")
    return MoshxploreTextFile(text: usesCRLF ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw,
                              encoding: encoding, hadBOM: hadBOM, usesCRLF: usesCRLF)
  }

  // Edited text → bytes in the file's original form. If the user typed characters the original
  // encoding can't hold (emoji into a Latin-1 file), upgrade to UTF-8 rather than mangle them.
  func encode(_ edited: String) -> Data {
    let restored = usesCRLF ? edited.replacingOccurrences(of: "\n", with: "\r\n") : edited
    var out = restored.data(using: encoding) ?? Data(restored.utf8)
    if hadBOM { out = Data([0xEF, 0xBB, 0xBF]) + out }
    return out
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
  private var uploadC: AnyCancellable?

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
  func connect(hostAlias: String, device: TermDevice?,
               completion: @escaping (Result<String, Error>) -> Void) {
    start()
    onWorker { [weak self] in
      guard let self else { return }
      let target: (hostName: String, host: MoshSSHHost, config: SSHClientConfig)
      do {
        target = try MoshroomSSH.resolveTarget(hostAlias: hostAlias, device: device)
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
        return
      }

      self.connectC = SSHClient.dial(target.hostName, with: target.config, withProxy: MoshroomSSH.executeProxyCommand)
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

  // List one absolute directory path. Symlinks are resolved first (a linked folder has to BE a
  // folder here, or nothing downstream lets you open it), then entries sort dirs-first, then by
  // case-insensitive name.
  func list(path: String, completion: @escaping (Result<[MoshxploreEntry], Error>) -> Void) {
    onWorker { [weak self] in
      guard let self, let root = self.root else {
        DispatchQueue.main.async { completion(.failure(MoshxploreError.notConnected)) }
        return
      }
      self.listC = root.cloneWalkTo(path)
        .flatMap { dir -> AnyPublisher<[MoshxploreEntry], Error> in
          dir.directoryFilesAndAttributes()
            .map { rows in
              rows.compactMap(MoshxploreEntry.init).filter { $0.name != "." && $0.name != ".." }
            }
            // The canonical directory path, not the one asked for: the entries are stat'd by full
            // path, and the caller may well have walked in through a link itself.
            .flatMap { Self.resolvingSymlinks($0, in: dir.current, root: root) }
            .eraseToAnyPublisher()
        }
        .sink(receiveCompletion: { c in
          if case .failure(let e) = c { DispatchQueue.main.async { completion(.failure(e)) } }
        }, receiveValue: { entries in
          let sorted = entries.sorted { a, b in
            a.isDirectory != b.isDirectory ? a.isDirectory
              : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
          }
          DispatchQueue.main.async { completion(.success(sorted)) }
        })
    }
  }

  /// How many links one listing resolves. Each is a round trip on the single (serial) SFTP channel,
  /// so a directory holding hundreds of them must not keep the browser waiting; past the cap the
  /// rest stay links, which is all they ever were before this existed.
  private static let symlinkResolveLimit = 64

  /// Re-tag every symlink with what it actually points at (see moshroomStatFollowingLinks). Order is
  /// preserved and the caller still sorts; a link we cannot stat is left untouched, on purpose.
  private static func resolvingSymlinks(_ entries: [MoshxploreEntry], in dirPath: String,
                                        root: Translator) -> AnyPublisher<[MoshxploreEntry], Error> {
    let links = Array(entries.enumerated().filter { $0.element.isSymlink }.prefix(symlinkResolveLimit))
    guard !links.isEmpty else {
      return Just(entries).setFailureType(to: Error.self).eraseToAnyPublisher()
    }
    let lookups = links.map { index, entry in
      root.moshroomStatFollowingLinks(child: entry.name, in: dirPath)
        .map { (index, $0) }
        .eraseToAnyPublisher()
    }
    return Publishers.Sequence(sequence: lookups)
      // One at a time: every op rides the one SFTP channel anyway.
      .flatMap(maxPublishers: .max(1)) { $0 }
      .collect()
      .map { resolved in
        var out = entries
        for (index, attrs) in resolved {
          guard let attrs, out.indices.contains(index) else { continue }
          let entry = out[index]
          out[index] = MoshxploreEntry(
            name: entry.name,
            isDirectory: (attrs[.type] as? FileAttributeType) == .typeDirectory,
            isSymlink: true,
            size: (attrs[.size] as? NSNumber)?.uint64Value ?? entry.size,
            modified: attrs[.modificationDate] as? Date ?? entry.modified)
        }
        return out
      }
      .eraseToAnyPublisher()
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

  // Upload one local file into the remote directory `remoteDir`, landing under the local file's
  // own name — the write-back half of the inline editor. Same connection, same worker thread;
  // SFTP `create` opens O_CREAT|O_TRUNC, so saving over an existing file replaces it in place.
  func upload(localURL: URL, remoteDir: String, completion: @escaping (Result<Void, Error>) -> Void) {
    onWorker { [weak self] in
      guard let self, let root = self.root else {
        DispatchQueue.main.async { completion(.failure(MoshxploreError.notConnected)) }
        return
      }
      let localFile = MoshroomFiles.Local().walkTo(localURL.path)
      let remote = root.cloneWalkTo(remoteDir)
      self.uploadC = Publishers.Zip(remote, localFile)
        .flatMap { rdir, lfile in
          rdir.copy(from: [lfile], args: CopyArguments(preserve: CopyAttributesFlag([]), checkTimes: false))
        }
        .sink(receiveCompletion: { c in
          switch c {
          case .finished: DispatchQueue.main.async { completion(.success(())) }
          case .failure(let e): DispatchQueue.main.async { completion(.failure(e)) }
          }
        }, receiveValue: { _ in })
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
      self?.uploadC = nil
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

// Adaptive palette — the explorer is a full app screen now, so it follows the system appearance
// exactly like Settings does (dark mode = the black + mushroom-red look). The one deliberate
// exception is the CODE surface in the detail view: always Moshlight's Mushroom soil.
enum MoshxploreStyle {
  static let dark = UIColor.label
  static let gray = UIColor.secondaryLabel
  static let stroke = UIColor.separator
  static let row = UIColor.secondarySystemGroupedBackground
  static let rowPressed = UIColor.tertiarySystemGroupedBackground
  static let screen = UIColor.systemGroupedBackground

  // The Moshxplore "Text Size" preference (Settings → Moshxplore) is an absolute point size that
  // controls ONLY the file viewer/editor CONTENT text — the thing you actually read and edit. The
  // explorer chrome (rows, buttons, titles, metadata, paths) keeps fixed, sensible defaults so the
  // navigator always looks right on any device regardless of the content size. Defaults: 15 px on
  // iPhone, 17 px on iPad. The explorer is built fresh per open, so a change applies next open.
  static let textSizeKey = "MoshxploreTextSize"
  static let textSizeRange = 12...24
  static var defaultTextSize: Int { UIDevice.current.userInterfaceIdiom == .pad ? 17 : 15 }
  private static var effectiveTextSize: CGFloat {
    let stored = UserDefaults.standard.integer(forKey: textSizeKey) // 0 = never set
    let size = stored == 0 ? defaultTextSize : stored
    return CGFloat(min(max(size, textSizeRange.lowerBound), textSizeRange.upperBound))
  }
  // The file viewer/editor content font — the ONLY thing the Text Size preference scales.
  static var contentFont: UIFont { .monospacedSystemFont(ofSize: effectiveTextSize, weight: .regular) }

  // Chrome fonts + paddings are FIXED at their authored sizes — a normal iPad/iPhone default that
  // reads well and never follows the content Text Size preference.
  static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
    .systemFont(ofSize: size, weight: weight)
  }
  static func inset(_ base: CGFloat) -> CGFloat { base }
}

// The tiny gray copy-glyph next to a path: tap → the path lands on the clipboard and the glyph
// flashes a checkmark for 2 s before reverting. One shared control for the file detail and the
// browser's current-folder path; iOS and Mac alike (UIPasteboard bridges to the Mac clipboard).
final class MoshxploreCopyButton: UIButton {
  var textToCopy: () -> String? = { nil }
  private var revertWork: DispatchWorkItem?

  init() {
    super.init(frame: .zero)
    #if targetEnvironment(macCatalyst)
    preferredBehavioralStyle = .pad
    #endif
    _setSymbol("doc.on.doc")
    addAction(UIAction { [weak self] _ in self?._copyNow() }, for: .touchUpInside)
    translatesAutoresizingMaskIntoConstraints = false
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func _setSymbol(_ name: String) {
    let cfg = UIImage.SymbolConfiguration(pointSize: MoshxploreStyle.inset(13), weight: .medium)
    setImage(UIImage(systemName: name, withConfiguration: cfg)?
      .withTintColor(MoshxploreStyle.gray, renderingMode: .alwaysOriginal), for: .normal)
  }

  private func _copyNow() {
    guard let text = textToCopy(), !text.isEmpty else { return }
    UIPasteboard.general.string = text
    _setSymbol("checkmark")
    revertWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?._setSymbol("doc.on.doc") }
    revertWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
  }
}

// MARK: - Entry row

// One file/folder row: icon, name, size·date, chevron. Tapping a folder descends into it; tapping a
// file opens its detail view. The whole row is the tap target.
private final class MoshxploreEntryRow: UIControl {

  init(entry: MoshxploreEntry, symbol: String, subtitle: String, onTap: @escaping () -> Void) {
    super.init(frame: .zero)
    self.onTap = onTap
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = MoshxploreStyle.row
    layer.cornerRadius = Moshstyle.rowRadius

    let icon = UIImageView(image: UIImage(systemName: symbol))
    icon.tintColor = entry.isDirectory ? .moshroomTint : MoshxploreStyle.dark
    icon.contentMode = .scaleAspectFit
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.setContentHuggingPriority(.required, for: .horizontal)

    let name = UILabel()
    name.text = entry.name
    name.font = MoshxploreStyle.font(15, .medium)
    name.textColor = MoshxploreStyle.dark
    name.lineBreakMode = .byTruncatingMiddle
    name.setContentCompressionResistancePriority(.required, for: .vertical)

    let meta = UILabel()
    meta.text = subtitle
    meta.font = MoshxploreStyle.font(12)
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
    didSet { backgroundColor = isHighlighted ? MoshxploreStyle.rowPressed : MoshxploreStyle.row }
  }
}

// MARK: - File detail

// The single-file view: name, metadata, an inline preview (image or text/code when it's small and
// readable), and the bottom action row — Download, joined by Edit when the text decoded cleanly.
// Edit turns the preview into the editor in place and becomes a single full-width Save; saving
// (driven by the card) lands back in view mode. Pure presentation — the card drives fetch + save.
private final class MoshxploreDetailView: UIView {

  var onBack: (() -> Void)?
  var onDownload: (() -> Void)?
  var onEditToggle: (() -> Void)?
  var onEditCancel: (() -> Void)?    // Edit ↔ Save taps; the card decides what they mean

  private(set) var isEditingText = false
  var editedText: String { textView.text ?? "" }

  private let titleLabel = UILabel()
  private let metaLabel = UILabel()
  private let previewBox = UIView()
  private let imageView = UIImageView()
  // TextKit 1 from birth: the line-number gutter reads `layoutManager`, and letting UIKit switch
  // engines lazily mid-life (the TextKit 2 → 1 fallback) glitches scrolling until a relayout.
  private let textView = UITextView(usingTextLayoutManager: false)
  private let placeholderIcon = UIImageView()
  private let placeholderLabel = UILabel()
  private let placeholder = UIStackView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  // The pill buttons use UIButton.Configuration — on Mac Catalyst that defaults to the `.mac`
  // behavioral style, which swaps in the native macOS push-button look and IGNORES the
  // configuration's contentInsets and fill (the "Download button has no padding and isn't
  // mushroom-red" bug). `.pad` keeps our authored pills identical on every platform.
  private static func pillButton() -> UIButton {
    let b = UIButton(type: .system)
    #if targetEnvironment(macCatalyst)
    b.preferredBehavioralStyle = .pad
    #endif
    return b
  }
  private let saveButton = MoshxploreDetailView.pillButton()     // top-right, next to the file name — edit mode only
  private let cancelButton = MoshxploreDetailView.pillButton()   // beside Save — white, discards the edit
  private let editButton = MoshxploreDetailView.pillButton()
  private let downloadButton = MoshxploreDetailView.pillButton()
  private let pathLabel = UILabel()                    // the full remote path, with its copy glyph
  private let pathCopyButton = MoshxploreCopyButton()
  private let actionRow = UIStackView()                // the bottom Edit/Download pair; hidden while editing

  // Moshlight: the code surface (Mushroom soil, the one and only theme), its line-number gutter,
  // and the detected language rules for the file on screen.
  private let gutter = MoshlightGutter()
  private var gutterWidthC: NSLayoutConstraint!
  private var codeRules: Moshlight.Rules?
  private var isCodeSurface = false
  private var pendingHighlight: DispatchWorkItem?
  // Computed, not a stored static: the size preference must be re-read on every fresh explorer,
  // and a cached `let` would pin the first launch's size for the whole app session.
  private static var codeFont: UIFont { MoshxploreStyle.contentFont }

  // The preview fills all the height between the meta line and the bottom buttons; while editing
  // the buttons step aside and it runs to the bottom edge. Toggled in enter/exit edit mode.
  private var previewBottomToButtons: NSLayoutConstraint!
  private var previewBottomToEdge: NSLayoutConstraint!

  init() {
    super.init(frame: .zero)

    let back = moshButton()
    back.setMoshIcon("chevron.backward", pointSize: 15, weight: .semibold, color: MoshxploreStyle.dark)
    back.setContentHuggingPriority(.required, for: .horizontal)
    back.widthAnchor.constraint(equalToConstant: 30).isActive = true
    back.heightAnchor.constraint(equalToConstant: 30).isActive = true
    back.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)

    titleLabel.font = MoshxploreStyle.font(16, .semibold)
    titleLabel.textColor = MoshxploreStyle.dark
    // A long filename wraps onto more lines rather than fighting the Save button for width.
    titleLabel.numberOfLines = 0
    titleLabel.lineBreakMode = .byCharWrapping
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    saveButton.configuration = Self.saveConfig(saving: false)
    saveButton.isHidden = true
    saveButton.setContentHuggingPriority(.required, for: .horizontal)
    saveButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    saveButton.addAction(UIAction { [weak self] _ in self?.onEditToggle?() }, for: .touchUpInside)

    // Cancel: the white twin of Save (white capsule, near-black text — the house chip colours,
    // fixed in both appearances). Same discard the back button performs while editing, but
    // visible right where the decision is being made.
    cancelButton.configuration = Self.cancelConfig()
    cancelButton.isHidden = true
    cancelButton.setContentHuggingPriority(.required, for: .horizontal)
    cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    cancelButton.addAction(UIAction { [weak self] _ in self?.onEditCancel?() }, for: .touchUpInside)

    let header = UIStackView(arrangedSubviews: [back, titleLabel, cancelButton, saveButton])
    header.axis = .horizontal
    header.spacing = 8
    header.alignment = .center

    metaLabel.font = MoshxploreStyle.font(12)
    metaLabel.textColor = MoshxploreStyle.gray
    metaLabel.numberOfLines = 0

    // The full remote path on its own line, with the copy glyph right beside it.
    pathLabel.font = MoshxploreStyle.font(12)
    pathLabel.textColor = MoshxploreStyle.gray
    pathLabel.lineBreakMode = .byTruncatingMiddle
    pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    pathLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)   // glyph rides the text
    pathCopyButton.textToCopy = { [weak self] in self?.pathLabel.text }

    // Full-bleed viewer surface — edge to edge, hairline top/bottom, no card chrome.
    previewBox.backgroundColor = MoshxploreStyle.row
    previewBox.layer.borderWidth = 0.5
    previewBox.layer.borderColor = MoshxploreStyle.stroke.cgColor
    previewBox.clipsToBounds = true
    previewBox.translatesAutoresizingMaskIntoConstraints = false

    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.isHidden = true

    textView.isEditable = false
    textView.backgroundColor = .clear
    textView.font = Self.codeFont
    textView.textColor = MoshxploreStyle.dark
    textView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isHidden = true
    // The moment this becomes the editor, iOS text "help" would mangle code — off across the board.
    textView.autocorrectionType = .no
    textView.autocapitalizationType = .none
    textView.spellCheckingType = .no
    textView.smartQuotesType = .no
    textView.smartDashesType = .no
    textView.smartInsertDeleteType = .no
    textView.keyboardDismissMode = .interactive
    textView.tintColor = .moshroomTint
    textView.keyboardAppearance = .dark   // the editor lives on mushroom soil
    textView.alwaysBounceVertical = true  // scrolling always answers, even when the file fits
    textView.delegate = self

    placeholderIcon.contentMode = .scaleAspectFit
    placeholderIcon.tintColor = .tertiaryLabel
    placeholderIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34)
    placeholderLabel.font = MoshxploreStyle.font(12)
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

    // The gutter sits over the text's left edge (text scrolls beneath it — its background is
    // opaque soil, a shade darker), so wrapped lines keep one number like any real editor.
    gutter.textView = textView
    gutter.isHidden = true
    gutter.onWidthChange = { [weak self] _ in self?._applySurface() }
    previewBox.addSubview(gutter)
    gutterWidthC = gutter.widthAnchor.constraint(equalToConstant: 36)

    downloadButton.configuration = Self.actionConfig(title: "Download", symbol: "arrow.down.to.line", primary: true)
    downloadButton.addAction(UIAction { [weak self] _ in self?.onDownload?() }, for: .touchUpInside)

    editButton.configuration = Self.actionConfig(title: "Edit", symbol: "pencil", primary: false)
    editButton.isHidden = true
    editButton.addAction(UIAction { [weak self] _ in self?.onEditToggle?() }, for: .touchUpInside)

    // Edit and Download sit centered at the bottom, sized to their content — a clean pair of
    // pills, not a stretched bar. The whole row steps aside while editing (Save is in the header).
    [editButton, downloadButton].forEach { actionRow.addArrangedSubview($0) }
    actionRow.axis = .horizontal
    actionRow.spacing = 12
    actionRow.translatesAutoresizingMaskIntoConstraints = false

    header.translatesAutoresizingMaskIntoConstraints = false
    metaLabel.translatesAutoresizingMaskIntoConstraints = false
    let pathRow = UIStackView(arrangedSubviews: [pathLabel, pathCopyButton, UIView()])
    pathRow.axis = .horizontal
    pathRow.spacing = 8
    pathRow.alignment = .center
    pathRow.translatesAutoresizingMaskIntoConstraints = false
    [header, metaLabel, pathRow, previewBox, actionRow].forEach { addSubview($0) }

    previewBottomToButtons = previewBox.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -12)
    previewBottomToEdge = previewBox.bottomAnchor.constraint(equalTo: bottomAnchor)

    NSLayoutConstraint.activate([
      // Header (back · filename · Save) and meta keep the screen margin; the viewer bleeds full width.
      header.topAnchor.constraint(equalTo: topAnchor),
      header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      metaLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
      metaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      pathRow.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 2),
      pathRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      pathRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      previewBox.topAnchor.constraint(equalTo: pathRow.bottomAnchor, constant: 12),
      previewBox.leadingAnchor.constraint(equalTo: leadingAnchor),
      previewBox.trailingAnchor.constraint(equalTo: trailingAnchor),
      previewBottomToButtons,
      actionRow.centerXAnchor.constraint(equalTo: centerXAnchor),
      actionRow.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      actionRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      // An image never goes gigantic: centered, at most 60% of the viewer in each dimension.
      imageView.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
      imageView.widthAnchor.constraint(lessThanOrEqualTo: previewBox.widthAnchor, multiplier: 0.6),
      imageView.heightAnchor.constraint(lessThanOrEqualTo: previewBox.heightAnchor, multiplier: 0.6),
      {
        let c = imageView.widthAnchor.constraint(equalTo: previewBox.widthAnchor, multiplier: 0.6)
        c.priority = .init(750); return c
      }(),
      {
        let c = imageView.heightAnchor.constraint(equalTo: previewBox.heightAnchor, multiplier: 0.6)
        c.priority = .init(750); return c
      }(),
      textView.topAnchor.constraint(equalTo: previewBox.topAnchor),
      textView.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor),
      textView.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
      gutter.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
      gutter.topAnchor.constraint(equalTo: previewBox.topAnchor),
      gutter.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor),
      gutterWidthC,
      placeholder.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
      placeholder.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
      placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: previewBox.leadingAnchor, constant: 16),
      placeholder.trailingAnchor.constraint(lessThanOrEqualTo: previewBox.trailingAnchor, constant: -16),
      spinner.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(name: String, meta: String, path: String) {
    titleLabel.text = name
    metaLabel.text = meta
    pathLabel.text = path
  }

  func showPreviewLoading() {
    isCodeSurface = false
    gutter.isHidden = true
    resetEditUI()
    imageView.isHidden = true; imageView.image = nil
    textView.isHidden = true; textView.text = nil
    placeholder.isHidden = true
    spinner.startAnimating()
  }

  func showImage(_ image: UIImage) {
    isCodeSurface = false
    gutter.isHidden = true
    resetEditUI()
    spinner.stopAnimating()
    placeholder.isHidden = true; textView.isHidden = true
    imageView.image = image
    imageView.isHidden = false
  }

  func showText(_ text: String, filename: String) {
    isCodeSurface = true
    let firstLine = String(text.prefix(120).prefix(while: { $0 != "\n" }))
    codeRules = Moshlight.rules(filename: filename, firstLine: firstLine)
    resetEditUI()
    spinner.stopAnimating()
    placeholder.isHidden = true; imageView.isHidden = true
    textView.text = text
    _rehighlightNow()
    gutter.noteTextChanged()
    gutter.isHidden = false
    textView.isHidden = false
    textView.setContentOffset(.zero, animated: false)
  }

  func showNoPreview(symbol: String, message: String) {
    isCodeSurface = false
    gutter.isHidden = true
    resetEditUI()
    spinner.stopAnimating()
    imageView.isHidden = true; textView.isHidden = true
    placeholderIcon.image = UIImage(systemName: symbol)
    placeholderLabel.text = message
    placeholder.isHidden = false
  }

  // MARK: Edit mode

  // Offer Edit only for a text preview that decoded cleanly (the card decides after fetching).
  func setEditAvailable(_ available: Bool) {
    editButton.isHidden = !available
  }

  // Edit tapped: the preview becomes the editor in place, the bottom row steps aside entirely,
  // and a compact Save appears top-right next to the file name. Just the textarea — no other chrome.
  func enterEditMode() {
    guard !isEditingText else { return }
    isEditingText = true
    actionRow.isHidden = true
    previewBottomToButtons.isActive = false
    previewBottomToEdge.isActive = true     // the editor takes the freed bottom space
    saveButton.isHidden = false
    cancelButton.isHidden = false
    textView.isEditable = true
    _applySurface()   // the amanita ring marks edit mode on the soil surface
    textView.becomeFirstResponder()
  }

  // While the upload runs the Save button spins and the text is locked; a failed save unlocks
  // everything right back into edit mode with the text intact.
  func setSaving(_ saving: Bool) {
    saveButton.configuration = Self.saveConfig(saving: saving)
    saveButton.isEnabled = !saving
    cancelButton.isEnabled = !saving   // a save mid-flight must resolve before discarding
    textView.isEditable = !saving
  }

  func exitEditMode() {
    guard isEditingText else { return }
    resetEditUI()
    editButton.isHidden = false   // the file is still an editable text — keep offering Edit
  }

  private func resetEditUI() {
    isEditingText = false
    textView.isEditable = false   // also resigns the keyboard if it was up
    actionRow.isHidden = false
    previewBottomToEdge.isActive = false
    previewBottomToButtons.isActive = true
    downloadButton.isHidden = false
    editButton.isHidden = true
    saveButton.isHidden = true
    cancelButton.isHidden = true
    saveButton.isEnabled = true
    saveButton.configuration = Self.saveConfig(saving: false)
    _applySurface()
  }

  // The two content surfaces: **Mushroom soil** for anything textual (the ONLY code theme — warm,
  // dark, ours; it never follows system light/dark), and the adaptive screen surface for images
  // and placeholders. Edit mode adds the amanita ring.
  private func _applySurface() {
    if isCodeSurface {
      previewBox.backgroundColor = Moshlight.Palette.background
      previewBox.layer.borderColor = isEditingText
        ? UIColor.moshroomTint.withAlphaComponent(0.55).cgColor
        : UIColor(white: 0, alpha: 0.35).cgColor
      previewBox.layer.borderWidth = isEditingText ? 1 : 0.5
      textView.indicatorStyle = .white
      gutterWidthC.constant = gutter.gutterWidth
      textView.textContainerInset = UIEdgeInsets(top: 10, left: gutter.gutterWidth + 8, bottom: 10, right: 10)
    } else {
      previewBox.backgroundColor = MoshxploreStyle.row
      previewBox.layer.borderColor = MoshxploreStyle.stroke.cgColor
      previewBox.layer.borderWidth = 0.5
      textView.indicatorStyle = .default
      textView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    }
  }

  // Re-run Moshlight over the current text (attributes only — the bytes are untouched), and keep
  // freshly-typed characters in cream until the next pass recolors them.
  private func _rehighlightNow() {
    Moshlight.apply(to: textView.textStorage, rules: codeRules, font: Self.codeFont)
    textView.typingAttributes = [.font: Self.codeFont, .foregroundColor: Moshlight.Palette.text]
  }

  // The bottom-row look, in the two house flavours: primary is the mushroom fill (Download),
  // secondary the white + hairline-stroke of the rows (Edit). Identical metrics, so the row
  // never jumps when Edit appears or hides.
  private static func actionConfig(title: String, symbol: String, primary: Bool) -> UIButton.Configuration {
    var cfg = UIButton.Configuration.filled()
    cfg.baseBackgroundColor = primary ? .moshroomTint : MoshxploreStyle.row
    cfg.baseForegroundColor = primary ? .white : MoshxploreStyle.dark
    cfg.cornerStyle = .large
    if !primary {
      cfg.background.strokeColor = MoshxploreStyle.stroke
      cfg.background.strokeWidth = 0.5
    }
    cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: MoshxploreStyle.inset(14), weight: .semibold))
    cfg.imagePadding = MoshxploreStyle.inset(8)
    var attr = AttributeContainer(); attr.font = MoshxploreStyle.font(16, .semibold)
    cfg.attributedTitle = AttributedString(title, attributes: attr)
    cfg.contentInsets = NSDirectionalEdgeInsets(top: MoshxploreStyle.inset(13), leading: MoshxploreStyle.inset(16), bottom: MoshxploreStyle.inset(13), trailing: MoshxploreStyle.inset(16))
    return cfg
  }

  // The header Cancel: Save's white twin — white capsule, near-black text (the house chip
  // colours, deliberately the same in light and dark).
  private static func cancelConfig() -> UIButton.Configuration {
    var cfg = UIButton.Configuration.filled()
    cfg.baseBackgroundColor = Moshstyle.chipFillOpaque
    cfg.baseForegroundColor = Moshstyle.ink
    cfg.cornerStyle = .capsule
    cfg.background.strokeColor = MoshxploreStyle.stroke
    cfg.background.strokeWidth = 0.5
    var attr = AttributeContainer(); attr.font = MoshxploreStyle.font(14, .semibold)
    cfg.attributedTitle = AttributedString("Cancel", attributes: attr)
    cfg.contentInsets = NSDirectionalEdgeInsets(top: MoshxploreStyle.inset(7), leading: MoshxploreStyle.inset(14), bottom: MoshxploreStyle.inset(7), trailing: MoshxploreStyle.inset(14))
    return cfg
  }

  // The header Save: a compact mushroom capsule sized to sit beside the file name.
  private static func saveConfig(saving: Bool) -> UIButton.Configuration {
    var cfg = UIButton.Configuration.filled()
    cfg.baseBackgroundColor = .moshroomTint
    cfg.baseForegroundColor = .white
    cfg.cornerStyle = .capsule
    cfg.showsActivityIndicator = saving
    var attr = AttributeContainer(); attr.font = MoshxploreStyle.font(14, .semibold)
    cfg.attributedTitle = AttributedString(saving ? "Saving…" : "Save", attributes: attr)
    cfg.imagePadding = MoshxploreStyle.inset(6)
    cfg.contentInsets = NSDirectionalEdgeInsets(top: MoshxploreStyle.inset(7), leading: MoshxploreStyle.inset(14), bottom: MoshxploreStyle.inset(7), trailing: MoshxploreStyle.inset(14))
    return cfg
  }
}

// Editing keeps the gutter numbering and the highlight honest: line starts recompute on every
// change (cheap single pass), colors follow after a short breath so typing never stutters.
extension MoshxploreDetailView: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    gutter.noteTextChanged()
    pendingHighlight?.cancel()
    guard codeRules != nil, textView.textStorage.length <= Moshlight.highlightMaxLength else { return }
    let work = DispatchWorkItem { [weak self] in
      self?._rehighlightNow()
      self?.gutter.setNeedsDisplay()
    }
    pendingHighlight = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    gutter.setNeedsDisplay()
  }
}

// MARK: - The card

// Pure presentation + its own SFTP session. SpaceController only feeds it the saved hosts, the
// current device (for SSH config), and a close hook.
final class MoshxploreView: UIView {

  var savedHosts: (() -> [String])?
  var device: (() -> TermDevice?)?
  var presentShare: ((URL) -> Void)?    // hand a saved file to the system share sheet

  private static let dark = MoshxploreStyle.dark
  private static let gray = MoshxploreStyle.gray
  private static let stroke = MoshxploreStyle.stroke

  private let hostStep = UIStackView()
  private let hostsStack = UIStackView()
  private let hostsScroll = UIScrollView()
  private let hostsEmpty = UILabel()

  private let browserStep = UIStackView()
  private let upButton = moshButton()
  private let hostsButton = moshButton()
  private let pathLabel = UILabel()
  private let pathCopyButton = MoshxploreCopyButton()   // copies the current folder path
  private let entriesStack = UIStackView()
  private let entriesScroll = UIScrollView()
  private let spinner = UIActivityIndicatorView(style: .medium)

  private let detailView = MoshxploreDetailView()

  private let errorLabel = UILabel()

  private let progressOverlay = UIView()
  private let progressTitle = UILabel()
  private let progressBar = UIProgressView(progressViewStyle: .default)
  private let cancelButton = moshButton()
  private let openButton = UIButton(type: .system)
  private let doneButton = moshButton()

  private var session: MoshxploreSession?
  private var hostAlias: String?
  // The picked host, exposed for the explorer TAB's title (nil while the host picker shows).
  var connectedHostAlias: String? { hostAlias }
  private var currentPath = "/"
  private var detailEntry: MoshxploreEntry?
  private var previewURL: URL?      // a fetched temp copy, reused as the save source when present
  private var savedURL: URL?        // the last saved file, handed to the share sheet from "Open"
  private var detailTextFile: MoshxploreTextFile?   // decoded text + its on-disk form; nil = not editable
  private var detailDidSave = false // an edit landed remotely — re-list on back so the row is fresh
  private var savingDetail = false  // an upload is in flight — hold back/toggle until it resolves

  private static let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter(); f.countStyle = .file; return f
  }()
  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
  }()

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    // A full screen now, not a floating card — the hosting controller paints the surface and the
    // navigation bar carries the title and the Close button (same as Settings and the composer).
    backgroundColor = .clear

    // --- Host step ---
    let hostSubtitle = UILabel()
    hostSubtitle.text = "Choose a host to browse"
    hostSubtitle.font = MoshxploreStyle.font(13)
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
      attributes: [.paragraphStyle: emptyPara, .font: MoshxploreStyle.font(13), .foregroundColor: Self.gray])
    hostsEmpty.numberOfLines = 0
    hostsEmpty.isHidden = true

    hostStep.axis = .vertical
    hostStep.spacing = 12
    hostStep.isLayoutMarginsRelativeArrangement = true
    hostStep.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
    hostStep.addArrangedSubview(hostSubtitle)
    hostStep.addArrangedSubview(hostsScroll)
    hostStep.addArrangedSubview(hostsEmpty)
    hostsScroll.setContentHuggingPriority(.init(1), for: .vertical)   // the list takes the screen

    // --- Browser step ---
    Self.style(iconButton: upButton, systemName: "chevron.backward")
    upButton.addAction(UIAction { [weak self] _ in self?.goUp() }, for: .touchUpInside)
    Self.style(iconButton: hostsButton, systemName: "rectangle.stack")
    hostsButton.addAction(UIAction { [weak self] _ in self?.backToHosts() }, for: .touchUpInside)

    pathLabel.font = MoshxploreStyle.font(13, .medium)
    pathLabel.textColor = Self.dark
    pathLabel.lineBreakMode = .byTruncatingHead
    pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    pathCopyButton.textToCopy = { [weak self] in self?.currentPath }
    // The copy glyph must sit right BESIDE the path text: the label hugs its content (truncating
    // when genuinely long) and the flexible spacer absorbs the leftover width.
    pathLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    let pathBar = UIStackView(arrangedSubviews: [upButton, pathLabel, pathCopyButton, UIView(), hostsButton])
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
    browserStep.isLayoutMarginsRelativeArrangement = true
    browserStep.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
    browserStep.addArrangedSubview(pathBar)
    browserStep.addArrangedSubview(entriesScroll)
    entriesScroll.setContentHuggingPriority(.init(1), for: .vertical)   // the list takes the screen

    spinner.hidesWhenStopped = true
    spinner.color = Self.gray

    // --- Detail step ---
    detailView.isHidden = true
    detailView.onBack = { [weak self] in self?.closeDetail() }
    detailView.onDownload = { [weak self] in self?.saveDetailFile() }
    detailView.onEditToggle = { [weak self] in self?.toggleDetailEdit() }
    detailView.onEditCancel = { [weak self] in self?.cancelDetailEdit() }

    errorLabel.font = MoshxploreStyle.font(12, .medium)
    errorLabel.textColor = .moshroomTint
    errorLabel.textAlignment = .center
    errorLabel.numberOfLines = 0
    errorLabel.isHidden = true

    // One step visible at a time; the visible step fills the whole screen — lists run tall,
    // the detail's viewer takes every point between its meta line and its bottom buttons.
    let content = UIStackView(arrangedSubviews: [hostStep, browserStep, detailView, spinner, errorLabel])
    content.axis = .vertical
    content.spacing = 12
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)

    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      content.leadingAnchor.constraint(equalTo: leadingAnchor),
      content.trailingAnchor.constraint(equalTo: trailingAnchor),
      content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

      hostsStack.topAnchor.constraint(equalTo: hostsScroll.contentLayoutGuide.topAnchor),
      hostsStack.bottomAnchor.constraint(equalTo: hostsScroll.contentLayoutGuide.bottomAnchor),
      hostsStack.leadingAnchor.constraint(equalTo: hostsScroll.contentLayoutGuide.leadingAnchor),
      hostsStack.trailingAnchor.constraint(equalTo: hostsScroll.contentLayoutGuide.trailingAnchor),
      hostsStack.widthAnchor.constraint(equalTo: hostsScroll.frameLayoutGuide.widthAnchor),

      entriesStack.topAnchor.constraint(equalTo: entriesScroll.contentLayoutGuide.topAnchor),
      entriesStack.bottomAnchor.constraint(equalTo: entriesScroll.contentLayoutGuide.bottomAnchor),
      entriesStack.leadingAnchor.constraint(equalTo: entriesScroll.contentLayoutGuide.leadingAnchor),
      entriesStack.trailingAnchor.constraint(equalTo: entriesScroll.contentLayoutGuide.trailingAnchor),
      entriesStack.widthAnchor.constraint(equalTo: entriesScroll.frameLayoutGuide.widthAnchor),
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
    pathCopyButton.isHidden = path == "/"   // copying the root path helps nobody
    // The old folder's rows vanish the INSTANT navigation starts: path and content must never
    // disagree on screen (a new path over stale rows reads as the wrong folder). Tap → rows
    // gone → spinner → the new listing lands.
    entriesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
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
      empty.font = MoshxploreStyle.font(13)
      empty.textColor = Self.gray
      empty.textAlignment = .center
      entriesStack.addArrangedSubview(empty)
      return
    }
    for entry in entries { entriesStack.addArrangedSubview(_entryRow(entry)) }
    entriesScroll.setContentOffset(.zero, animated: false)
  }

  // MARK: Rows

  // One saved host = one shared house card (moshHostCardButton — the exact same card Quick
  // Connect shows), wired to open the browser on that host.
  private func _hostRow(_ alias: String) -> UIView {
    let description = MoshHosts.withHost(alias)?.hostDescription ?? ""
    let b = moshHostCardButton(alias: alias, description: description)
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
    detailView.configure(name: entry.name, meta: detailMeta(for: entry), path: childPath(entry.name))
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

  // Discard the edit and stay on the file: restore the fetched text, back into view mode.
  // Reached from the header Cancel button and from back-while-editing alike.
  private func cancelDetailEdit() {
    guard !savingDetail, detailView.isEditingText, let original = detailTextFile else { return }
    detailView.showText(original.text, filename: detailEntry?.name ?? "")   // resets edit UI, drops keyboard
    detailView.setEditAvailable(true)
    errorLabel.isHidden = true
  }

  private func closeDetail() {
    guard !savingDetail else { return }   // a save is landing — resolve it before navigating
    // In edit mode, back means cancel: restore the fetched text and stay on the file. Deliberate
    // and reversible — never a silent discard-and-navigate on one accidental tap.
    if detailView.isEditingText {
      cancelDetailEdit()
      return
    }
    let refresh = detailDidSave
    clearDetail()
    // After a save, re-list so the row shows the fresh size/date; otherwise the rendered entries
    // are still current.
    if refresh { enter(path: currentPath) } else { showStep(browser: true) }
    errorLabel.isHidden = true
  }

  // Drop the detail state and bin any temp preview copy.
  private func clearDetail() {
    detailEntry = nil
    savedURL = nil
    detailTextFile = nil
    detailDidSave = false
    savingDetail = false
    detailView.exitEditMode()   // resign the keyboard if a tab switch/close lands mid-edit
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

  // Decode the fetched file off-main, then hand the image/text to the detail view. A strict text
  // decode also unlocks Edit; bytes the editor couldn't faithfully round-trip fall back to a
  // lossy, read-only preview.
  private func renderPreview(entry: MoshxploreEntry, url: URL) {
    let kind = MoshxplorePreview.kind(for: entry)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      var image: UIImage?
      var text: String?
      var textFile: MoshxploreTextFile?
      var binary = false
      switch kind {
      case .image: image = UIImage(contentsOfFile: url.path)
      case .text:
        if let data = try? Data(contentsOf: url) {
          textFile = MoshxploreTextFile.decode(data)
          if let textFile { text = textFile.text }
          else if data.contains(0) { binary = true }       // unknown extension that turned out binary
          else { text = String(decoding: data, as: UTF8.self) }  // odd encoding → lossy, read-only
        }
      case .none:  break
      }
      DispatchQueue.main.async {
        guard let self, self.detailEntry?.name == entry.name else { return }
        if let image { self.detailView.showImage(image) }
        else if let text {
          self.detailTextFile = textFile
          self.detailView.showText(text, filename: entry.name)
          self.detailView.setEditAvailable(textFile != nil)
        }
        else if binary {
          self.detailView.showNoPreview(symbol: Self.symbol(for: entry), message: "Binary content.\nDownload to open it.")
        }
        else { self.detailView.showNoPreview(symbol: Self.symbol(for: entry), message: "Couldn't load a preview.") }
      }
    }
  }

  // MARK: Inline edit (the Edit ↔ Save button)

  private func toggleDetailEdit() {
    guard detailTextFile != nil, !savingDetail else { return }
    if detailView.isEditingText { saveDetailEdit() }
    else { errorLabel.isHidden = true; detailView.enterEditMode() }
  }

  // Save: encode the edited text back into the file's on-disk form, stage it over the preview copy
  // (which keeps Download serving what was just saved), and SFTP it onto the exact remote path.
  // Success lands back in view mode with fresh metadata; any failure stays in the editor, text
  // intact, with the error shown.
  private func saveDetailEdit() {
    guard let entry = detailEntry, let file = detailTextFile, let staged = previewURL else { return }
    let edited = detailView.editedText
    let remoteDir = currentPath
    savingDetail = true
    detailView.setSaving(true)
    errorLabel.isHidden = true

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let data = file.encode(edited)
      let wrote = (try? data.write(to: staged, options: .atomic)) != nil
      DispatchQueue.main.async {
        guard let self, self.detailEntry?.name == entry.name else { return }
        guard wrote else {
          self.savingDetail = false
          self.detailView.setSaving(false)
          self.showError("Couldn't stage the edited file.")
          return
        }
        self.session?.upload(localURL: staged, remoteDir: remoteDir) { [weak self] result in
          guard let self, self.detailEntry?.name == entry.name else { return }
          self.savingDetail = false
          self.detailView.setSaving(false)
          switch result {
          case .success:
            self.detailDidSave = true
            self.detailTextFile = MoshxploreTextFile(text: edited, encoding: file.encoding,
                                                     hadBOM: file.hadBOM, usesCRLF: file.usesCRLF)
            let updated = MoshxploreEntry(name: entry.name, isDirectory: false, isSymlink: entry.isSymlink,
                                          size: UInt64(data.count), modified: Date())
            self.detailEntry = updated
            self.detailView.configure(name: updated.name, meta: self.detailMeta(for: updated), path: self.childPath(updated.name))
            self.detailView.exitEditMode()
          case .failure(let error):
            self.showError(self.message(for: error))
          }
        }
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
    progressOverlay.backgroundColor = MoshxploreStyle.screen.withAlphaComponent(0.98)
    progressOverlay.isHidden = true
    addSubview(progressOverlay)

    progressTitle.font = MoshxploreStyle.font(14, .medium)
    progressTitle.textColor = Self.dark
    progressTitle.numberOfLines = 2
    progressTitle.textAlignment = .center
    progressTitle.lineBreakMode = .byTruncatingMiddle

    progressBar.progressTintColor = .moshroomTint
    // Same track as the Moshdrop upload bar — the mushroom-red progress look is one thing app-wide.
    progressBar.trackTintColor = UIColor.moshroomTint.withAlphaComponent(Moshstyle.faintTintAlpha)

    cancelButton.setTitle("Cancel", for: .normal)
    cancelButton.titleLabel?.font = MoshxploreStyle.font(15, .semibold)
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
    var openAttr = AttributeContainer(); openAttr.font = MoshxploreStyle.font(15, .semibold)
    openCfg.attributedTitle = AttributedString("Open", attributes: openAttr)
    openCfg.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
    openButton.configuration = openCfg
    #if targetEnvironment(macCatalyst)
    openButton.preferredBehavioralStyle = .pad   // keep the mushroom fill + insets on Mac
    #endif
    openButton.isHidden = true
    openButton.addAction(UIAction { [weak self] _ in
      guard let self, let url = self.savedURL else { return }
      self.presentShare?(url)
    }, for: .touchUpInside)

    doneButton.setTitle("Done", for: .normal)
    doneButton.titleLabel?.font = MoshxploreStyle.font(15, .semibold)
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
    return parts.joined(separator: "  ·  ")
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
    // A linked folder IS a folder (you open it), drawn hollow so the link shows at a glance; the
    // row's subtitle says "link" as well.
    if entry.isDirectory { return entry.isSymlink ? "folder" : "folder.fill" }
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
    b.setMoshIcon(systemName, pointSize: 15, weight: .semibold, color: dark)
    b.translatesAutoresizingMaskIntoConstraints = false
    b.setContentHuggingPriority(.required, for: .horizontal)
    b.widthAnchor.constraint(equalToConstant: 30).isActive = true
    b.heightAnchor.constraint(equalToConstant: 30).isActive = true
  }
}

// MARK: - The explorer tab + SpaceController glue

// Moshxplore is a TAB (kind .explorer): a page inside the tabs page VC, living alongside the
// terminals. Its SFTP session survives tab switches — that is the point of being a tab — and is
// torn down when the tab closes. No in-content header: tabs close from Moshtabs, and the top
// chrome (Tabs / launcher) floats above every page alike.
final class MoshxploreTabController: UIViewController, MoshroomTabPage {

  let moshroomTabKey: UUID
  var moshroomTabKind: MoshroomTabKind { .explorer }
  // The Tabs list re-reads this on every open, so the row names the host once one is picked.
  var moshroomTabTitle: String? { explorer.connectedHostAlias ?? "Files" }

  let explorer = MoshxploreView()
  weak var space: SpaceController?
  var preferredHost: String?

  private var hostsObservers: [NSObjectProtocol] = []

  init(key: UUID = UUID()) {
    moshroomTabKey = key
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func viewDidLoad() {
    super.viewDidLoad()
    // The page rests on the live root ground (last terminal theme / house near-black) so it never
    // cuts a different black into the strips around the viewport; the explorer's own rows and
    // cards paint their semantic surfaces on top.
    view.backgroundColor = space?.view.backgroundColor ?? .moshroomBackground

    explorer.savedHosts = { [weak self] in self?.space?.moshroomSavedHostAliases ?? [] }
    // Any live terminal's device, not the current tab's: while THIS tab is front, currentTerm()
    // is nil by design, and connecting from the host picker must still work.
    explorer.device = { [weak self] in self?.space?.moshroomAnyTermDevice }
    // Hand a saved file to the system share sheet (Save to Files, Quick Look, open-in apps…).
    explorer.presentShare = { [weak self] url in
      guard let self else { return }
      let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      share.popoverPresentationController?.sourceView = self.view
      self.present(share, animated: true)
    }
    view.addSubview(explorer)

    NSLayoutConstraint.activate([
      // The explorer owns the whole page; each step manages its own margins. The bottom rides the
      // keyboard guide, so the inline editor is exactly the space above the keyboard.
      explorer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      explorer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      explorer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      explorer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
    ])

    // Keep the host picker live when hosts change — local saves AND iCloud pulls — but only while
    // that step is showing; an active browse session is left untouched.
    hostsObservers = [HostsCloudMirror.didSaveNotification, HostsCloudMirror.didChangeNotification].map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.explorer.reloadHostsIfVisible()
      }
    }

    explorer.present(preferredHost: preferredHost)
  }

  deinit {
    hostsObservers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  // The tab is closing: tear the SFTP session down with it.
  func moshroomTabWillClose() {
    explorer.teardown()
  }
}

extension SpaceController {
  // Open a NEW explorer tab — several make sense (one per host), so unlike Moshify this never
  // focuses an existing one. Defaults to the current tab's connected host (if it's a saved one)
  // so a connected session browses itself with one tap; else the host picker.
  func openMoshxploreTab() {
    // Capture the host BEFORE any dismissal/switch; the launcher modal may be on top right now.
    let host = currentTerm()?.moshroomUploadHost
    if presentedViewController != nil { dismiss(animated: false) }
    let ctrl = MoshxploreTabController()
    ctrl.space = self
    ctrl.preferredHost = host
    moshroomOpenTabPage(ctrl)
  }
}
