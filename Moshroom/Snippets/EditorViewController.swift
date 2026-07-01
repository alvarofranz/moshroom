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

import SwiftUI
import Runestone
import TreeSitterBashRunestone
import MoshroomSnippets


class EditorViewController: UIViewController, TextViewDelegate, UINavigationItemRenameDelegate {
  func navigationItem(_: UINavigationItem, didEndRenamingWith title: String) {}

  func navigationItemShouldBeginRenaming(_: UINavigationItem) -> Bool { true }

  func navigationItem(_: UINavigationItem, willBeginRenamingWith suggestedTitle: String, selectedRange: Range<String.Index>) -> (String, Range<String.Index>) {
    // preselect name part
    let parts = suggestedTitle.split(separator: "/", maxSplits: 1)
    if parts.count == 2 {
      return (suggestedTitle, suggestedTitle.range(of: String(parts[1]))!)
    } else {
      return (suggestedTitle, suggestedTitle.range(of: suggestedTitle)!)
    }
  }

  func navigationItem(_: UINavigationItem, shouldEndRenamingWith title: String) -> Bool {
    let str = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if str.hasPrefix("/") || !str.contains("/") || str.hasSuffix("/") {
      return false
    }

    let parts = title.split(separator: "/", maxSplits: 1)
    let category = model.cleanString(str: String(parts[0]))
    let name = model.cleanString(str:String(parts[1])) + ".sh"

    do {
      try model.renameSnippet(newCategory: category, newName: name, newContent: self.textView.text)
      return true
    } catch {
      showAlert(msg: "\(error)")
      return false
    }
  }

  func setNextTemplateTokenRanges(textView: TextView) {
    let text = textView.text
    let nextTokenRangeIndex: String.Index
    if let range = self.templateTokenRanges.first {
      nextTokenRangeIndex = Range(range, in: textView.text)!.upperBound
    } else {
      nextTokenRangeIndex = text.startIndex
    }

    if nextTokenRangeIndex < text.endIndex,
      let range = text[nextTokenRangeIndex...].range(of: #"\$\{[^\}]+\}"#, options: .regularExpression) {
      let token = String(text[range])
      let nextTokenRanges = text.ranges(of: token).map { NSRange($0, in: text) }
      self.templateTokenRanges = nextTokenRanges
      highlightTemplateTokenRanges(textView)
      let range = nextTokenRanges[0]
      textView.selectedTextRange =  textView.textRange(from: range)
    } else {
      _completeTemplates()
    }
  }

  @objc private func _completeTemplates() {
    _updateEditingMode(.code)
  }

  @objc func togglePinMode() {
    _updateForPinMode(!model.isPinnedMode)
  }

  private func _updateForPinMode(_ isPinned: Bool) {
    model.isPinnedMode = isPinned

    // Prevent/allow dismissal
    navigationController?.isModalInPresentation = isPinned

    _updateNavigationBar()
  }

  func textViewDidChangeSelection(_ textView: TextView) {
    // We could use this to trigger a search for underlying template.
    // But this would make the textview work unnecessarily.
    // We could also compare with the template ranges alone.
  }

  func textView(_ textView: TextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
    if self.acceptReplace || model.editingMode == .code {
      return true
    }

    // Check if a Tab or Enter was pressed, in which case, switch to "next token".
    if text == "\t" || text == "\n" {
      setNextTemplateTokenRanges(textView: textView)
      return false
    }

    guard let templateEditingRange = (templateTokenRanges.first {
      return $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound
    }) else {
      return false
    }

    // Replace all appearances in templateTokenRanges.
    // Move the templateTokenRanges to accommodate for the introduced text.
    var newTemplateTokenRanges: [NSRange] = []
    let editingLocationOffset  = range.lowerBound - templateEditingRange.lowerBound
    let newTokenRangeLength = templateEditingRange.length + text.count - range.length
    var accummulatedPositionOffset = 0

    self.acceptReplace = true
    defer {
      self.acceptReplace = false
    }
    templateTokenRanges.forEach {
      let replacementRange = NSRange(location: accummulatedPositionOffset + $0.location + editingLocationOffset, length: range.length)

      textView.replace(replacementRange, withText: text)

      // this will force rerendering of all highlights
      // textView.text = textView.text.replacingCharacters(in: Range(replacementRange, in: textView.text)!, with: text)
      let newTokenRange = NSRange(location: accummulatedPositionOffset + $0.location, length: newTokenRangeLength)
      newTemplateTokenRanges.append(newTokenRange)
      accummulatedPositionOffset += newTokenRangeLength - $0.length

      if templateEditingRange == $0 {
        textView.selectedRange = NSRange(location: newTokenRange.lowerBound + editingLocationOffset + text.count, length: 0)
      }
    }

    templateTokenRanges = newTemplateTokenRanges
    highlightTemplateTokenRanges(textView)
    textViewDidChange(textView)
    return false
  }

