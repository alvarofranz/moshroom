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
import MoshroomConfig

// Mirrors the local SSH-hosts blob (`~/.moshroom/hosts`) to and from iCloud Drive while
// "Sync with iCloud" is on. The local file stays the synchronous, authoritative source the connect
// path reads — iCloud Drive is only a background mirror, with whole-file **last-writer-wins** by
// modification date. Keys and passwords are deliberately NOT synced: they live in the device
// Keychain, so a synced host that uses one is set up per device.
//
// It self-installs once (`install()` from AppDelegate): it pushes whenever hosts are saved (the
// `MoshroomHostsDidSave` notification posted by `MoshHosts saveHosts`) and pulls on every foreground
// (and once at launch). All file work runs off the main thread with NSFileCoordinator; the only
// main-thread step is reloading `MoshHosts` after a pull.
@objc final class HostsCloudMirror: NSObject {

  // Posted by MoshHosts after the local hosts file is written (kept in sync with MoshHosts.m).
  static let didSaveNotification = Notification.Name("MoshroomHostsDidSave")
  // Posted (main thread) after a pull replaced the local hosts — open UI can refresh off it.
  static let didChangeNotification = Notification.Name("MoshroomHostsDidChangeFromICloud")

  private static let queue = DispatchQueue(label: "moshroom.hosts.cloudmirror", qos: .utility)
  private static var installed = false

  // MARK: - Lifecycle

  @objc static func install() {
    guard !installed else { return }
    installed = true
    let nc = NotificationCenter.default
    nc.addObserver(forName: didSaveNotification, object: nil, queue: nil) { _ in push() }
    nc.addObserver(forName: UIScene.willEnterForegroundNotification, object: nil, queue: nil) { _ in
      pullFromICloudIfNewerAndReload()
    }
    pullFromICloudIfNewerAndReload()   // launch pull
  }

  // Sync is on AND iCloud Drive is reachable for this account.
  private static var isActive: Bool {
    MoshroomDefaults.isICloudSyncEnabled() && FileManager.default.ubiquityIdentityToken != nil
  }

  private static var localURL: URL {
    URL(fileURLWithPath: MoshroomPaths.moshroomHostsFile())
  }

  // MARK: - Push (local → iCloud)

  @objc static func push() {
    guard isActive, let cloudURL = MoshroomPaths.iCloudHostsLocationURL() else { return }
    let local = localURL
    queue.async {
      guard let data = try? Data(contentsOf: local) else { return }
      let localDate = modificationDate(of: local)
      var coordError: NSError?
      NSFileCoordinator().coordinate(writingItemAt: cloudURL, options: .forReplacing, error: &coordError) { dst in
        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? data.write(to: dst, options: .atomic)) != nil else { return }
        // Stamp the cloud copy with the local mod date so this device never pulls back its own push.
        if let localDate {
          try? FileManager.default.setAttributes([.modificationDate: localDate], ofItemAtPath: dst.path)
        }
      }
    }
  }

  // MARK: - Pull (iCloud → local, only if newer)

  @objc static func pullFromICloudIfNewerAndReload() {
    guard isActive, let cloudURL = MoshroomPaths.iCloudHostsLocationURL() else { return }
    let local = localURL
    queue.async {
      try? FileManager.default.startDownloadingUbiquitousItem(at: cloudURL)
      var pulled: (data: Data, date: Date)?
      var coordError: NSError?
      NSFileCoordinator().coordinate(readingItemAt: cloudURL, options: [], error: &coordError) { src in
        guard FileManager.default.fileExists(atPath: src.path),
              let cloudDate = modificationDate(of: src) else { return }
        let localDate = modificationDate(of: local)
        guard localDate == nil || cloudDate > localDate!,
              let data = try? Data(contentsOf: src) else { return }
        pulled = (data, cloudDate)
      }
      guard let pulled else { return }
      guard (try? pulled.data.write(to: local, options: .atomic)) != nil else { return }
      // Match the local mod date to the cloud's so the next comparison is stable (no re-pull loop).
      try? FileManager.default.setAttributes([.modificationDate: pulled.date], ofItemAtPath: local.path)
      DispatchQueue.main.async {
        MoshHosts.loadHosts()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
      }
    }
  }

  private static func modificationDate(of url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }
}
