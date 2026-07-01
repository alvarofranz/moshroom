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

@testable import MoshroomFiles

class MoshroomFilesTests: XCTestCase {
  
  override func setUpWithError() throws {
    // Put setup code here. This method is called before the invocation of each test method in the class.
  }
  
  override func tearDownWithError() throws {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
  }
  
  func testExample() throws {
    // This is an example of a functional test case.
    // Use XCTAssert and related functions to verify your tests produce the correct results.
  }
  
  func testPerformanceExample() throws {
    // This is an example of a performance test case.
    self.measure {
      // Put the code you want to measure the time of here.
    }
  }
  
  func testTranslatorsMatching() throws {
    let f = Local()
    
    let expectMatches = expectation(description: "Matches")
    
    let c = f.walkTo("/Users/carlos")
      .flatMap { $0.translatorsMatching(path: "lib*") }
      .assertNoFailure()
      .sink(receiveCompletion: { _ in
        expectMatches.fulfill()
      }, receiveValue: { t in
        XCTAssertTrue(t.current.starts(with: "/Users/carlos/lib"))
        print(t.current)
      })
    
    wait(for: [expectMatches], timeout: 3)
  }
}
