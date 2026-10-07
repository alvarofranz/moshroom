// Copyright (C) 2026 Moshroom. Licensed under GPLv3; see COPYING.

import SwiftUI
import UIKit

enum Moshtour {
  static let version = 1
  static let versionKey = "MoshroomWelcomeTourVersion"
  static var hasBeenSeen: Bool { UserDefaults.standard.integer(forKey: versionKey) >= version }
  enum Finish { case close, addHost, keys }
}

final class MoshtourModel: ObservableObject {
  @Published var step = 0
  @Published var usesMosh = false
  @Published var usesTmux = true
  @Published var showDetails = false
  @Published var hostCount: Int
  let simulatedEmpty: Bool
  var finish: (Moshtour.Finish) -> Void = { _ in }
  private var observers: [NSObjectProtocol] = []
  private let countHosts: () -> Int

  init(countHosts: @escaping () -> Int) {
    self.countHosts = countHosts
    simulatedEmpty = MoshroomDevelopment.enabled("tour-no-hosts")
    hostCount = simulatedEmpty ? 0 : countHosts()
    for name in [HostsCloudMirror.didChangeNotification, HostsCloudMirror.didSaveNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        guard let self, !self.simulatedEmpty else { return }
        self.hostCount = self.countHosts()
      })
    }
  }
  func next() {
    if step < 5 { step += 1; showDetails = false }
    else { finish(.close) }
  }
  func back() { if step > 0 { step -= 1; showDetails = false } }
  func choose(_ number: Int) {
    if step == 2 {
      if number < 3 { usesMosh = number == 2 } else { usesTmux.toggle() }
    } else if step == 3 {
      MoshroomTyping.shared.select(MoshroomTypingMode.allCases[number - 1])
    }
  }
  deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

final class MoshtourController: UIHostingController<MoshtourView> {
  let model: MoshtourModel
  init(model: MoshtourModel) {
    self.model = model
    super.init(rootView: MoshtourView(model: model))
  }
  @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var canBecomeFirstResponder: Bool { true }
  override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); becomeFirstResponder() }
  override var keyCommands: [UIKeyCommand]? {
    [(UIKeyCommand.inputRightArrow, "next"), ("\r", "next"), (UIKeyCommand.inputLeftArrow, "back"),
     (UIKeyCommand.inputEscape, "close"), ("1", "1"), ("2", "2"), ("3", "3")].map { input, action in
      let key = UIKeyCommand(title: "", action: #selector(navigate(_:)), input: input, modifierFlags: [], propertyList: action)
      key.wantsPriorityOverSystemBehavior = true
      return key
    }
  }
  @objc private func navigate(_ command: UIKeyCommand) {
    switch command.propertyList as? String {
    case "next": model.next()
    case "back": model.back()
    case "close": model.finish(.close)
    case "1": model.choose(1)
    case "2": model.choose(2)
    case "3": model.choose(3)
    default: break
    }
  }
}

struct MoshtourView: View {
  @ObservedObject var model: MoshtourModel
  @ObservedObject private var typing = MoshroomTyping.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var typeSize
  private let ground = Color(UIColor.moshroomBackground)

