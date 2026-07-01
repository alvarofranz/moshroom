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

enum SearchMode {
  case general
  case insert
  case command
  case host
  case prompt
  case help
  case history
  
  func toString() -> String {
    switch self {
    case .general: return "General"
    case .insert: return "Insert"
    case .command: return "Command"
    case .host: return "Host"
    case .prompt: return "AI"
    case .help: return "Help"
    case .history: return "History"
    }
  }
  
  func toSymbol() -> String {
    switch self {
    case .general: return ""
    case .insert: return "<"
    case .command: return ">"
    case .host: return "@"
    case .prompt: return "$"
    case .help: return "?"
    case .history: return "!"
    }
  }
}
