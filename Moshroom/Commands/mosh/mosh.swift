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

import Combine
import Dispatch

import SSH
import ios_system

enum MoshError: Error, LocalizedError {
  case NoBinaryAvailable
  case UserCancelled
  case NoMoshServerArgs
  case NoRemoteServerIP
  case AddressInfo(String)
  case MissingArguments(String)

  public var errorDescription: String? {
    switch self {
    case .NoBinaryAvailable:
      return "Could not find a mosh-server on the remote."
    case .UserCancelled:
      return "User cancelled the operation"
    case .NoMoshServerArgs:
      return "Did not find mosh server startup message. (Have you installed mosh on your server?)"
    case .NoRemoteServerIP:
      return "Bad Mosh SSH_CONNECTION String."
    case .AddressInfo(let error):
      return "Address resolution failed - \(error)"
    case .MissingArguments(let message):
      return "\(message)"
    }
  }
}

@objc public class MoshroomMosh: Session {
  var exitCode: Int32 = 0
  var sshCancellable: AnyCancellable? = nil
  var proxyCancellable: AnyCancellable? = nil
  var proxyStream: SSH.Stream? = nil
  var currentRunLoop: RunLoop!
  var stdin: InputStream!
  var stdout: OutputStream!
  var stderr: OutputStream!
  var isVerbose: Bool = false
  private var initialMoshParams: MoshParams? = nil
  private let mcpSession: MCPSession
  // Signalled by onStateEncoded. One per client: a client parks at most once.
  private let parkAnswered = DispatchSemaphore(value: 0)
  private let escapeKey: String
  private var logger: MoshLogger! = nil
  var isRunloopRunning = false
  // True while this client is inside mosh_main: the only time it can checkpoint, repaint, or be
  // signalled (before, it is still bootstrapping over SSH; after, its thread is gone).
  private var isClientRunning = false
  /// This client checkpointed its state: it PARKED (stepped off the network so a later client can
  /// continue from that checkpoint), it did not end. A checkpoint is always a client's last act, so
  /// this is exact. MCPSession reads it once the client's thread has been joined.
  @objc private(set) var moshroomParked = false
  // The tab was closed before this client got going: it must never start.
  private var killRequested = false
  // Guards "the client is alive, so act on it" against the client leaving at that same moment: its
  // thread (and the pthread_t that names it) is only guaranteed to exist while isClientRunning is
  // true and it has not parked, and both only change under this lock.
  private let clientLock = NSLock()
  // The host's "Command on connect", captured on a fresh connect (never on a restore).
  private var pendingCommandOnConnect: String? = nil
  let stateCallback: mosh_state_callback = { (context, buffer, size) in
    guard let buffer = buffer, let context = context else {
      return
    }
    let data = Data(bytes: buffer, count: size)
    let session = Unmanaged<MoshroomMosh>.fromOpaque(context).takeUnretainedValue()
    session.onStateEncoded(data)
  }

  @objc init!(mcpSession: MCPSession, device: TermDevice!, andParams params: MoshParams!) {
    // The escape the client itself will listen for (it reads the same variable): a single
    // character it accepts, "" when the user switched the escape off, else its default Ctrl-^.
    let env = ProcessInfo.processInfo.environment["MOSH_ESCAPE_KEY"]
    if let env, env.count == 1, let v = env.unicodeScalars.first?.value,
       v > 0, v < 128, ![0x03, 0x04, 0x0a, 0x0c, 0x0d].contains(v) {
      self.escapeKey = env
    } else if env == "" {
      self.escapeKey = ""
    } else {
      self.escapeKey = "\u{1e}"
    }
    self.mcpSession = mcpSession

    super.init(device: device, andParams: params)

    self.stdin = InputStream(file: stream.in)
    self.stdout = OutputStream(file: stream.out)
    self.stderr = OutputStream(file: stream.err)
  }

