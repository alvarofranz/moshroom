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


struct MoshServerParams {
  let key: String
  let udpPort: String
  let remoteIP: String
}

extension MoshServerParams {
  init(parsing output: String, remoteIP: String?) throws {
    if let remoteIP = remoteIP {
      self.remoteIP = remoteIP
    } else {
      let remoteIPPattern = try! NSRegularExpression(
        pattern: "(?m)^MOSH SSH_CONNECTION (\\S*) (\\d*) (\\S*) (\\d*)$",
        options: []
      )
      if let remoteIPMatch = remoteIPPattern.firstMatch(
           in: output,
           options: [],
           range: NSRange(location: 0, length: output.utf8.count)
         ) {
        self.remoteIP = String(output[Range(remoteIPMatch.range(at: 3), in: output)!])
      } else {
        throw MoshError.NoRemoteServerIP
      }
    }

    let connectPattern = try! NSRegularExpression(
      pattern: "(?m)^MOSH CONNECT (\\d+) (\\S*)$",
      options: []
    )
    if let connectMatch = connectPattern.firstMatch(
         in: output,
         options: [],
         range: NSRange(output.startIndex..., in: output)
       ) {
      self.udpPort = String(output[Range(connectMatch.range(at: 1), in: output)!])
      self.key = String(output[Range(connectMatch.range(at: 2), in: output)!])
    } else {
      throw MoshError.NoMoshServerArgs
    }
  }
}
