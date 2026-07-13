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
//
// Moshlight: the in-tree syntax highlighter + line-number gutter behind Moshxplore's code view.
//
// One palette — **Mushroom** — warm, dark, ours. There is no light/dark pair and no theme picker:
// code renders on mushroom soil, full stop. Zero dependencies by design (this repo vendors or
// owns everything): a pragmatic single-pass tokenizer — comments and strings first, since they
// mask everything inside them, then keywords/numbers/keys outside those ranges — tuned for
// *scanning* configs, scripts and code in place, not for IDE-grade grammar. Colors are pure
// presentation attributes: the text bytes Moshxplore round-trips are never touched.
//
////////////////////////////////////////////////////////////////////////////////

import UIKit

enum Moshlight {

  // MARK: - The Mushroom palette (the only one)

  enum Palette {
    static let background = UIColor(red: 0.125, green: 0.105, blue: 0.095, alpha: 1)  // soil
    static let gutter     = UIColor(red: 0.100, green: 0.084, blue: 0.076, alpha: 1)  // darker strip
    static let text       = UIColor(red: 0.91, green: 0.89, blue: 0.85, alpha: 1)     // cream
    static let comment    = UIColor(red: 0.52, green: 0.47, blue: 0.42, alpha: 1)     // spore
    static let string     = UIColor(red: 0.85, green: 0.64, blue: 0.37, alpha: 1)     // honey
    static let number     = UIColor(red: 0.66, green: 0.75, blue: 0.50, alpha: 1)     // moss
    static let keyword    = UIColor(red: 0.90, green: 0.47, blue: 0.42, alpha: 1)     // amanita
    static let key        = UIColor(red: 0.93, green: 0.85, blue: 0.64, alpha: 1)     // cap cream
    static let lineNumber = UIColor(red: 0.44, green: 0.39, blue: 0.35, alpha: 1)
    static let hairline   = UIColor(white: 1, alpha: 0.07)
  }

  /// Beyond this many UTF-16 units the tokenizer stands down (plain cream text — still dark,
  /// still line-numbered). Keeps every keystroke and open instant, whatever lands in the card.
  static let highlightMaxLength = 300_000

  // MARK: - Language rules

  struct Rules {
    var lineComments: [String] = []          // "#", "//", "--", ";"
    var hashCommentNeedsBoundary = true      // "#" only at line start / after whitespace (a#b isn't a comment)
    var blockComment: (open: String, close: String)? = nil
    var stringDelimiters: [Character] = ["\"", "'"]
    var keywords: Set<String> = []
    var caseInsensitiveKeywords = false      // SQL
    var highlightsKeys = false               // `key:` / `key =` at line start (yaml/toml/ini/css)
    var jsonKeys = false                     // a string directly followed by ':' is a key
    var headingHashes = false                // markdown: '#'-led lines are headings, not comments
  }

  // Detect by extension (or well-known leaf name), with a shebang fallback for extensionless
  // scripts. Returns nil for content we shouldn't pretend to understand — plain cream, no circus.
  static func rules(filename: String, firstLine: String) -> Rules? {
    let leaf = filename.lowercased()
    let ext = (leaf as NSString).pathExtension

    switch ext {
    case "sh", "bash", "zsh", "fish": return .shell
    case "py": return .python
    case "js", "mjs", "cjs", "jsx", "ts", "tsx": return .javascript
    case "swift": return .swift
    case "go": return .go
    case "rs": return .rust
    case "rb": return .ruby
    case "php": return .php
    case "c", "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "hh", "java", "kt", "kts", "scala": return .cfamily
    case "sql": return .sql
    case "json", "jsonl", "ndjson": return .json
    case "yml", "yaml": return .yaml
    case "toml", "ini", "conf", "cfg", "properties", "env", "gitconfig", "editorconfig", "npmrc": return .conf
    case "css", "scss", "sass": return .css
    case "md", "markdown", "mdx": return .markdown
    case "html", "htm", "xml", "plist", "storyboard", "svg": return .markup
    case "lua": return .lua
    case "csv", "tsv", "log", "txt", "": break   // fall through to leaf/shebang checks
    default: break
    }

    switch leaf {
    case ".bashrc", ".zshrc", ".profile", ".bash_profile", "makefile", "dockerfile", "justfile":
      return .shell
    case ".gitignore", ".gitattributes", ".dockerignore", ".env", ".nvmrc":
      return .conf
    default: break
    }

    if firstLine.hasPrefix("#!") {
      if firstLine.contains("python") { return .python }
      if firstLine.contains("ruby") { return .ruby }
      if firstLine.contains("node") { return .javascript }
      return .shell   // #!/bin/sh, bash, zsh, env …
    }
    return nil
  }

  // MARK: - Apply (attributes only — never the text)

