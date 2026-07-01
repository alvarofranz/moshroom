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

struct TerminalStyleBundle: Codable {
  static let fileExtension = "moshroomstyle"

  let style: TerminalStyle
  let embeddedThemeContent: String?
  let embeddedThemeName: String?
  let embeddedFontContent: String?
  let embeddedFontName: String?
  let exportDate: Date
  let moshroomVersion: String?
}

// MARK: - Export

extension TerminalStyleBundle {
  private static func isDefaultResource(_ resource: MoshResource?, of type: MoshResource.Type) -> Bool {
    guard let resource = resource else { return false }
    return type.defaultResources()?.contains(where: { ($0 as? MoshResource)?.name == resource.name }) ?? false
  }

  static func export(style: TerminalStyle) -> TerminalStyleBundle {
    // Themes: only embed if not a built-in default (no other categories for themes).
    let themeResource = MoshTheme.withName(style.themeName)
    let embedTheme = themeResource != nil && !isDefaultResource(themeResource, of: MoshTheme.self)

    // Fonts have three categories:
    // - Built-in defaults (ship with Moshroom) → don't embed
    // - System-wide monospace fonts (exist on device, MoshFont.systemWide = true,
    //   MoshFont.isCustom also returns true for these) → don't embed
    // - User-added custom fonts → embed
    let fontResource = MoshFont.withName(style.fontName) as? MoshFont
    let embedFont = fontResource != nil
      && !isDefaultResource(fontResource, of: MoshFont.self)
      && !(fontResource?.systemWide ?? true)

    return TerminalStyleBundle(
      style: style,
      embeddedThemeContent: embedTheme ? themeResource?.content() : nil,
      embeddedThemeName: embedTheme ? style.themeName : nil,
      embeddedFontContent: embedFont ? fontResource?.content() : nil,
      embeddedFontName: embedFont ? style.fontName : nil,
      exportDate: Date(),
      moshroomVersion: UIApplication.moshroomVersion()
    )
  }
}

// MARK: - Import

extension TerminalStyleBundle {
  enum ImportResult {
    case success(TerminalStyle)
    case alreadyExists(existing: TerminalStyle, incoming: TerminalStyle)
    case successWithWarnings(TerminalStyle, [String])
  }

  func importInto(store: TerminalStyleStore) -> ImportResult {
    // Check if a style with this UUID already exists
    if let existing = store.style(for: style.id) {
      return .alreadyExists(existing: existing, incoming: style)
    }

    var warnings: [String] = []

    // Install embedded theme if not already present
    if let themeName = embeddedThemeName,
       let themeContent = embeddedThemeContent {
      if MoshTheme.withName(themeName) != nil {
        warnings.append("Theme '\(themeName)' already exists, using existing version.")
      } else if let data = themeContent.data(using: .utf8) {
        do {
          try MoshTheme.save(themeName, withContent: data)
        } catch {
          warnings.append("Could not install theme '\(themeName)': \(error.localizedDescription)")
        }
      }
    }

    // Install embedded font if not already present
    if let fontName = embeddedFontName,
       let fontContent = embeddedFontContent {
      if MoshFont.withName(fontName) != nil {
        warnings.append("Font '\(fontName)' already exists, using existing version.")
      } else if let data = fontContent.data(using: .utf8) {
        do {
          try MoshFont.save(fontName, withContent: data)
        } catch {
          warnings.append("Could not install font '\(fontName)': \(error.localizedDescription)")
        }
      }
    }

    let added = store.addStyle(style)

    if warnings.isEmpty {
      return .success(added)
    }
    return .successWithWarnings(added, warnings)
  }
}

// MARK: - Serialization

extension TerminalStyleBundle {
  func encode() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }

  static func decode(from data: Data) throws -> TerminalStyleBundle {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TerminalStyleBundle.self, from: data)
  }
}