  private var title: String {
    switch model.step {
    case 0: return "Your servers,\nin your pocket."
    case 1: return "One server.\nRoom for every project."
    case 2: return "Connect your way."
    case 3: return "Write the way you like."
    case 4: return "Show it,\ndon’t describe it."
    default: return model.hostCount == 0 ? "Let’s add your\nfirst server." : "You’re all set."
    }
  }
  private var subtitle: String {
    switch model.step {
    case 0: return "Connect to a machine you can reach over SSH. Bring your tools, your projects and your agents with you."
    case 1: return "A host is a saved server. A project opens a folder on it, with its own tab and, when tmux is available, its own lasting session."
    case 2: return "SSH or Mosh carries your connection. tmux keeps your work running on the server so you can return to it."
    case 3: return "A quick command or a long idea. Choose how you type, and switch whenever you like."
    case 4: return "Attach screenshots, PDFs and code in the composer. When you send, they upload to your server and your agent gets the path."
    default: return model.hostCount == 0
      ? "You’ll need the server’s address, your username, and a password or SSH key."
      : "\(model.hostCount) \(model.hostCount == 1 ? "host" : "hosts") ready. Pick one in Quick Connect and make yourself at home."
    }
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        HStack {
          Text("MOSHROOM")
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .tracking(3)
            .foregroundStyle(.secondary)
          Spacer()
          Button { model.finish(.close) } label: {
            MoshNavGlyph(systemName: "xmark")
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
            .buttonStyle(.plain)
            .moshCatalystPlainButtons()
            .accessibilityLabel("Skip welcome tour")
            .accessibilityIdentifier("tour.skip")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)

        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            illustration(height: max(90, min(190, geometry.size.height * 0.25)))
              .dynamicTypeSize(.large) // Decorative artwork; the explanatory text below scales.
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
              Text(["HELLO, WORLD", "HOSTS & PROJECTS", "CONNECTIONS & SESSIONS", "YOUR KEYBOARD", "MORE THAN TEXT", "READY WHEN YOU ARE"][model.step])
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(Color.moshTint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
              Text(typeSize.isAccessibilitySize ? title.replacingOccurrences(of: "\n", with: " ") : title)
                .font(.system(.largeTitle, design: .default).weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("tour.title")
              Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            pageControls(width: min(560, geometry.size.width - 48))
          }
          .frame(maxWidth: 560)
          .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 172), alignment: .center)
          .padding(.horizontal, 24)
          .padding(.vertical, 12)
          .id(model.step)
          .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 18)), removal: .opacity))
        }
        .scrollBounceBehavior(.basedOnSize)
        .simultaneousGesture(DragGesture(minimumDistance: 50).onEnded { gesture in
          guard abs(gesture.translation.width) > abs(gesture.translation.height) * 2 else { return }
          if gesture.translation.width < 0 {
            if model.step < 5 { model.next() }
          } else { model.back() }
        })

        footer
          .frame(maxWidth: 560)
          .padding(.horizontal, 24)
          .padding(.vertical, 18)
          .frame(maxWidth: .infinity)
      }
      .background(ground.ignoresSafeArea())
    }
    .preferredColorScheme(.dark)
    .tint(.moshTint)
    .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.3), value: model.step)
    .onChange(of: model.step) { _, _ in UIAccessibility.post(notification: .screenChanged, argument: title) }
  }

  private var footer: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(spacing: 12))
      : AnyLayout(HStackLayout(spacing: 16))
    return layout {
      HStack(spacing: 16) {
        if model.step > 0 {
          Button { model.back() } label: {
            Image(systemName: "arrow.left").font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
          .moshCatalystPlainButtons()
          .accessibilityLabel("Previous page")
          .accessibilityIdentifier("tour.back")
        }
        HStack(spacing: 5) {
          ForEach(0..<6) { index in
            Capsule().fill(index == model.step ? Color.moshTint : Color.white.opacity(0.18))
              .frame(width: index == model.step ? 22 : 6, height: 6)
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(model.step + 1) of 6")
        if typeSize.isAccessibilitySize { Spacer(minLength: 0) }
      }
      if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
      Button { model.next() } label: {
        HStack(spacing: 10) {
          Text(model.step == 5 ? (model.hostCount == 0 ? "Later" : "Start") : "Next")
            .fixedSize(horizontal: false, vertical: true)
          if model.step < 5 { Image(systemName: "arrow.right") }
        }
        .font(.body.weight(.semibold))
        .padding(.horizontal, 22)
        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, minHeight: 46)
        .foregroundStyle(model.step == 5 ? .white : Color(UIColor.moshroomBackground))
        .background(model.step == 5 ? Color.moshTint : .white, in: Capsule())
      }
      .buttonStyle(.plain)
      .moshCatalystPlainButtons()
      .accessibilityIdentifier("tour.next")
    }
  }

  @ViewBuilder private func pageControls(width: CGFloat) -> some View {
    switch model.step {
    case 1:
      note("One tap opens the folder. Existing tmux sessions resume where you left them.", symbol: "arrow.uturn.backward")
    case 2: connectionChoices
    case 3:
      Picker("Typing", selection: Binding(get: { typing.mode }, set: { typing.select($0) })) {
        ForEach(MoshroomTypingMode.allCases) { mode in Text(mode.title).tag(mode) }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("tour.typing")
      Text(typing.mode.detail).font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      note("Open the composer with the pencil button or the Compose command in the File menu (⌘E by default).", symbol: "square.and.pencil")
    case 4:
      // These four rows need no lazy loading. Keep their accessibility identity while
      // switching to a single column for narrow windows and accessibility text sizes.
      let rowLayout = typeSize.isAccessibilitySize || width < 452
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
      VStack(alignment: .leading, spacing: 12) {
        rowLayout {
          feature("Select to copy", detail: "Drag or hold text, then Copy.", symbol: "selection.pin.in.out")
          feature("Files", detail: "Browse, edit and download.", symbol: "folder")
        }
        rowLayout {
          feature("Vault", detail: "Passwords and 2FA codes.", symbol: "key")
          feature("Snips", detail: "Your saved prompts and commands.", symbol: "text.badge.plus")
        }
      }
    case 5:
      if model.hostCount == 0 {
        Button { model.finish(.addHost) } label: {
          Label("Add a host", systemImage: "plus").font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 50).foregroundStyle(.white)
            .background(Color.moshTint, in: RoundedRectangle(cornerRadius: Moshstyle.cardRadius))
        }
        .buttonStyle(.plain).moshCatalystPlainButtons()
        .disabled(model.simulatedEmpty)
        .accessibilityIdentifier("tour.add-host")
        Button { model.finish(.keys) } label: {
          Label("Set up an SSH key", systemImage: "key").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain).moshCatalystPlainButtons()
        .disabled(model.simulatedEmpty)
      } else {
        note("Find this tour again in Settings › Welcome Tour.", symbol: "sparkles")
      }
    default:
      note("Your tools run on your server. Moshroom brings their terminal to you.", symbol: "terminal")
    }
  }

  private var connectionChoices: some View {
    VStack(alignment: .leading, spacing: 16) {
      Picker("Connection", selection: $model.usesMosh) {
        Text("SSH").tag(false)
        Text("Mosh").tag(true)
      }.pickerStyle(.segmented).accessibilityIdentifier("tour.transport")
      Toggle(isOn: $model.usesTmux) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Keep work running with tmux").font(.subheadline.weight(.medium))
          Text("A session you can leave and return to.").font(.caption).foregroundStyle(.secondary)
        }
      }.accessibilityIdentifier("tour.tmux")

      VStack(alignment: .leading, spacing: 12) {
        feature(model.usesMosh ? "Made for changing networks" : "SSH, with your usual credentials",
                detail: model.usesMosh ? "Keeps the connection through temporary outages and Wi-Fi / mobile changes."
                  : model.usesTmux ? "Moshroom reconnects to the tmux session if the connection drops."
                  : "A dropped connection may end the shell and its attached programs.",
                symbol: model.usesMosh ? "wifi" : "network")
        feature(model.usesTmux ? "Come back from another device" : "An ordinary remote shell",
                detail: model.usesTmux ? "Reconnect to the same named session while it is running on the server."
                  : "There is no tmux session to attach to from a new connection.",
                symbol: model.usesTmux ? "arrow.triangle.2.circlepath" : "terminal")
      }
      Text("Explore the combinations here. This does not change your saved hosts.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      DisclosureGroup("Requirements & details", isExpanded: $model.showDetails) {
        VStack(alignment: .leading, spacing: 12) {
          detail("On the server", model.usesMosh
                 ? "SSH access to start the connection, mosh-server, and an allowed UDP port or range (60000–61000 by default).\(model.usesTmux ? " Also tmux." : "")"
                 : "SSH access.\(model.usesTmux ? " Also tmux; Moshroom falls back to plain SSH if it is unavailable or too old." : " No extra session manager is required.")")
          detail("What Moshroom opens", "Quick Connect’s SSH choice uses tmux by default. A Mosh host uses its configured startup command; Mosh projects try tmux and fall back to a shell if it is missing. Change host settings or long-press a host for a one-off connection.")
          detail("Leaving and returning", "Changing networks, backgrounding the app and closing a tab are different. Moshroom can restore a suspended Mosh connection when its saved state and server are still available. tmux lets a new connection attach to an existing session. Neither keeps a program alive after you end it or the server restarts.")
          detail("Scrolling", "SSH + tmux integrates the session’s history with Moshroom’s scrolling. Mosh synchronizes the visible screen; use the remote program or tmux for its history.")
        }.padding(.top, 10)
      }.font(.subheadline)
    }
  }

  private func detail(_ title: String, _ body: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.subheadline.weight(.semibold))
      Text(body).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
  private func note(_ text: String, symbol: String) -> some View {
    Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol) }
      .font(.footnote).foregroundStyle(.secondary)
      .padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: Moshstyle.cardRadius))
  }
  private func feature(_ title: String, detail: String, symbol: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol).foregroundStyle(Color.moshTint).frame(width: 24).padding(.top, 2)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }.frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
  }

  @ViewBuilder private func illustration(height: CGFloat) -> some View {
    TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion)) { timeline in
      let phase = reduceMotion ? 0.85 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5) / 5
      Group {
        switch model.step {
        case 0: TourConnectionArt(phase: phase, usesMosh: false, usesTmux: false)
        case 1: TourProjectArt(phase: phase)
        case 2: TourConnectionArt(phase: phase, usesMosh: model.usesMosh, usesTmux: model.usesTmux)
        case 3: TourEditorArt(phase: phase, direct: typing.mode == .direct || (typing.mode == .automatic && typing.hardwareKeyboard))
        case 4: TourEditorArt(phase: phase, direct: false)
        default:
          ZStack {
            Circle().stroke(Color.moshTint.opacity(0.15), lineWidth: 1).frame(width: height * 0.8, height: height * 0.8)
            Circle().fill(Color.moshTint.opacity(0.08)).frame(width: height * 0.62, height: height * 0.62)
            Image(systemName: model.hostCount == 0 ? "server.rack" : "checkmark")
              .font(.system(size: height * 0.28, weight: .medium)).foregroundStyle(Color.moshTint)
              .scaleEffect(reduceMotion ? 1 : 1 + 0.03 * sin(phase * .pi * 2))
          }.frame(maxWidth: .infinity)
        }
      }.frame(height: height).clipped()
    }
  }
}

