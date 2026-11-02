// Copyright (C) 2026 Moshroom. Licensed under GPLv3; see COPYING.
// A simulator host for the production renderer, gesture interaction and selection controller.
// It has its own bundle/container, no entitlements, sessions, hosts, keys or networking libraries.
import UIKit
import WebKit

// The gesture interaction only reads these collaborators; nothing connects or persists here.
enum MoshroomDefaults {
  static func selectedFontSize() -> NSNumber { 20 }
  static func doInvertVerticalScroll() -> Bool { false }
}
enum MoshLog { static func log(_ area: String, _ message: String) {} }
class TermController: NSObject { var moshroomAlternateScreenScrollPolicy = "none" }
class TermDevice { var view: TermView? }
class TermView: UIView { var termController: NSObject?; var webView: WKWebView? }

@main final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    window = UIWindow(frame: UIScreen.main.bounds)
    window?.rootViewController = SelectionFixture()
    window?.makeKeyAndVisible()
    return true
  }
}

final class SelectionFixture: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {
  private var web: WKWebView!
  private var selection: TerminalSelectionController!
  private let gestures = WKWebViewGesturesInteraction(jsScrollerPath: "t.scrollPort_.scroller_")
  private let status = UILabel()
  private var timer: Timer?
  private var ready = false
  private var gestureEvents: [String] = []
  private var copied = ""
  private var sent = 0
  private var inputTaps = 0

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .moshroomBackground
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.userContentController.add(self, name: "interOp")
    web = WKWebView(frame: .zero, configuration: config)
    web.navigationDelegate = self
    web.isOpaque = false
    web.backgroundColor = .moshroomBackground
    web.addInteraction(gestures)
    gestures.focused = true
    for recognizer in gestures.allRecognizers { recognizer.addTarget(self, action: #selector(noteGesture(_:))) }
    view.addSubview(web)
    web.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      web.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      web.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
      web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
      web.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -60),
    ])
    selection = TerminalSelectionController(webView: web, host: view)
    gestures.selection = selection
    status.accessibilityIdentifier = "fixture.status"
    status.text = "Selection fixture"
    status.textColor = .white
    status.frame = CGRect(x: 12, y: 60, width: 300, height: 35)
    view.addSubview(status)
    NotificationCenter.default.addObserver(forName: UIPasteboard.changedNotification, object: nil, queue: .main) { [weak self] _ in
      self?.copied = UIPasteboard.general.string ?? ""
    }
    NotificationCenter.default.addObserver(forName: NSNotification.Name(MoshroomTerminalInputTapNotification), object: web, queue: .main) { [weak self] note in
      if note.userInfo?["input"] as? Bool == true { self?.inputTaps += 1 }
    }
    let url = Bundle.main.url(forResource: "term", withExtension: "html", subdirectory: "TerminalResources")!
    web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateStatus() }
  }

  @objc private func noteGesture(_ recognizer: UIGestureRecognizer) {
    gestureEvents.append("\(type(of: recognizer)):\(recognizer.state.rawValue)")
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    web.evaluateJavaScript("window.applyUserSettings = () => { term_set('font-family', 'Menlo'); term_set('font-size', 20); }; term_init(false, true);")
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let d = message.body as? [String: Any] else { return }
    if d["op"] as? String == "sendString" { sent += 1 }
    guard d["op"] as? String == "terminalReady" else { return }
    let rows = ["▎ Select this paragraph", "▎ and copy clean text.", "▎", "▎ Keep pipes: a | b."]
    let encoded = String(data: try! JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!
    let history = ProcessInfo.processInfo.arguments.contains("-history") ? (0..<80).map { "History row \($0)\r\n" }.joined() : ""
    let prefix = String(data: try! JSONSerialization.data(withJSONObject: [history]), encoding: .utf8)!
    web.evaluateJavaScript("term_write(\(prefix)[0] + \(encoded).join('\\r\\n') + '\\r\\n\\r\\n');") { [weak self] _, _ in self?.ready = true }
  }

  private func updateStatus() {
    guard ready else { return }
    web.evaluateJavaScript("JSON.stringify({...term_selGeometry(),text:term_selText({oneLine:true}),raw:term_selText({raw:true}),x:_mshGeom().left+5*_mshGeom().cw,y:_mshGeom().originTop+(t.scrollbackRows_.length+t.screen_.cursorPosition.row-5+0.5)*_mshGeom().ch,cw:_mshGeom().cw,ch:_mshGeom().ch,top:t.scrollPort_.getTopRowIndex()})") { [weak self] result, _ in
      guard let self, let json = result as? String else { return }
      var report = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
      report["gestures"] = self.gestureEvents
      report["copied"] = self.copied
      report["sent"] = self.sent
      report["inputTaps"] = self.inputTaps
      self.status.accessibilityValue = String(data: try! JSONSerialization.data(withJSONObject: report), encoding: .utf8)
    }
  }
}