  @objc public override func main(_ argc: Int32, argv: Argv) -> Int32 {

    mcpSession.setActiveSession()
    self.currentRunLoop = RunLoop.current
    // In ObjC, sessionParams is a covariable for MoshParams.
    // In Swift we need to cast.
    if let initialMoshParams = self.sessionParams as? MoshParams,
       initialMoshParams.hasEncodedState() {
      return moshMain(initialMoshParams)
    } else {
      let command: MoshCommand
      do {
        command = try MoshCommand.parse(Array(argv.args(count: argc)[1...]))
      } catch {
        let message = MoshCommand.message(for: error)
        return die(message: message)
      }
      self.isVerbose = command.verbose
      self.logger = MoshLogger(output: self.stderr, logLevel: command.verbose ? .info : .error)

      let moshParams: MoshParams
      do {
        moshParams = try startMoshServer(using: command)
        self.copyToSession(moshParams: moshParams)
      } catch {
        return die(message: "\(error) - \(error.localizedDescription)")
      }

      // Fresh connect only (the restore branch above returns early) — remember the host's command.
      self.pendingCommandOnConnect = MoshHosts.withHost(command.hostAlias)?.commandOnConnect
      return moshMain(moshParams)
    }
  }

  func startMoshServer(using command: MoshCommand) throws -> MoshParams {
    let host: MoshSSHHost
    let config: SSHClientConfig
    let hostName: String
    let log = logger.log("startMoshServer")

    let resolved = try MoshConfig().resolveHost(alias: command.hostAlias, extending: command.bkSSHHost())
    host = resolved.host
    hostName = resolved.hostName
    config = try SSHClientConfigProvider.config(host: host, using: device)

    let moshClientParams = MoshClientParams(extending: command)
    let moshServerParams: MoshServerParams
    if let customKey = command.customKey {
      guard let customUDPPort = moshClientParams.customUDPPort else {
        throw MoshError.MissingArguments("If MOSH_KEY is set, port is required. (-p)")
      }

      // Resolved as part of the host info or explicit on params.
      let remoteIP = hostName
      moshServerParams = MoshServerParams(key: customKey, udpPort: customUDPPort, remoteIP: remoteIP)
      log.info("Manual Mosh server bootstrapped with params \(moshServerParams)")
    } else {
      let moshServerStartupArgs = getMoshServerStartupArgs(udpPort: moshClientParams.customUDPPort,
                                                           colors: nil,
                                                           exec: moshClientParams.remoteExecCommand)

      // Use the mosh-server already installed on the remote.
      let sequence: [MoshBootstrap] = [UseMoshOnPath(path: moshClientParams.server)]

      let pty: SSH.SSHClient.PTY?
      if command.noSshPty {
        pty = nil
      } else {
        pty = SSH.SSHClient.PTY(rows: Int32(self.device.rows), columns: Int32(self.device.cols))
      }

      // Feedback while the SSH bootstrap runs — a mosh connect must never look dead.
      print("Connecting to \(hostName)...", to: &stderr)

      var sshError: Error? = nil
      var _moshServerParams: MoshServerParams? = nil
      let bootstrapRunLoop = CFRunLoopGetCurrent()
      self.sshCancellable = SSHClient.dial(hostName, with: config, withProxy: { [weak self] in
        guard let self = self
        else {
          return
        }
        self.mcpSession.setActiveSession()
        self.executeProxyCommand(command: $0, sockIn: $1, sockOut: $2)
      })
      .flatMap { self.bootstrapMoshServer(on: $0,
                                          sequence: sequence,
                                          experimentalRemoteIP: moshClientParams.experimentalRemoteIP,
                                          family: command.addressFamily,
                                          args: moshServerStartupArgs,
                                          withPTY: pty) }

      .sink(
        receiveCompletion: { completion in
          switch completion {
          case .failure(let error):
            sshError = error
            // Surface the failure right away — do not depend on the teardown path to report it.
            print("Connection failed - \(error)", to: &self.stderr)
          default:
            break
          }
          self.kill()
          // Guarantee the bootstrap runloop exits so startMoshServer can throw/return;
          // cancelling the subscriptions alone does not always wake it.
          CFRunLoopStop(bootstrapRunLoop)
        },
        receiveValue: { params in
          _moshServerParams = params
        })

      self.isRunloopRunning = true
      SSHClient.run()
      self.isRunloopRunning = false

      if let error = sshError {
        throw error
      }

      guard let _moshServerParams = _moshServerParams else {
        throw MoshError.NoMoshServerArgs
      }
      moshServerParams = _moshServerParams
      log.info("Remote Mosh server bootstrapped with params \(moshServerParams)")
    }

    return MoshParams(server: moshServerParams, client: moshClientParams)
  }

