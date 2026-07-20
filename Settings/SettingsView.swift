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

struct SettingsView: View {

  var onClose: () -> Void = {}

  @State private var _moshroomVersion = UIApplication.moshroomShortVersion() ?? ""
  @State private var _iCloudSyncOn = MoshroomDefaults.isICloudSyncEnabled()
  @State private var _requireBiometric = MoshroomDefaults.isRequireBiometricUnlock()
  @AppStorage(MoshxploreStyle.textSizeKey) private var _moshxploreTextSize: Int = MoshxploreStyle.defaultTextSize
  private var _iCloudAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }
  @State private var _defaultUser = MoshroomDefaults.defaultUserName() ?? ""

  // Sync status for the iCloud section: "Syncing…" while a pass runs, then "2m ago" plus one
  // honest line about what the pass saw and did ("2 hosts · 14 snips · fetched from iCloud").
  @State private var _isSyncing = HostsCloudMirror.isSyncing
  @State private var _lastSync = HostsCloudMirror.lastSyncDate
  @State private var _syncSummary = HostsCloudMirror.lastSyncSummary
  @State private var _now = Date()
  private let _clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

  var body: some View {
    List {
      Section {
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
        Row {
          HStack {
            Label("Default User", systemImage: "person")
            Spacer()
            Text(_defaultUser).foregroundColor(.secondary)
          }
        } details: {
          MoshDefaultUserView()
        }
      } header: {
        Text("Connect")
      } footer: {
        Text("Identity keys, saved hosts and SSH agent defaults.")
      }

      Section {
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
      } header: {
        Text("Terminal")
      } footer: {
        Text("Theme, font and size; keyboard shortcuts; bell and notifications.")
      }

      Section {
        HStack {
          Label("Editor Text Size", systemImage: "textformat.size")
          Spacer()
          Text("\(_moshxploreTextSize) px")
            .foregroundColor(.secondary)
            .monospacedDigit()
          Stepper("", value: $_moshxploreTextSize, in: MoshxploreStyle.textSizeRange)
            .labelsHidden()
        }
      } header: {
        Text("Moshxplore")
      } footer: {
        Text("Text size for the file viewer and editor content.")
      }

      Section {
        Toggle(isOn: $_requireBiometric) {
          Label("Require Face ID / passcode", systemImage: "faceid")
        }
        .onChange(of: _requireBiometric) { on in
          MoshroomDefaults.setRequireBiometricUnlock(on)
          MoshroomDefaults.save()
        }
      } header: {
        Text("Security")
      } footer: {
        Text("Ask for Face ID or your passcode to open Moshroom, and hide its contents in the app switcher.")
      }

      Section {
        Toggle(isOn: $_iCloudSyncOn) {
          Label("Enabled", systemImage: "icloud")
        }
        .disabled(!_iCloudAvailable)
        .onChange(of: _iCloudSyncOn) { on in
          MoshroomDefaults.setICloudSyncEnabled(on)
          MoshroomDefaults.save()
          if on { HostsCloudMirror.syncNow() }
        }

        if _iCloudSyncOn && _iCloudAvailable {
          Button {
            HostsCloudMirror.syncNow()
          } label: {
            HStack(alignment: .center) {
              Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                .foregroundColor(.primary)
              Spacer()
              if _isSyncing {
                HStack(spacing: 6) {
                  ProgressView()
                  Text("Syncing…").foregroundColor(.secondary)
                }
              } else {
                VStack(alignment: .trailing, spacing: 2) {
                  if let last = _lastSync {
                    Text(_agoLabel(last))
                  }
                  if let summary = _syncSummary {
                    Text(summary).font(.footnote)
                  }
                }
                .foregroundColor(.secondary)
              }
            }
          }
          .disabled(_isSyncing)
        }
      } header: {
        Text("Sync with iCloud")
      } footer: {
        Text(_iCloudAvailable
             ? "One switch for everything: hosts, keys, snippets, passwords and 2FA codes follow your devices — secrets end-to-end encrypted through your iCloud Keychain. Secure Enclave keys never leave this device."
             : "Sign in to iCloud to sync your hosts, keys, snippets, passwords and 2FA codes across your devices.")
      }

      Section {
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

        ShareLink(item: MoshLog.fileURL) {
          Label("Export Logs", systemImage: "square.and.arrow.up")
        }
      } header: {
        Text("About & Support")
      } footer: {
        Text("The app version, bundled licenses, and the project's home on GitHub. Export Logs shares Moshroom's on-device diagnostic log (no passwords or message contents) to help troubleshoot.")
      }
    }
    .onAppear {
      MoshLog.ensureFileExists()   // so Export Logs always has a real file to share
      _iCloudSyncOn = MoshroomDefaults.isICloudSyncEnabled()
      _requireBiometric = MoshroomDefaults.isRequireBiometricUnlock()
      _defaultUser = MoshroomDefaults.defaultUserName() ?? ""
      _isSyncing = HostsCloudMirror.isSyncing
      _lastSync = HostsCloudMirror.lastSyncDate
      _syncSummary = HostsCloudMirror.lastSyncSummary
      _now = Date()
    }
    .onReceive(NotificationCenter.default.publisher(for: HostsCloudMirror.syncStateNotification)) { _ in
      _isSyncing = HostsCloudMirror.isSyncing
      _lastSync = HostsCloudMirror.lastSyncDate
      _syncSummary = HostsCloudMirror.lastSyncSummary
      _now = Date()
    }
    .onReceive(_clock) { now in
      _now = now   // keeps the "2m ago" label honest while the screen sits open
    }
    .listStyle(.insetGrouped)
    .moshReadableWidth()
    .moshHubChrome(title: "Settings", leading: {
      Button(action: onClose) { MoshNavGlyph(systemName: "xmark") }
        .buttonStyle(.plain)
        .moshCatalystPlainButtons()
        .accessibilityLabel("Close")
    })
    .tint(.moshTint)

  }

  // Best-fitting single unit — "just now", "5m ago", "3h ago", "2d ago". Simple and clean.
  private func _agoLabel(_ date: Date) -> String {
    let seconds = Int(_now.timeIntervalSince(date))
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86400 { return "\(seconds / 3600)h ago" }
    return "\(seconds / 86400)d ago"
  }
}

// The Default User editor — plain SwiftUI in the house style (replaces the old storyboard table).
// Spaces are stripped as you type, like the host alias field; saved on the way out, and only when
// non-empty (matching the previous behavior).
struct MoshDefaultUserView: View {
  @State private var _name = MoshroomDefaults.defaultUserName() ?? ""

  var body: some View {
    List {
      Section {
        TextField("Username", text: $_name)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .onChange(of: _name) { value in
            let sanitized = value.replacingOccurrences(of: " ", with: "")
            if sanitized != value { _name = sanitized }
          }
      } footer: {
        Text("Used to connect when a host doesn't set its own user.")
      }
    }
    .listStyle(.insetGrouped)
    .moshReadableWidth()
    .moshHubChromeBack(title: "Default User")
    .onDisappear {
      guard !_name.isEmpty else { return }
      MoshroomDefaults.setDefaultUserName(_name)
      MoshroomDefaults.save()
    }
  }
}
