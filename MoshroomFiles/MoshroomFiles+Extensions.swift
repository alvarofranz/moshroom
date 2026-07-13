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

public struct MoshroomFilesError: Error, LocalizedError {
  let errorDescription: String
  let originalError: Error
}

public extension Translator {
  func cloneWalkTo(_ path: String) -> AnyPublisher<Translator, Error> {
    let t = self.clone()
    return t.walkTo(path)
  }
}

extension Translator {
  public func translatorsMatching(path: String) -> AnyPublisher<Translator, Error> {
    // If the source path contains a wildcard, then list and filter
    // (or do it anyway).
    // ~/asdf/test* - go to asdf, list and
    // /asdf*
    let sourceRootPath: String
    if path.contains("/") {
      sourceRootPath = (path as NSString).deletingLastPathComponent
    } else {
      sourceRootPath = current
    }
    let sourceComponent = (path as NSString).lastPathComponent
    var sourceRootTranslator: Translator? = nil
    return self.cloneWalkTo(sourceRootPath)
      .flatMap { s -> AnyPublisher<FileAttributes, Error> in
        sourceRootTranslator = s
        return s.directoryFilesAndAttributes().flatMap { $0.publisher }.eraseToAnyPublisher()
      }.compactMap { (elem: MoshroomFiles.FileAttributes) -> String? in
        let name = elem[.name] as! String
        // Skip "." and ".."?
        if wildcard(name, pattern: sourceComponent) {
          return name
        }
        return nil
      }.flatMap { name in
        sourceRootTranslator!.cloneWalkTo(name).mapError { err in MoshroomFilesError(errorDescription: "Could not walk to \(name)", originalError: err)}
      }.eraseToAnyPublisher()
  }

  fileprivate func wildcard(_ string: String, pattern: String) -> Bool {
    let pred = NSPredicate(format: "self LIKE %@", pattern)
    return !NSArray(object: string).filtered(using: pred).isEmpty
  }
}