// Illustrations contain only deterministic sample data. Their labels are decorative; the page
// explains the idea in accessible text, and no host names, sessions or uploaded files are read.
private struct TourConnectionArt: View {
  let phase: Double
  let usesMosh: Bool
  let usesTmux: Bool
  var body: some View {
    HStack(spacing: 18) {
      Image(systemName: "iphone").font(.system(size: 66, weight: .ultraLight)).foregroundStyle(.white)
      GeometryReader { geometry in
        ZStack {
          Path { path in path.move(to: CGPoint(x: 0, y: geometry.size.height / 2)); path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2)) }
            .stroke(Color.moshTint.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: usesMosh ? [4, 6] : []))
          ForEach(0..<3) { index in
            Circle().fill(Color.moshTint).frame(width: 6, height: 6)
              .position(x: geometry.size.width * (phase + Double(index) / 3).truncatingRemainder(dividingBy: 1), y: geometry.size.height / 2)
          }
          Image(systemName: usesMosh ? (phase < 0.5 ? "wifi" : "antenna.radiowaves.left.and.right") : "lock.shield")
            .font(.title3).foregroundStyle(.secondary).offset(y: -30)
        }
      }
      VStack(spacing: 10) {
        Image(systemName: "server.rack").font(.system(size: 50, weight: .ultraLight))
        Text(usesTmux ? "tmux" : "server").font(.system(.caption, design: .monospaced))
          .foregroundStyle(usesTmux ? Color.moshTint : .secondary)
      }
      .frame(width: 108, height: 124)
      .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: Moshstyle.cardRadius))
      .overlay(RoundedRectangle(cornerRadius: Moshstyle.cardRadius).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }.padding(.horizontal, 24)
  }
}

