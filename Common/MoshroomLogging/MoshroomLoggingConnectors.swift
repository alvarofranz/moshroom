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

extension Publisher {
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
