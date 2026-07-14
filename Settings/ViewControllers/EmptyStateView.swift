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
import SwiftUI

/// THE empty state — one look for every "nothing here yet" screen in the app (hosts, keys,
/// vault, 2FA, shortcuts…): a mushroom-red icon, a short title, an optional explainer and an
/// optional action, centered at a readable width.
struct MoshEmptyState<Action: View>: View {
  let icon: String
  let title: String
  var message: String = ""
  @ViewBuilder let action: () -> Action

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: icon)
        .font(.system(size: 44))
        .foregroundColor(.moshTint)
      Text(title).font(.title3.weight(.semibold))
      if !message.isEmpty {
        Text(message)
          .font(.callout)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      action()
        .font(.headline)
        .foregroundColor(.moshTint)
        .padding(.top, 6)
    }
    .padding(32)
    .frame(maxWidth: 420)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

extension MoshEmptyState where Action == EmptyView {
  init(icon: String, title: String, message: String = "") {
    self.init(icon: icon, title: title, message: message, action: { EmptyView() })
  }
}
