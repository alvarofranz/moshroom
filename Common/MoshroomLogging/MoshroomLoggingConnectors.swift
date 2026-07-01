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
import Combine

class FileLogging {
  private let h: FileHandle
  let queue = DispatchQueue(label: "FileLogging")
  
  public init(to url: URL) throws {
    let fm = FileManager.default
    
    let attrs: [FileAttributeKey : Any] = [.protectionKey: FileProtectionType.none]
    
    if !fm.fileExists(atPath: url.path) {
      guard fm.createFile(atPath: url.path, contents: nil, attributes: attrs) else {
        throw NSError(domain: NSPOSIXErrorDomain, code: 1)
      }
    } else {
      try fm.setAttributes(attrs, ofItemAtPath: url.path)
    }
    
    self.h = try FileHandle(forWritingTo: url)
    h.truncateFile(atOffset: 0)
    //h.seekToEndOfFile()
  }
  
  func write(_ data: Data) {
    do {
      try h.write(contentsOf: data)
    } catch {
      debugPrint("Failed to write log: ", error)
    }
  }
}

extension Publisher {
  func sinkToFile(_ file: FileLogging) throws -> AnyCancellable where Self.Output == [MoshroomLogKeys:Any] {
    // TODO receive(on:)
    return receive(on: file.queue)
      .sink(receiveCompletion: { _ in},
                receiveValue: { string in
      let string = "\(string[.message] as? String ?? "")\n"
      if let data = (string).data(using: .utf8) {
        file.write(data)
      }
    })
  }

  func sinkToOutput() -> AnyCancellable where Self.Output == [MoshroomLogKeys:Any] {
    return sink(receiveCompletion: { _ in },
                receiveValue: { Swift.print($0[.message] ?? "") })
  }

  func filter(logLevel: MoshroomLogLevel) -> AnyPublisher<[MoshroomLogKeys:Any], Never>
  where Self.Output == [MoshroomLogKeys:Any], Self.Failure == Never {
      return filter { log in
        guard let filterLogLevel = log[.logLevel] as? MoshroomLogLevel else {
          return false
        }
        return filterLogLevel >= logLevel }
        .eraseToAnyPublisher()
  }

  func format(_ formatter: @escaping ([MoshroomLogKeys:Any]) -> String) -> AnyPublisher<[MoshroomLogKeys:Any], Never>
  where Self.Output == [MoshroomLogKeys:Any], Self.Failure == Never {
    return map {
      $0.merging([.message: formatter($0)],
                 uniquingKeysWith: { (_, new) in new })
    }.eraseToAnyPublisher()
  }
}
