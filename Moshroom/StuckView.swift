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

struct StuckView: View {
  private var _emojies = ["😱", "🤪", "🧐", "🥺", "🤔", "🤭", "🙈", "🙊"]
  var keyCode: KeyCode
  var dismissAction: () -> ()
  
  init(keyCode: KeyCode, dismissAction: @escaping () -> ()) {
    self.keyCode = keyCode
    self.dismissAction = dismissAction
  }
  
  var body: some View {
      VStack {
        HStack {
          Spacer()
          Button("Close", action: dismissAction)
        }.padding()
        Spacer()
        Text(_emojies.randomElement() ?? "🤥").font(.system(size: 60)).padding(.bottom, 26)
        Text("Stuck key detected.").font(.headline).padding(.bottom, 30)
        Text("Press \(keyCode.fullName) key").font(.system(size: 30))
        Spacer()
      }
  }
}
