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

struct StyleCustomizationView: View {
  @EnvironmentObject private var nav: Nav
  @ObservedObject private var store = TerminalStyleStore.shared

  @State private var editingStyle: TerminalStyle = TerminalStyle.makeBuiltInDefault()
  @State private var isLoaded = false
  @State private var themes: [MoshTheme] = []
  @State private var fonts: [MoshFont] = []
  @State private var previewRevision: Int = 0

  var body: some View {
    VStack(spacing: 0) {
      // -- Pinned Preview --
      TerminalPreviewCell(style: editingStyle, revision: previewRevision)
        .frame(height: 200)

      Text("Configuration will be applied to new terminal sessions.")
        .font(.footnote)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)

      // -- Scrollable Settings --
      List {
        // -- Themes --
        Section("Themes") {
          ForEach(themes, id: \.name) { theme in
            Button {
              editingStyle.themeName = theme.name
              applyToPreview()
            } label: {
              HStack {
                Text(theme.name).foregroundColor(.primary)
                Spacer()
                if editingStyle.themeName == theme.name {
                  Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
                }
              }
            }
          }
          .onDelete { offsets in
            deleteThemes(at: offsets)
          }

          Button {
            pushStoryboardController("MoshThemeCreateViewController")
          } label: {
            HStack {
              Text("Add a new theme")
              Spacer()
              Chevron()
            }
          }
        }

        // -- Fonts --
        Section("Fonts") {
          ForEach(fonts, id: \.name) { font in
            Button {
              editingStyle.fontName = font.name
              applyToPreview()
            } label: {
              HStack {
                Text(font.name).foregroundColor(.primary)
                Spacer()
                if editingStyle.fontName == font.name {
                  Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
                }
              }
            }
          }
          .onDelete { offsets in
            deleteFonts(at: offsets)
          }

          Button {
            pushStoryboardController("MoshFontCreateViewController")
          } label: {
            HStack {
              Text("Add a new font")
              Spacer()
              Chevron()
            }
          }
        }

        // -- Font Size & Options --
        Section {
          HStack {
            Text("Font Size")
            Spacer()
            Text("\(Int(editingStyle.fontSize)) px")
              .foregroundColor(.secondary)
            Stepper("", value: $editingStyle.fontSize, in: 1...100, step: 1)
              .labelsHidden()
              .onChange(of: editingStyle.fontSize) { _ in applyToPreview() }
          }

          HStack {
            Text("Enable Bold")
            Spacer()
            Picker("Enable Bold", selection: $editingStyle.boldMode) {
              Text("Auto").tag(TerminalStyle.BoldMode.auto)
              Text("On").tag(TerminalStyle.BoldMode.on)
              Text("Off").tag(TerminalStyle.BoldMode.off)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: editingStyle.boldMode) { _ in applyToPreview() }
          }

          Toggle("Bold as Bright", isOn: $editingStyle.boldAsBright)
            .onChange(of: editingStyle.boldAsBright) { _ in applyToPreview() }

          Toggle("Cursor Blink", isOn: $editingStyle.cursorBlink)
            .onChange(of: editingStyle.cursorBlink) { _ in applyToPreview() }
        } footer: {
          Text("Enable Bold controls whether bold text renders with a heavier font (Auto lets the theme decide). Bold as Bright additionally draws bold text in the bright color variants — how classic terminals did it. Cursor Blink is just that: a blinking or steady block cursor.")
        }
      }
      .listStyle(.insetGrouped)
      .moshReadableWidth()
    }
    .moshHubChromeBack(title: "Style")
    .onAppear {
      if !isLoaded {
        ensureEditableStyle()
        isLoaded = true
      }
      reloadResources()
    }
    .onDisappear {
      saveChanges()
    }
  }

  // MARK: - Style Management

  private func ensureEditableStyle() {
    if store.selectedStyleID == nil {
      let custom = store.createStyle(
        name: "Custom",
        themeName: store.builtInDefault.themeName,
        fontName: store.builtInDefault.fontName,
        fontSize: store.builtInDefault.fontSize,
        cursorBlink: store.builtInDefault.cursorBlink,
        boldMode: store.builtInDefault.boldMode,
        boldAsBright: store.builtInDefault.boldAsBright
      )
      store.setSelected(custom.id)
    }
    editingStyle = store.selectedStyle
  }

  /// Persist current editing state to the store so the MoshroomDefaults bridge
  /// exposes the new values, then bump revision to trigger TermView reload.
  private func applyToPreview() {
    store.updateStyle(editingStyle)
    previewRevision += 1
  }

  private func saveChanges() {
    store.updateStyle(editingStyle)
    MoshroomDefaults.save()
    NotificationCenter.default.post(name: NSNotification.Name(MoshAppearanceChanged), object: nil)
  }

  // MARK: - Resources

  private func reloadResources() {
    themes = (MoshTheme.all() as? [MoshTheme]) ?? []
    fonts = (MoshFont.all() as? [MoshFont]) ?? []
  }

  private func deleteThemes(at offsets: IndexSet) {
    let defaultCount = Int(MoshTheme.defaultResourcesCount())
    for offset in offsets.sorted().reversed() {
      if offset >= defaultCount {
        MoshTheme.remove(at: Int32(offset))
      }
    }
    reloadResources()
  }

  private func deleteFonts(at offsets: IndexSet) {
    let defaultCount = Int(MoshFont.defaultResourcesCount())
    for offset in offsets.sorted().reversed() {
      if offset >= defaultCount {
        MoshFont.remove(at: Int32(offset))
      }
    }
    reloadResources()
  }

  // MARK: - Navigation

  private func pushStoryboardController(_ identifier: String) {
    let storyboard = UIStoryboard(name: "Settings", bundle: nil)
    let vc = storyboard.instantiateViewController(withIdentifier: identifier)
    nav.navController.pushViewController(vc, animated: true)
  }
}

