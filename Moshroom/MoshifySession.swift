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

// Moshify's SFTP worker: one connection on its own run-loop thread, a serial op queue with
// priorities, retry and a watchdog, and the library scan.

import Foundation
import Combine

import MoshroomConfig
import MoshroomFiles
import SSH

// MARK: - SFTP worker

// The Moshify SFTP session: the shared run-loop-thread worker (MoshroomSFTPWorker), with a REAL
// op queue on top: one self-contained op at a time (SFTP over one channel is serial anyway), user
// ops jumping ahead of prefetches, one lazy redial retry for idempotent ops. This is what lets a
// ten-deep prefetch window coexist with "the user just tapped an uncached track". A watchdog on
// the same run loop catches the op that never answers (a half-open connection after sleep errors
// only after many minutes) and sends it down the same redial retry.
//
// Always HEADLESS: there is no terminal in front of the user for anything Moshify connects, so a
// prompt (an unknown host key, a password nobody saved) fails with a reason instead of waiting on
// a terminal tab that may be hidden.
final class MoshifySession {

  enum Priority { case user, prefetch }

  /// What an op hands back while it runs. `done` reports the outcome. `alive` is a sign of life (a
  /// chunk arrived, a folder listed) that holds the watchdog off. `landing` says the network part is
  /// over and what remains is local work (move, transcode) that no connection can stall.
  private final class OpContext {
    let attempt: Int
    let done: (Error?) -> Void
    let alive: () -> Void
    let landing: () -> Void

    init(attempt: Int, done: @escaping (Error?) -> Void, alive: @escaping () -> Void,
         landing: @escaping () -> Void) {
      self.attempt = attempt
      self.done = done
      self.alive = alive
      self.landing = landing
    }
  }

  private final class Op {
    enum Kind { case scan, download, probe, delete }

    let kind: Kind
    let priority: Priority
    let retryOnReconnect: Bool
    let remotePath: String?    // downloads carry it for dedupe/cancel; scans and deletes vary
    let describe: String
    var attempts = 0
    // Worker-thread only: the watchdog's view of the op.
    var lastActivity = Date()
    var localWork = false
    // Builds the pipeline against the connected root. MUST deliver user-facing SUCCESS itself
    // (hopping to main), then report to `done`. On failure it reports ONLY to `done`; the
    // session decides between a redial retry and delivering `deliverFailure`.
    let make: (Translator, OpContext) -> AnyCancellable
    let deliverFailure: (Error) -> Void

    init(kind: Kind, priority: Priority, retryOnReconnect: Bool, remotePath: String?, describe: String,
         make: @escaping (Translator, OpContext) -> AnyCancellable,
         deliverFailure: @escaping (Error) -> Void) {
      self.kind = kind
      self.priority = priority
      self.retryOnReconnect = retryOnReconnect
      self.remotePath = remotePath
      self.describe = describe
      self.make = make
      self.deliverFailure = deliverFailure
    }
  }

  /// How long an op may go without a sign of life before the connection under it is presumed dead.
  private static let stallLimit: TimeInterval = 45
  private static let watchdogInterval: TimeInterval = 10

  private let worker = MoshroomSFTPWorker(name: "moshify.sftp")

  // Worker-thread state.
  private var pending: [Op] = []
  private var activeOp: Op?
  private var activeC: AnyCancellable?
  private var dialC: AnyCancellable?
  private var root: Translator?
  private var hostAlias: String?

  // MARK: worker plumbing (the shared worker, plus the watchdog on its run loop)

  private func start() {
    guard worker.start(keepingAlive: self) else { return }
    worker.addRepeatingTimer(every: Self.watchdogInterval) { [weak self] in
      self?.checkWatchdog()
    }
  }

  private func onWorker(_ block: @escaping () -> Void) {
    worker.perform(block)
  }

  // MARK: public API (call on main; completions on main)

  func configure(hostAlias: String) {
    start()
    onWorker { [weak self] in
      guard let self else { return }
      if self.hostAlias != hostAlias {
        self.root = nil   // different host: the old connection is meaningless
      }
      self.hostAlias = hostAlias
    }
  }