  private func moshMain(_ moshParams: MoshParams) -> Int32 {

    
    let originalRawMode = device.rawMode
    self.device.rawMode = true

    defer {
      device.rawMode = originalRawMode
    }

    let _selfRef = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    // A checkpoint seeds exactly ONE client, and this is the one: take it, and tell the tab's archive
    // right away. A second client started from the same bytes would rewind the session behind the
    // server (states it already discarded, nonces it already saw) and the server would never answer
    // it again, a frozen screen that no reconnect inside the tab can fix.
    let checkpoint = moshParams.takeEncodedState()
    let encodedState = [UInt8](checkpoint ?? Data())
    if checkpoint != nil {
      mcpSession.moshroomCheckpointDidChange()
      // The first frame of a client restored from a checkpoint is drawn against a blank screen, so it
      // replays whatever the remote last left in its state: its last bell and its last clipboard
      // copy. Neither is news; the device lets them pass silently for a moment.
      device.moshroomQuietReplay()
    }

    if let localesPath = Bundle.main.path(forResource: "locales", ofType: "bundle"),
       let ccharLocalesPath = localesPath.cString(using: .utf8) {
      setenv("PATH_LOCALE", ccharLocalesPath, 1)
    }

    // "Command on connect": mosh flushes stdin as it takes over the terminal, so pre-buffering would be
    // dropped. Fire it a beat after mosh is up and reading — written as terminal input, exactly like
    // typing. The mosh client and the remote PTY both buffer, so ordering vs the prompt is handled
    // remotely. Fires once per fresh connect (nil on the restore path).
    if let onConnect = pendingCommandOnConnect?.trimmingCharacters(in: .whitespacesAndNewlines),
       !onConnect.isEmpty {
      pendingCommandOnConnect = nil
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.device.write(onConnect + "\r")
      }
    }

    clientLock.lock()
    let closed = killRequested
    if !closed {
      isClientRunning = true
    }
    clientLock.unlock()
    if closed {
      return 0
    }
    // The app put this tab to sleep while the client was still on its way up (an SSH bootstrap that
    // outlasted the trip to the background, or a wake that crossed a new suspend): park it straight
    // away. The escape waits in stdin and is the first thing the client reads, before it sends a
    // single packet, so the checkpoint is exactly the state it started from.
    if mcpSession.moshroomSuspended, let escape = controlEscape {
      device.write(inDirectly: "\(escape)\u{1a}")
    }
    mosh_main(
      self.stdin.file,
      self.stdout.file,
      self.device.window(),
      self.stateCallback,
      _selfRef,
      moshParams.ip,
      moshParams.port,
      moshParams.key,
      moshParams.predictionMode,
      encodedState,
      encodedState.count,
      moshParams.predictOverwrite
    )
    clientLock.lock()
    isClientRunning = false
    clientLock.unlock()

