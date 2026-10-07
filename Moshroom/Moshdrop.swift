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
// Moshdrop: hand a local file on the phone to the remote machine your agent lives on, and
// reference it *exactly* where you mean it in the prose.
//
// Pick from Photos / Files / Clipboard → the file appears **inline at the cursor** straight
// away (an image as a thumbnail, anything else as a filetype chip). Nothing is uploaded yet.
// You keep writing — "make this <image> look like this <pdf>". When you send, Moshdrop uploads
// every attachment to `~/.moshroom/uploads/` on a saved SSH host (reusing the saved SSH keys/config,
// the same path `scp` uses), showing "Uploading N of M", and only then writes the command —
// each inline chip swapped for its remote path. If an upload fails you land back in the editor
// with everything intact, told what failed.
//
// Anything iOS will hand off is accepted **except** video. The upload reuses the proven Combine
// SSH stack from CopyFiles.swift, driven on its own run-loop thread.
//
////////////////////////////////////////////////////////////////////////////////

import Combine
import CryptoKit
import Foundation
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers

import MoshroomConfig
import MoshroomFiles
import SSH

// MARK: - Inline attachment

/// A picked-but-not-yet-uploaded local file. It *is* an `NSTextAttachment`, so it drops straight
/// into the composer's attributed text at the cursor and renders inline — a rounded thumbnail for
/// images, a compact "[icon] name" chip for everything else. The upload is deferred to send time;
/// until then it just carries the local staging URL and the remote name it will land under.
final class MoshdropAttachment: NSTextAttachment {

  let localURL: URL
  let displayName: String
  let isImage: Bool
  let remoteName: String

  /// Where the file lands on the host once uploaded — the token that replaces this inline chip
  /// in the sent command.
  var remotePath: String { "~/\(Moshdrop.remoteDir)/\(remoteName)" }

  init(localURL: URL, displayName: String, isImage: Bool, remoteName: String) {
    self.localURL = localURL
    self.displayName = displayName
    self.isImage = isImage
    self.remoteName = remoteName
    super.init(data: nil, ofType: nil)
    _render()
  }

  required init?(coder: NSCoder) {
    // These are never archived in normal use; decode to safe defaults instead of crashing if some
    // path (state restoration, a future rich-paste) ever does.
    localURL = (coder.decodeObject(of: NSURL.self, forKey: "mdURL") as URL?) ?? URL(fileURLWithPath: "/dev/null")
    displayName = (coder.decodeObject(of: NSString.self, forKey: "mdName") as String?) ?? "file"
    isImage = coder.decodeBool(forKey: "mdImage")
    remoteName = (coder.decodeObject(of: NSString.self, forKey: "mdRemote") as String?) ?? "file"
    super.init(coder: coder)
    _render()
  }

  // Inline chips stay small (about a line tall) and are vertically centred on the surrounding text,
  // so the prose reads cleanly — "make this [img] match this [pdf]".
  private func _render() {
    let rendered: UIImage
    if isImage, let picked = Self._downsampled(localURL, maxPixel: 240) {
      rendered = Self._squareThumbnail(picked, side: 30)
    } else {
      rendered = Self._fileChip(name: displayName)
    }
    image = rendered
    // Centre the chip on the composer font's cap height so adjacent text lines up with it.
    let font = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
    bounds = CGRect(x: 0, y: (font.capHeight - rendered.size.height) / 2,
                    width: rendered.size.width, height: rendered.size.height)
  }

  // Decode at thumbnail resolution via ImageIO (never the full image) so a giant photo can't spike
  // memory just to draw a small inline preview.
  private static func _downsampled(_ url: URL, maxPixel: CGFloat) -> UIImage? {
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return UIImage(cgImage: cg)
  }

