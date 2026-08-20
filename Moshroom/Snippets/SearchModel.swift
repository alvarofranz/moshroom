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

import Combine
import Foundation
import MoshroomSnippets
import UIKit
import SwiftUI

class SearchModel: ObservableObject {
  weak var rootCtrl: UIViewController? = nil
  weak var inputView: UIView? = nil

  var fuzzyResults = FuzzyAccumulator(query: "")
  var searchResults = SearchAccumulator(query: "")
  var fuzzyCancelable: AnyCancellable? = nil
  var searchCancelable: AnyCancellable? = nil

  public var snippetContext: (any SnippetContext)? = nil

  var isFuzzyMode: Bool {
    self.searchResults.query.isEmpty
  }

  @Published var displayResults = [Snippet]() {
    didSet {
      if displayResults.isEmpty {
        self.selectedSnippetIdx = nil
      } else {
        self.selectedSnippetIdx = 0
      }
    }
  }

  @Published var selectedSnippetIdx: Int?

  @Published var currentSnippetName = ""
  @Published var editingSnippet: Snippet? = nil
  @Published var editingMode: TextViewEditingMode = .template
  @Published var newSnippetPresented = false
  @Published var indexProgress: SnippetsLocations.RefreshProgress = .none
  @Published var isPinnedMode = false
  @Published var languageMode: LanguageMode = .shell
  let defaultShellOutputFormatter = ShellOutputFormatter.lineBySemicolon

  let snippetsLocations: SnippetsLocations
  // Stored Index snapshot to search.
  var index: [Snippet] = []
  var indexFetchCancellable: Cancellable? = nil
  var indexProgressCancellable: Cancellable? = nil

  @Published private(set) var mode: SearchMode
  @Published private(set) var input: String {
    didSet {
      let splits = input.split(separator: " ", maxSplits: 1)
      guard
        self.mode != .general,
        let fuzzyQuery = splits.first
      else {
        self.fuzzyCancelable = nil
        self.searchCancelable = nil
        self.displayResults = []
        self.fuzzyResults.clear()
        self.searchResults.clear()
        return
      }
      var filterQuery = ""

      if splits.count == 2 {
        filterQuery = String(splits[1]).trimmingCharacters(in: .whitespacesAndNewlines)
      }

      let fQuery = String(fuzzyQuery)
//      fQuery.removeFirst()

      fuzzySearch(fQuery, filterQuery)
    }
  }



  init() throws {
    self.mode = .general
    self.input = ""

    self.snippetsLocations = try SnippetsLocations()

    self.indexFetchCancellable = self.snippetsLocations
      .indexPublisher
      // Refresh should happen on main thread, bc this is publishing changes.
      .receive(on: DispatchQueue.main)
      .sink(
      // Handle errors
      receiveCompletion: { _ in },
      receiveValue: { snippets in
        self.index = snippets
        self.input = { self.input }()
      })

    self.indexProgressCancellable = self.snippetsLocations
      .indexProgressPublisher
      .receive(on: DispatchQueue.main)
      .assign(to: \.indexProgress, on: self)
  }

  func updateWith(text: String) {
    self.mode = .insert
    self.input = text
  }

  func insertRawSnippet() {
    // The snippet should only be selectable if the content is already there,
    // as it has already been part of a search and cached.
    guard let snippet = currentSelection,
          let content = try? snippet.content
    else {
      return
    }

    sendContentToReceiver(content: content)
  }

  func copyRawSnippet() {
    guard let snippet = currentSelection,
          let content = try? snippet.content
    else {
      return
    }

    UIPasteboard.general.string = content
    self.close()
  }

  func openScratch() {
    let snippet = _beginScratch()

    self.currentSnippetName = snippet.fuzzyIndex
    self.editingSnippet = snippet

    let textView = TextViewBuilder.createForSnippetEditing()
    let editorCtrl = EditorViewController(textView: textView, model: self)
    _presentEditorSheet(editorCtrl, animated: false)
  }