  /// What a scan found, and whether every folder in it could be read. An incomplete scan is still
  /// worth showing, but it says nothing about the folders it missed (see MoshifyCache.purge).
  struct ScanResult {
    let tracks: [MoshifyTrack]
    let complete: Bool
  }

  // Recursive scan of the library folder for audio files, depth-capped, dotfiles skipped,
  // symlinks resolved (see listRecursive), one directory at a time.
  func scan(folder: String, completion: @escaping (Result<ScanResult, Error>) -> Void) {
    start()
    enqueue(Op(kind: .scan, priority: .user, retryOnReconnect: true, remotePath: nil, describe: "scan",
               make: { root, ctx in
      let state = ScanState(alive: ctx.alive)
      return Self.listRecursive(root: root, base: folder, depth: Moshify.scanDepth, state: state)
        .sink(receiveCompletion: { c in
          if case .failure(let e) = c { ctx.done(e) }
        }, receiveValue: { tracks in
          // A folder that would not list may have been the connection: one more go over a fresh
          // dial, and after that the library is what could be read.
          if state.incomplete && ctx.attempt == 0 {
            ctx.done(MoshifyError.scanIncomplete)
            return
          }
          let sorted = tracks.sorted { $0.remotePath.localizedCaseInsensitiveCompare($1.remotePath) == .orderedAscending }
          let result = ScanResult(tracks: sorted, complete: !state.incomplete)
          DispatchQueue.main.async { completion(.success(result)) }
          ctx.done(nil)
        })
    }, deliverFailure: { e in completion(.failure(e)) }))
  }

  // One file, staged in its own folder under Caches and MOVED onto `destination` only when it is
  // complete and playable: a cancelled or failed transfer can never poison the visible library
  // folder. The op stays the active one until the file has LANDED (transcode included), so the
  // dedupe below sees a track that is still converting.
  func download(track: MoshifyTrack, to destination: URL, priority: Priority,
                progress: @escaping (Double) -> Void,
                completion: @escaping (Result<URL, Error>) -> Void) {
    start()
    onWorker { [weak self] in
      guard let self else { return }
      // Dedupe: the same file queued or running is a no-op (the window rebuild re-asks).
      let same: (Op) -> Bool = { $0.kind == .download && $0.remotePath == track.remotePath }
      if let active = self.activeOp, same(active) { return }
      if self.pending.contains(where: same) { return }

      let op = Op(kind: .download, priority: priority, retryOnReconnect: true,
                  remotePath: track.remotePath, describe: "download \(priority)",
                  make: { root, ctx in
        let staging = Moshify.makeStagingDirectory()
        let localDir = MoshroomFiles.Local().walkTo(staging.path)
        let remote = root.cloneWalkTo(track.remotePath)
        var sent: UInt64 = 0
        return Publishers.Zip(localDir, remote)
          .flatMap { ldir, rfile in
            ldir.copy(from: [rfile], args: CopyArguments(preserve: CopyAttributesFlag([]), checkTimes: false))
          }
          .handleEvents(receiveCancel: { try? FileManager.default.removeItem(at: staging) })
          .sink(receiveCompletion: { c in
            switch c {
            case .finished:
              ctx.landing()
              Self.land(track: track, staging: staging, destination: destination) { outcome in
                switch outcome {
                case .landed(let url):
                  completion(.success(url))
                  ctx.done(nil)
                case .unplayable(let error):
                  // Not the connection's fault: a redial would fetch the same unplayable bytes.
                  completion(.failure(error))
                  ctx.done(nil)
                case .failed(let error):
                  ctx.done(error)
                }
              }
            case .failure(let e):
              try? FileManager.default.removeItem(at: staging)
              ctx.done(e)
            }
          }, receiveValue: { info in
            ctx.alive()
            guard info.size > 0 else { return }
            sent += info.written
            let frac = min(1.0, Double(sent) / Double(info.size))
            DispatchQueue.main.async { progress(frac) }
          })
      }, deliverFailure: { e in completion(.failure(e)) })

      self.pending.append(op)
      self.pump()
    }
  }

  private enum Landing {
    case landed(URL)
    case unplayable(Error)
    case failed(Error)
  }

