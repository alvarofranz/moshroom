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
import SafariServices
import SwiftUI


class DummyVC: UIViewController {
  override var canBecomeFirstResponder: Bool { true }
  override var prefersStatusBarHidden: Bool { true }
  public override var prefersHomeIndicatorAutoHidden: Bool { true }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow? = nil
  private var _ctrl = DummyVC()
  private var _lockCtrl: UIViewController? = nil
  private var _spCtrl = SpaceController()

  override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
    super.editingInteractionConfiguration
  }

  /**
   Handles the `ssh://` URL scheme.
   */
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {

    if let sshUrlScheme = URLContexts.first(where: { $0.url.scheme == "ssh" })?.url {
      _handleSshUrlScheme(with: sshUrlScheme)
    }
  }

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions)
  {
    _ = KBTracker.shared

    guard let windowScene = scene as? UIWindowScene else {
      return
    }

    defer {
    }

    let conditions = scene.activationConditions

    conditions.canActivateForTargetContentIdentifierPredicate = NSPredicate(value: true)
    conditions.prefersToActivateForTargetContentIdentifierPredicate = NSPredicate(format: "SELF == 'moshroom://open-scene/\(scene.session.persistentIdentifier)'")

    _spCtrl.restoreWith(stateRestorationActivity: session.stateRestorationActivity)

    let window = UIWindow(windowScene: windowScene)
    self.window = window

    window.rootViewController = _spCtrl
    window.isHidden = false

    // Await until scene and streams are ready
    // NOTE We could also store the contexts and use them later.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      self.scene(scene, openURLContexts: connectionOptions.urlContexts)
    }
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    guard let window = window else {
      return
    }

    // 1. Local Auth AutoLock Check

    if LocalAuth.shared.lockRequired {
      if let lockCtrl = _lockCtrl {
        if window.rootViewController != lockCtrl {
          window.rootViewController = lockCtrl
        }

        return
      }

      let unlockAction = scene.session.role == .windowApplication ? LocalAuth.shared.unlock : nil

      _lockCtrl = UIHostingController(rootView: LockView(unlockAction: unlockAction))
      window.rootViewController = _lockCtrl

      unlockAction?()

      return
    }

    _lockCtrl = nil
    LocalAuth.shared.stopTrackTime()

    // 2. Set space controller back and refresh layout

    let spCtrl = _spCtrl

    if window.rootViewController != spCtrl {
      window.rootViewController = spCtrl
    }

    guard let term = spCtrl.currentTerm() else {
      return
    }

    term.resumeIfNeeded()
    term.view?.setNeedsLayout()

    // We can present config or stuck view.
    guard spCtrl.presentedViewController == nil else {
      return
    }

    // 3. Stuck Key Check

    let input = KBTracker.shared.input
    if let key = input?.stuckKey() {
      input?.setTrackingModifierFlags([])

      if input?.isHardwareKB == true && key == .commandLeft {
        let ctrl = UIHostingController(rootView: StuckView(keyCode: key, dismissAction: {
          spCtrl.onStuckOpCommand()
        }))

        ctrl.modalPresentationStyle = .formSheet
        spCtrl.stuckKeyCode = key
        spCtrl.present(ctrl, animated: false)

        return
      }
    }

    spCtrl.stuckKeyCode = nil

    // 4. Focus Check

    if input == nil {
      DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) {
        if KBTracker.shared.input == nil {
          window.makeKey()
          spCtrl.focusOnShellAction()
          KBTracker.shared.input?.reportFocus(true)
        }
      }
      return
    }

    if term.termDevice.view?.isFocused() == false,
      input?.isRealFirstResponder == false,
      input?.window === window {
      DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) {
        if scene.activationState == .foregroundActive,
          input?.isRealFirstResponder == false {
          spCtrl.focusOnShellAction()
        }
      }

      return
    }

    if input?.window === window {
      DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) {
        if scene.activationState == .foregroundActive,
          term.termDevice.view?.isFocused() == false {
          spCtrl.focusOnShellAction()
        }
      }

      return
    }

    input?.reportStateReset()
  }

  func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
    _setDummyVC()
    return _spCtrl.stateRestorationActivity()
  }

  private func _setDummyVC() {
    if let _ = _spCtrl.presentedViewController {
      return
    }
    // Trick to reset stick cmd key.
    _ctrl.view.frame = _spCtrl.view.frame
    window?.rootViewController = _ctrl
    _ctrl.view.addSubview(_spCtrl.view)
  }

  @objc var spaceController: SpaceController { _spCtrl }

}

// MARK: Manage the `scene(_:openURLContexts:)` actions
extension SceneDelegate {

  /*
   Handles the `ssh://` URL scheme.
   */
  private func _handleSshUrlScheme(with sshUrl: URL) {
    func buildSSHCommand(from url: URL) -> String? {
      // Goal is to tokenize a SSH Command. The risk is that the URL may contian injection parameters.
      // We sanitize the input and make sure the result, specially the user@host part is a valid shell token.
      // The SSH library takes care of validating the host, user, etc...
      guard url.scheme == "ssh" else { return nil }
      guard let host = url.host?.removingPercentEncoding,
            host.rangeOfCharacter(from: .controlCharacters) == nil,
            host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            !host.starts(with:"-"),
            !host.starts(with:".") else {
        return nil
      }

      var sshCommand = "ssh "

      if let port = url.port {
        sshCommand += "-p \(port) "
      }

      if let userinfo = url.user?.removingPercentEncoding,
         userinfo.rangeOfCharacter(from: .controlCharacters) == nil {
        // Extract only the username before the first ";" if conn-params exist
        let username = userinfo.components(separatedBy: ";").first ?? ""
        guard username.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !username.starts(with:"-"),
              !username.starts(with:".") else {
          return nil
        }

        if username.count > 0 {
          sshCommand += "-l \(username) "
        }
      }

      sshCommand += "\(host)"
      return sshCommand
    }

    guard let sshCommand = buildSSHCommand(from: sshUrl),
          sshCommand.rangeOfCharacter(from: .controlCharacters) == nil else {
      return
    }

    _spCtrl.runShellSessionIntent(command: sshCommand)
  }

}
