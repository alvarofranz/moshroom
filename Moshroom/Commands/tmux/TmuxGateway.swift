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


// One SSH connection running `tmux -C`: dial, the command queue, the parser. It knows the protocol and
// nothing about what the output means (MoshroomTmux decides that).
//
// Threading: everything here runs on the thread whose run loop created the SSH client (the tmux child
// session's own thread). The channel's reads, libssh's callbacks and every call into this class happen
// there, so nothing is locked.

import Combine
import Dispatch
import Foundation
import SSH

final class TmuxGateway {
  typealias Completion = (TmuxReply) -> Void

  /// Every event that is not a reply (output, notifications, text before tmux started).
  var onEvent: ((TmuxEvent) -> Void)?
  /// The connection is gone (nil: the channel closed cleanly, tmux exited). Called once.
  var onClosed: ((Error?) -> Void)?

  private struct Pending {
    // The command line it was sent on: an error skips the rest of that line.
    let line: Int
    let completion: Completion?
  }

  private var client: SSHClient?
  private var stream: SSH.Stream?
  private var dialCancellable: AnyCancellable?
  private let parser = TmuxControlParser()
  private let input = TmuxLineSource()
  private var pending: [Pending] = []
  private var lineCounter = 0
  private(set) var isClosed = false

  /// Bytes of tmux output parsed so far (diagnostics only).
  private(set) var bytesIn = 0

  /// Dial `hostName` and exec `command`, which ends up running `tmux -C` with its stderr folded into
  /// stdout. tmux answers its OWN command line (new-session / attach-session) with the first reply
  /// block, before anything else: `attached` gets that reply.
  func connect(hostName: String,
               config: SSHClientConfig,
               command: String,
               proxy: SSHClient.ExecProxyCommandCallback?,
               attached: @escaping Completion) {
    pending = [Pending(line: 0, completion: attached)]
    dialCancellable = SSHClient.dial(hostName, with: config, withProxy: proxy)
      .flatMap { [weak self] client -> AnyPublisher<SSH.Stream, Error> in
        guard let self, !self.isClosed else {
          return Fail(error: TmuxError.cancelled).eraseToAnyPublisher()
        }
        self.client = client
        client.handleSessionException = { [weak self] error in
          self?.close(error)
        }
        // No PTY: control mode needs none, and without one nothing is echoed back.
        return client.requestExec(command: command, withPTY: nil)
      }
      .sink(receiveCompletion: { [weak self] completion in
        if case .failure(let error) = completion {
          self?.close(error)
        }
      }, receiveValue: { [weak self] stream in
        self?._start(stream)
      })
  }

  private func _start(_ stream: SSH.Stream) {
    guard !isClosed else {
      stream.cancel()
      return
    }
    self.stream = stream
    stream.handleCompletion = { [weak self] in
      self?.close(nil)
    }
    stream.handleFailure = { [weak self] error in
      self?.close(error)
    }
    // stdout only: the exec folds tmux's stderr into it. A separate stderr flow would end the stream
    // as soon as IT saw the channel's EOF, possibly before stdout had delivered its last lines.
    stream.connect(stdout: TmuxSinkWriter { [weak self] data in
      self?._received(data)
    }, stdin: input)
  }

  private func _received(_ data: DispatchData) {
    guard !isClosed else { return }
    bytesIn += data.count
    data.enumerateBytes { buffer, _, _ in
      parser.feed(buffer) { [weak self] event in
        self?._handle(event)
      }
    }
  }

  private func _handle(_ event: TmuxEvent) {
    guard !isClosed else { return }
    guard case .reply(let reply) = event else {
      onEvent?(event)
      return
    }
    guard !pending.isEmpty else {
      // A reply nobody waits for (cannot happen while the queue is in step): ignore it.
      return
    }
    let entry = pending.removeFirst()
    entry.completion?(reply)
    // tmux stops at the first failing command of a line and never runs, or answers, the rest.
    if reply.isError && entry.line > 0 {
      while let next = pending.first, next.line == entry.line {
        pending.removeFirst()
        next.completion?(.skippedReply)
      }
    }
  }

  /// Send commands on ONE line (tmux runs them back to back, nothing else in between). Completions are
  /// called in order with each command's reply; a command skipped because an earlier one failed, or
  /// because the connection went away, gets `TmuxReply.skippedReply`.
  func send(_ commands: [(String, Completion?)]) {
    let commands = commands.filter { !$0.0.isEmpty }
    guard !commands.isEmpty else { return }
    guard !isClosed, stream != nil else {
      commands.forEach { $0.1?(.skippedReply) }
      return
    }
    lineCounter += 1
    for command in commands {
      pending.append(Pending(line: lineCounter, completion: command.1))
    }
    // Never an empty line (it detaches the client) and never a newline inside a command.
    let line = commands.map { $0.0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " ; ") + "\n"
    Array(line.utf8).withUnsafeBytes { raw in
      input.send(DispatchData(bytes: raw))
    }
  }

  func send(_ command: String, _ completion: Completion? = nil) {
    send([(command, completion)])
  }

  var isAttachedChannel: Bool { stream != nil && !isClosed }

  /// Tear down. Safe to call from inside any callback: the SSH objects are released on the next turn of
  /// the run loop, never under the call that is running.
  func close(_ error: Error? = nil) {
    guard !isClosed else { return }
    isClosed = true
    let waiting = pending
    pending = []
    waiting.forEach { $0.completion?(.skippedReply) }
    let stream = self.stream
    let client = self.client
    let dial = self.dialCancellable
    self.stream = nil
    self.client = nil
    self.dialCancellable = nil
    let closed = onClosed
    onClosed = nil
    onEvent = nil
    let loop = CFRunLoopGetCurrent()
    CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
      stream?.cancel()
      _ = dial
      _ = client
      closed?(error)
    }
    CFRunLoopWakeUp(loop)
  }
}

enum TmuxError: Error, LocalizedError {
  case cancelled
  case message(String)

  var errorDescription: String? {
    switch self {
    case .cancelled: return "Cancelled"
    case .message(let text): return text
    }
  }
}

/// The channel's stdout, parsed as it arrives.
private final class TmuxSinkWriter: Writer {
  private let onData: (DispatchData) -> Void

  init(_ onData: @escaping (DispatchData) -> Void) {
    self.onData = onData
  }

  func write(_ buf: DispatchData, max length: Int) -> AnyPublisher<Int, Error> {
    onData(buf)
    return Just(length).setFailureType(to: Error.self).eraseToAnyPublisher()
  }
}

/// The channel's stdin: command lines, written one after another in the order they were sent.
private final class TmuxLineSource: WriterTo {
  private let subject = PassthroughSubject<DispatchData, Error>()

  func send(_ data: DispatchData) {
    subject.send(data)
  }

  func writeTo(_ w: Writer) -> AnyPublisher<Int, Error> {
    // Buffered: a line sent while the previous one is still being written waits its turn instead of
    // being dropped for lack of demand.
    subject
      .buffer(size: Int.max, prefetch: .keepFull, whenFull: .dropNewest)
      .flatMap(maxPublishers: .max(1)) { data in
        w.write(data, max: data.count)
      }
      .eraseToAnyPublisher()
  }
}