  /// The bytes are in `staging`: make them playable and put them where the library keeps them.
  /// The file is taken for what it is, the one file in the folder, because a linked track arrives
  /// under its TARGET's name, not the link's. Calls back on main.
  private static func land(track: MoshifyTrack, staging: URL, destination: URL,
                           completion: @escaping (Landing) -> Void) {
    let fm = FileManager.default
    func fail(_ outcome: Landing) {
      try? fm.removeItem(at: staging)
      DispatchQueue.main.async { completion(outcome) }
    }
    let files = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
    guard let arrived = files.first(where: {
      (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }) else {
      fail(.failed(MoshifyError.downloadMissing))
      return
    }
    // Named after the track, so the transcoder decides by the track's own extension.
    let named = staging.appendingPathComponent(track.fileName)
    if arrived.lastPathComponent != track.fileName {
      do { try fm.moveItem(at: arrived, to: named) } catch { fail(.failed(error)); return }
    }
    MoshifyTranscoder.prepare(named) { result in
      switch result {
      case .failure(let error):
        try? fm.removeItem(at: staging)
        completion(.unplayable(error))
      case .success(let playable):
        do {
          try? fm.removeItem(at: destination)
          try fm.moveItem(at: playable, to: destination)
          try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                ofItemAtPath: destination.path)
          try? fm.removeItem(at: staging)
          completion(.landed(destination))
        } catch {
          try? fm.removeItem(at: staging)
          completion(.failed(error))
        }
      }
    }
  }

  /// How long is this track? Reads the FIRST 32 KB of the remote file (and, for the layouts that
  /// keep the answer elsewhere, the LAST 64 KB or the frames behind an oversized MP3 tag) and parses
  /// the container on the device; see MoshifyAudioHeader. Nothing is installed on the server and
  /// nothing is downloaded whole: a listing gives a name, a size and a date, and the length lives
  /// inside the bytes. The remote file is always closed again.
  ///
  /// Runs at PREFETCH priority so a user tap always jumps ahead of it, and answers nil rather than
  /// guessing when the bytes do not state a length.
  func probeDuration(track: MoshifyTrack, completion: @escaping (TimeInterval?) -> Void) {
    start()
    enqueue(Op(kind: .probe, priority: .prefetch, retryOnReconnect: false, remotePath: nil, describe: "probe",
               make: { root, ctx in
      root.cloneWalkTo(track.remotePath)
        .flatMap { $0.open(flags: O_RDONLY) }
        .flatMap { file -> AnyPublisher<TimeInterval?, Error> in
          Self.measure(file: file, track: track)
            // A probe is a nicety: a file that will not read or parse just keeps no length.
            .replaceError(with: nil)
            .flatMap { seconds in
              file.close().map { _ in seconds }.replaceError(with: seconds)
            }
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
        }
        .sink(receiveCompletion: { c in
          if case .failure = c {
            DispatchQueue.main.async { completion(nil) }
            ctx.done(nil)
          }
        }, receiveValue: { seconds in
          DispatchQueue.main.async { completion(seconds) }
          ctx.done(nil)
        })
    }, deliverFailure: { _ in completion(nil) }))
  }

  private static let probeHeadBytes = 32 * 1024
  private static let probeTailBytes = 64 * 1024

  /// The reads behind probeDuration, against a file that is already open.
  private static func measure(file: MoshroomFiles.File,
                              track: MoshifyTrack) -> AnyPublisher<TimeInterval?, Error> {
    readUpTo(probeHeadBytes, from: file)
      .flatMap { head -> AnyPublisher<TimeInterval?, Error> in
        let fromHead = MoshifyAudioHeader.duration(head: head, fileName: track.fileName,
                                                   totalSize: track.size)
        let answer = Just(fromHead).setFailureType(to: Error.self).eraseToAnyPublisher()
        guard fromHead == nil, let sftpFile = file as? SFTPFile else { return answer }

        if MoshifyAudioHeader.wantsTail(fileName: track.fileName, headAnswer: fromHead),
           track.size > UInt64(probeHeadBytes) {
          let offset = track.size > UInt64(probeTailBytes) ? track.size - UInt64(probeTailBytes) : 0
          return sftpFile.seek(to: offset)
            .flatMap { _ in readUpTo(probeTailBytes, from: sftpFile) }
            .map { tail in
              MoshifyAudioHeader.duration(head: head, tail: tail,
                                          fileName: track.fileName, totalSize: track.size)
            }
            .eraseToAnyPublisher()
        }
        if let offset = MoshifyAudioHeader.audioOffset(head: head, fileName: track.fileName),
           offset < track.size {
          return sftpFile.seek(to: offset)
            .flatMap { _ in readUpTo(probeHeadBytes, from: sftpFile) }
            .map { frames in
              MoshifyAudioHeader.duration(frames: frames, at: offset,
                                          fileName: track.fileName, totalSize: track.size)
            }
            .eraseToAnyPublisher()
        }
        return answer
      }
      .eraseToAnyPublisher()
  }

