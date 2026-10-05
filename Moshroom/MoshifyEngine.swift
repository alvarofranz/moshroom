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

// Moshify's player: the transcoder that makes Opus playable, and the singleton engine (playback,
// the prefetch window, the audio session, lock-screen controls).

import UIKit
import Combine
import AVFoundation
import MediaPlayer

import MoshroomConfig
import MoshroomFiles
import SSH

// MARK: - Transcode

/// Turns a downloaded file the player cannot play into one it can, in place: an AVAssetExportSession
/// to m4a (AAC), which is native everywhere, keeps the size in the same ballpark as the Opus source
/// and leaves seeking and duration working exactly as before. Runs off the SFTP worker so a long
/// export never holds the connection. A failure is REPORTED, and the caller then drops the download
/// too (see MoshifySession.download): the cache never keeps a file the player cannot play, and the
/// track is skipped honestly instead of sitting there looking cached and refusing to start.
/// It runs inside the download's own staging folder, so two transcodes can never touch each other's
/// files and nothing reaches the visible library folder until it is playable.
enum MoshifyTranscoder {

  /// Convert if needed and hand back the file to store. Calls back on the main queue.
  static func prepare(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
    guard Moshify.needsTranscode(url.lastPathComponent) else {
      DispatchQueue.main.async { completion(.success(url)) }
      return
    }
    let output = url.deletingPathExtension().appendingPathExtension("m4a")
    let asset = AVURLAsset(url: url)
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
      DispatchQueue.main.async { completion(.failure(MoshifyError.cannotConvert(url.lastPathComponent))) }
      return
    }
    try? FileManager.default.removeItem(at: output)
    export.outputURL = output
    export.outputFileType = .m4a
    export.exportAsynchronously {
      let fm = FileManager.default
      guard export.status == .completed, fm.fileExists(atPath: output.path) else {
        MoshLog.log("moshify", "transcode failed: \(export.error?.localizedDescription ?? "unknown")")
        try? fm.removeItem(at: output)
        DispatchQueue.main.async { completion(.failure(MoshifyError.cannotConvert(url.lastPathComponent))) }
        return
      }
      // The Opus original has served its purpose; the cache keeps exactly one file per track.
      try? fm.removeItem(at: url)
      MoshLog.log("moshify", "transcoded \(url.pathExtension) → m4a")
      DispatchQueue.main.async { completion(.success(output)) }
    }
  }

  /// The exact length of a local file, read without playing it — so a row shows its duration as soon
  /// as the track is on the device, not only after it has been played once.
  static func duration(of url: URL) -> TimeInterval? {
    guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
    return Double(file.length) / file.fileFormat.sampleRate
  }
}

// MARK: - Engine

// The singleton player. All state mutates on MAIN; the SFTP worker calls back on main. The tab
// page is a thin observer over NotificationCenter — music survives tab switches and the surface
// closing; closing the Moshify TAB calls shutdown() (tab semantics: close = stop).
final class MoshifyEngine: NSObject, AVAudioPlayerDelegate {

  static let shared = MoshifyEngine()

  enum State: Equatable {
    case idle
    case connecting
    case ready
    case downloading(MoshifyTrack, Double)   // a BLOCKING fetch (tap / gap) — never a prefetch
    case playing(MoshifyTrack)
    case paused(MoshifyTrack)
    case error(String)                        // tracks retained so the list still renders

    // The state's SHAPE, download fraction ignored: stateDidChange fires on shape changes only,
    // while fraction ticks ride the throttled progress notification — otherwise every SFTP chunk
    // of a blocking fetch would reload the whole player UI.
    var shape: State {
      if case .downloading(let t, _) = self { return .downloading(t, 0) }
      return self
    }
  }

  private(set) var state: State = .idle {
    didSet {
      guard state.shape != oldValue.shape else { return }
      NotificationCenter.default.post(name: .moshifyStateDidChange, object: nil)
    }
  }

  /// Which music tab the engine currently belongs to. There is ONE audio pipeline in the app, so
  /// there is one owner: starting a library in another tab takes it over and stops what was
  /// playing. nil means nobody has claimed it this run (a fresh launch, or the owner tab closed),
  /// and then nothing plays: not a headphone button, not a media key.
  private(set) var ownerKey: UUID?

  private(set) var tracks: [MoshifyTrack] = []
  private(set) var currentTrack: MoshifyTrack?

