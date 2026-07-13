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
import LocalAuthentication

// Biometric/passcode gate for sensitive one-off actions (revealing or copying a private key).
@objc class LocalAuth: NSObject {

  @objc static let shared = LocalAuth()

  private var _inProgress = false

  override init() {
    super.init()
    // warm up LAContext
    LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
  }

  @objc func authenticate(callback: @escaping (_ success: Bool) -> Void, reason: String = "to access sensitive data.") {
    if _inProgress {
      callback(false)
      return
    }
    _inProgress = true
    
    let context = LAContext()
    var error: NSError?
    guard
      context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    else {
      debugPrint(error?.localizedDescription ?? "Can't evaluate policy")
      _inProgress = false
      callback(false)
      return
    }

    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason ) { success, error in
      DispatchQueue.main.async {
        self._inProgress = false
        callback(success)
      }
    }
  }
}
