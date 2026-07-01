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
import LibSSH

@testable import SSH

class PublishersTests: XCTestCase {
  
  func testTryOperation() throws {
    func session() -> SSHConnection {
      guard let session = ssh_new() else {
        return .fail(error: SSHError(title: "Could not create session object."))
      }
      
      return .just(session)
    }
    
    var tries = 0
    let expectRetries = expectation(description: "Retries done")
    let c = session().tryOperation { conn in
      if tries < 3 {
        print ("Retrying")
        tries += 1
        throw SSHError(SSH_AGAIN, forSession: conn)
      }
      expectRetries.fulfill()
    }.assertNoFailure().print("Sink").sink{}
    
    wait(for: [expectRetries], timeout: 2)
    c.cancel()
  }
  
  func testMultiStepOperation() throws {
    func session() -> SSHConnection {
      guard let session = ssh_new() else {
        return Fail(error: SSHError(title: "Could not create session object.")).eraseToAnyPublisher()
      }
      
      return .just(session)
    }
    
    var triesFirstLoop = 0
    var triesSecondLoop = 0
    let expectRetries = expectation(description: "Retries done")
    let c = session().print("Flow").eraseToAnyPublisher()
      .tryOperation { conn -> ssh_session in
        triesFirstLoop += 1
        if triesFirstLoop <= 3 {
          print ("Retrying First Loop")
          throw SSHError(SSH_AGAIN, forSession: conn)
        }
        if triesFirstLoop > 4 {
          XCTFail("First loop retried more than expected.")
        }
        return conn
      }.tryOperation { conn in
        triesSecondLoop += 1
        if triesSecondLoop <= 3 {
          print ("Retrying Second Loop")
          throw SSHError(SSH_AGAIN, forSession: conn)
        }
        expectRetries.fulfill()
      }
      .assertNoFailure().print("Sink").sink{}
    
    wait(for: [expectRetries], timeout: 2)
    c.cancel()
  }
  
  func testTryOperationWithValue() throws {
    // Note this will not work with Passthrough because it does not retain
    // any value, so whenever the tryOperation reconnects, there is nothing
    // to connect to.
    let pub = CurrentValueSubject<ssh_session, Error>(ssh_new())
    var tries = 0
    let expectRetries = expectation(description: "Retries done")
    
    let c = pub
      .eraseToAnyPublisher()
      .tryOperation { conn -> ssh_session in
        print("Retrying")
        if tries < 3 {
          tries += 1
          throw SSHError(SSH_AGAIN, forSession: conn)
        }
        expectRetries.fulfill()
        return conn
      }.tryOperation { $0 }
      .assertNoFailure().print("sink").sink {}
    
    //        func session(_ pub: PassthroughSubject<ssh_session, Error>) {
    //            guard let session = ssh_new() else {
    //                pub.send(completion: .failure(SSHError(title:"Could not create session.")))
    //                return
    //            }
    //            pub.send(session)
    //        }
    //
    //        session(pub)
    wait(for: [expectRetries], timeout: 5)
    c.cancel()
  }
  
  func testTryOperationWithPassthrough() throws {
    // Note the Passthrough does not does not retain any value,
    // so whenever the tryOperation reconnects, there is nothing
    // to connect to. That is why we wrap it inside the value we need the
    // operation to retry with.
    let pub = PassthroughSubject<ssh_session, Error>()
    var tries = 0
    let expectRetries = expectation(description: "Retries done")
    
    let c = pub
      .flatMap { conn -> AnyPublisher<Void, Error> in
        return AnyPublisher
          .just(conn)
          .tryOperation { conn in
            print("Retrying")
            if tries < 3 {
              tries += 1
              throw SSHError(SSH_AGAIN, forSession: conn)
            }
            expectRetries.fulfill()
          }.eraseToAnyPublisher()
      }.assertNoFailure().print("sink").sink {}
    
    func session(_ pub: PassthroughSubject<ssh_session, Error>) {
      guard let session = ssh_new() else {
        pub.send(completion: .failure(SSHError(title:"Could not create session.")))
        return
      }
      pub.send(session)
    }
    
    session(pub)
    wait(for: [expectRetries], timeout: 5)
    c.cancel()
  }
}