// MARK: - Terminal Preview

struct TerminalPreviewCell: UIViewRepresentable {
  var style: TerminalStyle
  /// Bump this to force a reload in updateUIView.
  var revision: Int

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> TermView {
    let termView = TermView(frame: .zero, termUIState: TermUIState(style: style))
    termView.backgroundColor = .systemGroupedBackground
    termView.isUserInteractionEnabled = false
    termView.device = context.coordinator
    context.coordinator.termView = termView
    termView.load()
    return termView
  }

  func updateUIView(_ termView: TermView, context: Context) {
    termView.applyTermUIState(TermUIState(style: style))
    termView.setCursorBlink(style.cursorBlink)
  }

  class Coordinator: NSObject, TermViewDeviceProtocol {
    weak var termView: TermView?

    var rawMode: Bool = false

    func viewIsReady() {
      guard let tv = termView else { return }
      tv.setWidth(60)
      writeColorShowcase()
    }

    func viewFontSizeChanged(_ size: Int) {}
    func viewSelectionChanged() {}
    func viewWinSizeChanged(_ win: winsize) {}
    func viewSend(_ data: String!) {}
    func viewCopy(_ text: String!) {}
    func viewShowAlert(_ title: String!, andMessage message: String!) {}
    func viewSubmitLine(_ line: String!) {}
    func viewAPICall(_ api: String!, andJSONRequest request: String!) {}
    func viewNotify(_ data: [AnyHashable: Any]!) {}
    func viewDidReceiveBellRing() {}

    private func writeColorShowcase() {
      let fgs = ["    m","   1m","  30m","1;30m","  31m","1;31m","  32m","1;32m",
                 "  33m","1;33m","  34m","1;34m","  35m","1;35m","  36m","1;36m","  37m","1;37m"]
      let bgs = ["40m","41m","42m","43m","44m","45m","46m","47m"]
      var lines: [String] = []
      for fg in fgs {
        let line = bgs.map { " \u{1b}[\(fg)\u{1b}[\($0)  gYw \u{1b}[0m" }.joined()
        lines.append(line)
      }
      termView?.write(lines.joined(separator: "\r\n"))
    }
  }
}