  func editSelectionOrCreate() {
    let snippet: Snippet

    // Scratch mode
    if currentSelection == nil {
      if self.input.isEmpty {
        snippet = _beginScratch()
      } else {
        openNewSnippet()
        return
      }
    } else {
      snippet = currentSelection!
      self.editingMode = .template
      // Current snippets always use shell mode
      self.languageMode = .shell
    }

    self.currentSnippetName = snippet.fuzzyIndex
    self.editingSnippet = snippet

    let textView = TextViewBuilder.createForSnippetEditing()
    let editorCtrl = EditorViewController(textView: textView, model: self)
    _presentEditorSheet(editorCtrl, animated: false)

  }

  /// Enter scratch mode: an unnamed code snippet in whichever language the user last used there
  /// (scratch remembers its language; saved snippets are always shell).
  private func _beginScratch() -> Snippet {
    self.editingMode = .code
    if let savedMode = LanguageMode(rawValue: MoshroomDefaults.scratchLanguageMode()) {
      self.languageMode = savedMode
    }
    return Snippet.scratch()
  }

  /// The sheet every snippet editor rides in: a page sheet that can sit as a 120pt strip above the
  /// keyboard or fill the screen, undimmed so the terminal behind stays readable, and modal in
  /// presentation while a pinned snippet is being edited. The entry points differ only in which
  /// editor goes inside.
  private func _presentEditorSheet(_ editorCtrl: UIViewController, animated: Bool) {
    let navCtrl = UINavigationController(rootViewController: editorCtrl)
    navCtrl.modalPresentationStyle = .pageSheet
    navCtrl.isModalInPresentation = isPinnedMode

    if let sheetCtrl = navCtrl.sheetPresentationController {
      if KBTracker.shared.isHardwareKB {
        sheetCtrl.detents = [
          .custom(resolver: { context in 120 }),
          .medium(),
          .large()
        ]
      } else {
        sheetCtrl.detents = [.custom(resolver: { context in 120 }), .large()]
      }
      sheetCtrl.largestUndimmedDetentIdentifier = .large
      sheetCtrl.prefersGrabberVisible = true
    }
    rootCtrl?.present(navCtrl, animated: animated)
  }

  func openNewSnippet() {
    self.newSnippetPresented = true

    let textView = TextViewBuilder.createForSnippetEditing()
    let editorCtrl = NewSnippetViewController(textView: textView, model: self)
    _presentEditorSheet(editorCtrl, animated: true)

  }

  @objc func sendContentToReceiver(content: String) {
    // NOTE Atm it is all shell content, at one point we should have different types.
    sendContentToReceiver(content: content, shellOutputFormatter: defaultShellOutputFormatter)
  }

  func sendContentToReceiver(content: String, shellOutputFormatter: ShellOutputFormatter) {
    let formatted = shellOutputFormatter.format(content)
    self.snippetContext?.providerSnippetReceiver()?.receive(formatted)
    cleanupAfterSend()
  }

  func sendPromptContentToReceiver(content: String) {
    let formatted = ShellOutputFormatter.raw.format(content)
    let receiver = self.snippetContext?.providerSnippetReceiver()
    receiver?.receive(formatted)

    // Prompt submit trails the content so shells don't read it as part of the same sequence.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      receiver?.receive("\r")
      self.cleanupAfterSend()
    }
  }

  private func cleanupAfterSend() {
    if isPinnedMode {
      self.input = ""
    } else {
      self.editingSnippet = nil
      self.input = ""
      self.snippetContext?.dismissSnippetsController()
    }
  }

  func close() {
    self.snippetContext?.dismissSnippetsController()
  }

  @objc func closeEditor() {
    self.editingSnippet = nil
    self.newSnippetPresented = false
    self.rootCtrl?.presentedViewController?.dismiss(animated: true) {
      self.focusOnInput()
    }
  }

  func focusOnInput() {
    _ = self.inputView?.becomeFirstResponder()
  }

  func saveSnippet(newContent: String) throws {
    guard let snippet = self.editingSnippet else {
      return
    }

    _ = try self.snippetsLocations.saveSnippet(folder: snippet.folder, name: snippet.name, content: newContent)
  }

  func deleteSnippet() throws {
    guard let snippet = editingSnippet else {
      return
    }

    try self.snippetsLocations.deleteSnippet(snippet: snippet)

    self.displayResults = []
    self.searchResults.clear()
    self.fuzzyResults.clear()
    self.input = ""
    self.editingSnippet = nil
  }

  func renameSnippet(newCategory: String, newName: String, newContent: String) throws {
    guard let snippet = self.editingSnippet else {
      return
    }
    let newSnippet = try
        self.snippetsLocations.renameSnippet(snippet: snippet, folder: newCategory, name: newName, content: newContent)
    self.displayResults = []
    self.searchResults.clear()
    self.fuzzyResults.clear()
    self.input = ""
    self.editingSnippet = newSnippet
  }

  func cleanString(str: String?) -> String {
    (str ?? "").lowercased()
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ".", with: "-")
      .replacingOccurrences(of: "~", with: "-")
      .replacingOccurrences(of: "\\", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func refreshIndex() {
    self.snippetsLocations.refreshIndex(forceUpdate: true)
  }
}

