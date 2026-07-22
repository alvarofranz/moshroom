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

// Moshroom-wide feature flag. Set to false to fall back to stock terminal input
// (on-terminal keyboard + SmartKeys bar).
enum Moshroom {
  // The terminal is input-less: a tap opens the Moshkitor composer instead of the keyboard.
  static let scratchOnly = true
}

// MARK: - The Moshkitor composer window

final class MoshkitorComposer: UIViewController, UITextViewDelegate {

  private weak var device: TermDevice?
  private let textView = UITextView()
  private let controls = UIView()

  // The unsent draft survives closing the composer; it's cleared once the text is sent. It's
  // attributed so inline Moshdrop attachments ride along with the typed text.
  private static var draft = NSAttributedString()
  private var didSend = false

  // Deferred Moshdrop uploads run on send; these hold the uploader + progress overlay alive.
  private var uploader: MoshdropUploader?
  private var progressOverlay: UIView?
  private var progressLabel: UILabel?
  private var progressBar: UIProgressView?
  private var isSending = false   // a send/upload is in flight (blocks re-entrancy + editing)
  private var isClosing = false   // the composer is going away (cancels a late upload completion)

  // Optional text to seed the composer with (used by the hardware-keyboard hand-off).
  private let seed: String
  // Set when Cmd+V opened the composer on a closed editor: drop the clipboard in once, on first
  // appearance (see viewDidAppear). One-shot so returning from a sub-picker never re-pastes.
  private var _pastesOnAppear: Bool

  // Suggestions strip (command completions), shown above the control bar only when non-empty.
  private let suggestionsScroll = UIScrollView()
  private let suggestionsStack = UIStackView()
  private var suggestionsHeight: NSLayoutConstraint!

  // The Share-tray button in the control bar. Present only when the tray holds items (images shared
  // to Moshroom via the system share sheet); tapping it opens the tray grid — see openTray / Moshtray.
  private var trayButton: UIButton?

  // The host attachments upload to (the current Quick Connect connection), or nil if not connected.
  private let connectedHost: String?
  // Fired with the final command as it's written to the terminal, so SpaceController can notice an
  // `ssh`/`mosh` connect and record its host as the next upload target.
  var onSend: ((String) -> Void)?

  init(device: TermDevice, seed: String = "", connectedHost: String? = nil, pasteOnAppear: Bool = false) {
    self.device = device
    self.seed = seed
    self.connectedHost = connectedHost
    self._pastesOnAppear = pasteOnAppear
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // The composer's baseline text style — kept on `typingAttributes` so typing never inherits an
  // attachment's styling and inserted runs match the rest of the prose.
  private var _defaultTypingAttributes: [NSAttributedString.Key: Any] {
    [.font: UIFont.monospacedSystemFont(ofSize: 17, weight: .regular), .foregroundColor: UIColor.label]
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    Moshdrop.sweepStaging()   // drop staging files orphaned by a previous abandoned/relaunched draft

    textView.delegate = self
    textView.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
    textView.textColor = .label
    textView.allowsEditingTextAttributes = false
    textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
    // A terminal composer must NEVER touch what you type: no autocorrect, no spell underlines,
    // no smart quotes/dashes (curly quotes corrupt commands), no auto-capitalization ("clear"
    // must never become "Clear"). What you write is exactly what the agent gets.
    textView.autocapitalizationType = .none
    textView.autocorrectionType = .no
    textView.spellCheckingType = .no
    textView.smartQuotesType = .no
    textView.smartDashesType = .no
    textView.smartInsertDeleteType = .no
    textView.keyboardDismissMode = .interactive
    textView.alwaysBounceVertical = true
    textView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(textView)

    suggestionsScroll.translatesAutoresizingMaskIntoConstraints = false
    suggestionsScroll.showsHorizontalScrollIndicator = false
    suggestionsScroll.clipsToBounds = true
    suggestionsScroll.backgroundColor = .secondarySystemBackground
    view.addSubview(suggestionsScroll)

    suggestionsStack.axis = .horizontal
    suggestionsStack.spacing = 8
    suggestionsStack.alignment = .center
    suggestionsStack.translatesAutoresizingMaskIntoConstraints = false
    suggestionsScroll.addSubview(suggestionsStack)

    controls.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controls)

    suggestionsHeight = suggestionsScroll.heightAnchor.constraint(equalToConstant: 0)

    // The control bar rides just above the software keyboard on iOS. On the Mac there is no
    // software keyboard, so the keyboard layout guide is an unreliable anchor (it can resolve to
    // the wrong edge under .overFullScreen and hide the bar) — pin it to the safe-area bottom so
    // Back / Snips / Attach / Send are ALWAYS on screen.
    #if targetEnvironment(macCatalyst)
    let controlsBottom = controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
    #else
    let controlsBottom = controls.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8)
    #endif

    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.bottomAnchor.constraint(equalTo: suggestionsScroll.topAnchor),

      suggestionsScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      suggestionsScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      suggestionsScroll.bottomAnchor.constraint(equalTo: controls.topAnchor),
      suggestionsHeight,

      suggestionsStack.leadingAnchor.constraint(equalTo: suggestionsScroll.contentLayoutGuide.leadingAnchor, constant: 10),
      suggestionsStack.trailingAnchor.constraint(equalTo: suggestionsScroll.contentLayoutGuide.trailingAnchor, constant: -10),
      suggestionsStack.topAnchor.constraint(equalTo: suggestionsScroll.contentLayoutGuide.topAnchor),
      suggestionsStack.bottomAnchor.constraint(equalTo: suggestionsScroll.contentLayoutGuide.bottomAnchor),
      suggestionsStack.heightAnchor.constraint(equalTo: suggestionsScroll.frameLayoutGuide.heightAnchor),

