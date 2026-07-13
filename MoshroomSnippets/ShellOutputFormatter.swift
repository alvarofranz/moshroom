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


public enum ShellOutputFormatter {
  case raw,
       block,
       lineBySemicolon,
       beginEnd,
       unprocessed

  public func format(_ script: String) -> String {
    if self == .unprocessed {
      return script
    }

    let commands = parseCommands(script)

    // Escape if no multi-line
    if commands.isEmpty {
      return ""
    } else if commands.count == 1 {
      return commands[0]
    }

    switch self {
    case .raw:
      return script
    case .lineBySemicolon:
      return commands.joined(separator: "; ")
    case .block:
      return script.wrapIn(prefix: "$(\n", suffix: "\n)")
    case .beginEnd:
      return script.wrapIn(prefix: "begin\n", suffix: "\nend")
    case .unprocessed:
      preconditionFailure("Unprocessed should not reach this point")  // Already handled above
    }
  }
  
  private func parseCommands(_ script: String) -> [String] {
    // Receives text and splits into multiple commands
    var currentCommand = ""
    var commands: [String] = []
    
    for line in script
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: .newlines) {
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)

      if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
        continue
      }

      if trimmedLine.hasSuffix("\\") {
        currentCommand += line.appending("\n")
      } else {
        currentCommand += line
        commands.append(currentCommand)
        currentCommand = ""
      }
    }
    
    return commands
  }
}

extension String {
  func wrapIn(prefix: String, suffix: String) -> String {
    return "\(prefix)\(self)\(suffix)"
  }
}
