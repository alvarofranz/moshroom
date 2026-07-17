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

struct PublishingOptions: OptionSet, CustomStringConvertible, CustomDebugStringConvertible {
  let rawValue: UInt8
  
  static let developer  = Self.init(rawValue: 1 << 0)
  static let testFlight = Self.init(rawValue: 1 << 1)
  static let appStore   = Self.init(rawValue: 1 << 2)
  
  static let legacyDeveloper  = Self.init(rawValue: 1 << 3)
  static let legacyTestFlight = Self.init(rawValue: 1 << 4)
  static let legacyAppStore   = Self.init(rawValue: 1 << 5)
  
#if MOSHROOM_LEGACY_PUBLISHING_OPTION_DEVELOPER
  static var current: Self  = .legacyDeveloper
#elseif MOSHROOM_LEGACY_PUBLISHING_OPTION_TESTFLIGHT
  static var current: Self  = .legacyTestFlight
#elseif MOSHROOM_LEGACY_PUBLISHING_OPTION_APPSTORE
  static var current: Self  = .legacyAppStore
#elseif MOSHROOM_PUBLISHING_OPTION_DEVELOPER
  static var current: Self  = .developer
#elseif MOSHROOM_PUBLISHING_OPTION_TESTFLIGHT
  static var current: Self  = .testFlight
#else
  static var current: Self  = .appStore
#endif
  
  var description: String {
    var result: [String] = []
    if self.contains(.developer) {
      result.append("Developer")
    }
    if self.contains(.testFlight) {
      result.append("Test Flight")
    }
    if self.contains(.appStore) {
      result.append("App Store")
    }
    
    if self.contains(.legacyDeveloper) {
      result.append("v14 Developer")
    }
    
    if self.contains(.legacyTestFlight) {
      result.append("v14 Test Flight")
    }
    
    if self.contains(.legacyAppStore) {
      result.append("v14 App Store")
    }
    
    return "(" + result.joined(separator: ", ") + ")"
  }
  
  var debugDescription: String {
    var result: [String] = []
    if self.contains(.developer) {
      result.append("developer")
    }
    if self.contains(.testFlight) {
      result.append("testFlight")
    }
    if self.contains(.appStore) {
      result.append("appStore")
    }
    
    if self.contains(.legacyDeveloper) {
      result.append("developer-legacy")
    }
    
    if self.contains(.legacyTestFlight) {
      result.append("testFlight-Legacy")
    }
    
    if self.contains(.legacyAppStore) {
      result.append("appStore-Legacy")
    }
    
    return "[" + result.joined(separator: ", ") + "]"
  }
}

@objc class FeatureFlags: NSObject {
  
  @available(*, unavailable)
  override init() { }

  @objc static func currentPublishingOptions() -> String {
    PublishingOptions.current.description
  }
}