      // A little breathing room above the keyboard.
      controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controlsBottom,
      controls.heightAnchor.constraint(equalToConstant: 50),
    ])

    _buildControls()

    let initial = NSMutableAttributedString(attributedString: Self.draft)
    if !seed.isEmpty {
      initial.append(NSAttributedString(string: seed, attributes: _defaultTypingAttributes))
    }
    textView.attributedText = initial
    textView.typingAttributes = _defaultTypingAttributes
    textView.selectedRange = NSRange(location: initial.length, length: 0)
    _updateSuggestions()

    // A share can land (via the share extension) while this composer is open but backgrounded — the
    // tray button must appear on return, when viewDidAppear won't fire for an already-presented VC.
    NotificationCenter.default.addObserver(self, selector: #selector(_refreshTrayButton),
                                           name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(true, animated: false)
    // Grab focus as early as possible (before viewDidAppear, which for an animated present only
    // fires after the slide). For the hardware-keyboard hand-off — presented un-animated — this
    // makes the text view first responder synchronously, so the next keystroke lands in the editor
    // instead of falling through to an empty responder chain (the Mac Catalyst beep).
    textView.becomeFirstResponder()
  }

  // Called by SpaceController when a hardware keystroke arrives while this composer is presented but
  // its text view isn't first responder yet (the present hand-off). Takes focus and routes the key
  // in, so Mac Catalyst never beeps on — or drops — the key that lands mid-transition. Returns
  // false (let the normal path run) once the text view is already first responder.
  @discardableResult
  func acceptHardwareKeyInTransition(_ presses: Set<UIPress>) -> Bool {
    // Only act while WE are the frontmost VC and don't yet hold focus. If a snips/Moshdrop picker
    // is presented over us (presentedViewController != nil) it owns the keyboard — never steal it.
    if presentedViewController != nil { return false }
    if textView.isFirstResponder { return false }
    guard let key = presses.first(where: { $0.key != nil })?.key,
          !key.modifierFlags.contains(.command) else { return false }
    textView.becomeFirstResponder()
    let text = key.characters
    if !text.isEmpty, !(text.first?.isNewline ?? true) {
      textView.insertText(text)
    }
    return true
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // A cancelled interactive dismiss (drag the sheet down, then release) routes back through here
    // after viewWillDisappear already set isClosing — clear it so sends/uploads aren't stuck blocked.
    isClosing = false
    _refreshTrayButton()   // a share may have landed (or the tray emptied) while we were away
    textView.becomeFirstResponder()
    // Cmd+V opened us on a closed editor — drop the clipboard in now that we're on screen and first
    // responder. One-shot: a return from a sub-picker must not paste again.
    if _pastesOnAppear {
      _pastesOnAppear = false
      smartPaste()
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    isClosing = true
    // Keep the unsent draft so it's still there next time; clear it once sent.
    Self.draft = didSend ? NSAttributedString() : (textView.attributedText ?? NSAttributedString())
    // Hand the first responder back to SpaceController so chain-dispatched commands
    // (config, etc.) keep working after the composer closes.
    navigationController?.presentingViewController?.becomeFirstResponder()
  }

  override var keyCommands: [UIKeyCommand]? {
    let sendCtrl = UIKeyCommand(input: "\r", modifierFlags: .control, action: #selector(sendAndClose))
    sendCtrl.wantsPriorityOverSystemBehavior = true
    let sendCmd = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(sendAndClose))
    sendCmd.wantsPriorityOverSystemBehavior = true
    let esc = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))
    return [sendCtrl, sendCmd, esc]
  }

  // A tight control bar sitting just above the keyboard (back on the left, the rest right),
  // styled with the same round Moshkeys buttons so the whole app matches.
  private func _buildControls() {
    let back = _barButton(systemImage: "chevron.left", action: #selector(close))

    var rightItems: [UIView] = [_barButton(systemImage: "chevron.left.forwardslash.chevron.right", action: #selector(openSnips))]
    let pb = UIPasteboard.general
    if pb.hasStrings || pb.hasImages || pb.hasURLs {
      rightItems.append(_barButton(systemImage: "doc.on.clipboard", action: #selector(smartPaste)))
    }
    let tray = _barButton(systemImage: "photo.on.rectangle.angled", action: #selector(openTray))
    tray.isHidden = MoshroomShareTray.isEmpty()   // shown only when something's been shared to Moshroom
    trayButton = tray
    rightItems.append(tray)
    rightItems.append(_barButton(systemImage: "paperclip", action: #selector(openMoshdrop)))
    rightItems.append(_barButton(systemImage: "paperplane.fill", action: #selector(sendAndClose)))

    let rightStack = UIStackView(arrangedSubviews: rightItems)
    rightStack.axis = .horizontal
    rightStack.spacing = 20
    rightStack.alignment = .center

    let spacer = UIView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let bar = UIStackView(arrangedSubviews: [back, spacer, rightStack])
    bar.axis = .horizontal
    bar.alignment = .center
    bar.translatesAutoresizingMaskIntoConstraints = false
    controls.addSubview(bar)
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 10),
      bar.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -10),
      bar.topAnchor.constraint(equalTo: controls.topAnchor),
      bar.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
    ])
  }

  private func _barButton(systemImage: String, action: Selector) -> UIButton {
    let b = moshkeyRoundButton()
    b.setMoshIcon(systemImage)
    b.setContentHuggingPriority(.required, for: .horizontal)
    b.addTarget(self, action: action, for: .touchUpInside)
    return b
  }

  // MARK: Actions

  @objc private func close() {
    dismiss(animated: false)   // instant, no slide (see SpaceController.dismiss)
  }

  // Paste, smart about the clipboard. An image or a real (agent-readable) file becomes an inline
  // Moshdrop attachment — dropped at the cursor exactly like the paperclip, uploaded on send;
  // anything else pastes as text. This is BOTH the control-bar paste button and where SpaceController
  // routes Cmd+V while the composer is up (the Edit-menu key command would otherwise paste into the
  // hidden terminal behind us — see SpaceController._onCommand). All local: nothing uploads until send.
  @objc func smartPaste() {
    guard !isSending, isViewLoaded, presentedViewController == nil else {
      MoshLog.log("paste", "smartPaste skipped (sending=\(isSending) loaded=\(isViewLoaded) subPresented=\(presentedViewController != nil))")
      return
    }
    if !textView.isFirstResponder { textView.becomeFirstResponder() }

    let pb = UIPasteboard.general
    MoshLog.log("paste", "smartPaste: hasImages=\(pb.hasImages) hasStrings=\(pb.hasStrings) hasURLs=\(pb.hasURLs)")

    // An image / file on the clipboard → inline attachment. Materialized into a temp file we own.
    if let (url, name) = Moshdrop.clipboardAttachable() {
      defer { try? FileManager.default.removeItem(at: url) }
      switch Moshdrop.makeAttachment(localURL: url, displayName: name) {
      case .success(let attachment):
        let attrs = try? FileManager.default.attributesOfItem(atPath: attachment.localURL.path)
        let bytes = (attrs?[.size] as? Int) ?? -1
        MoshLog.log("paste", "attached inline: name=\(attachment.displayName) image=\(attachment.isImage) staged=\(bytes)B")
        _insertAttachment(attachment)
        return
      case .failure(.notReadable):
        MoshLog.log("paste", "attachable rejected (not agent-readable): \(name)")
        _composerAlert(title: "Can't attach that",
                       message: "Moshdrop takes images, PDFs and text/code files — what your agent can read. Not video, audio, archives or apps.")
        return
      case .failure(.failed):
        MoshLog.log("paste", "attach staging failed for \(name) → falling back to text")
        break   // staging hiccup — fall through and at least paste any text that's there
      }
    }

    // Plain text → insert at the cursor. (Length only — never the pasted content.)
    if let s = UIPasteboard.general.string, !s.isEmpty {
      MoshLog.log("paste", "inserted text (\(s.count) chars)")
      textView.insertText(s)
    } else {
      MoshLog.log("paste", "nothing pasteable")
    }
  }

  @objc private func openSnips() {
    let picker = MoshkitorSnipsPicker(onPick: { [weak self] content in
      guard let self else { return }
      if !self.textView.isFirstResponder { self.textView.becomeFirstResponder() }
      self.textView.insertText(content)
    })
    present(UINavigationController(rootViewController: picker), animated: true)
  }

  // Moshdrop: attach a local file → shown inline right here; the upload waits until you send.
  @objc private func openMoshdrop() {
    Moshdrop.pick(over: self) { [weak self] attachment in
      self?._insertAttachment(attachment)
    }
  }

  // The Share tray: images shared to Moshroom (system share sheet → the Moshroom share extension)
  // wait in a small App-Group tray. This opens the grid to drop one inline; inserting removes it from
  // the tray (a shared screenshot is a one-shot). Works on any tab, connected or not.
  @objc private func openTray() {
    MoshLog.log("tray", "open: \(MoshroomShareTray.count()) item(s)")
    let tray = MoshtrayController(
      onPick: { [weak self] url in self?._insertFromTray(url) },
      onFinished: { [weak self] in self?._refreshTrayButton() })
    // Full-screen + instant, matching every other Moshroom surface (Moshxplore/Moshtabs/launcher):
    // .overFullScreen keeps the terminal in the window, and a stable full width sidesteps the sheet's
    // animate-to-final-width cell-sizing race.
    tray.modalPresentationStyle = .overFullScreen
    present(tray, animated: false)
  }

  private func _insertFromTray(_ url: URL) {
    if !textView.isFirstResponder { textView.becomeFirstResponder() }
    switch Moshdrop.makeAttachment(localURL: url, displayName: url.lastPathComponent) {
    case .success(let attachment):
      MoshroomShareTray.remove(url)   // one-shot: a shared image isn't reused
      MoshLog.log("tray", "inserted 1 inline, \(MoshroomShareTray.count()) left")
      _insertAttachment(attachment)
    case .failure:
      MoshLog.log("tray", "insert failed (not agent-readable / staging)")
      _composerAlert(title: "Couldn't insert",
                     message: "That shared image couldn't be added. It may have been removed.")
    }
  }

  @objc private func _refreshTrayButton() {
    trayButton?.isHidden = MoshroomShareTray.isEmpty()
  }

  // Drop the inline chip at the cursor, fenced by spaces so its remote path stays a lone token.
  private func _insertAttachment(_ attachment: MoshdropAttachment) {
    if !textView.isFirstResponder { textView.becomeFirstResponder() }
    let insertAt = textView.selectedRange
    let piece = NSMutableAttributedString()
    if insertAt.location > 0, !_isBreak(before: insertAt.location) {
      piece.append(NSAttributedString(string: " ", attributes: _defaultTypingAttributes))
    }
    piece.append(NSAttributedString(attachment: attachment))
    piece.append(NSAttributedString(string: " ", attributes: _defaultTypingAttributes))
    textView.textStorage.beginEditing()
    textView.textStorage.replaceCharacters(in: insertAt, with: piece)
    textView.textStorage.endEditing()
    textView.selectedRange = NSRange(location: insertAt.location + piece.length, length: 0)
    textView.typingAttributes = _defaultTypingAttributes
    textView.scrollRangeToVisible(textView.selectedRange)
    _updateSuggestions()
  }

  // Is the character before `loc` a space / tab / newline (so no extra spacer is needed)?
  private func _isBreak(before loc: Int) -> Bool {
    guard loc > 0 else { return true }
    let ch = (textView.text as NSString).substring(with: NSRange(location: loc - 1, length: 1))
    return ch == " " || ch == "\n" || ch == "\t"
  }

  // Send: if there are no attachments, write the text straight away. Otherwise upload every
  // attachment first (with a "Uploading N of M" overlay), then write the command — each inline
  // chip swapped for its remote path. Any failure drops you back in the editor, nothing lost.
  @objc private func sendAndClose() {
    guard !isSending else { return }
    guard device != nil else {
      _composerAlert(title: "No active session", message: "Reopen a terminal session, then send.")
      return
    }
    let attachments = _attachments()
    if attachments.isEmpty {
      isSending = true
      _writeAndDismiss(_composeCommand())
      return
    }
    guard let host = connectedHost else {
      _composerAlert(title: "Not connected",
                     message: "You must be in an active connection with a server so the attachment can be uploaded.")
      return
    }
    isSending = true
    _uploadThenSend(attachments, host: host)
  }

  // Write the composed command to the session, then close.
  private func _writeAndDismiss(_ text: String) {
    didSend = true
    onSend?(text)
    let device = self.device
    // Deliver the whole composed message through the terminal's paste path, which frames it as a
    // bracketed paste (ESC[200~ … ESC[201~) whenever the remote program has bracketed-paste mode on.
    // This is exactly what a real paste does — and what agent TUIs expect: opencode
    // drop the framed text straight into their prompt as literal input. A raw keystroke burst instead
    // gets misread (opencode ran even a SINGLE line as a shell command — "line 5: … command not
    // found", the well-known unframed-paste failure), so we must frame every send, not just
    // multi-line ones. hterm only adds the markers when the program actually turned bracketed paste
    // on, so the local `moshroom>` prompt and plain shells still receive it raw (unchanged).
    device?.sendBracketedPaste(text)
    // Trail the Enter so it lands after the paste (outside the bracketed-paste end marker) and the
    // agent doesn't read it as part of the same burst.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { device?.write("\r") }
    dismiss(animated: false)   // instant, no slide (see SpaceController.dismiss)
  }

  // The command as the agent will read it: typed text verbatim, each inline attachment swapped
  // for its remote path (valid only once uploaded — see _uploadThenSend).
  private func _composeCommand() -> String {
    let attr = textView.attributedText ?? NSAttributedString()
    let ns = attr.string as NSString
    var out = ""
    attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length), options: []) { value, range, _ in
      let sub = ns.substring(with: range)
      if let a = value as? MoshdropAttachment {
        // The run is the chip glyph (U+FFFC) plus any text that may have inherited its attribute:
        // map each glyph to the remote path, keep everything else as the literal text it is.
        for ch in sub { out += (ch == "\u{FFFC}") ? a.remotePath : String(ch) }
      } else if value == nil {
        out += sub
      }
      // else: a foreign attachment (e.g. a system-pasted image) — drop its U+FFFC placeholder.
    }
    // Bullets are an editor nicety — the agent receives a plain "- " list.
    var cmd = out
    if cmd.hasPrefix("• ") { cmd = "- " + String(cmd.dropFirst(2)) }
    return cmd.replacingOccurrences(of: "\n• ", with: "\n- ")
  }

  // Inline attachments in document (left-to-right, top-to-bottom) order.
  private func _attachments() -> [MoshdropAttachment] {
    guard let attr = textView.attributedText else { return [] }
    var found: [MoshdropAttachment] = []
    attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length), options: []) { value, _, _ in
      if let a = value as? MoshdropAttachment { found.append(a) }
    }
    return found
  }

  // Upload each attachment in turn (one at a time, so the count reads cleanly), updating the
  // overlay, then send. On the first failure: tear the overlay down and stay in the editor.
  private func _uploadThenSend(_ attachments: [MoshdropAttachment], host: String) {
    guard device != nil else { return }
    _showProgress("Uploading 1 of \(attachments.count)…")
    _uploadStep(attachments, index: 0, host: host)
  }

  private func _uploadStep(_ attachments: [MoshdropAttachment], index: Int, host: String) {
    // Bail if the composer is gone / closing / cancelled mid-upload, so a command never fires after
    // the fact and a late completion can't silently resume an already-cancelled send.
    guard isSending, !isClosing, view.window != nil, let device = device else { _endSending(); return }
    if index >= attachments.count {
      attachments.forEach { try? FileManager.default.removeItem(at: $0.localURL) }
      _hideProgress()
      _writeAndDismiss(_composeCommand())
      return
    }
    let a = attachments[index]
    _setProgress("Uploading \(index + 1) of \(attachments.count)\n\(a.displayName) → \(host)")
    progressBar?.setProgress(0, animated: false)
    let up = MoshdropUploader()
    uploader = up
    up.upload(localURL: a.localURL, hostAlias: host, device: device, remoteName: a.remoteName,
              progress: { [weak self] frac in self?._setProgressFraction(frac) }) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        self._uploadStep(attachments, index: index + 1, host: host)
      case .failure(let error):
        self._endSending()
        self._composerAlert(title: "Upload failed",
                            message: "Couldn't upload \(a.displayName):\n\(error.localizedDescription)\n\nYou're back in the editor — fix it and send again.")
      }
    }
  }

  // MARK: Upload progress overlay

  private func _showProgress(_ text: String) {
    _hideProgress()
    // Lock the editor while uploading: no edits (which would desync the command) and no keyboard.
    textView.isEditable = false
    let dim = UIView()
    dim.translatesAutoresizingMaskIntoConstraints = false
    dim.backgroundColor = UIColor.black.withAlphaComponent(0.35)

    let card = UIView()
    card.translatesAutoresizingMaskIntoConstraints = false
    card.backgroundColor = .secondarySystemBackground
    card.layer.cornerRadius = 18   // the one card radius, everywhere

    let spinner = UIActivityIndicatorView(style: .large)
    spinner.color = .moshroomTint
    spinner.startAnimating()
    spinner.translatesAutoresizingMaskIntoConstraints = false

    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.numberOfLines = 0
    label.textAlignment = .center
    label.font = .systemFont(ofSize: 15, weight: .medium)
    label.textColor = .label
    label.text = text

    // A real (mushroom-red) progress bar, driven by true SFTP byte counts — see _uploadStep.
    let bar = UIProgressView(progressViewStyle: .default)
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.progressTintColor = .moshroomTint
    bar.trackTintColor = UIColor.moshroomTint.withAlphaComponent(Moshstyle.faintTintAlpha)
    bar.progress = 0

    // Top-right ✕ — cancel the upload and drop straight back into the editor with everything intact.
    let cancel = moshButton()
    cancel.translatesAutoresizingMaskIntoConstraints = false
    cancel.setMoshIcon("xmark.circle.fill", pointSize: 22, color: .tertiaryLabel)
    cancel.addTarget(self, action: #selector(_cancelUpload), for: .touchUpInside)

    card.addSubview(spinner)
    card.addSubview(label)
    card.addSubview(bar)
    card.addSubview(cancel)
    dim.addSubview(card)
    view.addSubview(dim)

    NSLayoutConstraint.activate([
      dim.topAnchor.constraint(equalTo: view.topAnchor),
      dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      card.centerXAnchor.constraint(equalTo: dim.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: dim.centerYAnchor),
      card.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
      card.widthAnchor.constraint(lessThanOrEqualTo: dim.widthAnchor, multiplier: 0.82),

      spinner.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
      spinner.centerXAnchor.constraint(equalTo: card.centerXAnchor),

      label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
      label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
      label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),

      bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
      bar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
      bar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
      bar.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),

      cancel.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
      cancel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
    ])
    progressOverlay = dim
    progressLabel = label
    progressBar = bar
  }

  private func _setProgress(_ text: String) { progressLabel?.text = text }

  private func _setProgressFraction(_ fraction: Double) {
    progressBar?.setProgress(Float(fraction), animated: true)
  }

  private func _hideProgress() {
    progressOverlay?.removeFromSuperview()
    progressOverlay = nil
    progressLabel = nil
    progressBar = nil
    uploader = nil
  }

  // Failure / cancellation: tear the overlay down and hand the editor back, ready to retry.
  private func _endSending() {
    _hideProgress()
    isSending = false
    textView.isEditable = true
  }

  // The upload modal's ✕: abort the in-flight upload and return to the editor — text and every chip
  // stay exactly as they were, so you can change the text, remove a file, and send again.
  @objc private func _cancelUpload() {
    uploader?.cancel()
    _endSending()
  }

  private func _composerAlert(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  // MARK: Suggestions (command completion)

  // A suggestion chip is either a plain command (inserted as `cmd `) or a snip matched by its
  // filename (inserted as the snip's content).
  private enum Suggestion {
    case command(String)
    case snip(label: String, url: URL)
    var label: String {
      switch self {
      case .command(let c): return c
      case .snip(let label, _): return label
      }
    }
  }

  // Common remote agent commands worth suggesting even though they aren't local built-ins —
  // you run them after connecting.
  private static let _extraCommands = ["opencode"]

  func textViewDidChange(_ textView: UITextView) {
    _updateSuggestions()
  }

  // Never let typed text inherit a chip's `.attachment` attribute when the caret sits right after
  // one — that would mis-style the characters and make them vanish from the composed command.
  func textViewDidChangeSelection(_ textView: UITextView) {
    if textView.typingAttributes[.attachment] != nil {
      textView.typingAttributes = _defaultTypingAttributes
    }
  }

  // Auto-continue an unordered "- " list, iPhone-Notes style: Enter after a non-empty bullet starts
  // the next one; Enter on an empty bullet ends the list. It's all literal text — the agent just
  // receives "- item\n- item" on send. (ul only, no numbering.)
  func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
    guard range.length == 0 else { return true }   // only at a plain caret, never over a selection
    let ns = textView.text as NSString
    let priorNL = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: range.location))
    let lineStart = (priorNL.location == NSNotFound) ? 0 : priorNL.location + 1
    let line = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))

    // Typing the space after a line-leading "-" turns it into a pretty "•" bullet. The bullet is an
    // editor nicety only — `_composeCommand` sends it to the agent as a literal "- ".
    if text == " ", line == "-" {
      textView.textStorage.beginEditing()
      textView.textStorage.replaceCharacters(in: NSRange(location: lineStart, length: 1),
                                             with: NSAttributedString(string: "• ", attributes: _defaultTypingAttributes))
      textView.textStorage.endEditing()
      textView.selectedRange = NSRange(location: lineStart + 2, length: 0)
      textView.typingAttributes = _defaultTypingAttributes
      return false
    }

    // Enter inside a bullet list: continue with a fresh bullet, or end the list on an empty one.
    guard text == "\n", line.hasPrefix("• ") else { return true }
    if line.dropFirst(2).trimmingCharacters(in: .whitespaces).isEmpty {
      // Empty bullet + Enter → end the list: drop the marker, stay on the now-clean line.
      let markerRange = NSRange(location: lineStart, length: range.location - lineStart)
      textView.textStorage.beginEditing()
      textView.textStorage.replaceCharacters(in: markerRange, with: NSAttributedString(string: "", attributes: _defaultTypingAttributes))
      textView.textStorage.endEditing()
      textView.selectedRange = NSRange(location: lineStart, length: 0)
    } else {
      // Continue the list with a fresh bullet on the next line.
      textView.textStorage.beginEditing()
      textView.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: "\n• ", attributes: _defaultTypingAttributes))
      textView.textStorage.endEditing()
      textView.selectedRange = NSRange(location: range.location + 3, length: 0)
    }
    textView.typingAttributes = _defaultTypingAttributes
    textView.scrollRangeToVisible(textView.selectedRange)
    _updateSuggestions()
    return false
  }

  private func _updateSuggestions() {
    let items = _commandSuggestions()
    suggestionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    if items.isEmpty {
      suggestionsHeight.constant = 0
    } else {
      items.forEach { suggestionsStack.addArrangedSubview(_chip($0)) }
      suggestionsHeight.constant = 44
    }
  }

  private func _chip(_ suggestion: Suggestion) -> UIButton {
    let isSnip: Bool = { if case .snip = suggestion { return true } else { return false } }()
    var cfg = UIButton.Configuration.plain()
    var attr = AttributeContainer()
    attr.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
    attr.foregroundColor = UIColor.label
    cfg.attributedTitle = AttributedString(suggestion.label, attributes: attr)
    // Snips read in a red tint so they stand apart from plain commands.
    cfg.background.backgroundColor = isSnip
      ? UIColor.moshroomTint.withAlphaComponent(Moshstyle.faintTintAlpha) : .tertiarySystemFill
    cfg.background.cornerRadius = Moshstyle.cardRadius
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
    let b = UIButton(configuration: cfg)
    #if targetEnvironment(macCatalyst)
    b.preferredBehavioralStyle = .pad
    #endif
    b.addAction(UIAction { [weak self] _ in self?._applySuggestion(suggestion) }, for: .touchUpInside)
    return b
  }

  private func _commandSuggestions() -> [Suggestion] {
    guard let range = _commandTokenRange(), range.length > 0 else { return [] }
    let word = (textView.text as NSString).substring(with: range)
    let lower = word.lowercased()

    let commands = (Self._extraCommands + Complete._allCommands())
      .filter { $0.hasPrefix(word) && $0 != word }
      .map { Suggestion.command($0) }

    // Snips matched by their leaf name or full "folder/name" path (case-insensitive).
    let snips = MoshkitorSnips.flat()
      .filter { ($0.label as NSString).lastPathComponent.lowercased().hasPrefix(lower)
                || $0.label.lowercased().hasPrefix(lower) }
      .map { Suggestion.snip(label: $0.label, url: $0.url) }

    return Array((commands + snips).prefix(12))
  }

  // NSRange of the word at the cursor IF it sits in command position (line-leading), else nil.
  private func _commandTokenRange() -> NSRange? {
    guard textView.selectedRange.length == 0 else { return nil }
    let ns = textView.text as NSString
    let cursor = textView.selectedRange.location
    guard cursor <= ns.length else { return nil }

    func isSpace(_ i: Int) -> Bool {
      let c = ns.substring(with: NSRange(location: i, length: 1))
      return c == " " || c == "\t" || c == "\n"
    }

    var start = cursor
    while start > 0, !isSpace(start - 1) { start -= 1 }

    var i = start
    while i > 0 {
      let c = ns.substring(with: NSRange(location: i - 1, length: 1))
      if c == "\n" { break }
      if c != " " && c != "\t" { return nil }
      i -= 1
    }
    return NSRange(location: start, length: cursor - start)
  }

  private func _applySuggestion(_ suggestion: Suggestion) {
    guard let range = _commandTokenRange() else { return }
    let replacement: String
    switch suggestion {
    case .command(let c):
      replacement = c + " "
    case .snip(_, let url):
      replacement = (try? String(contentsOf: url, encoding: .utf8)) ?? suggestion.label
    }
    // Mutate textStorage (not textView.text) so any inline attachments elsewhere survive.
    textView.textStorage.beginEditing()
    textView.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: _defaultTypingAttributes))
    textView.textStorage.endEditing()
    let newCursor = range.location + (replacement as NSString).length
    textView.selectedRange = NSRange(location: newCursor, length: 0)
    textView.typingAttributes = _defaultTypingAttributes
    _updateSuggestions()
  }
}

