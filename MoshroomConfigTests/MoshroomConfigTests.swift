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

@testable import MoshroomConfig

class MoshroomConfigTests: XCTestCase {
  let fm = FileManager.default
  let hostAlias = "test"
  override func setUpWithError() throws {
    MoshHosts.loadHosts()
    // Put setup code here. This method is called before the invocation of each test method in the class.
    let sshConfigAttachment =
"""
Compression yes
CompressionLevel 8
ControlMaster no
"""
    
    let _ = MoshHosts.saveHost(hostAlias,
                                withNewHost: hostAlias,
                                hostName: "localhost",
                                sshPort: "22",
                                user: "glenda",
                                password: "password",
                                hostKey: "id_rsa",
                                moshServer: "",
                                moshPortRange: "",
                                startUpCmd: "",
                                prediction: MoshMoshPrediction(rawValue: 0),
                                proxyCmd: "exec nc %h:%p",
                                proxyJump: "jumphost",
                                sshConfigAttachment: sshConfigAttachment)
  }
  
  override func tearDownWithError() throws {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    try fm.removeItem(at: URL(fileURLWithPath: MoshroomPaths.moshroomHostsFile()))
    try fm.removeItem(at: MoshroomPaths.moshroomSSHConfigFileURL())
  }
  
func testBKHostsToSSHConfig() throws {
  let hostString = try MoshHosts.sshConfig().string()
  let expectConfig = ["Host \(hostAlias)",
                      "User glenda",
                      "Port 22",
                      "HostName localhost",
                      "ProxyCommand exec nc %h:%p",
                      "ProxyJump jumphost",
                      "Compression yes",
                      "ControlMaster no",
                      "IdentityFile id_rsa"
  ]

  expectConfig.forEach { row in
    if !hostString.contains(row) {
      XCTFail("\(row) not found on hostString")
    }
  }
  
  // Password should be skipped
  XCTAssertFalse(hostString.contains("Password password"))
}
  
  func testSSHConfigToSSHClientConfig() throws {
    // Test conversion to MoshSSHHost.
    // TODO First issue is that this MoshSSHHost is of an "undefined" format, what
    // makes it difficult to match to the one coming from SSHConfig as [String:Any].
    // TODO One issue for example is the "other commands" on SSHCommand.
    // A yes/no, will not get translated to true false sequence.
    let baseHost = try MoshSSHHost(content: ["user": "no-password",
                                           "port": "2222",
                                           "compression": "no",
                                           "sendenv": "TERM LC*"])

    let _ = try MoshConfig().bkSSHHost(hostAlias, extending: baseHost)
    guard let env = baseHost.sendEnv else {
      XCTFail("No env received")
      return
    }
    XCTAssert(env.contains("TERM") &&
              env.contains("LC*"), "List mapping failed")
  }
}