  func highlightTemplateTokenRanges(_ textView: TextView) {
    var num = 0

    let highlightedRanges = templateTokenRanges.map {
      num += 1
      return HighlightedRange(id: "templateToken-\(num)", range: $0, color: textView.theme.markedTextBackgroundColor)
    }

    textView.highlightedRanges = highlightedRanges
  }

  var textView: TextView
  var model: SearchModel
  var templateTokenRanges: [NSRange]
  var acceptReplace: Bool

  var _keyCommands: [UIKeyCommand] = []
  private var textViewBottomConstraint: NSLayoutConstraint?

  init(textView: TextView, model: SearchModel) {
    self.textView = textView
    self.model = model
    self.templateTokenRanges =  [NSRange]()
    self.acceptReplace = false
    super.init(nibName: nil, bundle: nil)
    self.textView.editorDelegate = self

    _keyCommands = [
      UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(send)),
      UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
    ]
    for cmd in _keyCommands {
      cmd.wantsPriorityOverSystemBehavior = true
    }
  }

  override var keyCommands: [UIKeyCommand] {
    get {
      _keyCommands
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    self.view.backgroundColor = UIColor.systemBackground
    self.view.addSubview(textView)

    textView.translatesAutoresizingMaskIntoConstraints = false
    let keyboardLayoutGuide = view.keyboardLayoutGuide
    textViewBottomConstraint = textView.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)

    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: view.topAnchor, constant: self.systemMinimumLayoutMargins.top),
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: self.systemMinimumLayoutMargins.leading),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -self.systemMinimumLayoutMargins.trailing),
      textViewBottomConstraint!
    ])

    if let snippet = model.editingSnippet,
       let content = try? snippet.content {
      textView.text = content
      self.title = snippet.fuzzyIndex
    } else {
      textView.text = ""
    }

    self.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel)
    self.navigationItem.leftBarButtonItem?.target = self
    self.navigationItem.leftBarButtonItem?.action = #selector(cancel)
    self.navigationItem.style = .editor

    _updateEditingMode(model.editingMode)

    // For scratch, we disable special options
    // Ideally, a "Save as" would allow to rename scratch somewhere else, but we cannot change it.
    if model.editingSnippet?.name == "scratch" {
      return
    }
    self.navigationItem.renameDelegate = self
    self.navigationItem.titleMenuProvider = { suggestions in
      var finalMenuElements = suggestions

      finalMenuElements.append(
        UICommand(
          title: "Save",
          image: UIImage(systemName: "folder"),
          action: #selector(self.saveSnippet)
        )
      )
      finalMenuElements.append(
        UICommand(
          title: "Delete",
          image: UIImage(systemName: "trash"),
          action: #selector(self.deleteSnippet),
          attributes: .destructive
        )
      )
      return UIMenu(children: finalMenuElements)
    }
  }

  @objc func saveSnippet() {
    do {
      try model.saveSnippet(newContent: self.textView.text)
    } catch {
      showAlert(msg: "\(error)")
    }
  }

  @objc func deleteSnippet() {
    do {
      try model.deleteSnippet()
      model.closeEditor()
    } catch {
      showAlert(msg: "\(error)")
    }
  }

  @objc func cancel() {
    model.closeEditor()
  }

  @objc func send() {
    // Send with appropriate formatter based on language mode
    switch model.languageMode {
    case .shell:
      model.sendContentToReceiver(content: textView.text, shellOutputFormatter: .lineBySemicolon)

    case .prompt:
      model.sendPromptContentToReceiver(content: textView.text)
    }

    if model.isPinnedMode {
      textView.text = ""
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    _ = textView.becomeFirstResponder()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    self.model.closeEditor()
  }

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(deleteSnippet) {
      // TODO: check location
      return true
    }
    return super.canPerformAction(action, withSender: sender)
  }

  func showAlert(msg: String) {
    let ctrl = UIAlertController(title: "Error", message: msg, preferredStyle: .alert)
    ctrl.addAction(UIAlertAction(title: "Ok", style: .default))
    self.present(ctrl, animated: true)
  }
}

