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

import Combine

public protocol FuzzySearchable {
  var fuzzyIndex: String { get }
}

extension Sequence where Element: FuzzySearchable {
  public func fuzzySearch(searchString: String, maxResults: Int) -> AnyPublisher<(Element, Matrix<Int?>), Error> {
    
    self.publisher.compactMap { candidate -> (match: Element, score: Int, matrix: Matrix<Int?>)? in
      candidate.fuzzyIndex.fuzzyMatch3(searchString).map { match in
        (candidate, match.score, match.matrix)
      }
    }
    .collect()
    .flatMap {
      $0.sorted(by: { $0.score > $1.score })
        .prefix(maxResults)
        .publisher
    }
    .map { ($0.match, $0.matrix) }
    .setFailureType(to: Error.self)
    .eraseToAnyPublisher()
  }

}


// https://github.com/objcio/S01E214-quick-open-from-recursion-to-loops/blob/master/QuickOpen/ContentView.swift
public struct Matrix<A> {
    var array: [A]
    let width: Int
    private(set) var height: Int
    init(width: Int, height: Int, initialValue: A) {
        array = Array(repeating: initialValue, count: width*height)
        self.width = width
        self.height = height
    }

    private init(width: Int, height: Int, array: [A]) {
        self.width = width
        self.height = height
        self.array = array
    }

    subscript(column: Int, row: Int) -> A {
        get { array[row * width + column] }
        set { array[row * width + column] = newValue }
    }

    subscript(row row: Int) -> Array<A> {
        return Array(array[row * width..<(row+1)*width])
    }

    func map<B>(_ transform: (A) -> B) -> Matrix<B> {
        Matrix<B>(width: width, height: height, array: array.map(transform))
    }

    mutating func insert(row: Array<A>, at rowIdx: Int) {
        assert(row.count == width)
        assert(rowIdx <= height)
        array.insert(contentsOf: row, at: rowIdx * width)
        height += 1
    }

    func inserting(row: Array<A>, at rowIdx: Int) -> Matrix<A> {
        var copy = self
        copy.insert(row: row, at: rowIdx)
        return copy
    }
}

extension Matrix where A == Int? {
  public func ranges() -> Array<NSRange> {
    var ranges = [NSRange]()
    var start = 0
    var len = 0
    for j in 0..<width {
      var found = false
      for i in 0..<height {
//        if let value = self[j, i], value >= 0 {
        if self[j, i] != nil {
          found = true
          break
        }
      }
      if found {
        if len == 0 {
          start = j
          len = 1
        } else {
          len += 1
        }
      } else {
        if len == 0 {
          continue
        }
        ranges.append(NSRange(location: start, length: len))
        start = 0
        len = 0
      }
    }
    if len != 0 {
      ranges.append(NSRange(location: start, length: len))
    }
    return ranges
  }
}

public struct Score {
    private(set) var value: Int = 0
    private var log: [(Int, String)] = []
    var explanation: String {
        log.map { "\($0.0):\t\($0.1)"}.joined(separator: "\n")
    }

    mutating func add(_ amount: Int, reason: String) {
        value += amount
        log.append((amount, reason))
    }

    mutating func add(_ other: Score) {
        value += other.value
        log.append(contentsOf: other.log)
    }
}

extension Score: Comparable {
    public static func < (lhs: Score, rhs: Score) -> Bool {
        lhs.value < rhs.value
    }

    public static func == (lhs: Score, rhs: Score) -> Bool {
        lhs.value == rhs.value
    }
}

extension String {
    public func fuzzyMatch3(_ needle: String) -> (score: Int, matrix: Matrix<Int?>)? {
        var matrix = Matrix<Int?>(width: self.count, height: needle.count, initialValue: nil)
        if needle.isEmpty { return (score: 0, matrix: matrix) }
        for (row, needleChar) in needle.enumerated() {
            var didMatch = false
            let prevMatchIdx: Int
            if row == 0 {
                prevMatchIdx = -1
            } else {
                prevMatchIdx = matrix[row: row-1].firstIndex { $0 != nil }!
            }
            for (column, char) in self.enumerated().dropFirst(prevMatchIdx + 1) {
                guard needleChar == char else {
                    continue
                }
                didMatch = true
                var score = 1
                if row > 0 {
                    var maxPrevious = Int.min
                    for prevColumn in 0..<column {
                        guard let s = matrix[prevColumn, row-1] else { continue }
                        let gapPenalty = (column-prevColumn) - 1
                        maxPrevious = max(maxPrevious, s - gapPenalty)
                    }
                    score += maxPrevious
                }
                matrix[column, row] = score
            }
            guard didMatch else { return nil }
        }
        guard let score = matrix[row: needle.count-1].compactMap({ $0 }).max() else {
            return  nil
        }
        return (score, matrix)
    }
}
