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

@testable import Moshroom


final class FileLocationPathTests: XCTestCase {
  let LocalRelativePath = "path/to/files"
  let LocalAbsolutePath = "/absolute/path/to/files"
  let LocalHomePath = "~/"

  let RemoteRelativePath = "sftp:host:path/to/files"
  let RemoteAbsolutePath = "sftp:host:/c:/path/to/files"
  // These should be untouched and canonicalized by Translator
  let RemoteHomePath = "user@host#2222:~/path/to/files"

  func testFileLocationPath() throws {
    // All locations should start with /

    let localPath = try! FileLocationPath(LocalRelativePath)
    XCTAssertTrue(localPath.proto == .local)
    // FM default path on tests is "/"
    XCTAssertTrue(localPath.filePath == "/path/to/files")

    let localAbsolutePath = try! FileLocationPath(LocalAbsolutePath)
    XCTAssertTrue(localAbsolutePath.proto == .local)
    XCTAssertTrue(localAbsolutePath.filePath == "/absolute/path/to/files")

    let homePath = try! FileLocationPath(LocalHomePath)
    XCTAssertTrue(homePath.proto == .local)
    XCTAssertTrue(homePath.filePath == "/~")

    let emptyLocalPath = try! FileLocationPath("")
    XCTAssertTrue(emptyLocalPath.proto == .local)
    XCTAssertTrue(emptyLocalPath.filePath == "/")

    let remotePath = try! FileLocationPath(RemoteRelativePath)
    XCTAssertTrue(remotePath.proto == .sftp)
    XCTAssertTrue(remotePath.hostPath == "host")
    XCTAssertTrue(remotePath.filePath == "/~/path/to/files")

    let remoteAbsolutePath = try! FileLocationPath(RemoteAbsolutePath)
    XCTAssertTrue(remoteAbsolutePath.proto == .sftp)
    XCTAssertTrue(remoteAbsolutePath.hostPath == "host")
    XCTAssertTrue(remoteAbsolutePath.filePath == "/c:/path/to/files")

    let remoteHomePath = try! FileLocationPath(RemoteHomePath)
    XCTAssertTrue(remoteHomePath.proto == nil)
    XCTAssertTrue(remoteHomePath.hostPath == "user@host#2222")
    XCTAssertTrue(remoteHomePath.filePath == "/~/path/to/files")

    let emptyRemoteHome = try! FileLocationPath("host:")
    XCTAssertTrue(emptyRemoteHome.proto == nil)
    XCTAssertTrue(emptyRemoteHome.hostPath == "host")
    XCTAssertTrue(emptyRemoteHome.filePath == "/~")
  }
}