  /// At most `length` bytes from the file's current position, gathered across however many chunks
  /// they arrive in (fewer at the end of the file). Stops asking once it has enough, so it is also
  /// correct against a reader that would go on to the end.
  private static func readUpTo(_ length: Int, from file: MoshroomFiles.Reader) -> AnyPublisher<Data, Error> {
    var got = 0
    return file.read(max: length)
      .prefix(while: { chunk in
        defer { got += chunk.count }
        return got < length
      })
      .reduce(Data()) { $0 + Data($1) }
      .map { $0.count > length ? $0.prefix(length) : $0 }
      .eraseToAnyPublisher()
  }

  // Deletes NEVER auto-retry: a half-applied unlink is ambiguous.
  func delete(remotePath: String, completion: @escaping (Result<Void, Error>) -> Void) {
    start()
    enqueue(Op(kind: .delete, priority: .user, retryOnReconnect: false, remotePath: remotePath, describe: "delete",
               make: { root, ctx in
      root.cloneWalkTo(remotePath)
        .flatMap { $0.remove() }
        .sink(receiveCompletion: { c in
          if case .failure(let e) = c { ctx.done(e) }
        }, receiveValue: { _ in
          DispatchQueue.main.async { completion(.success(())) }
          ctx.done(nil)
        })
    }, deliverFailure: { e in completion(.failure(e)) }))
  }

  // The engine rebuilt its window: every queued prefetch is stale (it re-enqueues what it wants).
  func cancelPrefetches() {
    cancel { $0.priority == .prefetch }
  }

  /// A blocking fetch of `remotePath` is starting: prefetches go, and so does any OTHER track's
  /// download the user has already moved on from.
  func cancelForFetch(of remotePath: String) {
    cancel { $0.priority == .prefetch || ($0.kind == .download && $0.remotePath != remotePath) }
  }

  /// The engine switched library: whatever was queued for the old one goes. Deletes stay, because
  /// the user asked for them.
  func cancelLibraryWork() {
    cancel { $0.kind != .delete }
  }

  func stop() {
    worker.stop { [weak self] in
      guard let self else { return }
      var dropped = self.pending
      if let active = self.activeOp { dropped.append(active) }
      self.pending.removeAll()
      self.activeC = nil
      self.activeOp = nil
      self.dialC = nil
      self.root = nil
      self.hostAlias = nil
      Self.deliverCancelled(dropped)
    }
  }

  // MARK: queue internals (worker thread only)

  private func enqueue(_ op: Op) {
    onWorker { [weak self] in
      self?.pending.append(op)
      self?.pump()
    }
  }

  /// Drop queued and running ops matching `drop`, telling each one it was cancelled (its caller may
  /// be keeping a note, like the engine's probing set). An op already landing its file is left to
  /// finish: the bytes are here, and cutting it off now would only throw them away.
  private func cancel(where drop: @escaping (Op) -> Bool) {
    onWorker { [weak self] in
      guard let self else { return }
      var dropped = self.pending.filter(drop)
      self.pending.removeAll(where: drop)
      if let active = self.activeOp, !active.localWork, drop(active) {
        self.activeC = nil
        self.activeOp = nil
        dropped.append(active)
      }
      Self.deliverCancelled(dropped)
      self.pump()
    }
  }