    // Parked or ended, MCPSession decides what comes next from `moshroomParked` (it is also the only
    // signal when the client left through the keyboard escape, which exits its thread and never gets
    // here). A client that ended for real leaves no checkpoint behind.
    if !moshroomParked {
      _ = moshParams.takeEncodedState()
    }
    return 0
  }

  private func getMoshServerStartupArgs(udpPort: String?,
                                 colors: String?,
                                 exec: String?) -> String {
    var args = ["new", "-s", "-c", colors ?? "256"]
    if let lang = getenv("LANG") {
      let localeFallback = "LANG=\(String(cString: lang))"
      args.append(contentsOf: ["-l", localeFallback])
    }

    if let udpPort = udpPort {
      args.append(contentsOf: ["-p", udpPort])
    }
    if let exec = exec {
      args.append(contentsOf: ["--", exec])
    }

    return args.joined(separator: " ")
  }

  private func bootstrapMoshServer(on client: SSHClient,
                                   sequence: [MoshBootstrap],
                                   experimentalRemoteIP: MoshMoshExperimentalIP,
                                   family: AddressFamily?,
                                   args: String,
                                   withPTY pty: SSH.SSHClient.PTY? = nil) -> AnyPublisher<MoshServerParams, Error> {
    let log = logger.log("bootstrapMoshServer")
    log.info("Trying bootstrap with sequence: \(sequence), experimental: \(experimentalRemoteIP), family: \(family), args: \(args)")

    if sequence.isEmpty {
      return Fail(error: MoshError.NoBinaryAvailable).eraseToAnyPublisher()
    }

    func tryBootstrap(_ sequence: [MoshBootstrap]) -> AnyPublisher<MoshServerParams, Error> {
      if sequence.count == 0 {
        return .fail(error: MoshError.NoMoshServerArgs)
      }

      let bootstrap = sequence.first!
      log.info("Trying \(bootstrap)")
      return Just(bootstrap)
        .flatMap { $0.start(on: client) }
        .map { moshServerPath -> String in
          if experimentalRemoteIP == MoshMoshExperimentalIPRemote {
            return "echo \"MOSH SSH_CONNECTION $SSH_CONNECTION\" && \(moshServerPath) \(args)"
          } else {
            return "\(moshServerPath) \(args)"
          }
        }
        .flatMap {
          log.info("Connecting to \($0)")
          return client.requestExec(command: $0, withPTY: pty)
        }
        .flatMap { s -> AnyPublisher<DispatchData, Error> in
          // The SSH PTY will multiplex, so we only try to parse stdout in all cases.
          s.read(max: 1024).eraseToAnyPublisher() //.zip(s.read_err(max: 1024)).eraseToAnyPublisher()
        }
        .flatMap { data -> AnyPublisher<MoshServerParams, Error> in
          return Just(data)
            .map {
              String(decoding: $0 as AnyObject as! Data, as: UTF8.self)
            }
            .tryMap { output -> MoshServerParams in
              log.info("Command output: \(output)")
              // IP Resolution
              switch experimentalRemoteIP {
              case MoshMoshExperimentalIPRemote:
                // remote - echo SSH_CONNECTION on remote for parsing.
                return try MoshServerParams(parsing: output, remoteIP: nil)
              case MoshMoshExperimentalIPLocal:
                // local - resolve address on its own.
                let remoteIP = try self.resolveAddress(host: client.host, port: client.options.port, family: family)
                return try MoshServerParams(parsing: output, remoteIP: remoteIP)
              default:
                // default - get it from the established SSH Connection.
                return try MoshServerParams(parsing: output, remoteIP: client.clientAddressIP())
              }
            }
            .catch{ err in
              //let err = String(decoding: err as AnyObject as! Data, as: UTF8.self)
              log.warn("Bootstrap failed with \(err)")
              var sequence = sequence
              sequence.removeFirst()
              return tryBootstrap(sequence)
            }
            .eraseToAnyPublisher()
        }
        .print()
        .eraseToAnyPublisher()
    }

    return tryBootstrap(sequence)
  }

  private func copyToSession(moshParams: MoshParams) {
    if let sessionParams = self.sessionParams as? MoshParams {
      sessionParams.copy(from: moshParams)
    }
  }

  // Migrated from Objc, based on...
  // getaddrinfo
  // https://stackoverflow.com/questions/39857435/swift-getaddrinfo
  // getnameinfo
  // https://stackoverflow.com/questions/44478074/swift-getnameinfo-unreliable-results-for-ipv6
  private func resolveAddress(host: String, port: String?, family: AddressFamily?) throws -> String {
    guard let port = (port ?? "22").cString(using: .utf8) else {
      throw MoshError.AddressInfo("Invalid port")
    }

    let ai_family = {
      switch family {
      case .IPv4:
        AF_INET
      case .IPv6:
        AF_INET6
      default:
        AF_UNSPEC
      }
    }()

    var hints = addrinfo(
      ai_flags: 0,
      ai_family: ai_family,
      ai_socktype: SOCK_STREAM,
      ai_protocol: IPPROTO_TCP,
      ai_addrlen: 0,
      ai_canonname: nil,
      ai_addr: nil,
      ai_next: nil)
    var result: UnsafeMutablePointer<addrinfo>? = nil
    let err = getaddrinfo(host, port, &hints, &result)
    if err != 0 {
      throw MoshError.AddressInfo("getaddrinfo failed with \(err)")
    }
    defer { freeaddrinfo(result) }

    guard let firstAddr = result?.pointee else {
      throw MoshError.AddressInfo("No address info found")
    }
    for ai in sequence(first: firstAddr, next: { $0.ai_next?.pointee }) {
      if (ai.ai_family != AF_INET && ai.ai_family != AF_INET6) {
        continue;
      }

      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      var port = port
      if getnameinfo(ai.ai_addr, ai.ai_addrlen,
                     &buffer, socklen_t(buffer.count),
                     &port, socklen_t(port.count),
                     NI_NUMERICHOST | NI_NUMERICSERV) != 0 {
        print("getnameinfo failed")
        continue
      }

      return String(cString: buffer)
    }

    throw MoshError.AddressInfo("Could not resolve address through getnameinfo.")
  }

  private func executeProxyCommand(command: String, sockIn: Int32, sockOut: Int32) {
    print("Running ProxyCommand")

    let hostName: String
    let config: SSHClientConfig
    let stdioHostAndPort: BindAddressInfo
    let proxyCommand: SSHCommand
    do {
      var argv = command.components(separatedBy: " ")
      if self.isVerbose {
        argv.append("-vv")
      }
      proxyCommand = try SSHCommand.parse(Array(argv[1...]))
      stdioHostAndPort = proxyCommand.stdioHostAndPort!
      let resolved = try proxyCommand.resolveHost()
      hostName = resolved.hostName
      config = try SSHClientConfigProvider.config(host: resolved.host, using: device)
    } catch {
      print("Configuration error - \(error)", to: &stderr)
      shutdown(sockIn, SHUT_RDWR)
      shutdown(sockOut, SHUT_RDWR)
      return
    }

    let outStream = DispatchOutputStream(stream: sockOut)
    let inStream = DispatchInputStream(stream: sockIn)

    Thread {
      self.proxyCancellable = SSHClient.dial(hostName, with: config)
        .flatMap() { $0.requestForward(to: stdioHostAndPort.bindAddress, port: Int32(stdioHostAndPort.port), from: "stdio", localPort: 22)
        }
        .sink(
          receiveCompletion: { completion in
            if case .failure(let error) = completion {
              print("Proxy forward error - \(error)", to: &self.stderr)
              self.proxyCancellable = nil
              shutdown(sockIn, SHUT_RDWR)
              shutdown(sockOut, SHUT_RDWR)
            }
          },
          receiveValue: { s in
            self.proxyStream = s
            s.connect(stdout: outStream, stdin: inStream)
          })

      SSHClient.run()
      print("Mosh proxy thread out")
    }.start()

  }

  @objc public override func kill() {
    if isRunloopRunning {
      proxyStream?.cancel()
      proxyStream = nil
      proxyCancellable = nil
      sshCancellable = nil
      return
    }
    clientLock.lock()
    defer { clientLock.unlock() }
    guard isClientRunning else {
      // Not up yet (or already gone): make sure it never starts.
      killRequested = true
      return
    }
    guard !moshroomParked, let tid = self.tid else { return }
    // MOSH-ESC . (only when the client honours an escape), and SIGINT, which it always does.
    if let escape = controlEscape {
      device.write(inDirectly: "\(escape)\u{2e}")
    }
    pthread_kill(tid, SIGINT)
  }

  /// Park the client: it checkpoints its state and steps off the network, and a later client carries
  /// the session on from that checkpoint (MCPSession). Through the client's own keyboard escape
  /// (escape, then Ctrl-Z), which it reads from stdin and needs nothing from the server for.
  ///
  /// Not SIGINFO, although the client also checkpoints on it and would leave more cleanly: a client
  /// that is already shutting itself down (a connect that timed out, a quit on a dead network) trips
  /// an assert in its SIGINFO path and aborts the whole app, while it simply ignores keyboard input
  /// then. Blocks for at most two seconds.
  @objc public override func suspend() {
    guard let escape = controlEscape else { return }
    clientLock.lock()
    // Not up yet: moshMain parks it as it starts (the tab is asleep by then). Parked already: done.
    guard isClientRunning, !moshroomParked else {
      clientLock.unlock()
      return
    }
    device.write(inDirectly: "\(escape)\u{1a}")
    clientLock.unlock()
    _ = parkAnswered.wait(timeout: .now() + 2)
  }

  /// Let go of the server right now, whatever the client is doing: a bootstrap in progress is
  /// cancelled, a running client parks (which never needs the server). For a reconnect.
  @objc func moshroomLetGo() {
    if isRunloopRunning {
      kill()
    } else {
      suspend()
    }
  }

  /// The terminal view was rebuilt (its web renderer was replaced) and shows nothing, while the client
  /// still believes its screen is displayed and would send only differences. Redraw the whole screen
  /// from the client's own copy of it, with no server round trip: the escape followed by Ctrl-L.
  /// False when the client cannot be asked (not running, or its escape is not a control key).
  @objc func moshroomRepaintRebuiltView() -> Bool {
    guard let escape = controlEscape else { return false }
    clientLock.lock()
    defer { clientLock.unlock() }
    guard isClientRunning, !moshroomParked else { return false }
    // The rebuilt page is on its main screen with normal cursor keys. The client switched to the
    // alternate screen and application cursor keys once, when it started, and never says so again;
    // its repaint re-sends everything else (colours, cursor, mouse and paste modes) but not those.
    device.view?.write("\u{1b}[?1049h\u{1b}[?1h")
    device.write(inDirectly: "\(escape)\u{0c}")
    return true
  }

  /// Whether a rebuilt view would be repainted by this client (see moshroomRepaintRebuiltView).
  @objc var moshroomCanRepaint: Bool {
    guard controlEscape != nil else { return false }
    clientLock.lock()
    defer { clientLock.unlock() }
    return isClientRunning && !moshroomParked
  }

  // The escape as something a program can type: the client only acts on a control-character escape
  // straight away (a printable one needs a newline first) and ignores a disabled one.
  private var controlEscape: String? {
    guard let scalar = escapeKey.unicodeScalars.first, scalar.value < 32 else { return nil }
    return escapeKey
  }

  @objc public override func sigwinch() {
    clientLock.lock()
    defer { clientLock.unlock() }
    guard isClientRunning, !moshroomParked, let tid = self.tid else { return }
    pthread_kill(tid, SIGWINCH)
  }

  @objc public override func handleControl(_ control: String!) {
    if isRunloopRunning {
      self.kill()
    }
  }

  // The client's LAST act before it leaves its thread: whatever asked for it (our suspend, or the
  // user typing the client's own suspend keys), the client is parked from here on.
  func onStateEncoded(_ encodedState: Data) {
    self.sessionParams.putEncodedState(encodedState)
    clientLock.lock()
    moshroomParked = true
    clientLock.unlock()
    parkAnswered.signal()
    mcpSession.moshroomCheckpointDidChange()
  }

  func die(message: String) -> Int32 {
    print(message, to: &stderr)
    return -1
  }

  deinit {
    print("Mosh is out")
  }
}

