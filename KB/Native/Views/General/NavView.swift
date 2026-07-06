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


import UIKit
import SwiftUI

class Nav: ObservableObject {
  let navController: UINavigationController
  
  init(navController: UINavigationController) {
    self.navController = navController
  }  
}

struct NavView<Content: View>: View {
  var content: () -> Content
  let nav: Nav
  
  init(navController: UINavigationController, content: @escaping () -> Content) {
    self.content = content
    self.nav = Nav(navController: navController)
  }
  
  var body: some View {
    content().environmentObject(nav)
  }
}