  // A small, rounded, centre-cropped square preview for image attachments.
  private static func _squareThumbnail(_ image: UIImage, side: CGFloat) -> UIImage {
    let size = CGSize(width: side, height: side)
    return UIGraphicsImageRenderer(size: size).image { _ in
      UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6).addClip()
      let scale = max(side / image.size.width, side / image.size.height)   // aspect-fill, centre-crop
      let w = image.size.width * scale, h = image.size.height * scale
      image.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
    }
  }

  // A compact "[icon] name" chip (mushroom-red tint) for non-image files — a line tall, no more.
  private static func _fileChip(name: String) -> UIImage {
    let font = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .medium)
    let label = _displayLabel(name) as NSString
    let textSize = label.size(withAttributes: [.font: font])
    let pad: CGFloat = 7, gap: CGFloat = 4, iconSide: CGFloat = 14, height: CGFloat = 28
    let width = pad + iconSide + gap + ceil(textSize.width) + pad
    let symbol = UIImage(systemName: _symbolName(for: name),
                         withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in
      let rect = CGRect(x: 0, y: 0, width: width, height: height)
      UIColor.moshroomTint.withAlphaComponent(Moshstyle.faintTintAlpha).setFill()
      UIBezierPath(roundedRect: rect, cornerRadius: 7).fill()
      symbol?.withTintColor(.moshroomTint, renderingMode: .alwaysOriginal)
        .draw(in: CGRect(x: pad, y: (height - iconSide) / 2, width: iconSide, height: iconSide))
      label.draw(at: CGPoint(x: pad + iconSide + gap, y: (height - textSize.height) / 2),
                 withAttributes: [.font: font, .foregroundColor: UIColor.label])
    }
  }

  // Keep a chip from getting wide for a long name: middle-truncate, keeping the extension.
  private static func _displayLabel(_ name: String) -> String {
    guard name.count > 24 else { return name }
    let ns = name as NSString
    let ext = ns.pathExtension
    let head = String(ns.deletingPathExtension.prefix(18))
    return ext.isEmpty ? "\(head)…" : "\(head)….\(ext)"
  }

  private static func _symbolName(for name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "pdf": return "doc.richtext"
    case "txt", "md", "markdown", "log", "rtf": return "doc.text"
    case "zip", "gz", "tar", "tgz", "7z", "rar": return "doc.zipper"
    case "json", "xml", "yml", "yaml", "csv", "plist": return "curlybraces"
    case "sh", "py", "js", "ts", "c", "h", "cpp", "swift", "rb", "go", "rs": return "chevron.left.forwardslash.chevron.right"
    default: return "doc.fill"
    }
  }
}

// MARK: - Entry point + shared host / naming helpers

enum Moshdrop {
  /// Remote directory (under the login home) where uploads land.
  static let remoteDir = ".moshroom/uploads"

  /// Images are downscaled to this on the long edge before upload — the most a vision model
  /// actually uses, so anything larger is just wasted bytes on the wire. Photos still look sharp.
  static let imageMaxPixel: CGFloat = 1568
  /// JPEG quality for recompressed images — small files that keep photos and screenshot text legible.
  static let jpegQuality: CGFloat = 0.8

  /// Present the source sheet (Photo / File / Clipboard) and hand back a ready-to-show inline
  /// attachment. Nothing is uploaded here — that waits until the composer is sent.
  static func pick(over presenter: UIViewController, onPicked: @escaping (MoshdropAttachment) -> Void) {
    let picker = MoshdropPicker(presenter: presenter, onPicked: onPicked)
    picker.start()
  }

  /// A clean, collision-free remote name: the file's md5 + its sanitized extension, e.g.
  /// `d41d8cd98f00b204e9800998ecf8427e.png`. No weird characters from the original filename ever
  /// reach `~/.moshroom/uploads/`, and identical content reuses the same name (natural de-dup).
  static func slugName(for url: URL) -> String {
    let hash = _md5Hex(ofFileAt: url) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let ext = _cleanExt(url.pathExtension)
    return ext.isEmpty ? hash : "\(hash).\(ext)"
  }

