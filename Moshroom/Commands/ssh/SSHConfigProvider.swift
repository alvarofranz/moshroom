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


import Foundation
import SSH
import Combine
import MoshroomConfig


fileprivate let HostKeyChangedWarningMessage = "@@WARNING! REMOTE IDENTIFICATION HAS CHANGED.\nNew Public key hash: %@.\nSomeone could be intercepting this connection, or the host's key was replaced.\nAccepting the following prompt will add a new entry for this host.\nType yes to trust the new host key [yes/N]: "

fileprivate let HostKeyChangedUnknownRequestMessage = "Public key hash: %@.\nThe server is unknown.\nDo you trust the host key? [Y/n]: "

fileprivate let HostKeyChangedNotFoundRequestMessage = "Public key hash: %@.\nThe server is unknown.\nDo you trust the host key? [Y/n]: "
// Having access from CLI
// Having access from UI. Some parameters must already exist, others need to be tweaked.
// Pass it a host and get everything necessary to connect, but some functions still need to be setup.

class SSHClientConfigProvider {
  /// The terminal this connect can talk THROUGH: prompts (password, passphrase, an unknown host
  /// key) and the log go there. nil means headless — the app is connecting on the user's behalf
  /// with no terminal in front of them (Moshify's library, Moshxplore's browsing), so saved keys
  /// and saved passwords work exactly as before and anything that would need an answer fails with
  /// a reason instead of hanging on a prompt nobody can see.
  let device: TermDevice?
  /// What the user already answered for this headless connect (nothing, for a terminal's).
  let answers: MoshroomHeadlessAnswers
  /// Headless only: the password this connect already knows (typed in the browser, or saved), offered
  /// ONCE to a keyboard-interactive server asking a single hidden question. A server offering only
  /// that method (PAM setups, FreeBSD's default) would otherwise never see the password at all.
  fileprivate var headlessPassword: String?
  let logger = PassthroughSubject<String, Never>()
  var logCancel: AnyCancellable? = nil
  let config: MoshConfig

  fileprivate init(using device: TermDevice?, answers: MoshroomHeadlessAnswers) throws {
    self.device = device
    self.answers = answers
    self.config = try MoshConfig()

    logCancel = logger.sink { [weak self] in self?.printLn($0, err: true) }
  }

  // Return HostName, SSHClientConfig for the server
  static func config(host: MoshSSHHost, using device: TermDevice?,
                     answers: MoshroomHeadlessAnswers = MoshroomHeadlessAnswers()) throws -> SSHClientConfig {
    let prov = try SSHClientConfigProvider(using: device, answers: answers)
    if device == nil, let password = answers.password ?? host.password, !password.isEmpty {
      prov.headlessPassword = password
    }

    let agent = prov.agent(for: host)

    let availableAuthMethods: [AuthMethod] = [AuthAgent(agent)] + prov.passwordAuthMethods(for: host)

    return
      host.sshClientConfig(authMethods: availableAuthMethods,
                           verifyHostCallback: (host.strictHostKeyChecking ?? true) ? prov.cliVerifyHostCallback : nil,
                           agent: agent,
                           logger: prov.logger)
  }
}

extension SSHClientConfigProvider {
  fileprivate func passwordAuthMethods(for host: MoshSSHHost) -> [AuthMethod] {
    var authMethods: [AuthMethod] = []

    // Host password
    if let password = host.password, !password.isEmpty {
      authMethods.append(AuthPassword(with: password))
    }

    authMethods.append(AuthKeyboardInteractive(requestAnswers: self.authPrompt, wrongRetriesAllowed: 2))
    // Password-Interactive
    authMethods.append(AuthPasswordInteractive(requestAnswers: self.authPrompt,
                                               wrongRetriesAllowed: 2))

    return authMethods
  }
  
  fileprivate func authPrompt(_ prompt: Prompt) -> AnyPublisher<[String], Error> {
    self.printLn(prompt.instruction, err: true)

    if device == nil {
      guard prompt.userPrompts.count == 1, !prompt.userPrompts[0].echo, let password = headlessPassword else {
        return Fail(error: MoshroomHeadlessNeed.password).eraseToAnyPublisher()
      }
      headlessPassword = nil   // once: a wrong one ends as a question, never as a loop
      return .just([password])
    }
    return prompt.userPrompts.publisher.tryMap { question -> String in
      guard let device = self.device else {
        throw MoshroomHeadlessNeed.password
      }
      guard let input = device.readline(question.prompt, secure: true) else {
        throw CommandError(message: "Couldn't read input")
      }
      return input
    }.collect()
    .eraseToAnyPublisher()
  }

