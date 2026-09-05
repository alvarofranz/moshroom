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
  @AppStorage(Moshify.cacheGBKey) private var _moshifyCacheGB: Int = 2
  private var _iCloudAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

  // Sync status for the iCloud section: "Syncing…" while a pass runs, then "2m ago" plus one
  // honest line about what the pass saw and did ("2 hosts · 14 snips · fetched from iCloud").
  @State private var _isSyncing = HostsCloudMirror.isSyncing
  @State private var _lastSync = HostsCloudMirror.lastSyncDate
  @State private var _syncSummary = HostsCloudMirror.lastSyncSummary
  @State private var _syncStatus = HostsCloudMirror.lastSyncStatus
  // The secrets half of sync — how much rides the iCloud Keychain, how much is still device-only, and
  // whether any identity is stuck holding a public half with no private one. Counts only (Moshsync).
  @State private var _health: Moshsync.Health? = nil
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
        HStack {
          Label("Music Cache", systemImage: "music.note")
          Spacer()
          Text("\(_moshifyCacheGB) GB")
            .foregroundColor(.secondary)
            .monospacedDigit()
          Stepper("", value: $_moshifyCacheGB, in: 1...8)
            .labelsHidden()
        }
      } header: {
        Text("Moshify")
      } footer: {
        Text("One budget for all your music, whichever server or tab it came from. When it is full, the tracks you played longest ago make room for the ones playing next.")
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
          // Turning it on is a full pass, secrets included: everything already on this device gets
          // re-written into the iCloud Keychain, not just what gets saved from now on.
          if on { HostsCloudMirror.syncNow() }
          _refreshHealth()
        }

        if _iCloudSyncOn && _iCloudAvailable {
          // What the last pass saw, one line per kind. A single trailing paragraph of counts was
          // unreadable; a row each reads like a receipt and has room to breathe.
          if let status = _syncStatus {
            ForEach(status.counts, id: \.label) { item in
              HStack {
                Text(item.label).foregroundColor(.secondary)
                Spacer()
                Text("\(item.count)").monospacedDigit()
              }
              .font(.subheadline)
            }
            HStack(alignment: .firstTextBaseline) {
              Text("Last sync").foregroundColor(.secondary)
              Spacer()
              VStack(alignment: .trailing, spacing: 2) {
                if _isSyncing {
                  HStack(spacing: 6) { ProgressView(); Text("Syncing…") }
                } else if let last = _lastSync {
                  Text(_agoLabel(last))
                }
                Text(status.state)
              }
              .multilineTextAlignment(.trailing)
            }
            .font(.subheadline)
          } else if let summary = _syncSummary {
            // Before the first structured pass (or an unavailable container): the plain sentence.
            Text(summary).font(.subheadline).foregroundColor(.secondary)
          }

          if let health = _health, !health.isEmpty {
            HStack {
              Text("Secrets").foregroundColor(.secondary)
              Spacer()
              Text(health.label).monospacedDigit()
            }
            .font(.subheadline)
          }

          if let health = _health, health.incompleteKeys > 0 {
            // The one state a user cannot diagnose alone: the record travelled, the private half did
            // not. Named here, in the sync section, because that is where they come looking.
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(health.incompleteKeys == 1
                     ? "1 key is waiting for its private half"
                     : "\(health.incompleteKeys) keys are waiting for their private half")
              }
              Text(Moshsync.incompleteKeysHint)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
          }

          // Sync Now closes the section: the status above is what you read, this is what you press.
          Button {
            HostsCloudMirror.syncNow()
          } label: {
            HStack {
              Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                .foregroundColor(.primary)
              Spacer()
              if _isSyncing { ProgressView() }
            }
          }
          .disabled(_isSyncing)
        }
      } header: {
        Text("Sync with iCloud")
      } footer: {
        Text(_iCloudAvailable
             ? "One switch for everything: hosts, keys, snippets, passwords and 2FA codes follow your devices — secrets end-to-end encrypted through your iCloud Keychain. Turning it on brings across what you already had, not just what you save next. Turning it off stops new secrets from syncing and leaves the ones already in your iCloud Keychain alone, so no other device loses anything. Secure Enclave keys never leave this device."
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
      _isSyncing = HostsCloudMirror.isSyncing
      _lastSync = HostsCloudMirror.lastSyncDate
      _syncSummary = HostsCloudMirror.lastSyncSummary
      _syncStatus = HostsCloudMirror.lastSyncStatus
      _now = Date()
      _refreshHealth()
    }
    .onReceive(NotificationCenter.default.publisher(for: HostsCloudMirror.syncStateNotification)) { _ in
      _isSyncing = HostsCloudMirror.isSyncing
      _lastSync = HostsCloudMirror.lastSyncDate
      _syncSummary = HostsCloudMirror.lastSyncSummary
      _syncStatus = HostsCloudMirror.lastSyncStatus
      _now = Date()
      _refreshHealth()
    }
    .onReceive(_clock) { now in
      _now = now   // keeps the "2m ago" label honest while the screen sits open
    }
    .listStyle(.insetGrouped)
    // Sections need a visible gap: the default spacing ran them together into one grey slab.
    .listSectionSpacing(26)
    .moshReadableWidth()
    .moshHubChrome(title: "Settings", leading: {
      Button(action: onClose) { MoshNavGlyph(systemName: "xmark") }
        .buttonStyle(.plain)
        .moshCatalystPlainButtons()
        .accessibilityLabel("Close")
    })
    .tint(.moshTint)

  }

  // A handful of keychain attribute queries — no values read, nothing decrypted — and it has to run
  // where MoshPubKey lives, which is the main thread.
  private func _refreshHealth() {
    _health = MoshroomDefaults.isICloudSyncEnabled() ? Moshsync.health() : nil
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