  // Streamed md5 (1 MB chunks) so a large file is never slurped whole into memory.
  private static func _md5Hex(ofFileAt url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = Insecure.MD5()
    while true {
      guard let chunk = (try? handle.read(upToCount: 1 << 20)) ?? nil, !chunk.isEmpty else { break }
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  // Lowercased, ASCII-alphanumeric, capped — keeps the slug a clean `<hash>.<ext>`.
  private static func _cleanExt(_ raw: String) -> String {
    let cleaned = raw.lowercased().filter { ($0.isLetter || $0.isNumber) && $0.isASCII }
    return String(cleaned.prefix(8))
  }

  /// Shrink a raster image for upload: downscale to `imageMaxPixel` on the long edge and re-encode as
  /// JPEG (`jpegQuality`), returning a temp-file URL — or `nil` meaning "upload the original untouched".
  /// A multi-MB iPhone photo becomes a couple hundred KB, and HEIC (which agents and vision models
  /// often can't read) becomes JPEG. We keep the JPEG only when it actually helps: HEIC/HEIF is always
  /// converted (compatibility); otherwise only if it came out smaller, so a tiny PNG or already-small
  /// image is never bloated, unless the original carries a GPS location, which the re-encode drops.
  /// Images with real transparency become PNG rather than JPEG (no alpha). GIFs are left alone
  /// (animation); PDFs and text/code never reach here.
  ///
  /// JPEG, not WebP: once the pixels are gone the dominant saving is already banked, and JPEG is read
  /// by everything on the remote side — including agent vision models, which reject HEIC. WebP would trim
  /// another ~25% for real compatibility risk; not worth it. (Flip the format here if that changes.)
  static func compressedImage(at url: URL) -> URL? {
    let ext = url.pathExtension.lowercased()
    guard ext != "gif" else { return nil }                                   // preserve animation
    guard UTType(filenameExtension: ext)?.conforms(to: .image) == true else { return nil }
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,                      // bake in EXIF orientation
      kCGImageSourceThumbnailMaxPixelSize: imageMaxPixel,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

    // JPEG has no alpha: a transparent PNG (a diagram, a logo, dark lines on nothing) would arrive
    // as a black image. Anything with real transparency is re-encoded as PNG instead.
    let transparent = _hasTransparency(cg)
    let type: UTType = transparent ? .png : .jpeg
    let out = stagingDir().appendingPathComponent("c-\(UUID().uuidString).\(transparent ? "png" : "jpg")")
    guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else { return nil }
    let props: [CFString: Any] = transparent ? [:] : [kCGImageDestinationLossyCompressionQuality: jpegQuality]
    CGImageDestinationAddImage(dest, cg, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: out); return nil }

    // The thumbnail carries no metadata, so the re-encode also drops a photo's location. That alone
    // is reason to keep it even when it did not come out smaller.
    let isHeic = (ext == "heic" || ext == "heif")
    let newSize = _fileSize(out)
    if !isHeic && !_hasLocation(src) && (newSize == 0 || newSize >= _fileSize(url)) {
      try? FileManager.default.removeItem(at: out)                           // didn't help → keep original
      return nil
    }
    return out
  }

  // Does any pixel actually show through? An alpha channel alone says nothing (plenty of opaque
  // images carry one), so look: draw it once, small enough to be cheap, and scan the alpha bytes.
  private static func _hasTransparency(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return false
    default: break
    }
    let side = 256
    let scale = min(1, CGFloat(side) / CGFloat(max(image.width, image.height)))
    let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
      guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { return true }   // could not tell: PNG is the safe answer
    var i = 3
    while i < pixels.count {
      if pixels[i] < 255 { return true }
      i += 4
    }
    return false
  }

  private static func _hasLocation(_ src: CGImageSource) -> Bool {
    guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
    return props[kCGImagePropertyGPSDictionary] != nil
  }

  private static func _fileSize(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
  }