  static func apply(to storage: NSTextStorage, rules: Rules?, font: UIFont) {
    let full = NSRange(location: 0, length: storage.length)
    storage.beginEditing()
    storage.setAttributes([.font: font, .foregroundColor: Palette.text], range: full)
    defer { storage.endEditing() }
    guard let rules, storage.length <= highlightMaxLength, storage.length > 0 else { return }

    let units = Array(storage.string.utf16)   // NSRange-true offsets
    var masked = [NSRange]()                  // comment/string spans, ascending

    func paint(_ range: NSRange, _ color: UIColor) {
      storage.addAttribute(.foregroundColor, value: color, range: range)
    }

    // --- Pass 1: comments + strings (a tiny state machine beats regex on escapes) ---
    var i = 0
    let n = units.count
    func matches(_ token: String, at pos: Int) -> Bool {
      let t = Array(token.utf16)
      guard pos + t.count <= n else { return false }
      for (k, u) in t.enumerated() where units[pos + k] != u { return false }
      return true
    }

    while i < n {
      let u = units[i]

      // Block comment
      if let block = rules.blockComment, matches(block.open, at: i) {
        let start = i
        i += block.open.utf16.count
        while i < n, !matches(block.close, at: i) { i += 1 }
        i = min(n, i + block.close.utf16.count)
        let r = NSRange(location: start, length: i - start)
        paint(r, Palette.comment); masked.append(r)
        continue
      }

      // Line comment (and markdown headings, which reuse the same shape)
      var lineToken: String? = nil
      for token in rules.lineComments where matches(token, at: i) {
        if token == "#" && rules.hashCommentNeedsBoundary {
          let atBoundary = i == 0 || units[i - 1] == 0x20 || units[i - 1] == 0x09 || units[i - 1] == 0x0A
          if !atBoundary { continue }
        }
        lineToken = token; break
      }
      if lineToken != nil {
        let start = i
        while i < n, units[i] != 0x0A { i += 1 }
        let r = NSRange(location: start, length: i - start)
        paint(r, rules.headingHashes ? Palette.key : Palette.comment)
        masked.append(r)
        continue
      }

      // String
      if let scalar = Unicode.Scalar(u), rules.stringDelimiters.contains(Character(scalar)) {
        let delim = u
        let start = i
        i += 1
        while i < n {
          if units[i] == 0x5C { i += 2; continue }        // backslash escape
          if units[i] == delim || units[i] == 0x0A { break }
          i += 1
        }
        if i < n, units[i] == delim { i += 1 }
        let r = NSRange(location: start, length: i - start)
        paint(r, Palette.string); masked.append(r)
        continue
      }

      i += 1
    }

    // --- Pass 2: keywords, numbers and keys outside the masked spans ---
    var maskIdx = 0
    func isMasked(_ pos: Int) -> Bool {
      while maskIdx < masked.count, masked[maskIdx].upperBound <= pos { maskIdx += 1 }
      return maskIdx < masked.count && masked[maskIdx].contains(pos)
    }
    func isIdentStart(_ u: UInt16) -> Bool {
      (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F
    }

    i = 0
    var atLineStart = true
    while i < n {
      let u = units[i]
      if u == 0x0A { atLineStart = true; i += 1; continue }
      if isMasked(i) { i += 1; continue }
      if u == 0x20 || u == 0x09 { i += 1; continue }

      // Identifier → keyword, or a leading `key:` / `key =`. Dots and dashes only join a token in
      // key-style files (yaml/toml/ini) — in code they must split `self.value` into real words.
      if isIdentStart(u) {
        let start = i
        while i < n {
          let v = units[i]
          let isWord = isIdentStart(v) || (v >= 0x30 && v <= 0x39)
            || (rules.highlightsKeys && (v == 0x2D || v == 0x2E))
          if !isWord { break }
          i += 1
        }
        let range = NSRange(location: start, length: i - start)
        let word = String(utf16CodeUnits: Array(units[start..<i]), count: i - start)

        if rules.highlightsKeys && atLineStart {
          var j = i
          while j < n, units[j] == 0x20 || units[j] == 0x09 { j += 1 }
          if j < n, units[j] == 0x3A || units[j] == 0x3D {   // ':' or '='
            paint(range, Palette.key)
            atLineStart = false
            continue
          }
        }
        let probe = rules.caseInsensitiveKeywords ? word.lowercased() : word
        if rules.keywords.contains(probe) { paint(range, Palette.keyword) }
        atLineStart = false
        continue
      }

      // Number
      if u >= 0x30 && u <= 0x39 {
        let start = i
        while i < n {
          let v = units[i]
          let isNum = (v >= 0x30 && v <= 0x39) || v == 0x2E || v == 0x5F || v == 0x78 || v == 0x58
            || (v >= 0x41 && v <= 0x46) || (v >= 0x61 && v <= 0x66)
          if !isNum { break }
          i += 1
        }
        paint(NSRange(location: start, length: i - start), Palette.number)
        atLineStart = false
        continue
      }

      atLineStart = false
      i += 1
    }

    // --- Pass 3 (JSON): a string immediately followed by ':' is a key ---
    if rules.jsonKeys {
      for r in masked {
        guard r.length > 0, units[r.location] == 0x22 else { continue }   // string spans only
        var j = r.upperBound
        while j < n, units[j] == 0x20 || units[j] == 0x09 { j += 1 }
        if j < n, units[j] == 0x3A { paint(r, Palette.key) }
      }
    }
  }
}

// MARK: - Language definitions

extension Moshlight.Rules {
  static let shell = Moshlight.Rules(
    lineComments: ["#"],
    keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case",
               "esac", "function", "in", "return", "local", "export", "echo", "exit", "set",
               "source", "alias", "sudo", "cd"])
  static let python = Moshlight.Rules(
    lineComments: ["#"],
    keywords: ["def", "class", "if", "elif", "else", "for", "while", "try", "except", "finally",
               "with", "as", "import", "from", "return", "yield", "lambda", "pass", "break",
               "continue", "raise", "in", "not", "and", "or", "is", "None", "True", "False",
               "global", "nonlocal", "async", "await", "self", "print"])
  static let javascript = Moshlight.Rules(
    lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'", "`"],
    keywords: ["function", "const", "let", "var", "if", "else", "for", "while", "do", "switch",
               "case", "break", "continue", "return", "new", "class", "extends", "import", "from",
               "export", "default", "try", "catch", "finally", "throw", "typeof", "instanceof",
               "in", "of", "async", "await", "yield", "this", "null", "undefined", "true", "false"])
  static let swift = Moshlight.Rules(
    lineComments: ["//"], blockComment: ("/*", "*/"),
    keywords: ["func", "let", "var", "if", "else", "guard", "for", "while", "repeat", "switch",
               "case", "break", "continue", "return", "class", "struct", "enum", "protocol",
               "extension", "import", "init", "deinit", "throws", "throw", "try", "catch", "defer",
               "in", "where", "as", "is", "nil", "true", "false", "self", "super", "public",
               "private", "internal", "fileprivate", "static", "final", "override", "mutating",
               "some", "any", "weak", "lazy"])
  static let go = Moshlight.Rules(
    lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'", "`"],
    keywords: ["func", "var", "const", "if", "else", "for", "range", "switch", "case", "break",
               "continue", "return", "type", "struct", "interface", "map", "chan", "go", "defer",
               "select", "package", "import", "nil", "true", "false", "make", "new", "error"])
  static let rust = Moshlight.Rules(
    lineComments: ["//"], blockComment: ("/*", "*/"),
    keywords: ["fn", "let", "mut", "if", "else", "for", "while", "loop", "match", "impl", "struct",
               "enum", "trait", "pub", "use", "mod", "crate", "return", "break", "continue",
               "self", "Self", "true", "false", "None", "Some", "Ok", "Err", "async", "await",
               "move", "ref", "where", "unsafe", "dyn"])
  static let ruby = Moshlight.Rules(
    lineComments: ["#"],
    keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "case", "when",
               "while", "until", "for", "do", "begin", "rescue", "ensure", "return", "yield",
               "require", "include", "nil", "true", "false", "self", "puts", "new", "attr_accessor"])
  static let php = Moshlight.Rules(
    lineComments: ["//", "#"], blockComment: ("/*", "*/"),
    keywords: ["function", "if", "else", "elseif", "foreach", "for", "while", "switch", "case",
               "break", "continue", "return", "class", "extends", "implements", "public",
               "private", "protected", "static", "new", "echo", "require", "include", "use",
               "namespace", "try", "catch", "finally", "null", "true", "false", "this"])
  static let cfamily = Moshlight.Rules(
    lineComments: ["//"], blockComment: ("/*", "*/"),
    keywords: ["if", "else", "for", "while", "do", "switch", "case", "break", "continue", "return",
               "struct", "class", "enum", "union", "typedef", "static", "const", "void", "int",
               "char", "float", "double", "long", "unsigned", "signed", "bool", "true", "false",
               "nullptr", "NULL", "public", "private", "protected", "virtual", "override", "new",
               "delete", "namespace", "using", "include", "define", "import", "interface",
               "implementation", "property", "nil", "self", "id"])
  static let sql = Moshlight.Rules(
    lineComments: ["--"], blockComment: ("/*", "*/"),
    keywords: ["select", "from", "where", "insert", "into", "values", "update", "set", "delete",
               "create", "table", "drop", "alter", "index", "join", "left", "right", "inner",
               "outer", "on", "as", "and", "or", "not", "null", "primary", "key", "foreign",
               "references", "group", "by", "order", "limit", "offset", "distinct", "having",
               "union", "count", "sum", "avg", "min", "max"],
    caseInsensitiveKeywords: true)
  static let json = Moshlight.Rules(
    keywords: ["true", "false", "null"], jsonKeys: true)
  static let yaml = Moshlight.Rules(
    lineComments: ["#"], keywords: ["true", "false", "null", "yes", "no"], highlightsKeys: true)
  static let conf = Moshlight.Rules(
    lineComments: ["#", ";"], keywords: ["true", "false", "yes", "no", "on", "off"],
    highlightsKeys: true)
  static let css = Moshlight.Rules(
    blockComment: ("/*", "*/"), highlightsKeys: true)
  static let markdown = Moshlight.Rules(
    lineComments: ["#"], stringDelimiters: ["`"], headingHashes: true)
  static let markup = Moshlight.Rules(
    blockComment: ("<!--", "-->"),
    keywords: ["html", "head", "body", "div", "span", "script", "style", "link", "meta", "img",
               "a", "p", "ul", "li", "table", "tr", "td", "key", "string", "dict", "array",
               "integer", "true", "false", "plist", "xml", "svg", "path", "g", "rect", "circle"])
  static let lua = Moshlight.Rules(
    lineComments: ["--"],
    keywords: ["function", "local", "if", "then", "else", "elseif", "end", "for", "while",
               "repeat", "until", "do", "return", "break", "in", "pairs", "ipairs", "nil",
               "true", "false", "not", "and", "or", "require"])
}

