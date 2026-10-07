// Copyright (C) 2026 Moshroom. Licensed under GPLv3; see COPYING.

import Foundation

/// A UTF-16 marked range belongs to UIKit. Diff only the committed prefix, by grapheme, and
/// never retract text just because an input method has temporarily marked it for replacement.
struct MoshroomInputBuffer {
  struct Change {
    let bytes: String
    let committed: String
    let clearAfterSending: Bool
  }
  enum Update {
    case change(Change)
    case composing
    case unsafeReplacement
  }
  private(set) var sent = ""

  func update(text: String, markedStart: Int?) -> Update {
    let source = text as NSString
    let prefix = markedStart.map { source.substring(to: min(max(0, $0), source.length)) } ?? text
    let old = Array(sent), new = Array(prefix)
    var shared = 0
    while shared < min(old.count, new.count),
          String(old[shared]).unicodeScalars.elementsEqual(String(new[shared]).unicodeScalars) {
      shared += 1
    }
    // A dead key or candidate picker can re-mark an already committed suffix. Wait for its
    // final replacement; erasing that suffix now would send a half-composed edit to the server.
    if markedStart != nil, shared < old.count { return .composing }
    let removed = old.dropFirst(shared)
    guard removed.allSatisfy({ $0.unicodeScalars.count == 1 }) else { return .unsafeReplacement }
    let added = String(new.dropFirst(shared))
    let bytes = String(repeating: "\u{7f}", count: removed.count)
      + added.replacingOccurrences(of: "\n", with: "\r")
    return .change(Change(bytes: bytes, committed: prefix,
                          clearAfterSending: markedStart == nil && (prefix.count >= 256 || prefix.contains(where: \.isNewline))))
  }
  mutating func accept(_ change: Change) { sent = change.clearAfterSending ? "" : change.committed }
  mutating func reset() { sent = "" }
}

/// One FIFO for text, special keys and pastes. Preparing a paste has NO side effects: the
/// terminal bytes come back to this queue before being written. Invalidating the generation
/// therefore makes a late JavaScript reply harmless, even after a timeout or a tab change.
final class MoshroomInputQueue {
  enum Failure: Error { case unavailable, needsComposer, timedOut }
  private enum Entry { case bytes(String), paste(String) }
  var isAllowed: () -> Bool = { false }
  var write: (String) -> Void = { _ in }
  var preparePaste: (String, @escaping (Result<String, Failure>) -> Void) -> Void = { _, reply in reply(.failure(.unavailable)) }
  var onFailure: (String, Failure) -> Void = { _, _ in }
  private var entries: [Entry] = []
  private var generation = UUID()
  private var preparing = false
  private var timeout: DispatchWorkItem?

  @discardableResult func send(_ bytes: String) -> Bool {
    guard isAllowed() else { return false }
    guard !bytes.isEmpty else { return true }
    entries.append(.bytes(bytes))
    drain()
    return true
  }
  func paste(_ text: String) {
    guard isAllowed(), !text.isEmpty else { return }
    entries.append(.paste(text))
    drain()
  }
  func cancel() {
    generation = UUID()
    timeout?.cancel()
    timeout = nil
    entries.removeAll()
    preparing = false
  }
  private func drain() {
    guard !preparing else { return }
    while !entries.isEmpty {
      guard isAllowed() else { cancel(); return }
      switch entries.removeFirst() {
      case .bytes(let bytes): write(bytes)
      case .paste(let text):
        preparing = true
        let ticket = generation
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(.timedOut), text: text, ticket: ticket) }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: deadline)
        preparePaste(text) { [weak self] result in self?.finish(result, text: text, ticket: ticket) }
        return
      }
    }
  }
  private func finish(_ result: Result<String, Failure>, text: String, ticket: UUID) {
    guard ticket == generation, preparing else { return }
    timeout?.cancel()
    timeout = nil
    guard isAllowed() else { cancel(); return }
    switch result {
    case .success(let bytes):
      preparing = false
      // Each paste gets its own ticket, including consecutive pastes in the same generation.
      let delivered = UUID()
      generation = delivered
      write(bytes)
      // A write can synchronously change ownership. Never invalidate or drain a new owner's
      // pending paste when returning from the old owner's callback.
      if generation == delivered { drain() }
    case .failure(let error):
      cancel()
      onFailure(text, error)
    }
  }
  deinit { timeout?.cancel() }
}
