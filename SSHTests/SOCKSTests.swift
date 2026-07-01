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
import Network
import XCTest

@testable import SSH

class SOCKSTests: XCTestCase {
  
  override func setUpWithError() throws {
    // Put setup code here. This method is called before the invocation of each test method in the class.
  }
  
  override func tearDownWithError() throws {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
  }
  
  func testSOCKSConnection() throws {
    let connection = SSHClient
      .dialWithTestConfig()
      .lastOutput(
        test: self,
        receiveCompletion: { completion in
          switch completion {
          case .finished: break
          case .failure(let error):
            if let error = error as? SSHError {
              XCTFail(error.description)
              break
            }
            XCTFail("Unknown error")
          }
        })
    
    let queue = DispatchQueue(label: "test")
    let server = try SOCKSServer(proxy: connection!)

    let conn = NWConnection(host: NWEndpoint.Host("localhost"), port: NWEndpoint.Port(rawValue: 1080)!, using: .tcp)
    
    let expectConn = self.expectation(description: "SOCKS Connected")
    conn.stateUpdateHandler = { state in
      print("Emitting conn \(state)")
      switch state {
      case .ready:
        // Continue after connected
        expectConn.fulfill()
      default:
        break
      }
    }
    
    conn.start(queue: queue)
    
    wait(for: [expectConn], timeout: 5)
    
    // Handshake
    let expectHandshake = self.expectation(description: "Handshake")
    let handshake = Data([0x05, 0x01, 0x00])
    conn.send(content: handshake, completion: NWConnection.SendCompletion.contentProcessed({ error in
      if let error = error {
        XCTFail(error.localizedDescription)
        return
      }
    }))
    
    conn.receive(minimumIncompleteLength: 2, maximumLength: 2) { (data, ctxt, complete, error) in
      if data != Data([0x05, 0x00]) {
        XCTFail("Handshake does not match")
        return
      }
      expectHandshake.fulfill()
    }
    wait(for: [expectHandshake], timeout: 5000)
    
    // Request
    let expectBinding = self.expectation(description: "Binding")
    let address = "www.google.com"
    var length = address.count
    var port: UInt16 = UInt16(80).bigEndian
    let request = Data([0x05, 0x01, 0x00, 0x03]) +
      Data(bytes: &length, count: MemoryLayout<UInt8>.size) +
      address.data(using: .utf8)! +
      Data(bytes: &port, count: MemoryLayout<UInt16>.size)
    conn.send(content: request, completion: NWConnection.SendCompletion.contentProcessed({ error in
      if let error = error {
        XCTFail(error.localizedDescription)
        return
      }
    }))
    
    conn.receive(minimumIncompleteLength: request.count, maximumLength: request.count) { (data, ctxt, complete, error) in
      expectBinding.fulfill()
    }
    wait(for: [expectBinding], timeout: 5000)
    
    let expectResponse = self.expectation(description: "Web Response")
    conn.send(content: "GET / HTTP/1.0\r\n\r\n".data(using: .utf8)!, completion: NWConnection.SendCompletion.contentProcessed({ error in
      if let error = error {
        XCTFail(error.localizedDescription)
        return
      }
    }))
    
    let response = "HTTP/1.0 200 OK"
    conn.receive(minimumIncompleteLength: response.count, maximumLength: response.count) { (data, ctxt, complete, error) in
      guard let data = data else {
        XCTFail("No data")
        return
      }
      let received = String(bytes: data[0..<response.count], encoding: .utf8)
      if received != response {
        XCTFail("HTTP response does not match. \(String(describing: received))")
      }
      expectResponse.fulfill()
      // TODO complete is never true. Even after the channel has been closed.
    }
    wait(for: [expectResponse], timeout: 1000)
  }
}
