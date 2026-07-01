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
import SwiftUI
import LocalAuthentication

struct SettingsView: View {

  @EnvironmentObject private var _nav: Nav
  @State private var _biometryType = LAContext().biometryType
  @State private var _moshroomVersion = UIApplication.moshroomShortVersion() ?? ""
  @State private var _iCloudSyncOn = MoshroomDefaults.isICloudSyncEnabled()
  private var _iCloudAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }
  @State private var _autoLockOn = MoshUserConfigurationManager.userSettingsValue(forKey: MoshUserConfigAutoLock)
  @State private var _defaultUser = MoshroomDefaults.defaultUserName() ?? ""

  var body: some View {
    List {
      Section("Connect") {
        Row {
          Label("Keys & Certificates", systemImage: "key")
        } details: {
          KeyListView()
        }
        Row {
          Label("Hosts", systemImage: "server.rack")
        } details: {
          HostListView()
        }
        Row {
          Label("Default Agent", systemImage: "key.viewfinder")
        } details: {
          DefaultAgentSettingsView()
        }
        RowWithStoryBoardId(content: {
          HStack {
            Label("Default User", systemImage: "person")
            Spacer()
            Text(_defaultUser).foregroundColor(.secondary)
          }
        }, storyBoardId: "MoshDefaultUserViewController")
      }

      Section("Terminal") {
        Row {
          Label("Style", systemImage: "paintpalette")
        } details: {
          StyleCustomizationView()
        }
        Row {
          Label("Keyboard", systemImage: "keyboard")
        } details: {
          KBConfigView(config: KBTracker.shared.loadConfig())
        }
        Row {
          Label("Notifications", systemImage: "bell")
        } details: {
          MoshNotificationsView()
        }
      }

      Section {
        Toggle(isOn: $_iCloudSyncOn) {
          Label("Sync with iCloud", systemImage: "icloud")
        }
        .disabled(!_iCloudAvailable)
        .onChange(of: _iCloudSyncOn) { on in
          MoshroomDefaults.setICloudSyncEnabled(on)
          MoshroomDefaults.save()
          if on {
            HostsCloudMirror.pullFromICloudIfNewerAndReload()
            HostsCloudMirror.push()
          }
        }

        RowWithStoryBoardId(content: {
          HStack {
            Label("Auto Lock", systemImage: _biometryType == .faceID ? "faceid" : "touchid")
            Spacer()
            Text(_autoLockOn ? "On" : "Off").foregroundColor(.secondary)
          }
        }, storyBoardId: "MoshSecurityConfigurationViewController")
      } header: {
        Text("Configuration")
      } footer: {
        Text(_iCloudAvailable
             ? "Hosts and snippets sync across your devices through iCloud Drive. Keys and passwords stay on each device."
             : "Sign in to iCloud to sync hosts and snippets across your devices.")
      }

      Section("About & Support") {
        RowWithStoryBoardId(content: {
          HStack {
            Label("About", systemImage: "questionmark.circle")
            Spacer()
            Text(_moshroomVersion).foregroundColor(.secondary)
          }
        }, storyBoardId: "MoshAboutViewController")

        Row {
          Label("Support", systemImage: "book")
        } details: {
          SupportView()
        }
      }
    }
    .onAppear {
      _iCloudSyncOn = MoshroomDefaults.isICloudSyncEnabled()
      _autoLockOn = MoshUserConfigurationManager.userSettingsValue(forKey: MoshUserConfigAutoLock)
      _defaultUser = MoshroomDefaults.defaultUserName() ?? ""

    }
    .listStyle(.grouped)
    .navigationTitle("Settings")

  }
}
