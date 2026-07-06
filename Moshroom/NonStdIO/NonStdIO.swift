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

public struct InputStream {
  let fd: Int32
  let file: UnsafeMutablePointer<FILE>
  
  public init(file: UnsafeMutablePointer<FILE>) {
    self.file = file
    self.fd = fileno(file)
  }
  
  
  public func readLine() -> String? {
    var char: UInt8 = 0
    let newLineChar: UInt8 = 0x0a
    var data = Data()
    while Darwin.read(fd, &char, 1) == 1 {
      if char == newLineChar {
        break
      }
      data.append(char)
    }
    
    return String(data: data, encoding: .utf8)
  }
  
  static var stdin:  InputStream  { .init(file: Darwin.stdin) }
  
}

public struct OutputStream: TextOutputStream {
  let fd: Int32
  let file: UnsafeMutablePointer<FILE>
  
  public init(file: UnsafeMutablePointer<FILE>) {
    self.file = file
    self.fd = fileno(file)
  }
  
  public func write(_ string: String) {
    Darwin.write(fd, string, string.utf8.count)
  }
  
  public func flush() {
    Darwin.fflush(file)
  }
  
  static var stdout: OutputStream { .init(file: Darwin.stdout) }
  static var stderr: OutputStream { .init(file: Darwin.stderr) }
}


public class NonStdIO: Codable {
  public var in_: InputStream
  public var out: OutputStream
  public var err: OutputStream
  
  public var verbose: Bool = false
  public var quiet: Bool = false
  
  public init(in_: InputStream? = nil, out: OutputStream? = nil, err: OutputStream? = nil) {
    self.in_ = in_ ?? InputStream.stdin
    self.out = out ?? OutputStream.stdout
    self.err = err ?? OutputStream.stderr
  }
  
  public required init(from decoder: Decoder) throws {
    self.in_ = InputStream.stdin
    self.out = OutputStream.stdout
    self.err = OutputStream.stderr
  }
  
  public func encode(to encoder: Encoder) throws {
  }
  
  public static let standard = NonStdIO()
}

public protocol WithNonStdIO {
  var io: NonStdIO { get }
}

public extension NonStdIO {
  func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    guard !quiet else {
      return
    }
    let s = items.map(String.init(describing:)).joined(separator: separator)
    Swift.print(s, terminator: terminator, to: &out)
  }
  
  func printError(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let s = items.map(String.init(describing:)).joined(separator: separator)
    Swift.print(s, terminator: terminator, to: &err)
  }
}


public extension WithNonStdIO {
  func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let s = items.map(String.init(describing:)).joined(separator: separator)
    io.print(s, terminator: terminator)
  }
  
  func printError(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let s = items.map(String.init(describing:)).joined(separator: separator)
    io.printError(s, terminator: terminator)
  }
}


