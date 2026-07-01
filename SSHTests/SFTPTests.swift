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
import MoshroomFiles
import Combine
import Dispatch

@testable import SSH

extension SSHClientConfig {
  static let testConfig = SSHClientConfig(
    user: Credentials.none.user,
    port: Credentials.port,
    authMethods: [],
    loggingVerbosity: .debug
  )
}

extension SSHClient {
  static func dialWithTestConfig() -> AnyPublisher<SSHClient, Error> {
    dial(Credentials.none.host, with: .testConfig)
  }
}

class SFTPTests: XCTestCase {
  var cancellableBag: [AnyCancellable] = []
  
  override class func setUp() {
    SSHInit()
  }
  
  func testRequest() throws {
    let list = SSHClient
      .dialWithTestConfig()
      .flatMap() { $0.requestSFTP() }
      .tryMap()  { try SFTPTranslator(on: $0) }
      .flatMap() { t -> AnyPublisher<[[FileAttributeKey : Any]], Error> in
        t.walkTo("~")
          .flatMap { $0.directoryFilesAndAttributes() }
          .eraseToAnyPublisher()
      }
      .assertNoFailure()
      .exactOneOutput(test: self)
    
    dump(list)
    XCTAssertNotNil(list)
    XCTAssertFalse(list!.isEmpty)
  }
  
  func testRead() throws {
    let expectation = self.expectation(description: "Buffer Written")
    
    //var connection: SSHClient?
    //var sftp: SFTPClient?
    
    let cancellable = SSHClient.dialWithTestConfig()
      .flatMap() { $0.requestSFTP() }
      .tryMap { try SFTPTranslator(on: $0) }
      .flatMap { $0.walkTo("linux.tar.xz") }
      .flatMap { $0.open(flags: O_RDONLY) }
      .flatMap { $0.read(max: SSIZE_MAX) }
      .reduce(0, { $0 + $1.count } )
      .assertNoFailure()
      .sink { count in
        XCTAssertTrue(count == 109078664, "Wrote \(count)")

        expectation.fulfill()
      }
    
    waitForExpectations(timeout: 15, handler: nil)
  }
  
