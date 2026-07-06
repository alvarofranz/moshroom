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



//#if canImport(ArgumentParser)

import Foundation
import ArgumentParser

public struct VerboseOptions: ParsableArguments {
  @Flag(name: .long)
  public var verbose: Bool = false
  
  @Flag(name: .long)
  public var quiet: Bool = false
  
  public init() { }
}


public protocol NonStdIOCommand: ParsableCommand, WithNonStdIO {
  var io: NonStdIO { get }
  var verboseOptions: VerboseOptions { get set }
}

public extension ParsableCommand where Self: WithNonStdIO {
  static func main(_ args: [String]? = nil, io: NonStdIO = .init()) -> Int32 {
    do {
      var command = try parseAsRoot(args)
      
      if let cmd = command as? WithNonStdIO {
        cmd.io.in_ = io.in_
        cmd.io.err = io.err
        cmd.io.out = io.out
      }
      
      if let cmd = command as? NonStdIOCommand {
        cmd.io.verbose = cmd.verboseOptions.verbose
        cmd.io.quiet = cmd.verboseOptions.quiet
        
        command = cmd
      }
      
      try command.run()
    } catch {
      return terminalIOExit(withError: error, io: io)
    }
    
    return 0
  }
  
  static func terminalIOExit(withError error: Error? = nil, io: NonStdIO) -> Int32 {
    guard let error = error else {
      return 0
    }
    
    var txt = io.quiet ? message(for: error) : fullMessage(for: error)
    let exitCode = exitCode(for: error).rawValue
    if txt.isEmpty {
      return exitCode
    }
    
    if !io.quiet,
      let localizedError = error as? LocalizedError,
      let recoverySuggestion = localizedError.recoverySuggestion,
      !recoverySuggestion.isEmpty {
      
      txt += "\n" + recoverySuggestion
    }
    
    if exitCode == 0 {
      io.print(txt)
    } else {
      io.printError(txt)
    }
    return exitCode
  }
}


//#endif