  var shuffle: Bool {
    get { UserDefaults.standard.bool(forKey: Moshify.shuffleKey) }
    set {
      // Remembered across launches, and OFF until the user asks for it (a bare UserDefaults bool
      // starts false — nothing here or anywhere else turns it on by itself).
      UserDefaults.standard.set(newValue, forKey: Moshify.shuffleKey)
      MoshLog.log("moshify", "shuffle \(newValue ? "on" : "off")")
      bag.removeAll()
      upcoming = []   // the other mode's window means nothing to this one
      rebuildUpcoming()
      NotificationCenter.default.post(name: .moshifyStateDidChange, object: nil)
    }
  }

  var elapsed: TimeInterval { player?.currentTime ?? 0 }
  var duration: TimeInterval { player?.duration ?? 0 }

  var currentIndex: Int? { currentTrack.flatMap { t in tracks.firstIndex(of: t) } }

  // Replaced on shutdown: the old worker winds down on its own object, so it can never clear the
  // queue of the one that replaces it.
  private var session = MoshifySession()
  private var cache: MoshifyCache { .shared }
  private var player: AVAudioPlayer?
  private var intendsToPlay = false
  /// An audio interruption (a call, Siri) is under way: nothing starts playing until it ends.
  private var interrupted = false
  private var upcoming: [MoshifyTrack] = []
  private var bag: [String] = []            // shuffle bag of cacheKeys — no repeats until dry
  private var consecutiveFailures = 0
  private var gapTask: UIBackgroundTaskIdentifier = .invalid
  private var remoteTargets: [(command: MPRemoteCommand, target: Any)] = []
  private var audioSessionConfigured = false
  private var lastProgressPost = Date.distantPast
  /// Bumped whenever the library changes hands (configure, shutdown): a scan that answers for an
  /// older one is dropped instead of painting the wrong tracks.
  private var libraryGeneration = 0
  /// Tracks whose length is being read off the server right now, so a list that scrolls back and
  /// forth asks once (see ensureDuration).
  private var probing = Set<String>()

  private override init() {
    super.init()
    try? FileManager.default.removeItem(at: Moshify.stagingDirectory)   // stale .part leftovers
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(_interruption(_:)),
                   name: AVAudioSession.interruptionNotification, object: nil)
    nc.addObserver(self, selector: #selector(_routeChange(_:)),
                   name: AVAudioSession.routeChangeNotification, object: nil)
    nc.addObserver(self, selector: #selector(_mediaReset),
                   name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
  }

  // MARK: configuration

  var isConfigured: Bool { Moshify.configuredHost != nil && Moshify.configuredFolder != nil }

  /// Point the engine at a library and hand it to `owner`. Whatever was playing stops: one sound
  /// at a time, by construction.
  func configure(hostAlias: String, folder: String, owner: UUID) {
    let handover = (ownerKey != owner)
    ownerKey = owner
    libraryGeneration += 1
    UserDefaults.standard.set(hostAlias, forKey: Moshify.hostKey)
    UserDefaults.standard.set(folder, forKey: Moshify.folderKey)
    stopPlayback()
    tracks = []
    // Whatever was queued for the last library (its window, its probes, a scan still running) is
    // stale now.
    session.cancelLibraryWork()
    // The cache is global and keeps what it holds: pointing this tab at another library does not
    // throw away the last one's downloads. The budget alone decides what goes, and only by
    // least-recently-played.
    MoshLog.log("moshify", "configured host + folder")
    if handover { NotificationCenter.default.post(name: .moshifyOwnerDidChange, object: nil) }
    refreshLibrary()
  }

  /// What this track lasts, if the file has ever been on the device (see MoshifyCache.noteDuration).
  func duration(of track: MoshifyTrack) -> TimeInterval? { cache.duration(of: track) }

