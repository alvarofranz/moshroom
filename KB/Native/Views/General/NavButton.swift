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


import SwiftUI

struct NavButton<Details: View>: View {
  @EnvironmentObject var nav: Nav
  var details: () ->  Details
  
  var body: some View {
    Button(action: {
      let rootView = self.details().environmentObject(self.nav)
      let vc = UIHostingController(rootView: rootView)
      self.nav.navController.pushViewController(vc, animated: true)
      }, label: { EmptyView() })
    // NB: never apply a button style here NOR wrap the pushed rootView in one. This row-tap button
    // has an EmptyView label, and so do the nested Row/NavButtons inside detail screens — a
    // .borderless style collapses their hit target and kills navigation on Catalyst. Screens that
    // need the iOS-flat look style their specific (visible-label) nav-bar buttons directly instead.
  }
}
struct StoryBoardNavButton: View {
  @EnvironmentObject var nav: Nav
  var storyBoardID: String
  
  var body: some View {
    Button(action: {
//      let rootView = self.details().environmentObject(self.nav)
//      let vc = UIHostingController(rootView: rootView)
      let storyboard = UIStoryboard(name: "Settings", bundle: nil)
      let vc = storyboard.instantiateViewController(identifier: storyBoardID)
      self.nav.navController.pushViewController(vc, animated: true)
      }, label: { EmptyView() })
  }
}
