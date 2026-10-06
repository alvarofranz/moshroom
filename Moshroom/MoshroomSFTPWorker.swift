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

// The plumbing every connection the app opens on the user's behalf shares: the explorer
// (MoshxploreSession), the music tab (MoshifySession) and uploads (MoshdropConnection). Each of
// those keeps its own policy (op queue, slots, warm pool, retries, watchdogs) on top of this.

import Combine
import Foundation

import MoshroomConfig
import MoshroomFiles
import SSH

/// A dedicated thread running a run loop, which is where libssh attaches its socket sources and
/// where every Combine pipeline of one connection runs. Everything a feature keeps about its
/// connection is touched only from blocks handed to `perform`.
///
/// `start`, `perform` and `stop` are called from the main thread (perform also from the worker
/// itself, to hop out of a callback).
final class MoshroomSFTPWorker {

  // Owned by one thread: `stop` ends THAT thread, so a worker started again right after a stop
  // can never be ended by the old thread's stop arriving late.
  private final class Loop {
    var running = true
    var timers: [Timer] = []
  }

  private let name: String
  private var thread: Thread?
  private var runLoopRef: CFRunLoop?
  private var loop: Loop?
  private let ready = DispatchSemaphore(value: 0)

  init(name: String) {
    self.name = name
  }

  /// Start the thread if it is not running. Returns true when this call started it. Blocks until
  /// the worker's run loop is published (sub-millisecond).
  ///
  /// The running thread holds the worker and `owner` (the feature object on top of it), so the
  /// feature outlives every block queued for it until `stop` ends the thread, and its connection
  /// state is released on the worker, never on main.
  @discardableResult
  func start(keepingAlive owner: AnyObject? = nil) -> Bool {
    guard thread == nil else { return false }
    let loop = Loop()
    let t = Thread { [self] in
      withExtendedLifetime(owner) {
        // Keep the run loop alive while libssh attaches its socket source to it.
        let keepAlive = Port()
        RunLoop.current.add(keepAlive, forMode: .default)
        self.runLoopRef = CFRunLoopGetCurrent()
        self.ready.signal()
        while loop.running {
          RunLoop.current.run(mode: .default, before: .distantFuture)
        }
        loop.timers.forEach { $0.invalidate() }
        RunLoop.current.remove(keepAlive, forMode: .default)
      }
    }
    t.name = name
    t.stackSize = 2 << 20
    self.loop = loop
    thread = t
    t.start()
    ready.wait()
    return true
  }

  /// Run `block` on the worker. A no-op once stopped (or before the first start).
  func perform(_ block: @escaping () -> Void) {
    guard let rl = runLoopRef else { return }
    CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, block)
    CFRunLoopWakeUp(rl)
  }

  /// A repeating timer on the worker's run loop, for a watchdog that has to live where the ops run.
  /// It ends with the thread.
  func addRepeatingTimer(every interval: TimeInterval, _ tick: @escaping () -> Void) {
    guard let loop else { return }
    perform {
      let timer = Timer(timeInterval: interval, repeats: true) { _ in tick() }
      RunLoop.current.add(timer, forMode: .default)
      loop.timers.append(timer)
    }
  }

  /// Run `cleanup` on the worker (drop the feature's connection state there), then end the thread.
  /// From the caller's side the worker is stopped at once: later `perform`s are no-ops.
  func stop(_ cleanup: @escaping () -> Void = {}) {
    guard let rl = runLoopRef, let loop else { return }
    CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) {
      cleanup()
      loop.running = false
      CFRunLoopStop(CFRunLoopGetCurrent())
    }
    CFRunLoopWakeUp(rl)
    runLoopRef = nil
    self.loop = nil
    thread = nil
  }

  /// The connect step: resolve a saved alias, dial it and open SFTP, yielding the SFTP root.
  /// Call on the worker (the connection lives on the calling thread's run loop).
  ///
  /// Always HEADLESS: nothing these workers connect has a terminal in front of the user, so a host
  /// that needs an answer (an unknown host key, a password nobody saved) fails with the reason
  /// instead of waiting on a prompt nobody can see (see SSHClientConfigProvider).
  ///
  /// Resolving the alias throws synchronously, so a caller can report a bad alias before it ever
  /// subscribes. `timeout`, when given, bounds the dial and the SFTP handshake together.
  static func connect(alias: String, timeout: TimeInterval? = nil,
                      timeoutError: @escaping () -> Error = { SSHError.connError(msg: "Timed out") })
    throws -> AnyPublisher<Translator, Error> {
    let target = try MoshroomSSH.resolveTarget(hostAlias: alias, device: nil)
    var sftp = SSHClient.dial(target.hostName, with: target.config, withProxy: MoshroomSSH.executeProxyCommand)
      .flatMap { $0.requestSFTP() }
      .tryMap { try SFTPTranslator(on: $0) as Translator }
      .eraseToAnyPublisher()
    if let timeout {
      sftp = sftp
        .timeout(.seconds(timeout), scheduler: RunLoop.current, customError: timeoutError)
        .eraseToAnyPublisher()
    }
    // Every app-side connection (uploads, Files, music) fails through here: leave the reason in the
    // log, since the alert the user saw is gone by the time anyone reads an exported log. The error's
    // own text names the step (connect, auth, host key), never a secret.
    return sftp
      .handleEvents(receiveCompletion: { completion in
        if case .failure(let error) = completion {
          MoshLog.log("ssh", "connection to \(alias) (\(target.hostName)) failed: \(error.localizedDescription)")
        }
      })
      .eraseToAnyPublisher()
  }
}