  // What the remote agent can actually read: images, PDFs, and text/code/data. Everything else —
  // video, audio, archives, apps, office binaries, unknown blobs — is refused.
  static func isAgentReadable(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    // Our own lists first: the system type table maps some code extensions to media (`.ts` is an
    // MPEG-2 transport stream to it, so TypeScript was refused as "video").
    if _textExtensions.contains(ext) || _textLeafNames.contains(url.lastPathComponent.lowercased()) {
      return true
    }
    if let type = UTType(filenameExtension: ext) {
      if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) || type.conforms(to: .audio) { return false }
      if type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .text) { return true }
    }
    return false
  }

  private static let _textExtensions: Set<String> = [
    "txt","text","md","markdown","mdx","rst","log","conf","cfg","ini","env","toml","lock",
    "yaml","yml","json","jsonl","ndjson","csv","tsv","xml","html","htm","css","scss","sass",
    "sh","bash","zsh","fish","py","ipynb","js","jsx","mjs","cjs","ts","tsx","rb","go","rs",
    "c","h","cc","cpp","cxx","hpp","hh","swift","java","kt","kts","scala","php","pl","lua",
    "r","jl","dart","ex","exs","clj","vue","svelte","sql","gradle","properties","mk","cmake",
    "diff","patch","tex","proto","graphql","gql","tf","hcl","mts","cts",
  ]
  private static let _textLeafNames: Set<String> = [
    ".env",".gitignore",".gitattributes",".editorconfig",".npmrc",".dockerignore",
    "dockerfile","makefile",".bashrc",".zshrc",".profile",
  ]

  /// A stable staging dir — survives the OS reclaiming the temp dir between pick and send.
  static func stagingDir() -> URL {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("moshdrop", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Delete staging files left behind by an abandoned/relaunched draft (staged more than a day
  /// ago). Called when the composer opens: cheap housekeeping so Caches/moshdrop/ can't grow
  /// unbounded. `keeping` names files a live draft still points at; they are never deleted,
  /// however old.
  static func sweepStaging(keeping: Set<URL> = []) {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: stagingDir(), includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    let kept = Set(keeping.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
    let cutoff = Date().addingTimeInterval(-24 * 3600)
    for item in items where !kept.contains(item.standardizedFileURL.resolvingSymlinksInPath()) {
      let mod = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      if let mod, mod < cutoff { try? fm.removeItem(at: item) }
    }
  }

  enum AttachError: Error {
    case notReadable   // not something the agent can read (video/audio/archive/app/…)
    case failed(Error) // staging/copy failure
  }

  /// Turn a local file into a staged, ready-to-show inline attachment: the same image compression,
  /// md5-slug staging and agent-readable gate the picker runs — pure model work, no UI. Shared by the
  /// Photo/File/Clipboard picker and the composer's Cmd+V smart paste, so there is one code path.
  static func makeAttachment(localURL: URL, displayName: String) -> Result<MoshdropAttachment, AttachError> {
    guard isAgentReadable(localURL) else { return .failure(.notReadable) }

    // Images are downsized + re-encoded to JPEG before staging; non-images stage byte-for-byte.
    let source = compressedImage(at: localURL) ?? localURL

    // Stage under a clean md5 slug name so `~/.moshroom/uploads/` never collects weird filenames.
    let remoteName = slugName(for: source)
    let staged = stagingDir().appendingPathComponent(remoteName)
    do {
      try? FileManager.default.removeItem(at: staged)
      try FileManager.default.copyItem(at: source, to: staged)
      // copyItem keeps the source's date, and the staging sweep ages files by it: a photo taken
      // last week would be swept from under the draft that just attached it.
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: staged.path)
    } catch {
      if source != localURL { try? FileManager.default.removeItem(at: source) }
      return .failure(.failed(error))
    }
    if source != localURL { try? FileManager.default.removeItem(at: source) }   // drop the temp JPEG

    let isImage = (UTType(filenameExtension: staged.pathExtension)?.conforms(to: .image)) ?? false
    return .success(MoshdropAttachment(localURL: staged, displayName: displayName, isImage: isImage, remoteName: remoteName))
  }

  /// The largest file a paste copies in (it is copied on the main thread).
  static let pasteMaxBytes = 50 * 1024 * 1024

  /// If the clipboard holds an image or a real file, materialize it into a temp file *we own* and
  /// return it with a display name; nil when the clipboard is text-only or empty. The caller deletes
  /// the temp once it has built the attachment. A file (e.g. copied in Finder / Files) is preferred
  /// over raw image data — it keeps the true name and extension; a screenshot / "Copy Image" with no
  /// backing file is written out as a PNG. Synchronous; call on the main thread. Never throws: a file
  /// the sandbox can't read simply falls through to the image/text branch, so paste degrades cleanly.
  static func clipboardAttachable() -> (url: URL, displayName: String)? {
    let pb = UIPasteboard.general

    // 1) A real file URL on the pasteboard (public.file-url), stored as its URL string.
    if pb.contains(pasteboardTypes: [UTType.fileURL.identifier]),
       let data = pb.data(forPasteboardType: UTType.fileURL.identifier),
       let str = String(data: data, encoding: .utf8),
       let fileURL = URL(string: str), fileURL.isFileURL {
      let scoped = fileURL.startAccessingSecurityScopedResource()
      defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
      let name = fileURL.lastPathComponent
      // Decide BEFORE copying (this runs on the main thread): something the agent can't read, a
      // folder, or a huge file is never worth the copy. It falls through like an unreadable one.
      let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
      if isAgentReadable(fileURL), size?.isRegularFile == true,
         let bytes = size?.fileSize, bytes <= pasteMaxBytes {
        let temp = FileManager.default.temporaryDirectory
          .appendingPathComponent("paste-\(UUID().uuidString)-\(name)")
        if (try? FileManager.default.copyItem(at: fileURL, to: temp)) != nil {
          return (temp, name)
        }
      }
      // couldn't (or shouldn't) read it: fall through to image/text
    }

    // 2) A copied PDF can have data without a file URL or a text representation.
    // Keep it as a document instead of silently ignoring the enabled Paste control.
    if pb.contains(pasteboardTypes: [UTType.pdf.identifier]),
       let pdf = pb.data(forPasteboardType: UTType.pdf.identifier),
       !pdf.isEmpty, pdf.count <= pasteMaxBytes {
      let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("paste-\(UUID().uuidString).pdf")
      if (try? pdf.write(to: temp)) != nil {
        return (temp, "clipboard.pdf")
      }
    }

    // 3) Raw image data (screenshot, "Copy Image") — write a PNG we own.
    if pb.hasImages, let image = pb.image, let png = image.pngData() {
      let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("paste-\(UUID().uuidString).png")
      if (try? png.write(to: temp)) != nil {
        return (temp, "clipboard.png")
      }
    }

    return nil
  }
}

// MARK: - Picker (Photos / Files / Clipboard → inline attachment, no upload)
//
// Retains itself (in `live`) for the duration of the asynchronous pick, since UIKit pickers only
// hold a weak delegate.

final class MoshdropPicker: NSObject {

  private static var live = Set<MoshdropPicker>()

  private weak var presenter: UIViewController?
  private let onPicked: (MoshdropAttachment) -> Void

  // iPad presents the source sheet as a popover with no Cancel button, so tapping *outside* it
  // dismisses with no action firing. This latches whether a real source was chosen, so the
  // popover-dismiss delegate can `finish()` (releasing the picker retained in `live`) only on a
  // dismiss-without-choosing — never when the sheet closed to hand off to the Photos/Files picker.
  private var _choiceMade = false

  init(presenter: UIViewController, onPicked: @escaping (MoshdropAttachment) -> Void) {
    self.presenter = presenter
    self.onPicked = onPicked
    super.init()
  }

  func start() {
    Self.live.insert(self)
    _presentSourceSheet()
  }

  private func finish() { Self.live.remove(self) }

  // MARK: Source selection

  private func _presentSourceSheet() {
    let sheet = UIAlertController(title: "Attach a file", message: nil, preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: "Photo", style: .default) { [weak self] _ in self?._choiceMade = true; self?._pickPhoto() })
    sheet.addAction(UIAlertAction(title: "File", style: .default) { [weak self] _ in self?._choiceMade = true; self?._pickFile() })
    if UIPasteboard.general.hasImages {
      sheet.addAction(UIAlertAction(title: "Clipboard image", style: .default) { [weak self] _ in self?._choiceMade = true; self?._pickClipboard() })
    }
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.finish() })
    _presentPopoverSafe(sheet)
  }

  private func _pickPhoto() {
    var config = PHPickerConfiguration()
    config.filter = .images           // images only — never video
    config.selectionLimit = 1
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    presenter?.present(picker, animated: true)
  }

  private func _pickFile() {
    // public.item = anything iOS can hand off; we reject video after the fact.
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter?.present(picker, animated: true)
  }

  private func _pickClipboard() {
    guard let image = UIPasteboard.general.image, let data = image.pngData() else {
      presenter?.moshdropAlert(title: "Empty clipboard", message: "No image on the clipboard.")
      finish(); return
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard.png")
    do { try data.write(to: url) } catch { _fail(error); return }
    _emit(localURL: url, displayName: "clipboard.png")
  }

  // MARK: Produce the inline attachment

  // Every source here is a temp copy we made (the clipboard PNG, the Photos copy, the document
  // picker's asCopy file): staging copies it on, so it goes once the attempt is over, either way.
  private func _emit(localURL: URL, displayName: String) {
    defer { try? FileManager.default.removeItem(at: localURL) }
    switch Moshdrop.makeAttachment(localURL: localURL, displayName: displayName) {
    case .success(let attachment):
      onPicked(attachment)
      finish()
    case .failure(.notReadable):
      // Only the things the agent can actually read (images / PDFs / text & code). No video, audio,
      // archives, apps or other binaries.
      presenter?.moshdropAlert(title: "Can't attach that",
                               message: "Moshdrop takes images, PDFs and text/code files — what your agent can read. Not video, audio, archives or apps.")
      finish()
    case .failure(.failed(let error)):
      _fail(error)
    }
  }

  private func _fail(_ error: Error) {
    presenter?.moshdropAlert(title: "Couldn't attach", message: error.localizedDescription)
    finish()
  }

  // MARK: Helpers

  private func _presentPopoverSafe(_ alert: UIAlertController) {
    if let pop = alert.popoverPresentationController, let view = presenter?.view {
      pop.sourceView = view
      pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 60, width: 0, height: 0)
      pop.permittedArrowDirections = []
      pop.delegate = self   // iPad: catch an outside-tap dismissal so the picker doesn't leak in `live`
    }
    presenter?.present(alert, animated: true)
  }
}