// MARK: - Line-number gutter

// A thin numbered strip pinned to the code view's left edge, numbering LOGICAL lines (a wrapped
// long line keeps one number, on its first fragment — like every real editor). Draws only the
// visible lines, straight off TextKit's line fragments, so a 1 MB log scrolls as smoothly
// unnumbered files do.
final class MoshlightGutter: UIView {

  weak var textView: UITextView?
  private(set) var gutterWidth: CGFloat = 36
  var onWidthChange: ((CGFloat) -> Void)?

  private var lineStarts: [Int] = [0]   // UTF-16 offset of each logical line start

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = Moshlight.Palette.gutter
    isUserInteractionEnabled = false
    translatesAutoresizingMaskIntoConstraints = false
    contentMode = .redraw
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // Recompute line starts (single pass) and grow the strip when the digit count needs it.
  func noteTextChanged() {
    guard let tv = textView else { return }
    var starts = [0]
    let units = tv.text.utf16
    var offset = 0
    for u in units {
      offset += 1
      if u == 0x0A { starts.append(offset) }
    }
    lineStarts = starts
    let digits = max(2, String(starts.count).count)
    let width = ceil(CGFloat(digits) * 7.5) + 16
    if width != gutterWidth {
      gutterWidth = width
      onWidthChange?(width)
    }
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    guard let tv = textView, !tv.isHidden else { return }
    let lm = tv.layoutManager
    let tc = tv.textContainer

    // Separator hairline on the right edge.
    let ctx = UIGraphicsGetCurrentContext()
    ctx?.setFillColor(Moshlight.Palette.hairline.cgColor)
    ctx?.fill(CGRect(x: bounds.width - 0.5, y: 0, width: 0.5, height: bounds.height))

    let visible = CGRect(x: 0, y: tv.contentOffset.y, width: tv.bounds.width, height: tv.bounds.height)
      .insetBy(dx: 0, dy: -20)
    let glyphs = lm.glyphRange(forBoundingRect: visible.offsetBy(dx: 0, dy: -tv.textContainerInset.top), in: tc)
    let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

    let attrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
      .foregroundColor: Moshlight.Palette.lineNumber,
    ]

    // Binary-search the first visible logical line, then walk until past the visible range.
    var lo = 0, hi = lineStarts.count - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if lineStarts[mid] <= chars.location { lo = mid } else { hi = mid - 1 }
    }

    for line in lo..<lineStarts.count {
      let start = lineStarts[line]
      if start > chars.upperBound && line > lo { break }

      var fragment: CGRect
      if start >= lm.numberOfGlyphs {
        // The empty last line of a newline-terminated file.
        fragment = lm.extraLineFragmentRect
        if fragment.isEmpty { break }
      } else {
        fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil)
      }
      let y = fragment.minY + tv.textContainerInset.top - tv.contentOffset.y
      guard y > -30, y < bounds.height + 10 else { continue }

      let label = "\(line + 1)" as NSString
      let size = label.size(withAttributes: attrs)
      label.draw(at: CGPoint(x: bounds.width - size.width - 7, y: y + 1.5), withAttributes: attrs)
    }
  }
}
