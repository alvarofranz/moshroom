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
import Foundation
import LibSSH

public protocol AuthMethod {
  // Standard name used to compare the auth method with the available ones from the server.
  func name() -> String
  var displayName: String { get }
}

extension AuthMethod {
  public var displayName: String { get { return name() } }
}

protocol Authenticator: AuthMethod {
  func auth(user: String, host: String, on conn: SSHConnection) -> AnyPublisher<AuthState, Error>
}

public enum AuthState {
  case success
  case denied
  case `continue`(auth: AnyPublisher<AuthState, Error>)
  case partial
}

// MARK: Password Authentication Method

public class AuthPassword: AuthMethod, Authenticator {
  let password: String
  
  public init(with password: String) {
    self.password = password
  }
  
  func auth(_ session: ssh_session) throws -> AuthState {
    let rc = ssh_userauth_password(session, nil, password)
    let auth = ssh_auth_e(rc)
    switch auth {
    case SSH_AUTH_SUCCESS: return .success
    case SSH_AUTH_DENIED:  return .denied
    case SSH_AUTH_PARTIAL: return .partial
    case SSH_AUTH_AGAIN:   throw SSHError(auth: auth, forSession: session)
    default:               throw SSHError(auth: auth, forSession: session)
    }
  }
  
  func auth(user: String, host: String, on conn: SSHConnection) -> AnyPublisher<AuthState, Error> {
    conn.tryAuth { try self.auth($0) }
  }
  
  public func name() -> String {
    "password"
  }
}

// MARK: None Authentication Method

/// This method allows to get the available authentication methods. It also gives the server a chance to authenticate the user with just
/// his/her login. Some old hardware use this feature to fallback the user on a "telnet over SSH" style of login.
public class AuthNone: AuthMethod, Authenticator {
  public init() {
    
  }
  
  func auth(_ session: ssh_session) throws -> AuthState {
    let rc = ssh_userauth_none(session, nil)
    let auth = ssh_auth_e(rc)
    
    switch auth {
    case SSH_AUTH_SUCCESS: return .success
    case SSH_AUTH_DENIED:  return .denied
    default:
      throw SSHError(auth: auth, forSession: session)
    }
  }
  
  internal func auth(user: String, host: String, on connection: SSHConnection) -> AnyPublisher<AuthState, Error> {
    connection.tryAuth { try self.auth($0) }
  }
  
  public func name() -> String {
    "none"
  }
}

// MARK: Keyboard Interactive Authentication Method

public struct Prompt {
  public let name: String
  public let instruction: String
  public struct Question {
    public let prompt: String
    public let echo: Bool
  }
  
  public var userPrompts: [Question]
}

public class AuthPasswordInteractive: AuthMethod, Authenticator {
  public func name() -> String {
    "password-interactive"
  }
  
  public typealias RequestAnswersCb = (Prompt) -> AnyPublisher<[String], Error>
  
  let requestAnswers: RequestAnswersCb
  
  /// Authentication will be tried this number of times prior to failing.
  /// If there are retries left it returns a `SSH_AUTH_AGAIN`
  var wrongRetriesLeft: Int
  
  public init(requestAnswers f: @escaping RequestAnswersCb, wrongRetriesAllowed: Int = 1) {
    self.requestAnswers = f
    
    self.wrongRetriesLeft = wrongRetriesAllowed
  }
  
  func auth(user: String, host: String, on conn: SSHConnection) -> AnyPublisher<AuthState, Error> {
    let p = Prompt(name: "password", instruction: "(\(user)@\(host))", userPrompts: [Prompt.Question(prompt: "password:", echo: false)])

    return self.requestAnswers(p)
        .flatMap { answers -> AnyPublisher<AuthState, Error> in
          return conn.tryAuth { session in
            let password = answers[0]
            let rc = ssh_userauth_password(session, nil, password)
            let val = ssh_auth_e(rc)
            switch val {
            case SSH_AUTH_SUCCESS: return .success
            case SSH_AUTH_DENIED:
              self.wrongRetriesLeft -= 1
              if self.wrongRetriesLeft >= 0 {
                return .continue(auth: self.auth(user: user, host: host, on: conn))
              }
              return .denied
            case SSH_AUTH_PARTIAL: return .partial
            case SSH_AUTH_AGAIN:   throw SSHError(auth: val, forSession: session)
            default:               throw SSHError(auth: val, forSession: session)
            }
          }
        }.eraseToAnyPublisher()
  }
}
// Try Authentication in phases. So you can return the state of the authentication,
// and whether or not there is another step or phase that needs to be called right after.
// Let TryAuth understand Success or Denied, and let it work through the details in
// case it needs to do something else.
public class AuthKeyboardInteractive: AuthMethod, Authenticator {
  public typealias RequestAnswersCb = (Prompt) -> AnyPublisher<[String], Error>
  
