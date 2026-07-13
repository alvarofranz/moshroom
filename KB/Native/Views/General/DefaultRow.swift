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

struct DefaultRow<Details: View>: View {
  @Binding var title: String
  @Binding var description: String?
  var details: () ->  Details
  
  init(title: String, description: String? = nil, details: @escaping () -> Details) {
    _title = .constant(title)
    _description = .constant(description)
    self.details = details
  }
  
  init(title: Binding<String>, description: Binding<String?> = .constant(nil), details: @escaping () -> Details) {
    _title = title
    _description = description
    self.details = details
  }
  
  var body: some View {
    Row(content: {
      HStack {
        Text(self.title).foregroundColor(.primary)
        Spacer()
        Text(self.description ?? "").foregroundColor(.secondary)
      }
    }, details: self.details)
  }
}
