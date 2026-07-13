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
import ios_system

public typealias Argv = UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?

extension Argv {
  static func build(_ args: [String]) -> (argc: Int32, argv: Self, buff: UnsafeMutablePointer<Int8>?) {
    let argc = args.count

    let cArgsSize = args.reduce(argc) { $0 + $1.utf8.count }

    // Store arguments in contiguous memory.
    guard
      let argsBuffer = calloc(cArgsSize, MemoryLayout<Int8>.size)?.assumingMemoryBound(to: Int8.self)
    else {
      return (argc: 0, argv: nil, buff: nil)
    }

    let argv = UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>.allocate(capacity: argc)

    var currentArgsPosition = argsBuffer

    args.enumerated().forEach { i, arg in
      let len = strlen(arg)
      strncpy(currentArgsPosition, arg, len)
      argv[i] = currentArgsPosition
      currentArgsPosition = currentArgsPosition.advanced(by: len + 1)
    }


    return (argc: Int32(argc), argv: argv, buff: argsBuffer)
  }

  static func build(_ args: String ...) -> (argc: Int32, argv: Self, buff: UnsafeMutablePointer<Int8>?) {
    build(args)
  }

  func args(count: Int32) -> [String] {
    guard let argv = self else {
      return []
    }
    var res: [String] = []
    for i in 0..<count {
      guard let cStr = argv[Int(i)] else {
        res.append("")
        continue
      }

      res.append(String(cString: cStr))
    }
    return res
  }
}

struct CommandError: Error {
  let message: String
}

func tty() -> TermDevice {
  let session = Unmanaged<MCPSession>.fromOpaque(thread_context).takeUnretainedValue()
  return session.device
}
