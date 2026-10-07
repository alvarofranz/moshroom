// Copyright (C) 2026 Moshroom. Licensed under GPLv3; see COPYING.

import UIKit
import UniformTypeIdentifiers

// UIKit owns normal text, marked text and dictation. This responder owns terminal commands;
// both feed the same device-bound FIFO. The web view never owns keyboard input.
final class MoshroomDirectInput: UITextView, UITextViewDelegate {
  weak var owner: SpaceController?
  private weak var device: TermDevice?
  private let output = MoshroomInputQueue()
  private var buffer = MoshroomInputBuffer()
  private var mutationDepth = 0
  private var resetting = false
  private var held: Set<UIKeyboardHIDUsage> = []
  private var repeatingKey: UIKeyboardHIDUsage?
  private var repeatTimer: Timer?
  private var repeatStarted = Date.distantPast
  var wantsSoftKeyboard = false
  var controlLatched = false { didSet { keysBar?.updateControl() } }
  var controlLocked = false { didSet { keysBar?.updateControl() } }
  private var keysBar: MoshroomDirectKeysBar?
  private var probeOnly: Bool { MoshroomDevelopment.enabled("direct-probe") }

  private func trace(_ event: @autoclosure () -> String) {
    guard device?.secureTextEntry != true else { return }
    MoshroomDevelopment.inputProbe(event())
  }

