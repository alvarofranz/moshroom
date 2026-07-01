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

struct EmptyStateHandlerView: View {
  
  let action: (() -> Void)
  let title: String
  let systemIconName: String
  
  init(action: @escaping (() -> Void), title: String, systemIconName: String) {
    self.title = title
    self.action = action
    self.systemIconName = systemIconName
  }
  
  var body: some View {
    VStack {
      Spacer()
      VStack {
        HStack {
          Label(title, systemImage: "plus")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 18.5))
        }
        Image(systemName: systemIconName).imageScale(.large).opacity(0.7)
          .padding(.init(top: 12, leading: 0, bottom: 20, trailing: 0))
      }
      .foregroundStyle(Color(.moshroomTint))
      .onTapGesture {
        action()
      }
      Spacer()
    }
  }
}

struct EmptyStateView<Action: View>: View {
  
  let action: Action
  let systemIconName: String
  let description: String
  let learnMoreURL: URL?
  
  init(action: Action, systemIconName: String, description: String = "", learnMoreURL: URL? = nil) {
    self.action = action
    self.systemIconName = systemIconName
    self.description = description
    self.learnMoreURL = learnMoreURL
  }
  
  var body: some View {
    VStack {
      Spacer()
      
      Image(systemName: systemIconName)
        .resizable()
        .scaledToFit()
        .frame(width: 80, height: 80)
        .foregroundColor(.accentColor)
        .padding(.bottom, 12)
      
      if !description.isEmpty {
        Text(description)
          .font(.callout)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 20)
      }
      
      action
        .font(.headline)
        .foregroundColor(.accentColor)
        .padding(.top, 12)
      
      Spacer()
      
      Divider()
        .padding(.horizontal, 40)
      
      if let learnMoreURL = learnMoreURL {
        Button(action: {
          UIApplication.shared.open(learnMoreURL, options: [:], completionHandler: nil)
        }) {
          Text("Learn More")
            .font(.footnote)
            .underline()
            .foregroundColor(Color(.moshroomTint))
        }
        .padding(.top, 8)
        .padding(.bottom, 20)
      }
    }
    .padding()
  }
}
