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

public protocol AdaptiveSearchable {
  var searchableContent: String { get }
}

// NOTE This uses Data, but CFData functions may be more optimized for
// what we are trying to do.
// Ranges is supported on 16+ only.
// We could also just use a prototype for the algorithm.
// We could move this as part of String.
public func Search(content: String, searchString: String) -> [(line: String, ranges: [NSRange])] { // [Range<Int>] {
  // Read file on Data
  // Return ranges
  // let d = try Data(contentsOf: url)
  // This may not be a proper way to transform to U8
  //return d.ranges(of: [UInt8](searchString.utf8))

  // Separate in tokens.
  // On first range, extract a line, and from there search the rest recursively.
  let compareOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
  let searchTokens = searchString.components(separatedBy: " ")
    .filter { !$0.isEmpty } // filter with multiple spaces inside
    .sorted { $0.count > $1.count }

  var searchTokenRanges: [(String, [NSRange])] = []
  let linesLimit = 5
  content.enumerateLines { line, stop in
    var lineRanges: [NSRange] = []
    for range in line.ranges(of: searchTokens[0], options: compareOptions) {
      lineRanges.append(NSRange(range, in: line))
      for token in searchTokens[1...] {
        let subRanges = line.ranges(of: token, options: compareOptions)
        if subRanges.isEmpty {
          return
        } else {
          for range in subRanges {
            lineRanges.append(NSRange(range, in: line))
          }
        }
      }
    }
    if !lineRanges.isEmpty {
      searchTokenRanges.append((line, lineRanges))
      
      if searchTokenRanges.count >= linesLimit {
        stop = true
      }
    }
    
  }

  return searchTokenRanges
}

//   let str = try String(contentsOf: url)
//   return str.ranges(of: searchString, options: [.caseInsensitive, .diacriticInsensitive])
// }

extension String {
  func ranges(of substring: String, options: CompareOptions = [], locale: Locale? = nil) -> [Range<Index>] {
    var ranges: [Range<Index>] = []
    while let range = range(of: substring, options: options, range: (ranges.last?.upperBound ?? self.startIndex)..<self.endIndex, locale: locale) {
      ranges.append(range)
    }
    return ranges
  }
}

extension Snippet: AdaptiveSearchable {
  public var searchableContent: String {
    (try? self.content) ?? ""
  }
}