// MARK: - UIDocumentPickerDelegate

extension MoshdropPicker: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { finish(); return }
    _emit(localURL: url, displayName: url.lastPathComponent)
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish() }
}

// MARK: - PHPickerViewControllerDelegate

extension MoshdropPicker: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let item = results.first?.itemProvider else { finish(); return }
    let preferred = item.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true })
      ?? UTType.image.identifier
    let suggested = (item.suggestedName ?? "photo").replacingOccurrences(of: "/", with: "-")
    item.loadFileRepresentation(forTypeIdentifier: preferred) { [weak self] url, error in
      guard let self else { return }
      if let error { DispatchQueue.main.async { self._fail(error) }; return }
      guard let url else { DispatchQueue.main.async { self.finish() }; return }
      // The provided URL is temporary and reclaimed on return — copy it out first.
      let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
      let local = FileManager.default.temporaryDirectory.appendingPathComponent("\(suggested).\(ext)")
      try? FileManager.default.removeItem(at: local)
      do { try FileManager.default.copyItem(at: url, to: local) }
      catch { DispatchQueue.main.async { self._fail(error) }; return }
      DispatchQueue.main.async { self._emit(localURL: local, displayName: local.lastPathComponent) }
    }
  }
}

// MARK: - UIPopoverPresentationControllerDelegate (iPad: release the picker on an outside-tap)