  init() {
    super.init(frame: .zero, textContainer: nil)
    backgroundColor = .clear
    textColor = .clear
    tintColor = .clear
    autocorrectionType = .no
    spellCheckingType = .no
    autocapitalizationType = .none
    smartDashesType = .no
    smartQuotesType = .no
    smartInsertDeleteType = .no
    keyboardType = .default
    keyboardAppearance = .dark
    textContentType = nil
    isScrollEnabled = false
    allowsEditingTextAttributes = false
    dataDetectorTypes = []
    isFindInteractionEnabled = false
    textDragInteraction?.isEnabled = false
    if #available(iOS 17.0, *) { inlinePredictionType = .no }
    if #available(iOS 18.0, *) { writingToolsBehavior = .none }
    delegate = self
    accessibilityLabel = "Terminal input"
    accessibilityIdentifier = "terminal.input"
    pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.text.identifier, UTType.image.identifier, UTType.fileURL.identifier, UTType.pdf.identifier])
    output.isAllowed = { [weak self] in self?.canWrite == true }
    output.write = { [weak self] bytes in
      guard let self, self.canWrite else { return }
      self.owner?.dismissMoshnector()
      if self.device?.secureTextEntry != true { MoshroomDevelopment.inputBytes(bytes) }
      self.device?.write(bytes)
      self.owner?.moshroomPositionDirectInput()
    }
    output.preparePaste = { [weak self] text, reply in
      guard let self, let view = self.device?.view, view.isReady,
            let encoded = try? JSONSerialization.data(withJSONObject: [text]),
            let json = String(data: encoded, encoding: .utf8) else {
        reply(.failure(.unavailable)); return
      }
      view.webView.evaluateJavaScript("term_prepareDirectPaste(\(json)[0]);") { result, error in
        guard error == nil, let result = result as? [String: Any] else {
          reply(.failure(.unavailable)); return
        }
        if result["needsComposer"] as? Bool == true { reply(.failure(.needsComposer)) }
        else if let bytes = result["bytes"] as? String { reply(.success(bytes)) }
        else { reply(.failure(.unavailable)) }
      }
    }
    output.onFailure = { [weak self] text, error in
      guard let self else { return }
      self.clearText()
      if case .needsComposer = error { self.owner?.openMoshkitor(seed: text) }
      else { self.owner?.showAlert(msg: "The paste could not be sent. Input queued behind it was cancelled. Please paste again when the terminal is ready.") }
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var undoManager: UndoManager? { nil }
  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    action == #selector(terminalKey(_:)) && markedTextRange == nil
  }

  private var canWrite: Bool {
    !probeOnly && isFirstResponder && owner?.moshroomCanTypeDirect == true
      && device != nil && device === owner?.currentDevice && device?.view?.isReady == true
  }
  func bind(to device: TermDevice?) {
    guard self.device !== device else { return }
    resetComposition()
    self.device = device
    refreshSecureEntry()
  }
  func refreshSecureEntry() {
    let secure = device?.secureTextEntry == true
    guard isSecureTextEntry != secure else { return }
    resetComposition()
    isSecureTextEntry = secure
    if isFirstResponder { reloadInputViews() }
  }
  func resetComposition() {
    trace("reset firstResponder=\(isFirstResponder) utf16=\(text.utf16.count)")
    stopRepeating()
    held.removeAll()
    output.cancel()
    controlLatched = false
    controlLocked = false
    clearText()
  }
  private func clearText() {
    resetting = true
    super.unmarkText()
    text = ""
    selectedRange = NSRange(location: 0, length: 0)
    buffer.reset()
    resetting = false
    owner?.moshroomShowComposition(nil)
  }
  @discardableResult override func resignFirstResponder() -> Bool {
    // unmarkText during resignation may confirm a candidate. Invalidate BEFORE UIKit does it.
    resetComposition()
    resetting = true
    let result = super.resignFirstResponder()
    resetting = false
    return result
  }

  override var inputAccessoryView: UIView? {
    get {
      #if targetEnvironment(macCatalyst)
      return nil
      #else
      guard !MoshroomTyping.shared.hardwareKeyboard else { return nil }
      if keysBar == nil { keysBar = MoshroomDirectKeysBar(input: self) }
      return keysBar
      #endif
    }
    set { super.inputAccessoryView = newValue }
  }

  // Some Catalyst keys arrive as text commands instead of UIPress (measured with the phase-zero
  // probe). Priority commands cover those keys; UIKit still handles ALL keys while an IME composes.
  override var keyCommands: [UIKeyCommand]? {
    guard markedTextRange == nil else { return [] }
    var bindings: [(String, UIKeyModifierFlags, String)] = [
      (UIKeyCommand.inputEscape, [], "\u{1b}"), ("\t", [], "\t"), ("\t", .shift, "\u{1b}[Z"),
      ("\r", [], "\r"), ("\r", .shift, "\n"), ("\r", .control, "\n"),
      ("\r", .alternate, "\u{1b}\r"), ("\u{8}", .alternate, "\u{1b}\u{7f}"),
      ("\u{8}", .control, "\u{8}"), (" ", .control, "\0"), ("2", .control, "\0"),
      ("6", .control, "\u{1e}"), ("[", .control, "\u{1b}"), ("\\", .control, "\u{1c}"),
      ("]", .control, "\u{1d}"), ("^", .control, "\u{1e}"), ("_", .control, "\u{1f}")
    ]
    for scalar in UInt8(97)...UInt8(122) {
      bindings.append((String(UnicodeScalar(scalar)), .control, String(UnicodeScalar(scalar - 96))))
    }
    return bindings.map { input, mods, bytes in
      let command = UIKeyCommand(title: "", action: #selector(terminalKey(_:)), input: input,
                                 modifierFlags: mods, propertyList: ["bytes": bytes])
      command.wantsPriorityOverSystemBehavior = true
      return command
    }
  }
  @objc private func terminalKey(_ command: UIKeyCommand) {
    guard markedTextRange == nil, let dict = command.propertyList as? [String: String], let bytes = dict["bytes"] else { return }
    trace("command \(bytes.utf8.map { String(format: "%02x", $0) }.joined(separator: " "))")
    MoshroomTyping.shared.noteHardwareKey()
    sendSpecial(bytes)
  }
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    var native = Set<UIPress>()
    for press in presses {
      if let key = press.key {
        trace("press \(key.keyCode.rawValue) mods=\(key.modifierFlags.rawValue) scalars=\(key.characters.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: ","))")
        MoshroomTyping.shared.noteHardwareKey()
        if !probeOnly, handle(key) { continue }
      }
      native.insert(press)
    }
    if !native.isEmpty { super.pressesBegan(native, with: event) }
  }
  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    release(presses)
    super.pressesEnded(presses, with: event)
  }
  override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    release(presses)
    super.pressesCancelled(presses, with: event)
  }
  func release(_ presses: Set<UIPress>) {
    for press in presses {
      guard let code = press.key?.keyCode else { continue }
      held.remove(code)
      if repeatingKey == code { stopRepeating() }
    }
  }
  private func handle(_ key: UIKey) -> Bool {
    let mods = key.modifierFlags
    if mods.contains(.command) { return true }
    if markedTextRange != nil { return false }
    if let bytes = specialBytes(key) {
      guard !held.contains(key.keyCode) else { return true }
      held.insert(key.keyCode)
      sendSpecial(bytes)
      if key.keyCode != .keyboardEscape { startRepeating(key: key.keyCode, bytes: bytes) }
      return true
    }
    if key.keyCode == .keyboardDeleteOrBackspace { return false }
    if (224...231).contains(key.keyCode.rawValue) { return false }
    return mods.contains(.control) || key.characters.isEmpty || !MoshroomKeyboard.isTypable(key.characters)
  }
  private func specialBytes(_ key: UIKey) -> String? {
    let mods = key.modifierFlags
    if let bytes = MoshroomKeyboard.navigationBytes(for: key.keyCode, modifiers: mods,
                                                    applicationCursor: device?.moshroomApplicationCursor ?? false) { return bytes }
    switch key.keyCode {
    case .keyboardReturnOrEnter, .keypadEnter:
      if mods.contains(.control) || mods.contains(.shift) { return "\n" }
      return mods.contains(.alternate) ? "\u{1b}\r" : "\r"
    case .keyboardTab: return mods.contains(.shift) ? "\u{1b}[Z" : "\t"
    case .keyboardEscape: return "\u{1b}"
    case .keyboardDeleteOrBackspace:
      if mods.contains(.alternate) { return "\u{1b}\u{7f}" }
      if mods.contains(.control) { return "\u{8}" }
      return nil
    default: break
    }
    if mods.contains(.control) {
      if key.keyCode == .keyboardSpacebar || key.keyCode == .keyboard2 { return "\0" }
      return MoshroomKeyboard._controlBytes(for: key)
    }
    return nil
  }
  func acceptHardwareKeys(_ presses: Set<UIPress>) {
    becomeFirstResponder()
    for press in presses {
      guard let key = press.key else { continue }
      if !handle(key), MoshroomKeyboard.isTypable(key.characters) { insertText(key.characters) }
    }
  }
  func sendSpecial(_ bytes: String) {
    guard !probeOnly, canWrite else { return }
    clearText()
    output.send(bytes)
  }
  private func startRepeating(key: UIKeyboardHIDUsage, bytes: String) {
    stopRepeating()
    repeatingKey = key
    repeatStarted = Date()
    #if targetEnvironment(macCatalyst)
    let defaults = UserDefaults.standard
    let delay = max(0.15, min(2, (defaults.object(forKey: "InitialKeyRepeat") as? Double ?? 25) / 60))
    let interval = max(0.02, min(0.2, (defaults.object(forKey: "KeyRepeat") as? Double ?? 3) / 60))
    #else
    let delay = 0.4, interval = 0.05
    #endif
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      guard let self else { return }
      guard self.canWrite, self.markedTextRange == nil, Date().timeIntervalSince(self.repeatStarted) < 30 else {
        self.stopRepeating(); return
      }
      self.output.send(bytes)
    }
    timer.fireDate = Date().addingTimeInterval(delay)
    repeatTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  private func stopRepeating() {
    repeatTimer?.invalidate()
    repeatTimer = nil
    repeatingKey = nil
  }
  override func insertText(_ text: String) {
    trace("insert \(text.utf8.map { String(format: "%02x", $0) }.joined(separator: " "))")
    if !probeOnly, markedTextRange == nil, controlLatched || controlLocked,
       text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first {
      // Control applies to ASCII only; Unicode case expansion must never turn ß into ^S.
      let value = scalar.value
      if value == 32 || (64...95).contains(value) || (97...122).contains(value) {
        sendSpecial(String(UnicodeScalar(value == 32 ? 0 : value & 31)!))
        controlLatched = false
        return
      }
      controlLatched = false
    }
    mutationDepth += 1
    super.insertText(text)
    mutationDepth -= 1
    flushText()
  }
  override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
    mutationDepth += 1
    super.setMarkedText(markedText, selectedRange: selectedRange)
    mutationDepth -= 1
    flushText()
  }
  override func unmarkText() {
    mutationDepth += 1
    super.unmarkText()
    mutationDepth -= 1
    flushText()
  }
  override func deleteBackward() {
    trace("delete")
    if probeOnly || markedTextRange != nil {
      mutationDepth += 1
      super.deleteBackward()
      mutationDepth -= 1
      flushText()
    } else {
      // One physical Backspace is one DEL, including with an empty buffer after a barrier.
      sendSpecial("\u{7f}")
    }
  }
  func textViewDidChange(_ textView: UITextView) {
    trace("change utf16=\(text.utf16.count) marked=\(markedTextRange != nil)")
    flushText()
  }
  private func flushText() {
    guard !probeOnly, !resetting, mutationDepth == 0 else { return }
    guard canWrite else { trace("flush blocked"); clearText(); return }
    let mark = markedTextRange.map { offset(from: beginningOfDocument, to: $0.start) }
    owner?.moshroomShowComposition(markedTextRange.flatMap { self.text(in: $0) })
    switch buffer.update(text: text, markedStart: mark) {
    case .composing: break
    case .unsafeReplacement:
      // Leave the remote text intact. A fresh local buffer prevents a later correction from
      // assuming we erased a multi-scalar grapheme that different shells erase differently.
      clearText()
    case .change(let change):
      guard output.send(change.bytes) else { clearText(); return }
      buffer.accept(change)
      if change.clearAfterSending { clearText() }
    }
  }

  func pasteClipboard() {
    guard canWrite else { return }
    let pasteboard = UIPasteboard.general
    if pasteboard.hasImages || pasteboard.contains(pasteboardTypes: [UTType.fileURL.identifier, UTType.pdf.identifier]) {
      owner?.openMoshkitorPasting()
      return
    }
    guard let text = pasteboard.string, !text.isEmpty else { return }
    pasteText(text)
  }
  func pasteText(_ text: String) {
    guard canWrite else { return }
    stopRepeating()
    clearText()
    if text.contains(where: \.isNewline), device?.moshroomBracketedPaste != true {
      owner?.openMoshkitor(seed: text)
      return
    }
    output.paste(text)
  }

  override func paste(itemProviders: [NSItemProvider]) {
    // UIPasteControl supplies permission to read the pasteboard for this deliberate action.
    pasteClipboard()
  }
  deinit { repeatTimer?.invalidate() }
}
