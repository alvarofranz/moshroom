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
import XCTest
import ArgumentParser

class SSHCommandTests: XCTestCase {

  override func setUp() {
    // Put setup code here. This method is called before the invocation of each test method in the class.
  }

  override func tearDown() {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
  }

  func testSshCommandParameters() throws {
    let commandString = "-vv -L 8080:localhost:80 -i id_rsa -p 2023 username@17.0.0.1 -- echo 'hello'"

    do {
      var components = commandString.components(separatedBy: " ")
      let command = try SSHCommand.parse(components)

      XCTAssertTrue(command.localPortForward?.localPort == 8080)
      XCTAssertTrue(command.localPortForward?.remotePort == 80)
      XCTAssertTrue(command.localPortForward?.bindAddress == "localhost")
      XCTAssertTrue(command.verbose == 2)
      XCTAssertTrue(command.port == 2023)
      XCTAssertTrue(command.identityFile == "id_rsa")
      XCTAssertTrue(command.host == "17.0.0.1")
      XCTAssertTrue(command.user == "username")
      XCTAssertTrue(command.command == ["echo", "'hello'"])
    } catch {
      let msg = SSHCommand.message(for: error)
      XCTFail("Couldn't parse command: \(msg)")
    }
  }

  func testMoshCommandParameters() throws {
    var commandString = "localhost tmux -vv --attach"

    do {
      let components = commandString.components(separatedBy: " ")
      let command = try SSHCommand.parse(components)
      XCTAssertTrue(command.command == ["tmux", "--attach"])
    } catch {
      let msg = SSHCommand.message(for: error)
      XCTFail("Couldn't parse command: \(msg)")
    }

    commandString = "localhost -- tmux -vv --attach"

    do {
      let components = commandString.components(separatedBy: " ")
      let command = try SSHCommand.parse(components)
      XCTAssertTrue(command.command == ["tmux", "-vv", "--attach"])
    } catch {
      let msg = SSHCommand.message(for: error)
      XCTFail("Couldn't parse command: \(msg)")
    }
  }


  func testSshCommandOptionals() throws {
    let args = ["-o", "ProxyCommand=ssh", "localhost", "-o", "Compression=yes", "-o", "CompressionLevel=4"]
    do {
      let command = try SSHCommand.parse(args)

      let options = try command.connectionOptions.get()
      XCTAssertTrue(options.proxyCommand == "ssh")
      XCTAssertTrue(options.compression == true)
      XCTAssert(options.compressionLevel == 4)
    } catch {
      let msg = SSHCommand.message(for: error)
      XCTFail("Couldn't parse SSH command: \(msg)")
    }
  }

  func testUnknownOptional() throws {
    let args = ["-o", "ProxyCommand=ssh", "localhost", "-o", "Compresion=yes"]
    do {
      let command = try SSHCommand.parse(args)
      XCTFail("Parsing should have failed")
    } catch {
    }
  }
}
