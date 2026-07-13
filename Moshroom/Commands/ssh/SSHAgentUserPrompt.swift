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

import SSH

// Request confirmation from the user to utilize a specific key by a connection.
// Notes. In the future we could add biometric checks here, but I prefer to have them in the keys.
public class SSHAgentUserPrompt: SSHAgentConstraint {
  public var name: String { "User Prompt" }
  var window: UIWindow? = nil
  var promptSelection: MoshAgentForward = MoshAgentForwardConfirm

  public func enforce(useOf key: SSH.SSHAgentKey, by client: SSH.SSHClient) -> Bool {
    // Short-circuit based on previous selection
    if promptSelection == MoshAgentForwardNo {
      return false
    } else if promptSelection == MoshAgentForwardYes {
      return true
    }

    let semaphore = DispatchSemaphore(value: 0)
    var shouldForwardKey: Bool = false
    
    let alert = UIAlertController(title: "Agent", message: "Forward key \"\(key.name)\" on \(client.host)?", preferredStyle: .alert)
    alert.addAction(
      UIAlertAction(title: NSLocalizedString("Forward Once", comment: "Forward the key this time"),
                    style: .default,
                    handler: { _ in
                      shouldForwardKey = true
                      semaphore.signal()
                      self.window = nil
                    }))
    alert.addAction(
      UIAlertAction(title: NSLocalizedString("Forward this Session", comment: "Forward the key for the this session lifetime"),
                    style: .default,
                    handler: { _ in
                      self.promptSelection = MoshAgentForwardYes
                      shouldForwardKey = true
                      semaphore.signal()
                      self.window = nil
                    }))
    alert.addAction(
      UIAlertAction(title: NSLocalizedString("Do not forward", comment: "Do not forward"),
                    style: .cancel,
                    handler: { _ in
                      self.promptSelection = MoshAgentForwardNo
                      shouldForwardKey = false
                      semaphore.signal()
                      self.window = nil
                    }))

    DispatchQueue.main.async {
      let foregroundActiveScene = UIApplication.shared.connectedScenes.filter { $0.activationState == .foregroundActive }.first
      guard let foregroundWindowScene = foregroundActiveScene as? UIWindowScene else {
        semaphore.signal()
        return
      }
      
      let window = UIWindow(windowScene: foregroundWindowScene)
      self.window = window
      window.rootViewController = UIViewController()
      window.windowLevel = .alert + 1
      window.makeKeyAndVisible()
      window.rootViewController!.present(alert, animated: true, completion: nil)
    }

    semaphore.wait()

    return shouldForwardKey
  }
}