private struct TourProjectArt: View {
  let phase: Double
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Image(systemName: "server.rack").foregroundStyle(Color.moshTint)
        VStack(alignment: .leading, spacing: 2) {
          Text("myserver").font(.body.weight(.semibold))
          Text("Your development machine").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
      }
      ForEach(["api", "website"], id: \.self) { project in
        HStack(spacing: 12) {
          Text(project == "api" ? "├" : "└").foregroundStyle(.secondary)
          Image(systemName: "folder").foregroundStyle(project == "api" ? Color.moshTint : .secondary)
          Text(project)
          Spacer()
          if project == "api", phase > 0.4 { Image(systemName: "arrow.up.forward").foregroundStyle(Color.moshTint) }
        }
        .font(.system(.subheadline, design: .monospaced))
        .padding(.leading, 8)
      }
    }
    .padding(20)
    .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Moshstyle.cardRadius))
    .overlay(RoundedRectangle(cornerRadius: Moshstyle.cardRadius).stroke(Color.moshTint.opacity(phase > 0.4 ? 0.7 : 0.15), lineWidth: 1))
    .frame(maxWidth: 420)
    .frame(maxWidth: .infinity)
  }
}

private struct TourEditorArt: View {
  let phase: Double
  let direct: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(direct ? "TERMINAL" : "COMPOSER").font(.system(.caption2, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
        Spacer()
        Image(systemName: direct ? "terminal" : "square.and.pencil").foregroundStyle(.secondary)
      }
      if direct {
        HStack(spacing: 0) {
          Text("$ ").foregroundStyle(Color.moshTint)
          Text(String("git status".prefix(min(10, Int(phase * 18)))))
          Rectangle().fill(Color.moshTint).frame(width: 8, height: 19).opacity(phase < 0.75 || Int(phase * 20) % 2 == 0 ? 1 : 0)
          Spacer()
        }.font(.custom("JetBrainsMono-Regular", size: 17, relativeTo: .body))
        Text(phase > 0.65 ? "On branch main" : " ").font(.custom("JetBrainsMono-Regular", size: 13, relativeTo: .caption)).foregroundStyle(.secondary)
      } else {
        Text("Can you help with this screen?").font(.body)
        HStack(spacing: 10) {
          Image(systemName: phase < 0.65 ? "photo" : "doc")
            .foregroundStyle(Color.moshTint).frame(width: 36, height: 32)
            .background(Color.moshTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
          Text(phase < 0.65 ? "screenshot.png" : "~/.moshroom/uploads/…png")
            .font(.custom("JetBrainsMono-Regular", size: 12, relativeTo: .caption))
            .foregroundStyle(.secondary).lineLimit(1)
          Spacer(minLength: 0)
          Image(systemName: "arrow.up").font(.body.weight(.semibold))
            .foregroundStyle(Color(UIColor.moshroomBackground)).frame(width: 34, height: 34)
            .background(.white, in: Circle())
        }
      }
    }
    .padding(20)
    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: Moshstyle.cardRadius))
    .overlay(RoundedRectangle(cornerRadius: Moshstyle.cardRadius).stroke(Color.white.opacity(0.12), lineWidth: 1))
    .frame(maxWidth: 460).frame(maxWidth: .infinity)
  }
}