  func refreshLibrary() {
    guard let host = Moshify.configuredHost, let folder = Moshify.configuredFolder else {
      state = .idle
      return
    }
    state = .connecting
    let generation = libraryGeneration
    session.configure(hostAlias: host)
    session.scan(folder: folder) { [weak self] result in
      guard let self, generation == self.libraryGeneration,
            Moshify.configuredHost == host, Moshify.configuredFolder == folder else { return }
      switch result {
      case .success(let scan):
        // Reached it: only now is it worth offering as a recent library.
        Moshify.noteRecent(host: host, folder: folder)
        let found = scan.tracks
        self.tracks = found
        if scan.complete {
          self.cache.purge(notIn: found, host: host, folder: folder)
        } else {
          // What a folder that would not list holds is unknown, not gone: keep its cached tracks.
          MoshLog.log("moshify", "library scan incomplete, cache left as it is")
        }
        if let current = self.currentTrack, !found.contains(current) {
          self.stopPlayback()
        }
        self.state = self.currentTrack.map { self.intendsToPlay ? .playing($0) : .paused($0) } ?? .ready
        self.rebuildUpcoming()
        NotificationCenter.default.post(name: .moshifyLibraryDidChange, object: nil)
        MoshLog.log("moshify", "library scanned: \(found.count) tracks")
      case .failure(let e):
        self.state = .error(Self.message(for: e))
        NotificationCenter.default.post(name: .moshifyLibraryDidChange, object: nil)
        MoshLog.log("moshify", "scan failed: \(type(of: e))")
      }
    }
  }

  func isCached(_ track: MoshifyTrack) -> Bool { cache.isCached(track) }

  // MARK: transport

  func play(at index: Int) {
    guard ownerKey != nil, tracks.indices.contains(index) else { return }
    intendsToPlay = true
    interrupted = false   // the user pressed play: their intent outranks a stale interruption
    consecutiveFailures = 0
    startOrFetch(track: tracks[index])
  }

  func togglePlayPause() {
    guard ownerKey != nil else { return }
    switch state {
    case .playing:
      intendsToPlay = false
      player?.pause()
      if let t = currentTrack { state = .paused(t) }
      updateNowPlaying()
    case .paused:
      intendsToPlay = true
      interrupted = false
      activateAudioSession()
      if player?.play() == true, let t = currentTrack { state = .playing(t) }
      updateNowPlaying()
    case .ready, .idle, .error:
      if tracks.isEmpty {
        // Nothing scanned (a failed connect, a fresh restore): play = try the library again.
        if isConfigured { refreshLibrary() }
        return
      }
      // Nothing loaded yet: start from the top (or the shuffle draw).
      if let first = upcoming.first ?? tracks.first {
        intendsToPlay = true
        interrupted = false
        startOrFetch(track: first)
      }
    case .connecting, .downloading:
      break
    }
  }

  func next() {
    guard ownerKey != nil, !tracks.isEmpty else { return }
    intendsToPlay = true
    // Skipping a track that is still on its way: the window was decided when the last track began
    // and still starts with it, so step past it instead of asking for it again.
    if case .downloading(let t, _) = state { upcoming.removeAll { $0 == t } }
    advance()
  }

  // MARK: delete (exact ordering: advance → unlink → only then forget)