// M O S H K I T O R   S N I P S
//
// Single source of truth for the on-disk snip tree: root-level `.sh` files plus one tier of
// folders that hold `.sh` snips. Used by both the Snips picker and the composer autocomplete.

enum MoshkitorSnips {
  typealias Snip = (name: String, url: URL)
  typealias Folder = (name: String, snips: [Snip])

  static func grouped() -> (root: [Snip], folders: [Folder]) {
    var root: [Snip] = []
    var folders: [Folder] = []
    let fm = FileManager.default
    guard let dir = MoshroomPaths.localSnippetsLocationURL(),
          let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else { return (root, folders) }
    for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      if isDir {
        let snips = ((try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
          .filter { $0.pathExtension == "sh" }
          .sorted { $0.lastPathComponent < $1.lastPathComponent }
          .map { (name: $0.deletingPathExtension().lastPathComponent, url: $0) }
        if !snips.isEmpty { folders.append((name: entry.lastPathComponent, snips: snips)) }
      } else if entry.pathExtension == "sh" {
        root.append((name: entry.deletingPathExtension().lastPathComponent, url: entry))
      }
    }
    return (root, folders)
  }

  // Every snip flattened to (label, url): "name" for root snips, "folder/name" for nested.
  static func flat() -> [(label: String, url: URL)] {
    let g = grouped()
    return g.root.map { (label: $0.name, url: $0.url) }
      + g.folders.flatMap { folder in folder.snips.map { (label: "\(folder.name)/\($0.name)", url: $0.url) } }
  }
}

// MARK: - Moshkitor's snippet gallery (accordion)
//
// Reads local snippets straight from disk: root-level `.moshroom/snippets/*.sh` first, then
// every nested folder that holds snips (shown by its full relative path, one open at a
// time, no indent). Tap inserts; swipe edits/deletes; `+` creates a brand-new snip in a
// dedicated editor (independent of the composer text).

final class MoshkitorSnipsPicker: UITableViewController {