  let requestAnswers: RequestAnswersCb
  
  /// Authentication will be tried this number of times prior to failing.
  /// If there are retries left it returns a `SSH_AUTH_AGAIN`
  var wrongRetriesLeft: Int = 2
  
  public init(requestAnswers f: @escaping RequestAnswersCb, wrongRetriesAllowed: Int = 3) {
    self.requestAnswers = f
    
    self.wrongRetriesLeft = wrongRetriesAllowed
  }
  
  func auth(user: String, host: String, on conn: SSHConnection) -> AnyPublisher<AuthState, Error> {
    return conn.tryAuth { session in
      let rc = ssh_userauth_kbdint(session, nil, nil)
      let auth = ssh_auth_e(rc)
      switch auth {
      case SSH_AUTH_SUCCESS:
        return .success
      case SSH_AUTH_PARTIAL:
        return .partial
      case SSH_AUTH_DENIED:
        self.wrongRetriesLeft -= 1
        
        if self.wrongRetriesLeft >= 0 {
          throw SSHError(auth: SSH_AUTH_AGAIN, forSession: session)
        }
        
        return .denied
      case SSH_AUTH_INFO:
        // Get prompt info
        let p = self.prompts(user: user, host: host, session: session)
        
        return AuthState.continue(
          auth: self.requestAnswers(p)
            .tryMap { answers in
              _ = try answers.enumerated().map { (idx, answer) in
                
                let str = answer.cString(using: .utf8)
                let rc = ssh_userauth_kbdint_setanswer(session, UInt32(idx), str)
                
                if rc < 0 {
                  throw SSHError(rc, forSession: session)
                }
              }
              return conn
            }
            // We need to loop, as we may receive questions in multiple phases.
            .flatMap { self.auth(user: user, host: host, on: $0) }
            .eraseToAnyPublisher()
        )
      default:
        throw SSHError(auth: auth, forSession: session)
      }
    }
  }
  
  func prompts(user: String, host: String, session: ssh_session) -> Prompt {
    let name = ssh_userauth_kbdint_getname(session)
    let instruction = ssh_userauth_kbdint_getinstruction(session)
    let nprompts = ssh_userauth_kbdint_getnprompts(session)
    
    var userPrompts: [Prompt.Question] = []
    
    
    _ = (0..<nprompts).map { n in
      var echo: CChar = 0
      
      let prompt = ssh_userauth_kbdint_getprompt(session, UInt32(n), &echo)
      let userPrompt = Prompt.Question(prompt: String(cString: prompt!), echo: (echo > 0 ? true : false))
      
      userPrompts.append(userPrompt)
    }
    
    return Prompt(name: String(cString: name!),
                  instruction: "\(user)@\(host)'s \(String(cString: instruction!))",
                  userPrompts: userPrompts)
  }
  
  public func name() -> String {
    "keyboard-interactive"
  }
}

// Gives a chance to any key hold by the Agent
public class AuthAgent: AuthMethod, Authenticator {
  public func name() -> String { "publickey" }
  
  let agent: SSHAgent
  
  public init(_ agent: SSHAgent) {
    self.agent = agent
  }
  
  internal func auth(user: String, host: String, on conn: SSHConnection) -> AnyPublisher<AuthState, Error> {
    return conn.tryAuth { try self.auth($0) }
  }
  
  func auth(_ session: ssh_session) throws -> AuthState {
    let rc = ssh_userauth_agent(session, nil)
    let auth = ssh_auth_e(rc)

    switch auth {
    case SSH_AUTH_SUCCESS:
      return .success
    case SSH_AUTH_DENIED:
      return .denied
    case SSH_AUTH_PARTIAL:
      return .partial
    default:
      // NOTE This may return a completely different error because the failure may not be tied
      // to the status of the agent.
      throw SSHError(auth: ssh_auth_e(rawValue: rc), forSession: session)
    }
  }
}
