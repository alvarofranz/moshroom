// Copyright (C) 2026 Moshroom. Licensed under GPLv3; see COPYING.

import Combine
import GameController
import UIKit

enum MoshroomTypingMode: String, CaseIterable, Identifiable {
  case composer, direct, automatic
  var id: String { rawValue }
  var title: String {
    switch self {
    case .composer: return "Composer"
    case .direct: return "Direct"
    case .automatic: return "Automatic"
    }
  }
  var detail: String {
    switch self {
    case .composer: return "Write in a roomy editor, then send. Ideal for long prompts and attachments."
    case .direct: return "Type straight into the terminal. Open the composer whenever you need more room."
    case .automatic: return "Direct with a hardware keyboard; Composer with the on-screen keyboard."
    }
  }
}

final class MoshroomTyping: ObservableObject {
  static let shared = MoshroomTyping()
  static let defaultsKey = "MoshroomTypingMode"
  static let didChange = Notification.Name("MoshroomTypingDidChange")

  @Published private(set) var mode: MoshroomTypingMode
  @Published private(set) var hardwareKeyboard = false
  private var observers: [NSObjectProtocol] = []

  var isDirect: Bool { mode == .direct || (mode == .automatic && hardwareKeyboard) }

  private init() {
    mode = Self.savedMode
    hardwareKeyboard = Self.connectedKeyboard
    let nc = NotificationCenter.default
    for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
      observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.updateHardware(Self.connectedKeyboard)
      })
    }
    observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self, self.mode != Self.savedMode else { return }
      self.mode = Self.savedMode
      nc.post(name: Self.didChange, object: self)
    })
  }

  private static var savedMode: MoshroomTypingMode {
    UserDefaults.standard.string(forKey: defaultsKey).flatMap(MoshroomTypingMode.init(rawValue:)) ?? .composer
  }
  private static var connectedKeyboard: Bool {
    #if targetEnvironment(macCatalyst)
    return true
    #else
    return GCKeyboard.coalesced != nil
    #endif
  }
  func select(_ value: MoshroomTypingMode) {
    guard value != mode else { return }
    mode = value
    UserDefaults.standard.set(value.rawValue, forKey: Self.defaultsKey)
    NotificationCenter.default.post(name: Self.didChange, object: self)
  }
  func noteHardwareKey() { updateHardware(true) }
  private func updateHardware(_ connected: Bool) {
    guard hardwareKeyboard != connected else { return }
    hardwareKeyboard = connected
    NotificationCenter.default.post(name: Self.didChange, object: self)
  }
  deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

// Test switches are local files or launch arguments, never preferences that sync or ship enabled.
enum MoshroomDevelopment {
  static func enabled(_ name: String) -> Bool {
    #if MOSHROOM_PUBLISHING_OPTION_DEVELOPER
    return ProcessInfo.processInfo.arguments.contains("-moshroom-" + name)
      || FileManager.default.fileExists(atPath: directory.appendingPathComponent("debug-" + name).path)
    #else
    return false
    #endif
  }
  static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Moshroom", isDirectory: true)
  }
  static func inputProbe(_ event: @autoclosure () -> String) {
    #if MOSHROOM_PUBLISHING_OPTION_DEVELOPER
    guard enabled("direct-probe") || enabled("direct-events") else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("direct-probe.log")
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data((event() + "\n").utf8))
    #endif
  }
  static var testSession: String? {
    #if MOSHROOM_PUBLISHING_OPTION_DEVELOPER
    guard let value = try? String(contentsOf: directory.appendingPathComponent("debug-tmux-session"), encoding: .utf8) else { return nil }
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard name.hasPrefix("moshroom-test-"), name.count < 80,
          name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }) else { return nil }
    return name
    #else
    return nil
    #endif
  }
  static func inputBytes(_ bytes: String) {
    #if MOSHROOM_PUBLISHING_OPTION_DEVELOPER
    guard enabled("direct-bytes") else { return }
    let url = directory.appendingPathComponent("direct-bytes.log")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data((bytes.utf8.map { String(format: "%02x", $0) }.joined(separator: " ") + "\n").utf8))
    #endif
  }
}