  private enum Row {
    case folder(name: String, expanded: Bool)
    case snip(name: String, url: URL)
  }

  private struct Folder { let name: String; let snips: [(name: String, url: URL)] }

  private var rootSnips: [(name: String, url: URL)] = []
  private var folders: [Folder] = []
  private var expandedFolder: String?
  private var rows: [Row] = []

  private let onPick: (String) -> Void

  init(onPick: @escaping (String) -> Void) {
    self.onPick = onPick
    super.init(style: .plain)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Snips"
    navigationItem.leftBarButtonItem = moshNavChipBarItem(icon: "xmark", target: self, action: #selector(close))
    navigationItem.rightBarButtonItem = moshNavChipBarItem(icon: "plus", target: self, action: #selector(newSnip))
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
    _reloadFromDisk()
  }

  // One level only: root-level `.sh` files, plus one tier of
  // folders each holding their own `.sh` snips.
  private func _reloadFromDisk() {
    let g = MoshkitorSnips.grouped()
    rootSnips = g.root
    folders = g.folders.map { Folder(name: $0.name, snips: $0.snips) }
    _rebuildRows()
  }

  private func _rebuildRows() {
    rows = rootSnips.map { .snip(name: $0.name, url: $0.url) }
    for folder in folders {
      let expanded = folder.name == expandedFolder
      rows.append(.folder(name: folder.name, expanded: expanded))
      if expanded { rows.append(contentsOf: folder.snips.map { .snip(name: $0.name, url: $0.url) }) }
    }
    tableView.reloadData()
  }

  @objc private func close() { dismiss(animated: true) }

  @objc private func newSnip() {
    let editor = MoshkitorSnipEditor(existingURL: nil, name: "", content: "") { [weak self] in self?._reloadFromDisk() }
    navigationController?.pushViewController(editor, animated: true)
  }

  private func _editSnip(_ url: URL) {
    let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let editor = MoshkitorSnipEditor(existingURL: url, name: MoshkitorSnipEditor.displayName(for: url), content: content) { [weak self] in
      self?._reloadFromDisk()
    }
    navigationController?.pushViewController(editor, animated: true)
  }

  // MARK: Table

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath)
    var config = cell.defaultContentConfiguration()
    switch rows[indexPath.row] {
    case .folder(let name, let expanded):
      config.text = name
      config.image = UIImage(systemName: "folder")
      config.textProperties.font = .systemFont(ofSize: 16, weight: .semibold)
      cell.contentConfiguration = config
      let chevron = UIImageView(image: UIImage(systemName: expanded ? "chevron.down" : "chevron.right"))
      chevron.tintColor = .tertiaryLabel
      cell.accessoryView = chevron
    case .snip(let name, _):
      config.text = name
      cell.contentConfiguration = config
      cell.accessoryView = nil
    }
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch rows[indexPath.row] {
    case .folder(let name, _):
      expandedFolder = (expandedFolder == name) ? nil : name   // accordion: only one open
      _rebuildRows()
    case .snip(_, let url):
      if let content = try? String(contentsOf: url, encoding: .utf8) {
        onPick(content)
        dismiss(animated: true)
      }
    }
  }

