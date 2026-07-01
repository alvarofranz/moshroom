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
import SSH
import Combine

fileprivate let defaultTimout: TimeInterval = 5

extension XCTestCase {
  func waitPublisher<P: Publisher>(
    _ publisher: P,
    timeout: TimeInterval = defaultTimout,
    receiveCompletion: @escaping ((Subscribers.Completion<P.Failure>) -> Void),
    receiveValue: @escaping (P.Output) -> Void
  ) {
    let expectation = self.expectation(description: "Publisher completes or cancel")
    let c = publisher.handleEvents(
      receiveCompletion: { _ in
        expectation.fulfill()
      },
      receiveCancel: {
        expectation.fulfill()
      }
    )
    .sink(receiveCompletion: receiveCompletion, receiveValue: receiveValue)
    
    wait(for: [expectation], timeout: timeout)
    c.cancel()
  }
}

extension Publisher {
  
  func sink(
    test: XCTestCase,
    timeout: TimeInterval = defaultTimout,
    receiveCompletion: @escaping ((Subscribers.Completion<Self.Failure>) -> Void) = { _ in },
    receiveValue: @escaping ((Self.Output) -> Void) = { _ in }
  ) {
    test.waitPublisher(
      self,
      timeout: timeout,
      receiveCompletion: receiveCompletion,
      receiveValue: receiveValue
    )
  }
  
  func lastOutput(
    test: XCTestCase,
    timeout: TimeInterval = defaultTimout,
    receiveCompletion: @escaping ((Subscribers.Completion<Self.Failure>) -> Void) = { _ in }
  ) -> Self.Output? {
    var lastValue: Self.Output?
    sink(test: test, timeout: timeout, receiveCompletion: receiveCompletion) {
      lastValue = $0
    }
    return lastValue
  }
  
  func exactOneOutput(
    test: XCTestCase,
    timeout: TimeInterval = defaultTimout,
    receiveCompletion: @escaping ((Subscribers.Completion<Self.Failure>) -> Void) = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Self.Output! {
    var value: Self.Output? = nil
    sink(test: test, timeout: timeout, receiveCompletion: receiveCompletion) {
      XCTAssertNil(value, file: file, line: line)
      value = $0
    }
    
    XCTAssertNotNil(value, file: file, line: line)
    return value
  }
  
  func noOutput(
    test: XCTestCase,
    timeout: TimeInterval = defaultTimout,
    receiveCompletion: @escaping ((Subscribers.Completion<Self.Failure>) -> Void) = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    var value: Self.Output? = nil
    sink(test: test, timeout: timeout, receiveCompletion: receiveCompletion) { _ in
      XCTFail("Should not have received a output", file: file, line: line)
    }
  }
}


extension Subscribers.Completion {
  var error: Error? {
    switch self {
    case .finished: return nil
    case .failure(let err): return err
    }
  }
}


func assertCompletionFinished(_ completion: Any?, file: StaticString = #filePath, line: UInt = #line) {
  guard
    let c = completion as? Subscribers.Completion<Error>
  else {
    XCTFail("receiveCompletion is not called", file: file, line: line)
    return
  }
  
  switch c {
  case .finished: break
  case .failure(let error):
    if let error = error as? SSHError {
      XCTFail(error.description, file: file, line: line)
    } else {
      XCTFail("Unknown error: \(error)", file: file, line: line)
    }
  }
}


func assertCompletionFailure(_ completion: Any?, withError error: SSHError, file: StaticString = #filePath, line: UInt = #line) {
  guard
    let c = completion as? Subscribers.Completion<Error>,
    let err = c.error as? SSHError,
    err == error
  else {
    XCTFail("Should completed with .faulure(\(error). Got: " + String(describing: completion), file: file, line: line)
    return
  }
}
