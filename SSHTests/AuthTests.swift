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

import XCTest
import Combine
import Dispatch

@testable import SSH


class AuthTests: XCTestCase {
  
  override class func setUp() {
    SSHInit()
  }
    
  func testPasswordAuthenticationWithCallback() {
    let requestAnswers: SSHClientConfig.RequestVerifyHostCallback = { prompt in
      .just(InteractiveResponse.affirmative)
    }
    
    let config = SSHClientConfig(
      user: Credentials.password.user,
      port: Credentials.port,
      authMethods: [AuthPassword(with: Credentials.password.password)],
      verifyHostCallback: requestAnswers
    )
    
    var completion: Any? = nil
    let connection = SSHClient
      .dial(Credentials.password.host, with: config)
      .exactOneOutput(
        test: self,
        receiveCompletion: {
          completion = $0
        }
      )
    
    assertCompletionFinished(completion)
    XCTAssertNotNil(connection)
  }
  
  func testPasswordAuthentication() throws {
    let config = SSHClientConfig(
      user: Credentials.password.user,
      port: Credentials.port,
      authMethods: [AuthPassword(with: Credentials.password.password)]
    )
    
    var completion: Any? = nil
    
    let connection = SSHClient
      .dial(Credentials.host, with: config)
      .exactOneOutput(
        test: self,
        receiveCompletion: {
          completion = $0
        }
      )
    
    assertCompletionFinished(completion)
    XCTAssertNotNil(connection)
  }
  
  /**
   Feed the wrong private key to the test and then continue as normal to test partial authentication.
   */
  func testPartialAuthenticationFailingFirst() throws {
    let config = SSHClientConfig(
      user: Credentials.partialAuthentication.user,
      port: Credentials.port,
      authMethods: [
        AuthPublicKey(privateKey: Credentials.notCopiedPrivateKey),
        AuthPassword(with: Credentials.partialAuthentication.password),
        AuthPublicKey(privateKey: Credentials.privateKey)
      ])
    
    var completion: Any? = nil

    let connection = SSHClient
      .dial(Credentials.partialAuthentication.host, with: config)
      .exactOneOutput(
        test: self,
        receiveCompletion: {
          completion = $0
        }
      )
    
    assertCompletionFinished(completion)
    XCTAssertNotNil(connection)
  }
  
  /**
   Only providing a method of the two needed to authenticate. Should fail as it also need password authentication to be provided.
   */
  func testFailingPartialAuthentication() throws {
    let config = SSHClientConfig(
      user: Credentials.partialAuthentication.user,
      port: Credentials.port,
      authMethods: [AuthPublicKey(privateKey: Credentials.notCopiedPrivateKey)]
    )
    
    var completion: Any? = nil
    
    let connection = SSHClient
      .dial(Credentials.partialAuthentication.host, with: config)
      .lastOutput(
        test: self,
        receiveCompletion: {
          completion = $0
        }
      )
    
    assertCompletionFailure(completion, withError: .authFailed(methods: config.authenticators))
    XCTAssertNil(connection)
  }
  
  /**
   
   */
  func testPublicKeyPartialAuthentication() throws {
    let config = SSHClientConfig(
      user: Credentials.partialAuthentication.user,
      port: Credentials.port,
      authMethods: [
        AuthPublicKey(privateKey: Credentials.privateKey),
        AuthPassword(with: Credentials.partialAuthentication.password)
      ]
    )
    
    var completion: Any? = nil
    
    let connection = SSHClient
      .dial(Credentials.partialAuthentication.host, with: config)
      .exactOneOutput(
        test: self,
        receiveCompletion: {
          completion = $0
        }
      )
    assertCompletionFinished(completion)
    XCTAssertNotNil(connection)
  }
  
  func testAgentPartialAuthentication() throws {
    let agent = SSHAgent()
    let key = try SSHKey(fromFileBlob: Credentials.privateKey.data(using: .utf8)!)
    agent.loadKey(key, aka: "testKey")
    
    let config = SSHClientConfig(
      user: Credentials.partialAuthentication.user,
      port: Credentials.port,
      authMethods: [
        AuthAgent(agent),
        AuthPassword(with: Credentials.partialAuthentication.password)
      ],
      agent: agent
    )
    
    var completion: Any? = nil
    
    let connection = SSHClient
      .dial(Credentials.partialAuthentication.host, with: config)
      .exactOneOutput(
        test: self,
        receiveCompletion: {
          completion = $0
        }
      )
    assertCompletionFinished(completion)
    XCTAssertNotNil(connection)
  }
  
  // MARK: Wrong credentials
  // This test should fail before the timeout expecation is consumed
  func testFailWithWrongCredentials() {
    let config = SSHClientConfig(
      user: Credentials.wrongPassword.user,
      port: Credentials.port,
      authMethods: [AuthPassword(with: Credentials.wrongPassword.password)]
    )
    
    var completion: Any? = nil
    
    SSHClient
      .dial(Credentials.wrongPassword.host, with: config)
      .noOutput(
        test: self,
        timeout: 10,
        receiveCompletion: {
          completion = $0
        }
      )
    
    assertCompletionFailure(completion, withError: .authFailed(methods: config.authenticators))
  }
  
