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

enum KeyUIError: Error, LocalizedError {
  case emptyName
  case duplicateName(name: String)
  case authKeyGenerationFailed
  case saveCardFailed
  case generationFailed
  case noReadAccess
  
  var errorDescription: String? {
    switch self {
    case .emptyName: return "Key name can't be empty."
    case .duplicateName(let name): return "Key with name `\(name)` already exists."
    case .authKeyGenerationFailed: return "Could not generate public key."
    case .saveCardFailed: return "Can't save key."
    case .generationFailed: return "Generation failed."
    case .noReadAccess: return "Can't get read access to file."
    }
  }
}