extension MoshParams {
  convenience init(server: MoshServerParams, client: MoshClientParams) {
    self.init()

    self.key = server.key
    self.port = server.udpPort
    self.ip = server.remoteIP
    self.predictionMode = String(describing: client.predictionMode)
    self.predictOverwrite = client.predictOverwrite
    self.serverPath = client.server
  }
}

struct MoshLogger {
  var handler = [MoshroomLogging.LogHandlerFactory]()
  init(output: OutputStream, logLevel: MoshroomLogLevel = .error) {
    handler.append(
      {
        $0
          .filter(logLevel: logLevel)
          .format { [ ($0[.component] as? String)?.appending(":") ?? "global:",
                    $0[.message] as? String ?? ""
                  ].joined(separator: " ") }
         // .sink(receiveValue: { print($0[.message]) })
        .sinkToStream(output)
      }
    )
  }

  func log(_ component: String) -> MoshroomLogger {
    MoshroomLogger(component, handlers: handler)
  }
}

extension Publisher {
  fileprivate func sinkToStream(_ stream: OutputStream) -> AnyCancellable where Self.Output == [MoshroomLogKeys:Any] {
    let out = NonStdIO(err: stream)
    return sink(receiveCompletion: { _ in },
                receiveValue: {
      out.printError($0[.message] ?? "")
    })
  }
}