extension MoshdropPicker: UIPopoverPresentationControllerDelegate {
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    // Fires only for an interactive dismissal of the source-sheet popover (iPad outside-tap). If a
    // source was actually chosen, the Photos/Files picker flow owns teardown; otherwise release the
    // picker we retained in `live` so it doesn't leak.
    if !_choiceMade { finish() }
  }
}

// MARK: - The SFTP uploader (one warm connection per host, on its own run-loop thread)

/// Uploads one attachment. A thin handle over the host's shared MoshdropConnection, so the files of
/// one send (and a quick follow-up send) ride a single SSH connection. Main thread only.
final class MoshdropUploader {

  private var connection: MoshdropConnection?
  private var token: Int?

  /// Cancel the in-flight upload: the work stops on the connection's own thread and no completion
  /// is delivered (the caller already knows).
  func cancel() {
    if let connection, let token { connection.cancel(token) }
    token = nil
  }

  /// Uploads `localURL` into `~/<Moshdrop.remoteDir>/<remoteName>` on `hostAlias`, reusing
  /// the saved SSH config/keys. Completion is delivered on the main queue.
  ///
  /// Always headless (MoshroomSFTPWorker.connect): an upload runs behind the composer, where a
  /// prompt would sit unseen, so a host that needs an answer (an unknown host key, a password nobody
  /// saved) fails with the reason instead. `device` is accepted for source compatibility and unused.
  func upload(localURL: URL,
              hostAlias: String,
              device: TermDevice?,
              remoteName: String,
              progress: @escaping (Double) -> Void = { _ in },
              completion: @escaping (Result<Void, Error>) -> Void) {
    let connection = MoshdropConnection.forHost(hostAlias)
    self.connection = connection
    token = connection.upload(localURL: localURL, remoteName: remoteName,
                              progress: progress, completion: completion)
  }
}

/// One SFTP connection to one host, kept warm for a minute after its last upload. It dials once,
/// makes `~/.moshroom/uploads/` once and sweeps it once, instead of all three per file. A
/// connection that died while idle (the app slept, the network changed) is noticed and redialed,
/// and an upload it broke is retried once: an upload is a whole-file overwrite under a content
/// hash name, so running it again is harmless.
final class MoshdropConnection {

  private static var pool: [String: MoshdropConnection] = [:]   // main thread only
  private static let idleSeconds: TimeInterval = 60
  private static var nextToken = 0

  static func forHost(_ alias: String) -> MoshdropConnection {
    if let existing = pool[alias] { return existing }
    let made = MoshdropConnection(hostAlias: alias)
    pool[alias] = made
    return made
  }

  let hostAlias: String
  private let worker = MoshroomSFTPWorker(name: "moshdrop.upload")
  private var idleWork: DispatchWorkItem?   // main thread

