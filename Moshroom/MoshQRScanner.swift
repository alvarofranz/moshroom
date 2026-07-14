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
import AVFoundation

// A live camera QR reader for adding 2FA accounts. It emits every distinct payload it sees (so a
// multi-QR Google export can be scanned one code after another without leaving the camera). The
// caller decides when it's done and dismisses. Pure AVFoundation — no dependency.
struct MoshQRScannerView: UIViewControllerRepresentable {
  var onFound: (String) -> Void
  var onError: (String) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound, onError: onError) }
  func makeUIViewController(context: Context) -> MoshQRScannerController {
    let c = MoshQRScannerController()
    c.delegate = context.coordinator
    return c
  }
  func updateUIViewController(_ controller: MoshQRScannerController, context: Context) {}

  final class Coordinator: NSObject, MoshQRScannerControllerDelegate {
    let onFound: (String) -> Void
    let onError: (String) -> Void
    private var last: String?
    init(onFound: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
      self.onFound = onFound; self.onError = onError
    }
    func scanner(_ c: MoshQRScannerController, didFind payload: String) {
      guard payload != last else { return }   // de-dupe the same code frame after frame
      last = payload
      onFound(payload)
    }
    func scannerDidFail(_ c: MoshQRScannerController, reason: String) { onError(reason) }
  }
}

protocol MoshQRScannerControllerDelegate: AnyObject {
  func scanner(_ c: MoshQRScannerController, didFind payload: String)
  func scannerDidFail(_ c: MoshQRScannerController, reason: String)
}

final class MoshQRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  weak var delegate: MoshQRScannerControllerDelegate?
  private let session = AVCaptureSession()
  private var preview: AVCaptureVideoPreviewLayer?
  private let sessionQueue = DispatchQueue(label: "moshroom.qr.session")

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: configure()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
        DispatchQueue.main.async {
          if ok { self?.configure() }
          else { self?.delegate?.scannerDidFail(self!, reason: "Camera access denied") }
        }
      }
    default:
      delegate?.scannerDidFail(self, reason: "Camera access is off — enable it in Settings › Moshroom.")
    }
  }

  private func configure() {
    guard let device = AVCaptureDevice.default(for: .video),
          let input = try? AVCaptureDeviceInput(device: device),
          session.canAddInput(input) else {
      delegate?.scannerDidFail(self, reason: "No camera available on this device.")
      return
    }
    session.addInput(input)

    let output = AVCaptureMetadataOutput()
    guard session.canAddOutput(output) else {
      delegate?.scannerDidFail(self, reason: "Can't read QR codes on this device.")
      return
    }
    session.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: .main)
    output.metadataObjectTypes = [.qr]

    let layer = AVCaptureVideoPreviewLayer(session: session)
    layer.videoGravity = .resizeAspectFill
    layer.frame = view.bounds
    view.layer.addSublayer(layer)
    preview = layer

    sessionQueue.async { [session] in session.startRunning() }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview?.frame = view.bounds
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    sessionQueue.async { [session] in if session.isRunning { session.stopRunning() } }
  }

  func metadataOutput(_ output: AVCaptureMetadataOutput,
                      didOutput metadataObjects: [AVMetadataObject],
                      from connection: AVCaptureConnection) {
    guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
          let value = obj.stringValue else { return }
    delegate?.scanner(self, didFind: value)
  }
}
