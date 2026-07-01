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

extension Translator {
  public func directoryFilesAndAttributesResolvingLinks() -> AnyPublisher<[FileAttributes], Error> {
    directoryFilesAndAttributes()
      .flatMap { filesAttributes -> AnyPublisher<[FileAttributes], Never> in
        filesAttributes.publisher
          .flatMap { attrs -> AnyPublisher<FileAttributes, Never> in
            guard let type = attrs[.type] as? FileAttributeType,
                  let name = attrs[.name] as? String,
                  type == .typeSymbolicLink else {
              return .just(attrs)
            }

            return cloneWalkTo(name)
              .flatMap { $0.stat()
                           .map { attrs in
                             // Resolve it but make sure the name is still the symlink, otherwise it will be the destination.
                             var attrs = attrs
                             attrs[.name] = name
                             return attrs
                           }
              }
              .catch { _ in Just(attrs) }
              .eraseToAnyPublisher()
          }.map { $0 }
          .collect()
          .eraseToAnyPublisher()
      }.eraseToAnyPublisher()
  }

  public func directoryFilesAndAttributesWithTargetLinks() -> AnyPublisher<[FileAttributes], Error>  {
    directoryFilesAndAttributes()
      .flatMap { filesAttributes -> AnyPublisher<[FileAttributes], Never> in
        filesAttributes.publisher
          .flatMap { attrs -> AnyPublisher<FileAttributes, Never> in
            guard let type = attrs[.type] as? FileAttributeType,
                  let name = attrs[.name] as? String,
                  type == .typeSymbolicLink else {
              return .just(attrs)
            }

            return cloneWalkTo(name)
              .flatMap {
                $0.stat()
                  .map { targetAttrs in
                    var attrs = attrs
                    attrs[.symbolicLinkTargetInfo] = targetAttrs
                    return attrs
                  }
              }
              .catch { _ in Just(attrs) }
              .eraseToAnyPublisher()
          }.map { $0 }
          .collect()
          .eraseToAnyPublisher()
      }.eraseToAnyPublisher()
  }

  public func mkdir(name: String) -> AnyPublisher<Translator, Error> {
    mkdir(name: name, mode: S_IRWXU | S_IRWXG | S_IRWXO)
  }

  public func mkPath(path: String) -> AnyPublisher<Translator, Error> {
    cloneWalkTo(path)
      .catch { _ in
        let name = (path as NSString).lastPathComponent
        let parentPath = (path as NSString).deletingLastPathComponent
        return mkPath(path: parentPath).flatMap { $0.mkdir(name: name ) }.eraseToAnyPublisher()
      }.eraseToAnyPublisher()
  }
}