  // Worker thread only.
  private var dir: Translator?
  private var dialing = false
  private var waiting: [(Result<Translator, Error>) -> Void] = []
  private var dialC: AnyCancellable?
  private var ops: [Int: AnyCancellable] = [:]
  private var cancelled = Set<Int>()

  private init(hostAlias: String) {
    self.hostAlias = hostAlias
  }

  private func start() {
    worker.start(keepingAlive: self)
  }

  private func onWorker(_ block: @escaping () -> Void) {
    worker.perform(block)
  }

  // MARK: Main-thread API

  func upload(localURL: URL, remoteName: String,
              progress: @escaping (Double) -> Void,
              completion: @escaping (Result<Void, Error>) -> Void) -> Int {
    idleWork?.cancel()
    idleWork = nil
    start()
    Self.nextToken += 1
    let token = Self.nextToken
    let done: (Result<Void, Error>) -> Void = { [weak self] result in
      DispatchQueue.main.async {
        completion(result)
        self?.scheduleIdleTeardown()
      }
    }
    onWorker { [weak self] in
      guard let self else { return }
      self._upload(token: token, localURL: localURL, remoteName: remoteName, retry: true,
                   progress: progress, done: done)
    }
    return token
  }

  func cancel(_ token: Int) {
    onWorker { [weak self] in
      guard let self else { return }
      // A running copy is cancelled outright (its staged temp is cleaned on cancel); one still
      // waiting for the dial is marked, and skipped when the dial lands.
      if self.ops.removeValue(forKey: token) == nil { self.cancelled.insert(token) }
    }
    scheduleIdleTeardown()
  }

