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
import Runestone
import TreeSitterBashRunestone

enum TextViewEditingMode {
  case template, code
}

enum LanguageMode: String {
  case shell = "shell"
  case prompt = "prompt"
}

extension TextView {
  func textRange(from range: NSRange) -> UITextRange? {
    let start = self.position(from: self.beginningOfDocument, offset: range.location)!
    let end = self.position(from: start, offset: range.length)!
    return self.textRange(from: start, to: end)
  }

  func configure(for languageMode: LanguageMode) {
    switch languageMode {
    case .shell:
      // Shell mode: disable text assistance features
      self.autocapitalizationType = .none
      self.autocorrectionType = .no
      self.smartDashesType = .no
      self.smartQuotesType = .no
      self.smartInsertDeleteType = .no
      self.spellCheckingType = .no
      self.setLanguageMode(TreeSitterLanguageMode(language: .bash))

    case .prompt:
      // Prompt mode: enable text assistance features for writing prompts
      self.autocapitalizationType = .sentences
      self.autocorrectionType = .yes
      self.smartDashesType = .yes
      self.smartQuotesType = .yes
      self.smartInsertDeleteType = .yes
      self.spellCheckingType = .yes
      self.setLanguageMode(PlainTextLanguageMode())
    }
  }
}

class TextViewBuilder {
  static func createForSnippetEditing() -> TextView {
    return textView()
  }

  static func textView() -> TextView {
    let tv = TextView()
    tv.theme = PragmataProTheme(originalTheme: DefaultTheme())
    tv.backgroundColor = .clear
    tv.inputAssistantItem.leadingBarButtonGroups = []
    tv.inputAssistantItem.trailingBarButtonGroups = []

    return tv
  }
}

public final class PragmataProTheme<T: Runestone.Theme>: Runestone.Theme {
  
  public var font = MoshroomSnippetsFonts.snippetEditContent
  
  public var textColor: UIColor {
    originalTheme.textColor
  }
  
  public var gutterBackgroundColor: UIColor {
    originalTheme.gutterBackgroundColor
  }
  
  public var gutterHairlineColor: UIColor {
    originalTheme.gutterHairlineColor
  }
  
  public var lineNumberColor: UIColor {
    originalTheme.lineNumberColor
  }
  
  public var lineNumberFont: UIFont {
    originalTheme.font
  }
  
  public var selectedLineBackgroundColor: UIColor {
    originalTheme.selectedLineBackgroundColor
  }
  
  public var selectedLinesLineNumberColor: UIColor {
    originalTheme.selectedLinesLineNumberColor
  }
  
  public var selectedLinesGutterBackgroundColor: UIColor {
    originalTheme.selectedLinesGutterBackgroundColor
  }
  
  public var invisibleCharactersColor: UIColor {
    originalTheme.invisibleCharactersColor
  }
  
  public var pageGuideHairlineColor: UIColor {
    originalTheme.pageGuideHairlineColor
  }
  
  public var pageGuideBackgroundColor: UIColor {
    originalTheme.pageGuideBackgroundColor
  }
  
  public var markedTextBackgroundColor: UIColor {
    originalTheme.markedTextBackgroundColor
  }
  
  public func textColor(for highlightName: String) -> UIColor? {
    originalTheme.textColor(for: highlightName)
  }
  
  var originalTheme: T
  
  init(originalTheme: T) {
    self.originalTheme = originalTheme
  }
}
 