  override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    guard case .snip(_, let url) = rows[indexPath.row] else { return nil }

    let edit = UIContextualAction(style: .normal, title: "Edit") { [weak self] _, _, done in
      self?._editSnip(url); done(true)
    }
    edit.backgroundColor = .moshroomTint

    let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
      let alert = UIAlertController(title: "Delete snip?", message: url.deletingPathExtension().lastPathComponent, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(false) })
      alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
        try? FileManager.default.removeItem(at: url)
        self?._reloadFromDisk()
        done(true)
      })
      self?.present(alert, animated: true)
    }

    return UISwipeActionsConfiguration(actions: [delete, edit])
  }
}

// MARK: - Snip editor (create + edit, independent of the composer)

final class MoshkitorSnipEditor: UIViewController {

  private let nameField = UITextField()
  private let contentView = UITextView()
  private let existingURL: URL?
  private let onSaved: () -> Void

  init(existingURL: URL?, name: String, content: String, onSaved: @escaping () -> Void) {
    self.existingURL = existingURL
    self.onSaved = onSaved
    super.init(nibName: nil, bundle: nil)
    nameField.text = name
    contentView.text = content
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // "folder/name" for a snip in a folder, or just "name" at the root (one level).
  static func displayName(for url: URL) -> String {
    let name = url.deletingPathExtension().lastPathComponent
    guard let root = MoshroomPaths.localSnippetsLocationURL() else { return name }
    let parent = url.deletingLastPathComponent().standardizedFileURL
    if parent == root.standardizedFileURL { return name }
    return "\(parent.lastPathComponent)/\(name)"
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = existingURL == nil ? "New snip" : "Edit snip"
    navigationItem.rightBarButtonItem = moshNavChipLabelItem(title: "Save", target: self, action: #selector(save))

    nameField.placeholder = "name  or  folder/name"
    nameField.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
    nameField.autocapitalizationType = .none
    nameField.autocorrectionType = .no
    nameField.clearButtonMode = .whileEditing
    nameField.borderStyle = .roundedRect
    nameField.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(nameField)

    contentView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
    contentView.autocapitalizationType = .none
    contentView.autocorrectionType = .no
    contentView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
    contentView.layer.borderColor = UIColor.separator.cgColor
    contentView.layer.borderWidth = 1
    contentView.layer.cornerRadius = 8
    contentView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(contentView)

    NSLayoutConstraint.activate([
      nameField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      nameField.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      nameField.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),

      contentView.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 12),
      contentView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      contentView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
      contentView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if (nameField.text ?? "").isEmpty { nameField.becomeFirstResponder() } else { contentView.becomeFirstResponder() }
  }

  @objc private func save() {
    guard let raw = nameField.text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
          let root = MoshroomPaths.localSnippetsLocationURL() else {
      _alert(title: "Name required"); return
    }
    // One level only: "folder/name" or "name".
    let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
    let folder = parts.count == 2 ? parts[0] : nil
    let name = parts.count == 2 ? parts[1] : parts[0]
    guard !name.isEmpty, !name.contains("/") else {
      _alert(title: "Use one level", message: "Name it \"name\" or \"folder/name\"."); return
    }
    let dir = folder.map { root.appendingPathComponent($0) } ?? root
    let newURL = dir.appendingPathComponent(name + ".sh")

    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try (contentView.text ?? "").write(to: newURL, atomically: true, encoding: .utf8)
    } catch {
      _alert(title: "Couldn't save", message: error.localizedDescription); return
    }
    // Renamed/moved: drop the old file.
    if let old = existingURL, old.standardizedFileURL != newURL.standardizedFileURL {
      try? FileManager.default.removeItem(at: old)
    }
    onSaved()
    navigationController?.popViewController(animated: true)
  }

  private func _alert(title: String, message: String? = nil) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}

// MARK: - Opening Moshkitor

extension SpaceController {
  // Opened by the Moshkeys compose button, by the hardware keyboard once typing exceeds a
  // single probe keystroke, or by a tap on the terminal's input line (the cursor row — see
  // the tap dispatch in WKWebView.swift/term.js). Long-press select/copy is untouched.
  func openMoshkitor(seed: String = "", pasteOnOpen: Bool = false) {
    dismissMoshnector()
    view.subviews.compactMap({ $0 as? MoshkeysBar }).first?.closeIfOpen()
    guard presentedViewController == nil, let device = currentDevice else { return }
    let composer = MoshkitorComposer(device: device, seed: seed,
                                     connectedHost: currentTerm()?.moshroomConnectedHost,
                                     pasteOnAppear: pasteOnOpen)
    composer.onSend = { [weak self] command in
      // The user ran something in this tab → the terminal now has content; don't pop Quick Connect back.
      self?.currentTerm()?.moshroomUserHasInteracted = true
      // Catch an `ssh`/`mosh` typed here so the next attachment uploads to that host.
      self?.noteConnectionCommand(command)
    }
    let nav = UINavigationController(rootViewController: composer)
    // The composer owns the whole screen, on every device — writing to the agent is the main
    // event, and a sheet (iPhone) or centered card (iPad) wastes canvas. Close is the ✕ up top.
    // .overFullScreen (NOT .fullScreen): the covered terminal must STAY in the window — pulling
    // the web view out and back re-latches WebKit's selection painting into a dead near-black
    // box that no responder dance reliably heals (reproduced live 2026-07-10). Same look, and
    // SpaceController's dismiss override restores what viewDidAppear no longer re-fires for.
    nav.modalPresentationStyle = .overFullScreen
    // Always present instantly (no slide) — consistent with every other full-screen surface and with
    // the instant dismiss (see SpaceController.dismiss). This also keeps the old hardware-keyboard
    // guarantee: with a seed, the editor must be on screen and first responder immediately, or the
    // next keystroke lands with no responder and Mac Catalyst beeps (and drops the key).
    present(nav, animated: false)
  }