  func deleteTrack(_ track: MoshifyTrack, completion: @escaping (String?) -> Void) {
    if track == currentTrack {
      if tracks.count <= 1 {
        stopPlayback()
        state = .ready
      } else {
        advance()
      }
    }
    session.delete(remotePath: track.remotePath) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        self.cache.remove(track)
        self.tracks.removeAll { $0 == track }
        self.bag.removeAll { $0 == track.cacheKey }
        if self.upcoming.contains(track) { self.rebuildUpcoming() }
        NotificationCenter.default.post(name: .moshifyLibraryDidChange, object: nil)
        MoshLog.log("moshify", "track deleted on server")
        completion(nil)
      case .failure(let e):
        completion(Self.message(for: e))
      }
    }
  }

  // MARK: teardown

  // Closing the Moshify tab stops the music — tab semantics. Config and cache stay for next time.
  func shutdown() {
    ownerKey = nil
    libraryGeneration += 1
    stopPlayback()
    session.stop()
    session = MoshifySession()
    tracks = []
    upcoming = []
    bag = []
    state = .idle
    removeRemoteCommands()
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    if audioSessionConfigured {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      audioSessionConfigured = false
    }
    MoshLog.log("moshify", "engine shut down")
    NotificationCenter.default.post(name: .moshifyOwnerDidChange, object: nil)
  }

  // MARK: playback internals

  private func startOrFetch(track: MoshifyTrack) {
    if let url = cache.localURL(for: track) {
      startPlayback(track: track, url: url)
      return
    }
    // The host owns the folder the bytes land in, so a download cannot start without knowing it.
    guard let host = Moshify.configuredHost else { return }
    state = .downloading(track, 0)
    beginGapTaskIfNeeded()
    session.cancelForFetch(of: track.remotePath)
    let destination = cache.destinationURL(for: track, host: host)
    session.download(track: track, to: destination, priority: .user, progress: { [weak self] frac in
      guard let self, case .downloading(let t, _) = self.state, t == track else { return }
      self.state = .downloading(track, frac)
      self.postProgressThrottled()
    }, completion: { [weak self] result in
      self?.fetchDidFinish(track, host: host, result: result)
    })
  }

  /// A download ended, user or prefetch alike. The file is indexed whatever happened meanwhile, but
  /// it only starts playing if it is still the track the player is waiting for: the user may have
  /// tapped another one, and a late answer must never take the speaker from it.
  private func fetchDidFinish(_ track: MoshifyTrack, host: String, result: Result<URL, Error>) {
    let awaited: Bool = {
      if case .downloading(let t, _) = state { return t == track }
      return false
    }()
    switch result {
    case .success(let url):
      noteLanded(track, at: url, host: host)
      NotificationCenter.default.post(name: .moshifyLibraryDidChange, object: nil)
      if awaited { startPlayback(track: track, url: url) }
    case .failure(let e):
      if case MoshifyError.cancelled = e { return }
      guard awaited else { return }
      endGapTask()
      state = .error(Self.message(for: e))
      MoshLog.log("moshify", "user fetch failed: \(type(of: e))")
    }
  }

  private func startPlayback(track: MoshifyTrack, url: URL) {
    activateAudioSession()
    do {
      let p = try AVAudioPlayer(contentsOf: url)
      p.delegate = self
      player = p
      currentTrack = track
      consecutiveFailures = 0
      // play() answers false when the session cannot start (a call holds it, another app will not
      // mix): then the honest state is paused, with the intent kept so the interruption's end
      // resumes it.
      if intendsToPlay && !interrupted && p.play() {
        state = .playing(track)
      } else {
        if intendsToPlay && !interrupted { MoshLog.log("moshify", "player refused to start") }
        state = .paused(track)
      }
      endGapTask()
      cache.notePlayed(track)
      cache.noteDuration(p.duration, for: track)
      rebuildUpcoming()
      updateNowPlaying()
      installRemoteCommandsIfNeeded()
    } catch {
      // A corrupt file, a purged one, or a format this device cannot decode: evict it and skip on,
      // but never loop forever. The OSStatus goes to the log because "which codec" is exactly what
      // one needs to know here.
      MoshLog.log("moshify", "player init failed (\((error as NSError).code)) for .\(url.pathExtension) — skipping")
      cache.remove(track)
      // The window was built around the track BEFORE this one, so it may well start with this
      // very file: take it out, or advance lands on it again and fetches it once more.
      upcoming.removeAll { $0 == track }
      consecutiveFailures += 1
      if consecutiveFailures >= 3 {
        endGapTask()
        state = .error("Several tracks could not be played. They may be in a format this device cannot decode.")
        return
      }
      advance()
    }
  }

  private func stopPlayback() {
    player?.stop()
    player = nil
    currentTrack = nil
    intendsToPlay = false
    endGapTask()
    upcoming = []
  }

  private func advance() {
    guard !tracks.isEmpty else { return }
    let nextTrack = upcoming.first ?? tracks.first!
    startOrFetch(track: nextTrack)
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    guard intendsToPlay else { return }
    advance()
  }

  // MARK: the prefetch window

  // The next ten tracks, decided when a track starts so prefetch and advance can never disagree.
  // Shuffle draws from the no-repeat bag; sequential walks the list wrapping. Downloads enqueue
  // IN ORDER at prefetch priority — the serial queue fetches them one after another.
  private func rebuildUpcoming() {
    session.cancelPrefetches()
    let previous = upcoming
    upcoming = []
    guard tracks.count > 1, let host = Moshify.configuredHost else { return }
    let want = min(Moshify.prefetchWindow, tracks.count - 1)
    if shuffle {
      var taken = Set<String>()
      if let c = currentTrack { taken.insert(c.cacheKey) }
      // The draw already ahead stays ahead: only the track that just started leaves it, and the
      // bag tops it back up. Redrawing all ten at every song threw nine away unplayed (and their
      // prefetched bytes with them).
      let live = Set(tracks.map { $0.cacheKey })
      for t in previous where upcoming.count < want {
        guard live.contains(t.cacheKey), taken.insert(t.cacheKey).inserted else { continue }
        upcoming.append(t)
      }
      while upcoming.count < want {
        bag.removeAll { taken.contains($0) }
        if bag.isEmpty {
          bag = tracks.map { $0.cacheKey }.filter { !taken.contains($0) }.shuffled()
          if bag.isEmpty { break }
        }
        let key = bag.removeFirst()
        taken.insert(key)
        if let t = tracks.first(where: { $0.cacheKey == key }) { upcoming.append(t) }
      }
    } else {
      let start = (currentIndex ?? -1) + 1
      for i in 0..<want {
        upcoming.append(tracks[(start + i) % tracks.count])
      }
    }

    // Nothing has played yet: the window is decided (play starts from it) but nothing is fetched.
    // Opening a library must not spend the user's data on tracks nobody asked for.
    guard currentTrack != nil else { return }

    // Enqueue the window's missing files in order, respecting the cap: protected = playing +
    // the whole window; a track that cannot fit ends the prefetch run (the cap always wins).
    var protected = Set(upcoming.map { $0.cacheKey })
    if let c = currentTrack { protected.insert(c.cacheKey) }
    var planned: UInt64 = 0
    let cap = Moshify.cacheCapBytes
    for track in upcoming where !cache.isCached(track) {
      guard cache.canFit(incoming: track.size, planned: planned, cap: cap, protected: protected) else {
        MoshLog.log("moshify", "prefetch stopped by cache cap")
        break
      }
      planned += track.size
      let destination = cache.destinationURL(for: track, host: host)
      session.download(track: track, to: destination, priority: .prefetch, progress: { _ in },
                       completion: { [weak self] result in
        self?.fetchDidFinish(track, host: host, result: result)
      })
    }
    evictAroundWindow()
  }

  /// Learn how long a track is WITHOUT having it on the device: a small header read over the SFTP
  /// connection already open (see MoshifySession.probeDuration). Called for the rows the user can
  /// actually see, so a thousand-track library costs nothing until it is looked at, and the answer is
  /// remembered in the index for good.
  func ensureDuration(for track: MoshifyTrack) {
    guard cache.duration(of: track) == nil, !probing.contains(track.cacheKey) else { return }
    probing.insert(track.cacheKey)
    session.probeDuration(track: track) { [weak self] seconds in
      guard let self else { return }
      self.probing.remove(track.cacheKey)
      guard let seconds else { return }
      self.cache.noteDuration(seconds, for: track)
      NotificationCenter.default.post(name: .moshifyLibraryDidChange, object: nil)
    }
  }

  /// A track's bytes are here: index it, learn its length, and hold the budget. The same three steps
  /// whether the user tapped it or the prefetch window brought it in.
  private func noteLanded(_ track: MoshifyTrack, at url: URL, host: String) {
    cache.noteDownloaded(track, at: url, host: host)
    noteDurationOfLocalFile(at: url, for: track)
    evictAroundWindow()
  }

  /// Read a landed file's length off the disk (no playback needed) and remember it, so the row shows
  /// "0:03 · 11 KB" the moment the track is on the device. Off the main thread — opening a file to
  /// read its length is cheap but not free.
  private func noteDurationOfLocalFile(at url: URL, for track: MoshifyTrack) {
    guard cache.duration(of: track) == nil else { return }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let seconds = MoshifyTranscoder.duration(of: url) else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        self.cache.noteDuration(seconds, for: track)
        NotificationCenter.default.post(name: .moshifyLibraryDidChange, object: nil)
      }
    }
  }

  private func evictAroundWindow() {
    var protected = Set(upcoming.map { $0.cacheKey })
    if let c = currentTrack { protected.insert(c.cacheKey) }
    if case .downloading(let t, _) = state { protected.insert(t.cacheKey) }
    cache.evict(toFit: Moshify.cacheCapBytes, protected: protected)
  }

  private func postProgressThrottled() {
    let now = Date()
    guard now.timeIntervalSince(lastProgressPost) > 0.1 else { return }
    lastProgressPost = now
    NotificationCenter.default.post(name: .moshifyProgressDidChange, object: nil)
  }

  // MARK: audio session + interruptions

  private func activateAudioSession() {
    let s = AVAudioSession.sharedInstance()
    if !audioSessionConfigured {
      try? s.setCategory(.playback, mode: .default)
      audioSessionConfigured = true
    }
    try? s.setActive(true)
  }

  @objc private func _interruption(_ note: Notification) {
    guard let info = note.userInfo,
          let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    switch type {
    case .began:
      // An "ended" is not guaranteed to follow, which is why any explicit play clears this too.
      interrupted = true
      if case .playing(let t) = state {
        player?.pause()
        state = .paused(t)
        updateNowPlaying()
      }
    case .ended:
      interrupted = false
      let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
      if opts.contains(.shouldResume), intendsToPlay, case .paused(let t) = state {
        activateAudioSession()
        if player?.play() == true { state = .playing(t) }
        updateNowPlaying()
      }
    @unknown default:
      break
    }
  }

  @objc private func _routeChange(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
          reason == .oldDeviceUnavailable else { return }
    // The classic headphones-unplugged: pause, never blast the speaker.
    DispatchQueue.main.async { [weak self] in
      guard let self, case .playing(let t) = self.state else { return }
      self.intendsToPlay = false
      self.player?.pause()
      self.state = .paused(t)
      self.updateNowPlaying()
    }
  }

  @objc private func _mediaReset() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.audioSessionConfigured = false
      guard let track = self.currentTrack, let url = self.cache.localURL(for: track) else { return }
      let position = self.player?.currentTime ?? 0
      self.player = try? AVAudioPlayer(contentsOf: url)
      self.player?.delegate = self
      self.player?.currentTime = position
      self.intendsToPlay = false
      self.state = .paused(track)
      self.updateNowPlaying()
    }
  }

  // MARK: background gap

  // While audio plays the app runs unbounded; the dangerous window is the GAP — a track ends in
  // background with the next one not yet cached. A background task + the still-active audio
  // session buy the download time; if iOS still suspends us, the state stays .downloading and
  // playback resumes when the app is next opened (the op retries over a fresh dial).
  private func beginGapTaskIfNeeded() {
    guard intendsToPlay, gapTask == .invalid else { return }
    gapTask = UIApplication.shared.beginBackgroundTask(withName: "moshify.gap") { [weak self] in
      self?.endGapTask()
    }
  }

  private func endGapTask() {
    guard gapTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(gapTask)
    gapTask = .invalid
  }

  // MARK: lock screen / now playing

  private func installRemoteCommandsIfNeeded() {
    guard remoteTargets.isEmpty else { return }
    let center = MPRemoteCommandCenter.shared()
    func add(_ command: MPRemoteCommand,
             _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
      remoteTargets.append((command, command.addTarget(handler: handler)))
    }
    add(center.playCommand) { [weak self] _ in
      guard let self, case .paused = self.state else { return .commandFailed }
      self.togglePlayPause()
      return .success
    }
    add(center.pauseCommand) { [weak self] _ in
      guard let self, case .playing = self.state else { return .commandFailed }
      self.togglePlayPause()
      return .success
    }
    add(center.togglePlayPauseCommand) { [weak self] _ in
      guard let self, self.ownerKey != nil else { return .commandFailed }
      self.togglePlayPause()
      return .success
    }
    add(center.nextTrackCommand) { [weak self] _ in
      guard let self, self.ownerKey != nil else { return .commandFailed }
      self.next()
      return .success
    }
    // No previous, no seek, no skip: the lock screen must not render controls we don't have.
    center.previousTrackCommand.isEnabled = false
    center.changePlaybackPositionCommand.isEnabled = false
    center.skipForwardCommand.isEnabled = false
    center.skipBackwardCommand.isEnabled = false
    center.seekForwardCommand.isEnabled = false
    center.seekBackwardCommand.isEnabled = false
  }

  /// The music tab closed: a headphone button or a media key must not wake a library nobody owns.
  private func removeRemoteCommands() {
    remoteTargets.forEach { $0.command.removeTarget($0.target) }
    remoteTargets = []
  }

  private func updateNowPlaying() {
    guard let track = currentTrack else {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      return
    }
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: track.title,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]
    if let p = player {
      info[MPMediaItemPropertyPlaybackDuration] = p.duration
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p.currentTime
      info[MPNowPlayingInfoPropertyPlaybackRate] = p.isPlaying ? 1.0 : 0.0
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private static func message(for error: Error) -> String {
    if case let FileError.Fail(msg) = error { return msg }
    return error.localizedDescription
  }
}
