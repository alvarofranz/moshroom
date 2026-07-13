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

extension MoshMoshPrediction: Hashable {
  var label: String {
    switch self {
    case MoshMoshPredictionAdaptive: return "Adaptive"
    case MoshMoshPredictionAlways: return "Always"
    case MoshMoshPredictionNever: return "Never"
    case MoshMoshPredictionExperimental: return "Experimental"
    case _: return ""
    }
  }
  
  var hint: String {
    switch self {
    case MoshMoshPredictionAdaptive: return "Local echo for slower links [default]"
    case MoshMoshPredictionAlways: return "Use local echo even on fast links"
    case MoshMoshPredictionNever: return "Never use local echo"
    case MoshMoshPredictionExperimental: return "Aggressively echo even when incorrect"
    case _: return ""
    }
  }

  static var all: [MoshMoshPrediction] {
    [
      MoshMoshPredictionAdaptive,
      MoshMoshPredictionAlways,
      MoshMoshPredictionNever,
      MoshMoshPredictionExperimental
    ]
  }
}

extension MoshMoshExperimentalIP: Hashable {
  var label: String {
    switch self {
    case MoshMoshExperimentalIPNone: return "None"
    case MoshMoshExperimentalIPLocal: return "Local"
    case MoshMoshExperimentalIPRemote: return "Remote"
    case _: return ""
    }
  }
  
  var hint: String {
    switch self {
    case MoshMoshExperimentalIPNone: return "No experimental IP resolution"
    case MoshMoshExperimentalIPLocal: return "Resolve the IP locally"
    case MoshMoshExperimentalIPRemote: return "Resolve the IP in the remote"
    case _: return ""
    }
  }

  static var all: [MoshMoshExperimentalIP] {
    [
      MoshMoshExperimentalIPNone,
      MoshMoshExperimentalIPLocal,
      MoshMoshExperimentalIPRemote,
    ]
  }
}

struct MoshCustomOptionsPickerView: View {
  @Binding var predictionValue: MoshMoshPrediction
  @Binding var overwriteValue: Bool
  @Binding var experimentalIPValue: MoshMoshExperimentalIP
  
  var body: some View {
    List {
      Section(footer: Text(predictionValue.hint)) {
        ForEach(MoshMoshPrediction.all, id: \.self) { value in
          HStack {
            Text(value.label).tag(value)
            Spacer()
            Checkmark(checked: predictionValue == value)
          }
          .contentShape(Rectangle())
          .onTapGesture { predictionValue = value }
        }
      }
      Section(footer: Text("Prediction overwrites instead of inserting")) {
        HStack {
          Toggle("Overwrite", isOn: $overwriteValue)
        }
      }
      Section(footer: Text(experimentalIPValue.hint)) {
        ForEach(MoshMoshExperimentalIP.all, id: \.self) { value in
          HStack {
            Text(value.label).tag(value)
            Spacer()
            Checkmark(checked: experimentalIPValue == value)
          }
          .contentShape(Rectangle())
          .onTapGesture { experimentalIPValue = value }
        }
      }
    }
    .listStyle(InsetGroupedListStyle())
    .navigationTitle("Mosh Options")
  }
}