  // Cmd+V while no composer is up: everything the user SENDS goes through Moshkitor, so a paste
  // opens the composer and drops the clipboard in (see viewDidAppear → smartPaste), rather than
  // injecting into the read-only transcript. No-op on an empty clipboard so a stray Cmd+V is quiet.
  func openMoshkitorPasting() {
    let pb = UIPasteboard.general
    guard pb.hasStrings || pb.hasImages || pb.hasURLs else { return }
    openMoshkitor(pasteOnOpen: true)
  }

  // Settings = the built-in config screen (same as the `config` command), so everything
  // lives in one place.
  func openSettings() {
    view.subviews.compactMap({ $0 as? MoshkeysBar }).first?.closeIfOpen()
    showConfigAction()
  }
}

// MARK: - Hardware keyboard routing (Bluetooth)
//
// In keyboard-less terminal mode SpaceController is the first responder, so it receives
// hardware key presses. We route them so single-key TUI reactions keep working while
// real typing flows into Moshkitor:
//
//   • control combos / Return / Tab / Esc / arrows / Backspace  → straight to the agent
//   • the first printable keystroke                              → live to the agent (a probe)
//   • a second printable keystroke in quick succession          → open Moshkitor seeded with
//                                                                  both chars (the probe is erased)
//
// Send from Moshkitor with Ctrl+Enter (Enter inserts a newline).

enum MoshroomKeyboard {
  private static var pendingChar: String?
  private static var resetItem: DispatchWorkItem?

