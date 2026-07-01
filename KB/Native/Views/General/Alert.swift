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

struct AlertModifier: ViewModifier {
  @Binding var errorMessage: String
  
  private var _isPresented: Binding<Bool> {
    Binding(get: { !errorMessage.isEmpty }, set: { _ in errorMessage = ""})
  }
  
  func body(content: Content) -> some View {
    content.alert(isPresented: _isPresented) {
      Alert(
        title: Text("Error"),
        message: Text(errorMessage),
        dismissButton: .default(Text("Ok"))
      )
    }
  }
}

extension View {
  func alert(errorMessage: Binding<String>) -> some View {
    modifier(AlertModifier(errorMessage: errorMessage))
  }
}