  private static func deliverCancelled(_ ops: [Op]) {
    guard !ops.isEmpty else { return }
    DispatchQueue.main.async { ops.forEach { $0.deliverFailure(MoshifyError.cancelled) } }
  }

  private func pump() {
    guard activeOp == nil, dialC == nil, !pending.isEmpty else { return }
    guard let root else { dial(); return }
    let idx = pending.firstIndex { $0.priority == .user } ?? 0
    let op = pending.remove(at: idx)
    op.lastActivity = Date()
    op.localWork = false
    activeOp = op
    let ctx = OpContext(
      attempt: op.attempts,
      done: { [weak self] error in self?.onWorker { self?.finish(op: op, error: error) } },
      alive: { [weak self, weak op] in self?.onWorker { op?.lastActivity = Date() } },
      landing: { [weak self, weak op] in self?.onWorker { op?.localWork = true } })
    activeC = op.make(root, ctx)
  }

  private func finish(op: Op, error: Error?) {
    guard activeOp === op else { return }   // preempted/cancelled ops report into the void
    activeOp = nil
    activeC = nil
    if let error {
      if op.retryOnReconnect, op.attempts == 0 {
        // Lazy reconnect: drop the (possibly stale) connection and run the op once more through
        // a fresh dial — this heals server-side idle timeouts after a suspension.
        op.attempts += 1
        root = nil
        pending.insert(op, at: 0)
        MoshLog.log("moshify", "op \(op.describe) failed, retrying over a fresh dial")
      } else {
        DispatchQueue.main.async { op.deliverFailure(error) }
      }
    }
    pump()
  }

  /// A running op with no sign of life for `stallLimit` is presumed to sit on a dead connection
  /// (nothing else would ever end it): drop the connection and let `finish` decide, which means
  /// one retry over a fresh dial for the ops that allow it.
  private func checkWatchdog() {
    guard let op = activeOp, !op.localWork,
          Date().timeIntervalSince(op.lastActivity) > Self.stallLimit else { return }
    MoshLog.log("moshify", "op \(op.describe) stalled, dropping the connection")
    activeC = nil
    root = nil
    finish(op: op, error: MoshifyError.timeout)
  }

  private func dial() {
    guard dialC == nil else { return }
    guard let alias = hostAlias else { failAll(MoshifyError.notConfigured); return }
    // Headless on purpose (see MoshroomSFTPWorker.connect): saved keys and saved passwords work,
    // anything that needs an answer fails with a reason.
    let sftp: AnyPublisher<Translator, Error>
    do {
      sftp = try MoshroomSFTPWorker.connect(alias: alias, timeout: 30, timeoutError: { MoshifyError.timeout })
    } catch {
      failAll(error)
      return
    }
    MoshLog.log("moshify", "dialing \(alias)")
    dialC = sftp
      .sink(receiveCompletion: { [weak self] c in
        guard let self else { return }
        self.dialC = nil
        if case .failure(let e) = c { self.failAll(e) }
      }, receiveValue: { [weak self] translator in
        guard let self else { return }
        self.dialC = nil
        self.root = translator
        self.pump()
      })
  }

  // A failed dial fails every queued op honestly — an unreachable host must not loop.
  private func failAll(_ error: Error) {
    let ops = pending
    pending.removeAll()
    DispatchQueue.main.async { ops.forEach { $0.deliverFailure(error) } }
  }

  /// One scan's bookkeeping, touched only from the SFTP worker thread (every op there is serial).
  /// `canonical` holds every directory walked, by CANONICAL path, so a folder reached twice (a link
  /// pointing back up the tree, or a link and the real folder both in the library) is walked once.
  /// `incomplete` records that some folder could not be read.
  private final class ScanState {
    var canonical = Set<String>()
    var incomplete = false
    let alive: () -> Void
    init(alive: @escaping () -> Void) { self.alive = alive }
  }

