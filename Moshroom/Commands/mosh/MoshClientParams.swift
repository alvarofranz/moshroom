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

struct MoshClientParams {
  let predictionMode: MoshMoshPrediction
  let predictOverwrite: String?
  let experimentalRemoteIP: MoshMoshExperimentalIP
  let customUDPPort: String?
  let server: String
  let remoteExecCommand: String?

  init(extending cmd: MoshCommand) {
    let bkHost = MoshHosts.withHost(cmd.hostAlias)

    let customUDPPort: String? = if let moshPort = bkHost?.moshPort { String(describing: moshPort) } else { nil }
    self.customUDPPort = cmd.customUDPPort ?? customUDPPort
    let moshServer: String? = if let moshServer = bkHost?.moshServer, !moshServer.isEmpty { moshServer } else { nil }
    self.server  = cmd.server ?? moshServer ?? "mosh-server"
    self.predictionMode = cmd.predict ?? MoshMoshPrediction(UInt32(truncating: bkHost?.prediction ?? 0))
    self.predictOverwrite = cmd.predictOverwrite ? "yes" : bkHost?.moshPredictOverwrite
    self.experimentalRemoteIP = cmd.experimentalRemoteIP ?? MoshMoshExperimentalIP(UInt32(truncating: bkHost?.moshExperimentalIP ?? 0))
    let remoteExecCommand: String? = if let command = bkHost?.moshStartup, !command.isEmpty { command } else { nil }
    self.remoteExecCommand = !cmd.remoteExecCommand.isEmpty ? cmd.remoteExecCommand.joined(separator: " ") : remoteExecCommand
  }
}