  // MARK: No authentication methods provided
  
  /**
   Don't provide any authentication methods. Should succeed with a host that has none auth method
   */
  func testEmptyAuthMethods() throws {
    let config = SSHClientConfig(
      user: Credentials.none.user,
      port: Credentials.port,
      authMethods: []
    )
    
    var completion: Any? = nil
    
    let connection = SSHClient
      .dial(Credentials.none.host, with: config)
      .exactOneOutput(
        test: self,
        receiveCompletion: {
          completion = $0
        }
      )
    
    assertCompletionFinished(completion)
    XCTAssertNotNil(connection)
  }
  
  func testNoneAuthentication() {
    let config = SSHClientConfig(
      user: Credentials.none.user,
      port: Credentials.port,
      authMethods: [AuthNone()]
    )
    
    var completion: Any? = nil
    
    let connection = SSHClient
      .dial(Credentials.none.host, with: config)
      .exactOneOutput(
        test: self,
        receiveCompletion: {
          completion = $0
        }
      )
    
    assertCompletionFinished(completion)
    XCTAssertNotNil(connection)
  }
  
  /**
   Test first a failing method then a method that succeeds.
   */
  func testFirstFailingThenSucceeding() throws {
    let config = SSHClientConfig(
      user: Credentials.password.user,
      port: Credentials.port,
      authMethods: [
        AuthPassword(with: Credentials.wrongPassword.password),
        AuthPassword(with: Credentials.password.password)
      ]
    )
    
    var completion: Any? = nil
    
    let connection = SSHClient
      .dial(Credentials.password.host, with: config)
      .lastOutput(
        test: self,
        timeout: 10,
        receiveCompletion: {
          completion = $0
        }
      )
    
    assertCompletionFinished(completion)
    XCTAssertNotNil(connection)
  }
  
  /**
   We expect to be kicked out by the server before we get a chance to try all.
   */
  func testExhaustRetries() throws {
    let config = SSHClientConfig(
      user: Credentials.password.user,
      port: Credentials.port,
      authMethods: [
        AuthPassword(with: Credentials.wrongPassword.password),
        AuthPassword(with: Credentials.wrongPassword.password),
        AuthPassword(with: Credentials.wrongPassword.password),
        AuthPassword(with: Credentials.wrongPassword.password),
        AuthPassword(with: Credentials.password.password)
      ]
    )
    
    var completion: Any? = nil
    
    SSHClient
      .dial(Credentials.password.host, with: config)
      .sink(
        test: self,
        timeout: 30,
        receiveCompletion: {
          completion = $0
        }
      )
    
    assertCompletionFailure(completion, withError: .connError(msg: ""))
  }
  
  // MARK: Public Key Authentication
  
  /**
   Should fail when importing a private key `wrongPrivateKey` that's not correctly formatted.
   */
  func testImportingIncorrectPrivateKey() {
    
    let config = SSHClientConfig(
      user: Credentials.publicKeyAuthentication.user,
      port: Credentials.port,
      authMethods: [AuthPublicKey(privateKey: Credentials.wrongPrivateKey)]
    )
  
    var completion: Any? = nil
    
    SSHClient
      .dial(Credentials.publicKeyAuthentication.host, with: config)
      .sink(
        test: self,
        receiveCompletion: {
          completion = $0
        }
      )

    assertCompletionFailure(completion, withError: .authError(msg: ""))
  }
  
  func testPubKeyAuthentication() {
    
    let config = SSHClientConfig(
      user: Credentials.publicKeyAuthentication.user,
      port: Credentials.port,
      authMethods: [AuthPublicKey(privateKey: Credentials.privateKey)]
    )
    
    var completion: Any? = nil
    
    let connection = SSHClient.dial(Credentials.publicKeyAuthentication.host, with: config)
      .lastOutput(
        test: self,
        receiveCompletion: {
          completion = $0
        }
      )
    
    assertCompletionFinished(completion)
    XCTAssertNotNil(connection)
  }
  
  // MARK: Interactive Keyboard Authentication
  func testInteractiveKeyboardAuth() throws {
    var retry = 0
    
    let requestAnswers: AuthKeyboardInteractive.RequestAnswersCb = { prompt in
      dump(prompt)
      
      var answers: [String] = []
      
      if prompt.userPrompts.count > 0 {
        // Fail on first retry
        if retry > 0 {
          answers = [Credentials.interactive.password]
        } else {
          retry += 1
          answers = []
        }
      } else {
        answers = []
      }
      
      return .just(answers)
    }
    
    let config = SSHClientConfig(
      user: Credentials.interactive.user,
      port: Credentials.port,
      authMethods: [AuthKeyboardInteractive(requestAnswers: requestAnswers)]
    )
    
    let connection = SSHClient
      .dial(Credentials.interactive.host, with: config)
      .exactOneOutput(
        test: self,
        timeout: 10,
        receiveCompletion: { completion in
          switch completion {
          case .finished:
            break
          case .failure(let error):
            if let error = error as? SSHError {
              XCTFail(error.description)
              break
            }
            XCTFail("Unknown error")
          }
        }
      )
    
    XCTAssertNotNil(connection)
  }
}