  // A depth-capped, serial walk over the library folder. Skips dotfiles and any name containing "/"
  // (the sweepRemote leaf-safety trick). A symlink is RESOLVED before it is judged, through the one
  // shared rule (Translator.moshroomStatFollowingLinks): a linked track plays, a linked album folder
  // is walked like any other but through its canonical path and only once, and a broken link is
  // skipped. A subfolder that will not list is skipped too (and noted), never the whole library.
  private static func listRecursive(root: Translator, base: String, depth: Int,
                                    state: ScanState) -> AnyPublisher<[MoshifyTrack], Error> {
    let none = Just([MoshifyTrack]()).setFailureType(to: Error.self).eraseToAnyPublisher()
    return root.cloneWalkTo(base)
      .flatMap { dir -> AnyPublisher<[FileAttributes], Error> in
        guard state.canonical.insert(dir.current).inserted else {
          return Just([]).setFailureType(to: Error.self).eraseToAnyPublisher()
        }
        return dir.directoryFilesAndAttributes()
      }
      .flatMap { rows -> AnyPublisher<[MoshifyTrack], Error> in
        state.alive()
        var tracks: [MoshifyTrack] = []
        var subdirs: [String] = []
        var links: [String] = []
        for attrs in rows {
          guard let name = attrs[.name] as? String, !name.isEmpty,
                name != ".", name != "..",
                !name.hasPrefix("."), !name.contains("/") else { continue }
          let type = attrs[.type] as? FileAttributeType
          if type == .typeSymbolicLink {
            links.append(name)
            continue
          }
          if type == .typeDirectory {
            if depth > 0 { subdirs.append(name) }
            continue
          }
          guard type == .typeRegular else { continue }
          let ext = (name as NSString).pathExtension.lowercased()
          guard Moshify.audioExtensions.contains(ext) else { continue }
          let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
          tracks.append(MoshifyTrack(remotePath: base + "/" + name, fileName: name, size: size))
        }

        var branches: [AnyPublisher<[MoshifyTrack], Error>] = subdirs.map { sub in
          listRecursive(root: root, base: base + "/" + sub, depth: depth - 1, state: state)
            .catch { _ -> AnyPublisher<[MoshifyTrack], Error> in
              state.incomplete = true
              return none
            }
            .eraseToAnyPublisher()
        }
        branches += links.map { name in
          Self.linkBranch(root: root, base: base, name: name, depth: depth, state: state)
        }
        guard !branches.isEmpty else {
          return Just(tracks).setFailureType(to: Error.self).eraseToAnyPublisher()
        }
        return Publishers.Sequence(sequence: branches)
          .flatMap(maxPublishers: .max(1)) { $0 }
          .collect()
          .map { tracks + $0.flatMap { $0 } }
          .eraseToAnyPublisher()
      }
      .eraseToAnyPublisher()
  }

  /// One symlink, resolved: a track if it points at audio, a walk if it points at a folder nobody has
  /// walked yet, nothing at all if it is broken. A link that cannot be read is not a scan failure,
  /// but it does make the scan incomplete.
  private static func linkBranch(root: Translator, base: String, name: String, depth: Int,
                                 state: ScanState) -> AnyPublisher<[MoshifyTrack], Error> {
    let none = Just([MoshifyTrack]()).setFailureType(to: Error.self).eraseToAnyPublisher()
    return root.moshroomStatFollowingLinks(child: name, in: base)
      .flatMap { attrs -> AnyPublisher<[MoshifyTrack], Error> in
        guard let attrs, let type = attrs[.type] as? FileAttributeType else { return none }
        if type == .typeDirectory {
          guard depth > 0 else { return none }
          return root.cloneWalkTo(base + "/" + name)
            .flatMap { target -> AnyPublisher<[MoshifyTrack], Error> in
              // listRecursive claims the canonical path itself; this only saves the walk.
              guard !state.canonical.contains(target.current) else { return none }
              return listRecursive(root: root, base: target.current, depth: depth - 1, state: state)
            }
            .eraseToAnyPublisher()
        }
        guard type == .typeRegular,
              Moshify.audioExtensions.contains((name as NSString).pathExtension.lowercased())
        else { return none }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        return Just([MoshifyTrack(remotePath: base + "/" + name, fileName: name, size: size)])
          .setFailureType(to: Error.self)
          .eraseToAnyPublisher()
      }
      .catch { _ -> AnyPublisher<[MoshifyTrack], Error> in
        state.incomplete = true
        return none
      }
      .eraseToAnyPublisher()
  }
}
