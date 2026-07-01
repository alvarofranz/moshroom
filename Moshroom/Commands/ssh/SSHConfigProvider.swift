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


fileprivate let HostKeyChangedWarningMessage = "@@WARNING! REMOTE IDENTIFICATION HAS CHANGED.\nNew Public key hash: %@.\nAccepting the following prompt will add a new entry for this host.\nDo you trust the host key? [Y/n]: "

fileprivate let HostKeyChangedUnknownRequestMessage = "Public key hash: %@.\nThe server is unknown.\nDo you trust the host key? [Y/n]: "

fileprivate let HostKeyChangedNotFoundRequestMessage = "Public key hash: %@.\nThe server is unknown.\nDo you trust the host key? [Y/n]: "
// Having access from CLI
// Having access from UI. Some parameters must already exist, others need to be tweaked.
// Pass it a host and get everything necessary to connect, but some functions still need to be setup.

class SSHClientConfigProvider {
  let device: TermDevice
  let logger = PassthroughSubject<String, Never>()
  var logCancel: AnyCancellable? = nil
  let config: MoshConfig

  fileprivate init(using device: TermDevice) throws {
    self.device = device
    self.config = try MoshConfig()

    logCancel = logger.sink { [weak self] in self?.printLn($0, err: true) }
  }

  // Return HostName, SSHClientConfig for the server
  static func config(host: MoshSSHHost, using device: TermDevice) throws -> SSHClientConfig {
    let prov = try SSHClientConfigProvider(using: device)

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
  // NOTE Unused as we moved to a pure agent. Leaving here in case it is useful in the future.
  fileprivate func keyAuthMethods(for host: MoshSSHHost) -> [AuthMethod] {
    var authMethods: [AuthMethod] = []

    // Explicit identity
    if let identities = host.identityFile {
      identities.forEach { identity in
        if let (identityKey, name) = config.privateKey(forIdentifier: identity) {
            authMethods.append(AuthPublicKey(privateKey: identityKey, keyName: name))
        }
      }
    } else {
      // All default keys
      for (defaultKey, name) in config.defaultKeys() {
        authMethods.append(AuthPublicKey(privateKey: defaultKey, keyName: name))
      }
    }

    return authMethods
  }
  
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

    return prompt.userPrompts.publisher.tryMap { question -> String in
      guard let input = self.device.readline(question.prompt, secure: true) else {
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
        signer.setPromptOnView(device.view)
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

    let readAnswer = self.device.readline(messageToShow, secure: false)

    if let answer = readAnswer?.lowercased() {
      if answer.starts(with: "y") || answer.isEmpty {
        response = .affirmative
      }
    } else {
      printLn("Cannot read input.", err: true)
    }

    return .just(response)
  }
  
  fileprivate func printLn(_ string: String, err: Bool = false) {
    let line = string.appending("\r\n")
    let s = err ? device.stream.err : device.stream.out
    fwrite(line, line.lengthOfBytes(using: .utf8), 1, s)
  }
}
