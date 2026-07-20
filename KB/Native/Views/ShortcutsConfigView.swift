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


// MARK: - ActionsList

struct ActionsList: View {
  @ObservedObject var shortcut: KeyShortcut
  var commandsMode: Bool
  var usedActions: Set<String> = []

  var pressList = KeyBindingAction.pressList
  var commandList = KeyBindingAction.commandList

  var body: some View {
    List {
      if commandsMode {
        Section(header: Text("Commands")) {
          ForEach(commandList.filter { ka in
            ka.id == shortcut.action.id || !usedActions.contains(ka.id)
          }, id: \.id) { ka in
            self._row(value: ka)
          }
        }
      } else {
        Section(header: Text("Action")) {
          _rowCustomSequence()
          ForEach(pressList, id: \.id) { ka in
            self._row(value: ka)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .moshReadableWidth()
    .moshHubChromeBack(title: "Action")
  }

  private func _rowCustomSequence() -> some View {
    let checked = shortcut.action.isCustomHEX
    return HStack {
      Text(checked ? "Press \(shortcut.action.title)" : "Press Custom Sequence")
      Spacer()
      Checkmark(checked: checked)
    }
    .overlay(NavButton(details: {
      CustomSequenceView(shortcut: self.shortcut)
    }))
  }

  private func _row(value: KeyBindingAction) -> some View {
    HStack {
      Text(value.title)
      Spacer()
      Checkmark(checked: shortcut.action.id == value.id)
    }.overlay(
      Button(action: {
        self.shortcut.action = value
      }, label: { EmptyView() }
      )
    )
  }
}

// MARK: - CustomSequenceView

enum SequenceMode: String, CaseIterable {
  case hex = "Hex"
  case string = "String"
}

struct CustomSequenceView: View {
  @ObservedObject var shortcut: KeyShortcut
  @State private var mode: SequenceMode
  @State private var input: String
  private let _formatter = HexFormatter()

  init(shortcut: KeyShortcut) {
    self.shortcut = shortcut
    let (hex, stringInput) = shortcut.action.hexValues
    let isString = stringInput != nil
    self._mode = State(initialValue: isString ? .string : .hex)
    self._input = State(initialValue: isString ? stringInput! : hex)
  }

  var body: some View {
    List {
      Section {
        Picker("Mode", selection: $mode) {
          ForEach(SequenceMode.allCases, id: \.self) { m in
            Text(m.rawValue).tag(m)
          }
        }
        .pickerStyle(SegmentedPickerStyle())
      }
      Section(
        footer: Text(mode == .string
          ? "Use string sequence, with \\x for escape characters."
          : "Use hex encoded sequence.")
      ) {
        TextField(mode == .string ? "Custom String" : "HEX", text: $input)
          .disableAutocorrection(true)
          .keyboardType(.asciiCapable)
      }
    }
    .listStyle(.insetGrouped)
    .moshReadableWidth()
    .moshHubChromeBack(title: "Custom Sequence")
    .onChange(of: mode) { _ in
      input = ""
    }
    .onDisappear {
      guard !input.isEmpty else { return }
      if mode == .string {
        let hex = _formatter.stringToHexString(input)
        shortcut.action = .hex(hex, stringInput: input, comment: nil)
      } else {
        let hex = _formatter.hexString(str: input)
        shortcut.action = .hex(hex, stringInput: nil, comment: nil)
      }
    }
  }
}

// MARK: - HexFormatter

class HexFormatter: Formatter {
  private let _hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

  override func string(for obj: Any?) -> String? {
    guard let str = obj as? NSString
    else {
      return nil
    }
    return str.uppercased
  }

  override func editingString(for obj: Any) -> String? {
    if let str = obj as? NSString {
      return str as String
    }
    return nil
  }

  override func isPartialStringValid(_ partialString: String, newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
    return partialString.isEmpty || partialString.rangeOfCharacter(from: _hexCharacterSet.inverted) == nil
  }

  override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
    obj?.pointee = hexString(str: string) as NSString
    return true
  }

  func hexString(str: String) -> String {
    String(
      str.replacingOccurrences(of: "[^0-9abcdef]", with: "", options: [.regularExpression, .caseInsensitive], range: nil)
        .uppercased()
        .prefix(1000)
    )
  }

  func stringToHexString(_ input: String) -> String {
    var result = ""
    var currentIndex = input.startIndex

    while currentIndex < input.endIndex {
      let currentCharacter = input[currentIndex]

      if currentCharacter == "\\" && input.index(currentIndex, offsetBy: 1) < input.endIndex && input[input.index(currentIndex, offsetBy: 1)] == "x" {
        // Skip "\x"
        currentIndex = input.index(currentIndex, offsetBy: 2)
        var hexSubstring = ""
        for _ in 0..<2 {
          if currentIndex < input.endIndex, "0123456789ABCDEFabcdef".contains(input[currentIndex]) {
            hexSubstring.append(input[currentIndex])
            currentIndex = input.index(after: currentIndex)
          } else {
            break
          }
        }
        // Ensure is double digit.
        if hexSubstring.count == 1 {
          hexSubstring = "0" + hexSubstring
        }
        result.append(hexSubstring)
      } else {
        let hexValue = String(format: "%02X", currentCharacter.unicodeScalars.first?.value ?? 0)
        result.append(hexValue)
        currentIndex = input.index(after: currentIndex)
      }
    }

    return result
  }
}

// MARK: - ShortcutConfigView

struct ShortcutConfigView: View {
  @EnvironmentObject var nav: Nav
  @ObservedObject var config: KBConfig
  @StateObject private var draft: KeyShortcut

  let shortcut: KeyShortcut?  // nil for new
  let commandsMode: Bool

  private var isNew: Bool { shortcut == nil }

  init(config: KBConfig, shortcut: KeyShortcut?, commandsMode: Bool, initialAction: KeyBindingAction = .none) {
    self._config = ObservedObject(wrappedValue: config)
    self.shortcut = shortcut
    self.commandsMode = commandsMode
    if let s = shortcut {
      self._draft = StateObject(wrappedValue: KeyShortcut(action: s.action, modifiers: s.modifiers, input: s.input))
    } else {
      self._draft = StateObject(wrappedValue: KeyShortcut(action: initialAction, modifiers: [], input: ""))
    }
  }

  private var isComplete: Bool {
    guard !draft.input.isEmpty else { return false }
    switch draft.action {
    case .none:
      return false
    case .hex(let val, _, _):
      return !val.isEmpty
    default:
      return true
    }
  }

  var body: some View {
      List {
        Section(
          header: Text("Combination"),
          footer: Text("Press keys on external KB to change.")
        ) {
          HStack {
            Text(draft.description)
          }
        }
        Section(header: Text("Action")) {
          DefaultRow(title: draft.action.title) {
            ActionsList(
              shortcut: self.draft,
              commandsMode: self.commandsMode,
              usedActions: Set(self.config.shortcuts
                .filter { $0 !== self.shortcut }
                .map { $0.action.id })
            )
          }
        }
      }
    .listStyle(.insetGrouped)
    .moshReadableWidth()
    .moshHubChrome(title: "Shortcut", leading: {
      Button(action: {
        _done()
      }) { MoshNavLabel(title: isComplete ? "Done" : "Cancel") }
    }, trailing: {
      Group {
        if !isNew {
          if draft.isInDefaultCommandList {
            if draft.isCleared {
              Button(action: {
                if let original = KeyShortcut.defaultFor(self.draft) {
                  self.shortcut?.modifiers = original.modifiers
                  self.shortcut?.input = original.input
                }
                self.nav.navController.popViewController(animated: true)
                self.config.touch()
              }) { MoshNavLabel(title: "Set Default") }
            } else {
              Button(action: {
                self.shortcut?.input = ""
                self.shortcut?.modifiers = []
                self.nav.navController.popViewController(animated: true)
                self.config.touch()
              }) { MoshNavLabel(title: "Clear") }
            }
          } else {
            Button(action: {
              self.config.shortcuts.removeAll(where: { $0 === self.shortcut })
              self.nav.navController.popViewController(animated: true)
              self.config.touch()
            }) { MoshNavLabel(title: "Delete") }
          }
        }
      }
    })
    .background(KeyCaptureView(shortcut: draft))
  }

  private func _done() {
    if isComplete {
      if let shortcut = shortcut {
        // Existing: commit draft to original
        shortcut.action = draft.action
        shortcut.modifiers = draft.modifiers
        shortcut.input = draft.input
      } else {
        // New: append to config
        let newShortcut = KeyShortcut(action: draft.action, modifiers: draft.modifiers, input: draft.input)
        config.shortcuts.append(newShortcut)
      }
      config.touch()
    }

    // Incomplete: just pop, nothing was added
    nav.navController.popViewController(animated: true)
  }
}

// MARK: - ShortcutsConfigView

struct ShortcutsConfigView: View {
  @EnvironmentObject var nav: Nav
  @ObservedObject var config: KBConfig
  var commandsMode: Bool

  var body: some View {
    let list = _list
    Group {
      if list.isEmpty {
        _emptyView()
      } else {
        _tableView(list: list)
      }
    }
    .moshHubChromeBack(title: commandsMode ? "Shortcuts" : "Presses") {
      if !list.isEmpty {
        Button(action: _addAction) { MoshNavLabel(title: "Add") }
      }
    }
  }

  private func _emptyView() -> some View {
    AnyView(MoshEmptyState(icon: "keyboard", title: "No shortcuts yet") {
      Button(action: _addAction) { Label("Add shortcut", systemImage: "plus") }
    })
  }

  private func _tableView(list: [KeyShortcut]) -> some View {
    List {
      ForEach(list, id: \.id) { shortcut in
        DefaultRow(title: shortcut.title, description: shortcut.description) {
          ShortcutConfigView(
            config: self.config,
            shortcut: shortcut,
            commandsMode: self.commandsMode
          )
        }
        .swipeActions(edge: .trailing) {
          if shortcut.isInDefaultCommandList {
            Button("Clear") {
              shortcut.input = ""
              shortcut.modifiers = []
              self.config.touch()
            }
            .tint(.orange)
          } else {
            Button("Delete", role: .destructive) {
              self.config.shortcuts.removeAll(where: { $0 === shortcut })
              self.config.touch()
            }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .moshReadableWidth()
  }

  private func _addAction() {
    let usedActions = Set(config.shortcuts.map { $0.action.id })
    let action: KeyBindingAction
    if commandsMode {
      action = KeyBindingAction.commandList.first { !usedActions.contains($0.id) }
        ?? KeyBindingAction.command(.clipboardCopy)
    } else {
      action = .none
    }
    let rootView = ShortcutConfigView(
      config: config,
      shortcut: nil,
      commandsMode: commandsMode,
      initialAction: action
    ).environmentObject(nav)
    let vc = UIHostingController(rootView: rootView)
    nav.navController.pushViewController(vc, animated: true)
  }

  private var _list: [KeyShortcut] {
    config
      .shortcuts
      .filter({$0.action.isCommand == commandsMode})
      .sorted(by: {$0.title < $1.title})
  }

}