  func testWriteTo() throws {
    let expectation = self.expectation(description: "Buffer Written")
    
    //var connection: SSHClient?
    //var sftp: SFTPClient?
    let buffer = MemoryBuffer(fast: true)
    var totalWritten = 0
    
    let cancellable = SSHClient.dialWithTestConfig()
      .flatMap { $0.requestSFTP() }
      .tryMap  { try SFTPTranslator(on: $0) }
      .flatMap { $0.walkTo("linux.tar.xz") }
      .flatMap { $0.open(flags: O_RDONLY) }.flatMap() { f -> AnyPublisher<Int, Error> in
        let file = f as! SFTPFile
        return file.writeTo(buffer)
      }.assertNoFailure()
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          expectation.fulfill()
        case .failure(let error):
          // Problem here is we can have both SFTP and SSHError
          XCTFail("Crash")
        }
      }, receiveValue: { written in
        totalWritten += written
      })
    
    waitForExpectations(timeout: 15, handler: nil)
    XCTAssertTrue(totalWritten == 109078664, "Wrote \(totalWritten)")
    print("TOTAL \(totalWritten)")
  }
  
  func testWrite() throws {
    let writeExpectation = self.expectation(description: "File Written")
    
    //var connection: SSHClient?
    var root: SFTPTranslator? = nil
    var totalWritten = 0
    
    let gen = RandomInputGenerator(fast: true)
    
    let cancelWrite = SSHClient.dialWithTestConfig()
      .flatMap() { $0.requestSFTP() }
      .tryMap()  { t in
        let r = try SFTPTranslator(on: t)
        root = r
        return r
      }
      .flatMap() { $0.walkTo("/tmp") }
      .flatMap() { $0.create(name: "newfile", mode: S_IRWXU) }
      .flatMap() { file in
        return gen.read(max: 5 * 1024 * 1024)
          .flatMap() { data in
            return file.write(data, max: data.count)
          }
      }.sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          writeExpectation.fulfill()
        case .failure(let error):
          // Problem here is we can have both SFTP and SSHError
          if let err = error as? SSH.FileError {
            XCTFail(err.description)
          } else {
            XCTFail("Crash")
          }
        }
      }, receiveValue: { written in
        totalWritten += written
      })
    
    waitForExpectations(timeout: 15, handler: nil)
    XCTAssert(totalWritten == 5 * 1024 * 1024, "Did not write all data")
    
    totalWritten = 0
    let overwriteExpectation = self.expectation(description: "File Overwritten")
    
    guard let root = root else {
      XCTFail("No root translator.")
      return
    }
    
    let cancelOverwrite = root.walkTo("/tmp")
      .flatMap() { $0.create(name: "newfile", mode: S_IRWXU) }
      .flatMap() { file in
        return gen.read(max: 4 * 1024 * 1024)
          .flatMap() { data in
            return file.write(data, max: data.count)
          }
      }.sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          overwriteExpectation.fulfill()
        case .failure(let error):
          // Problem here is we can have both SFTP and SSHError
          if let err = error as? SSH.FileError {
            XCTFail(err.description)
          } else {
            XCTFail("Crash")
          }
        }
      }, receiveValue: { written in
        totalWritten += written
      })
    
    waitForExpectations(timeout: 15, handler: nil)
    XCTAssert(totalWritten == 4 * 1024 * 1024, "Did not write all data")
    
    let statExpectation = self.expectation(description: "File Stat")
    let cancelStat = root.walkTo("/tmp/newfile")
      .flatMap { (t: Translator) -> AnyPublisher<FileAttributes, Error> in t.stat() }
      .assertNoFailure()
      .sink { (stats: FileAttributes) in
        XCTAssertTrue(stats[.size] as! Int == 4 * 1024 * 1024)
        statExpectation.fulfill()
      }
    
    waitForExpectations(timeout: 15, handler: nil)
  }
  
  func testWriteToWriter() throws {
    let expectation = self.expectation(description: "Buffer Written")
    
//    var connection: SSHClient?
    var translator: SFTPTranslator?
    let buffer = MemoryBuffer(fast: true)
    var totalWritten = 0
    
    let cancellable = SSHClient.dialWithTestConfig()
      .flatMap() { $0.requestSFTP() }
      .tryMap()  { try SFTPTranslator(on: $0) }
      .flatMap() { t -> AnyPublisher<File, Error> in
        translator = t
        // TODO Create a random file first, or use one from a previous test.
        return t.walkTo("linux.tar.xz")
          .flatMap { $0.open(flags: O_RDONLY) }.eraseToAnyPublisher()
      }.flatMap() { f -> AnyPublisher<Int, Error> in
        let file = f as! SFTPFile
        return translator!.walkTo("/tmp/")
          .flatMap { $0.create(name: "linux.tar.xz", mode: S_IRWXU) }
          .flatMap() { file.writeTo($0) }.eraseToAnyPublisher()
      }.sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          expectation.fulfill()
        case .failure(let error):
          // Problem here is we can have both SFTP and SSHError
          XCTFail("Crash")
        }
      }, receiveValue: { written in
        totalWritten += written
      })
    
    waitForExpectations(timeout: 15, handler: nil)
    XCTAssertTrue(totalWritten == 109078664, "Wrote \(totalWritten)")
    print("TOTAL \(totalWritten)")
    // TODO Cleanup
  }
  
  // Z Makes sure we run this one last
  func testZRemove() throws {
    let expectation = self.expectation(description: "Removed")
    
//    var connection: SSHClient?
//    var sftp: SFTPClient?
    let buffer = MemoryBuffer(fast: true)
    var totalWritten = 0
    
    let cancellable = SSHClient.dialWithTestConfig()
      .flatMap() { $0.requestSFTP() }
      .tryMap()  { try SFTPTranslator(on: $0) }
      .flatMap() { $0.walkTo("/tmp/linux.tar.xz") }
      .flatMap() { $0.remove() }
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          print("done")
        case .failure(let error as SSH.FileError):
          XCTFail(error.description)
        case .failure(let error):
          XCTFail("\(error)")
        }
      }, receiveValue: { result in
        XCTAssertTrue(result)
        expectation.fulfill()
      })
    
    waitForExpectations(timeout: 5, handler: nil)
  }
  
  // func testMkdir() throws {
  //     let config = SSHClientConfig(user: "carlos", authMethods: [AuthPassword(with: "")])
  
  //     let expectation = self.expectation(description: "Removed")
  
  //     var connection: SSHClient?
  //     var sftp: SFTPClient?
  //     let buffer = MemoryBuffer(fast: true)
  //     var totalWritten = 0
  
  //     let cancellable = SSHClient.dial("localhost", with: config)
  //         .flatMap() { conn -> AnyPublisher<SFTPClient, Error> in
  //             print("Received connection")
  //             connection = conn
  //             return conn.requestSFTP()
  //         }.flatMap() { client -> AnyPublisher<SFTPClient, Error> in
  //             return client.walkTo("/tmp/tmpfile")
  //         }.flatMap() { file in
  //             return file.remove()
  //         }
  //         .sink(receiveCompletion: { completion in
  //             switch completion {
  //             case .finished:
  //                 print("done")
  //             case .failure(let error):
  //                 XCTFail(dump(error))
  //             }
  //         }, receiveValue: { result in
  //             XCTAssertTrue(result)
  //             expectation.fulfill()
  //         })
  
  //     waitForExpectations(timeout: 5, handler: nil)
  //     connection?.close()
  // }
  // }
  
  func testCopyAsASource() {
    continueAfterFailure = false

//    var connection: SSHClient?
//    var sftp: SFTPClient?
    let local = Local()
    
    try? FileManager.default.removeItem(atPath: "/tmp/test/copy_test")
    try? FileManager.default.createDirectory(atPath: "/tmp/test", withIntermediateDirectories: true, attributes: nil)
    
    let copied = self.expectation(description: "Copied structure")
    SSHClient.dialWithTestConfig()
      .flatMap() { $0.requestSFTP() }
      .tryMap()  { try SFTPTranslator(on: $0) }
      .flatMap() { $0.walkTo("copy_test") }
      .flatMap() { f -> CopyProgressInfoPublisher in
        return local.walkTo("/tmp/test").flatMap { $0.copy(from: [f]) }.eraseToAnyPublisher()
      }.sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          print("done")
          copied.fulfill()
        case .failure(let error):
          XCTFail("\(error)")
        }
      }, receiveValue: { result in
        dump(result)
      }).store(in: &cancellableBag)
    
    wait(for: [copied], timeout: 30)
  }
 
  func testCopyAsDest() {    
    let local = Local()
    
    let connection = SSHClient
      .dialWithTestConfig()
      .exactOneOutput(test: self)
      
    connection?
      .requestExec(command: "rm -rf ~/test")
      .sink(test: self)
    
    let translator = connection?
      .requestSFTP()
      .tryMap { try SFTPTranslator(on: $0) }
      .exactOneOutput(test: self)
    
    var completion: Any? = nil
    
    translator?
      .walkTo("/home/no-password")
      .flatMap() { f -> CopyProgressInfoPublisher in
        local.walkTo("/tmp/test").flatMap { f.copy(from: [$0]) }.eraseToAnyPublisher()
      }.sink(
        test: self,
        receiveCompletion: {
          completion = $0
        }
      )
    
    assertCompletionFinished(completion)
  }
  
  // Write and read a stat
//  func testStat() throws {
//
//  }
}
