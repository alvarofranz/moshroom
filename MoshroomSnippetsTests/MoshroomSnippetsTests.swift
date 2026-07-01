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

import XCTest
@testable import MoshroomSnippets

final class MoshroomSnippetsTests: XCTestCase {
  func testSnippets() async throws {
    let local = LocalSnippets(from: URL(fileURLWithPath: "test-snippets"))

    try local.saveSnippet(folder: "General", name: "Start SSH Connection.sh.enc", content: "ssh host_name")
    try local.saveSnippet(folder: "General", name: "Start SSH Connection.sh.enc", content: "ssh $host")

    let snippets = try await local.listSnippets()
    print(snippets)
    _ = Dictionary(uniqueKeysWithValues: snippets.lazy.map { ($0.indexable, $0) })

    try local.deleteSnippet(folder: "General", name: "Start SSH Connection.sh.enc")
  }

  func testMultilineRanges() {
    let result = Search(content: """
    git config --global user.name "${first_name_last_name}"
    git config --global user.email "${email}"
    """, searchString: "use")
    for (line, ranges) in result {
      for range in ranges {
        _ = (line as NSString).substring(with: range)
      }
    }
  }
}