extension SpaceController {
  func openMoshtour() {
    let host = moshroomTopPresenter
    moshroomPresentFullScreen(from: host) { [weak self, weak host] in
      let model = MoshtourModel(countHosts: { [weak self] in self?.moshroomSavedHostAliases.count ?? 0 })
      let simulatedEmpty = model.simulatedEmpty
      model.finish = { [weak self, weak host] destination in
        guard let self, let host else { return }
        if !MoshroomDevelopment.enabled("welcome-tour") && !simulatedEmpty {
          UserDefaults.standard.set(Moshtour.version, forKey: Moshtour.versionKey)
        }
        host.dismiss(animated: false) { [weak self] in
          guard let self else { return }
          self.moshroomRestoreKeyboardOwner()
          self.showMoshnectorIfIdle()
          if destination != .close {
            // A first-launch tour has no Settings underneath. Open setup directly then;
            // dismiss only when returning through an existing modal stack.
            if self.presentedViewController != nil {
              self.dismiss(animated: false) { [weak self] in self?.moshroomOpenTourSetup(destination) }
            } else {
              self.moshroomOpenTourSetup(destination)
            }
          }
        }
      }
      return MoshtourController(model: model)
    }
  }

  private func moshroomOpenTourSetup(_ destination: Moshtour.Finish) {
    guard !MoshroomDevelopment.enabled("tour-no-hosts") else { return }
    moshroomPresentFullScreen(from: self) {
      let nav = UINavigationController()
      let settings = SettingsHostingController.createSettings(nav: nav, onClose: { [weak self] in self?.dismiss(animated: false) },
                                                              onWelcomeTour: { [weak self] in self?.openMoshtour() })
      let content: UIViewController
      if destination == .addHost {
        content = UIHostingController(rootView: NavView(navController: nav) { HostView(host: nil, reloadList: {}) })
      } else {
        content = UIHostingController(rootView: NavView(navController: nav) { KeyListView() })
      }
      nav.setViewControllers([settings, content], animated: false)
      return nav
    }
  }
}