extension EditorViewController {
  private var isScratch: Bool {
    model.editingSnippet?.name == "scratch"
  }

  private func _updateEditingMode(_ mode: TextViewEditingMode) {
    model.editingMode = mode

    if model.editingMode == .template {
      self.textView.selectionHighlightColor = .systemYellow.withAlphaComponent(0.3)
      self.textView.selectionBarColor = .systemYellow.withAlphaComponent(0.8)
      self.textView.insertionPointColor = .systemYellow.withAlphaComponent(0.8)
      self.textView.returnKeyType = .next
      textView.configure(for: model.languageMode)

      self.navigationItem.rightBarButtonItem =
        UIBarButtonItem(
          title: "Complete", style: .done, target: self, action: #selector(_completeTemplates)
        )

      self.setNextTemplateTokenRanges(textView: textView)

    } else if model.editingMode == .code {
      self.textView.selectionHighlightColor = .moshroomTint.withAlphaComponent(0.3)
      self.textView.selectionBarColor = .moshroomTint.withAlphaComponent(0.8)
      self.textView.insertionPointColor = .moshroomTint.withAlphaComponent(0.8)
      self.textView.highlightedRanges = []
      model.editingMode = .code
      self.textView.returnKeyType = .default

      _updateForLanguageMode(model.languageMode)
    }
  }

  private func _updateForLanguageMode(_ languageMode: LanguageMode) {
    // Update model
    model.languageMode = languageMode

    if isScratch {
      MoshroomDefaults.setScratchLanguageMode(languageMode.rawValue)
      MoshroomDefaults.save()
    }

    // Configure TextView for the language mode
    textView.configure(for: languageMode)

    _updateNavigationBar()
  }

  private func _createSendAction(title: String, formatter: ShellOutputFormatter) -> UIAction {
    UIAction(title: title, handler: { _ in
      self.model.sendContentToReceiver(content: self.textView.text, shellOutputFormatter: formatter)
      if self.model.isPinnedMode {
        self.textView.text = ""
      }
    })
  }

  private func _updateNavigationBar() {
    let pinButton = UIBarButtonItem(
      image: UIImage(systemName: model.isPinnedMode ? "pin.fill" : "pin"),
      style: .plain,
      target: self,
      action: #selector(togglePinMode)
    )

    let languageModeButton = UIBarButtonItem(
      image: UIImage(systemName: "textformat"),
      primaryAction: nil,
      menu: _createLanguageModeMenu()
    )

    var sendButtons: [UIBarButtonItem] = [
      UIBarButtonItem(
        image: UIImage(systemName: "paperplane.fill"),
        style: .plain,
        target: self,
        action: #selector(send)
      )
    ]

    // Only add send options menu for shell mode
    if model.languageMode == .shell {
      let sendWithNewlineOptions = [
        _createSendAction(title: "Raw", formatter: .raw),
        _createSendAction(title: "Block", formatter: .block),
        _createSendAction(title: "B/E", formatter: .beginEnd),
        _createSendAction(title: "Semicolon", formatter: .lineBySemicolon)
      ]

      sendButtons.append(
        UIBarButtonItem(
          image: UIImage(systemName: "ellipsis.circle"),
          primaryAction: nil,
          menu: UIMenu(title: "Send as", children: sendWithNewlineOptions)
        )
      )
    }

    var configButtons: [UIBarButtonItem] = [pinButton]
    if isScratch {
      configButtons.append(languageModeButton)
    }

    let flexibleSpace = UIBarButtonItem(systemItem: .flexibleSpace)

    var rightBarButtonItems: [UIBarButtonItem] = sendButtons
    rightBarButtonItems.append(flexibleSpace)
    rightBarButtonItems.append(contentsOf: configButtons)

    self.navigationItem.rightBarButtonItems = rightBarButtonItems
  }

  private func _createLanguageModeMenu() -> UIMenu {
    let shellAction = UIAction(
      title: "Shell",
      image: UIImage(systemName: "terminal"),
      state: model.languageMode == .shell ? .on : .off,
      handler: { _ in self._updateForLanguageMode(.shell) }
    )

    let promptAction = UIAction(
      title: "Prompt",
      image: UIImage(systemName: "text.bubble"),
      state: model.languageMode == .prompt ? .on : .off,
      handler: { _ in self._updateForLanguageMode(.prompt) }
    )

    return UIMenu(title: "Language Mode", children: [shellAction, promptAction])
  }
}