  fileprivate func agent(for host: MoshSSHHost) -> SSHAgent {
    let agent = SSHAgent()

    let consts: [SSHAgentConstraint] = [SSHConstraintTrustedConnectionOnly()]
    //let consts: [SSHAgentConstraint] = [SSHAgentUserPrompt()]

    let signers = config.signer(forHost: host) ?? config.defaultSigners()

    signers.forEach { (signer, name) in
      // NOTE We could also keep the reference and just read the key at the proper time.
      if let signer = signer as? MoshroomConfig.InputPrompter {
        // No view headless: a key needing a passphrase prompt cannot be unlocked without one, and
        // the signer reports that itself rather than us guessing here.
        if let view = device?.view {
          signer.setPromptOnView(view)
        }
        signer.setLogger(self.logger, verbosity: host.logLevel ?? .none)
      }
      agent.loadKey(signer, aka: name, constraints: consts)
    }

    // Link to Default Agent
    if let defaultAgent = SSHDefaultAgent.instance {
      agent.linkTo(agent: defaultAgent)
    } else {
      printLn("Default agent is not available.")
    }

    return agent
  }

}

extension SSHClientConfigProvider {
  func cliVerifyHostCallback(_ prompt: SSH.VerifyHost) -> AnyPublisher<InteractiveResponse, Error> {
    var response: SSH.InteractiveResponse = .negative

    let messageToShow: String
    switch prompt {
    case .changed(serverFingerprint: let serverFingerprint):
      messageToShow = String(format: HostKeyChangedWarningMessage, serverFingerprint)
    case .unknown(serverFingerprint: let serverFingerprint):
      messageToShow = String(format: HostKeyChangedUnknownRequestMessage, serverFingerprint)
    case .notFound(serverFingerprint: let serverFingerprint):
      messageToShow = String(format: HostKeyChangedNotFoundRequestMessage, serverFingerprint)
    }

    let keyChanged: Bool
    if case .changed = prompt { keyChanged = true } else { keyChanged = false }

    guard let device = self.device else {
      // Headless: never accept a key nobody confirmed. Whoever started the connect either reports the
      // reason (connect once from a terminal tab) or shows the fingerprint and dials again with the
      // user's answer: only that exact fingerprint, and only for a host seen for the first time.
      if !keyChanged, let trusted = answers.trustedHostKey, trusted == prompt.moshroomFingerprint {
        printLn("Trusted the host key \(trusted) for this host.", err: true)
        return .just(.affirmative)
      }
      let need = MoshroomHeadlessNeed.hostKey(fingerprint: prompt.moshroomFingerprint, changed: keyChanged)
      printLn(need.localizedDescription, err: true)
      return Fail(error: need).eraseToAnyPublisher()
    }

    let readAnswer = device.readline(messageToShow, secure: false)

    if let answer = readAnswer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      if keyChanged {
        // A changed (or different-type) key is what an interception looks like: only an
        // explicit yes accepts it. Enter alone, a bare "y", or anything else, refuses.
        if answer == "yes" {
          response = .affirmative
        }
      } else if answer.starts(with: "y") || answer.isEmpty {
        // First contact with an unknown host keeps the usual default-yes answer.
        response = .affirmative
      }
    } else {
      printLn("Cannot read input.", err: true)
    }

    return .just(response)
  }
  
  fileprivate func printLn(_ string: String, err: Bool = false) {
    guard let device else {
      // Headless connects have no transcript to print into; the log keeps the trail.
      MoshLog.log("ssh", string)
      return
    }
    let line = string.appending("\r\n")
    let s = err ? device.stream.err : device.stream.out
    fwrite(line, line.lengthOfBytes(using: .utf8), 1, s)
  }
}

private extension SSH.VerifyHost {
  var moshroomFingerprint: String {
    switch self {
    case .changed(let fingerprint), .unknown(let fingerprint), .notFound(let fingerprint): return fingerprint
    }
  }
}