  @discardableResult
  static func handle(_ presses: Set<UIPress>, device: TermDevice?, openComposer: (String) -> Void) -> Bool {
    guard let key = presses.first(where: { $0.key != nil })?.key else { return false }
    let mods = key.modifierFlags

    // Leave ⌘ shortcuts (new tab, etc.) to the terminal core.
    if mods.contains(.command) { return false }

    // Ctrl-combos pass through as their control byte.
    if mods.contains(.control) {
      guard let bytes = _controlBytes(for: key) else { return false }
      device?.write(bytes)
      _clearPending()
      return true
    }

    // Non-text keys go live to the agent/TUI.
    if let bytes = _specialBytes(for: key) {
      device?.write(bytes)
      _clearPending()
      return true
    }

    // Printable text.
    let text = key.characters
    guard !text.isEmpty, !(text.first?.isNewline ?? true) else { return false }

    if let first = pendingChar {
      // Second keystroke: hand off to Moshkitor, erasing the probe char already sent.
      _clearPending()
      device?.write("\u{7F}")
      openComposer(first + text)
    } else {
      // First keystroke: live to the agent, remembered briefly.
      device?.write(text)
      _setPending(text)
    }
    return true
  }

  private static func _setPending(_ s: String) {
    pendingChar = s
    resetItem?.cancel()
    let item = DispatchWorkItem { pendingChar = nil }
    resetItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: item)
  }

  private static func _clearPending() {
    resetItem?.cancel()
    resetItem = nil
    pendingChar = nil
  }

  private static func _specialBytes(for key: UIKey) -> String? {
    switch key.keyCode {
    case .keyboardReturnOrEnter, .keypadEnter: return "\r"
    case .keyboardTab: return "\t"
    case .keyboardEscape: return "\u{1B}"
    case .keyboardDeleteOrBackspace: return "\u{7F}"
    case .keyboardUpArrow: return "\u{1B}[A"
    case .keyboardDownArrow: return "\u{1B}[B"
    case .keyboardRightArrow: return "\u{1B}[C"
    case .keyboardLeftArrow: return "\u{1B}[D"
    default: return nil
    }
  }

  private static func _controlBytes(for key: UIKey) -> String? {
    guard let scalar = key.charactersIgnoringModifiers.uppercased().unicodeScalars.first else { return nil }
    let v = scalar.value
    guard v >= 0x41, v <= 0x5A else { return nil }   // Ctrl+A ... Ctrl+Z
    return String(UnicodeScalar(v & 0x1F)!)
  }
}
