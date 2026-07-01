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
import UIKit

extension Set where Element == UIScene {
  func activeAppScene(exclude: UIScene? = nil) -> UIWindowScene? {
    first { scene -> Bool in
      let isForeground = (scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive)
        
      return isForeground
        && scene.session.role == .windowApplication
        && scene != exclude
        && scene as? UIWindowScene != nil
    } as? UIWindowScene
  }
}