  private func scheduleIdleTeardown() {
    idleWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.teardown() }
    idleWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleSeconds, execute: work)
  }

  private func teardown() {
    if Self.pool[hostAlias] === self { Self.pool[hostAlias] = nil }
    worker.stop { [weak self] in
      guard let self else { return }
      self.dialC = nil
      self.ops = [:]
      self.dir = nil
      self.waiting = []
    }
  }

  // MARK: Worker

  private func _upload(token: Int, localURL: URL, remoteName: String, retry: Bool,
                       progress: @escaping (Double) -> Void,
                       done: @escaping (Result<Void, Error>) -> Void) {
    withDir { [weak self] result in
      guard let self else { return }
      if self.cancelled.remove(token) != nil { return }
      let dir: Translator
      switch result {
      case .failure(let e): done(.failure(e)); return
      case .success(let d): dir = d
      }

      // Stage the local file under its final remote name (SFTP copies it across verbatim), in a
      // folder of its own so two uploads can never share a staging path.
      let stagingDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("moshdrop-up-\(UUID().uuidString)", isDirectory: true)
      let staged = stagingDir.appendingPathComponent(remoteName)
      do {
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: localURL, to: staged)
      } catch {
        try? FileManager.default.removeItem(at: stagingDir)
        done(.failure(error))
        return
      }
      let cleanUp = { try? FileManager.default.removeItem(at: stagingDir) }

      // Real upload progress: SFTP reports incremental bytes per chunk (`written`) against the
      // file's total `size`; accumulate and surface a true 0…1 fraction (never a faked one).
      var sent: UInt64 = 0
      self.ops[token] = MoshroomFiles.Local().walkTo(staged.path)
        .flatMap { file in
          dir.copy(from: [file], args: CopyArguments(preserve: CopyAttributesFlag([]), checkTimes: false))
        }
        .handleEvents(receiveCompletion: { _ in cleanUp() }, receiveCancel: { cleanUp() })
        .sink(receiveCompletion: { [weak self] c in
          guard let self else { return }
          self.ops[token] = nil
          switch c {
          case .finished:
            done(.success(()))
          case .failure(let e):
            if retry, !dir.isConnected {
              // The connection died under us (most likely while idle): dial again, once.
              self.dir = nil
              self._upload(token: token, localURL: localURL, remoteName: remoteName, retry: false,
                           progress: progress, done: done)
            } else {
              done(.failure(e))
            }
          }
        }, receiveValue: { info in
          guard info.size > 0 else { return }
          sent += info.written
          let frac = min(1.0, Double(sent) / Double(info.size))
          DispatchQueue.main.async { progress(frac) }
        })
    }
  }

  // The live uploads dir, dialing (and preparing it) first when there is none or it has died.
  private func withDir(_ body: @escaping (Result<Translator, Error>) -> Void) {
    if let dir, dir.isConnected {
      body(.success(dir))
      return
    }
    dir = nil
    waiting.append(body)
    guard !dialing else { return }
    let sftp: AnyPublisher<Translator, Error>
    do {
      sftp = try MoshroomSFTPWorker.connect(alias: hostAlias)
    } catch {
      finishDial(.failure(error))
      return
    }
    dialing = true
    dialC = sftp
      .flatMap { root in Self.ensureRemoteDir(root, path: "/~/\(Moshdrop.remoteDir)") }
      .flatMap { dir -> AnyPublisher<Translator, Error> in
        // Once per connection: sweep stale uploads (best-effort), then hand the dir on.
        Self.sweepRemote(dir).setFailureType(to: Error.self).map { _ in dir }.eraseToAnyPublisher()
      }
      .sink(receiveCompletion: { [weak self] c in
        if case .failure(let e) = c { self?.finishDial(.failure(e)) }
      }, receiveValue: { [weak self] dir in
        self?.dir = dir
        self?.finishDial(.success(dir))
      })
  }

  private func finishDial(_ result: Result<Translator, Error>) {
    dialing = false
    let pending = waiting
    waiting = []
    pending.forEach { $0(result) }
  }

  // Best-effort housekeeping: delete files in the remote uploads dir older than 48h so it can't
  // grow without bound. FAIL-SAFE by design — only entries we can positively identify as regular
  // files AND positively date as older than the cutoff are removed; anything missing/uncertain is
  // left untouched, deletions run one-at-a-time (SFTP is serial), and any error just skips the
  // cleanup. It never blocks or fails the upload, and only ever touches `~/.moshroom/uploads/`.
  private static func sweepRemote(_ dir: Translator) -> AnyPublisher<Void, Never> {
    let cutoff = Date().addingTimeInterval(-48 * 3600)
    // Capture the dir path once and only ever walk a CLONE — SFTPTranslator.walkTo mutates the
    // receiver in place, and `dir` is the very translator the upload's copy depends on.
    let base = dir.current
    return dir.directoryFilesAndAttributes()
      .flatMap { entries -> AnyPublisher<Void, Error> in
        let stale: [String] = entries.compactMap { attrs in
          // Leaf names only — never "." / ".." / anything with a slash, so a weird listing can't
          // walk the delete outside the uploads dir.
          guard let name = attrs[.name] as? String, name != ".", name != "..", !name.contains("/") else { return nil }
          guard (attrs[.type] as? FileAttributeType) == .typeRegular else { return nil }
          guard let modified = attrs[.modificationDate] as? Date, modified < cutoff else { return nil }
          return name
        }
        guard !stale.isEmpty else { return Just(()).setFailureType(to: Error.self).eraseToAnyPublisher() }
        return stale.publisher
          .setFailureType(to: Error.self)
          .flatMap(maxPublishers: .max(1)) { name -> AnyPublisher<Void, Error> in
            dir.cloneWalkTo((base as NSString).appendingPathComponent(name))
              .flatMap { $0.remove() }
              .map { _ in () }
              .replaceError(with: ())              // one stubborn file shouldn't abort the sweep
              .setFailureType(to: Error.self)
              .eraseToAnyPublisher()
          }
          .collect()
          .map { _ in () }
          .eraseToAnyPublisher()
      }
      .replaceError(with: ())                       // listing failed → just skip the cleanup
      .eraseToAnyPublisher()
  }

  /// `mkdir -p` for each path segment, walking into any that already exist.
  private static func ensureRemoteDir(_ root: Translator, path: String) -> AnyPublisher<Translator, Error> {
    let segments = path.split(separator: "/").map(String.init)   // ["~", ".moshroom", "uploads"]
    guard let first = segments.first else {
      return Fail(error: MoshdropError.badPath).eraseToAnyPublisher()
    }
    var pub = root.walkTo("/" + first)
    for segment in segments.dropFirst() {
      pub = pub.flatMap { parent in
        parent.mkdir(name: segment, mode: S_IRWXU)
          .tryCatch { _ in parent.walkTo((parent.current as NSString).appendingPathComponent(segment)) }
      }.eraseToAnyPublisher()
    }
    return pub
  }
}

enum MoshdropError: LocalizedError {
  case badPath
  var errorDescription: String? {
    switch self {
    case .badPath: return "Could not resolve the remote upload directory."
    }
  }
}

// MARK: - Alert helper

extension UIViewController {
  fileprivate func moshdropAlert(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}