public protocol SnippetReceiver {
  func receive(_ content: String)
}

public protocol SnippetContext {
  func presentSnippetsController()
  func dismissSnippetsController()
  func providerSnippetReceiver() -> (any SnippetReceiver)?
}

extension TermDevice: SnippetReceiver {
  public func receive(_ content: String) {
    if self.rawMode {
      self.write(inDirectly: content)
    } else {
      self.view?.paste(content)
    }
  }
}

// MARK: Search

extension SearchModel {
  func fuzzySearch(_ query: String, _ searchQuery: String) {
    guard self.fuzzyResults.query != query
    else {
      self.fuzzyCancelable = nil // <- cancel fuzzy
      return search(query: searchQuery)
    }

    self.searchCancelable = nil

    if query.isEmpty {
      self.fuzzyCancelable = nil
      self.displayResults = []
      self.fuzzyResults.clear()
      self.searchResults.clear()
      return
    }

    let query = query.lowercased()

    self.fuzzyCancelable = fuzzyResults
      .chooseSource(query: query, wideIndex: self.index)
      .fuzzySearch(searchString: query, maxResults: ResultsLimit)
      .subscribe(on: DispatchQueue.global())
      .reduce(FuzzyAccumulator(query: query), FuzzyAccumulator.accumulate(_:_:))
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { completion in
        },
        receiveValue: { fuzzyResults in
          self.fuzzyResults = fuzzyResults
          self.search(query: searchQuery)
        })
  }

  func search(query: String) {
    if self.fuzzyResults.isEmpty {
      self.searchCancelable = nil
      self.displayResults = []
      return
    }

    if query.isEmpty {
      self.searchResults.clear()
      self.displayResults = self.fuzzyResults.snippets
      self.searchCancelable = nil
      return
    }

    self.searchCancelable = searchResults
      .chooseSource(query: query, wideIndex: self.fuzzyResults.snippets)
      .publisher
      .subscribe(on: DispatchQueue.global())
      .map { s in (s, Search(content: s.searchableContent, searchString: query)) }
      .reduce(SearchAccumulator(query: query), SearchAccumulator.accumulate(_:_:))
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { _ in },
        receiveValue: { res in
          self.searchResults = res
          self.displayResults = res.snippets
        })
  }
}

// MARK: Snippet Selection
var generated: Bool = false

extension SearchModel {
  var currentSelection: Snippet? {
    if let idx = selectedSnippetIdx {
      return displayResults[idx]
    } else {
      return nil
    }

  }

  func onSnippetTap(_ snippet: Snippet) {
    if let index = self.displayResults.firstIndex(of: snippet) {
      self.selectedSnippetIdx = index
      self.editSelectionOrCreate()
    }
  }

  public func selectNextSnippet() {
    guard displayResults.count > 0  else {
      self.selectedSnippetIdx = nil
      return
    }
    guard let idx = self.selectedSnippetIdx else {
      self.selectedSnippetIdx = displayResults.count - 1
      return
    }

    self.selectedSnippetIdx = idx == 0 ? displayResults.count - 1 : idx - 1
  }

  public func selectPrevSnippet() {
    guard displayResults.count > 0  else {
      self.selectedSnippetIdx = nil
      return
    }
    guard let idx = self.selectedSnippetIdx else {
      self.selectedSnippetIdx = 0
      return
    }
    self.selectedSnippetIdx = (idx + 1 ) % displayResults.count
  }
}
