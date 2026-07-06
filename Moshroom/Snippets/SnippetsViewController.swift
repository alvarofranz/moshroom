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
import SwiftUI
import MoshroomSnippets

struct SwiftUISnippetsView: View {
  @ObservedObject var model: SearchModel

  @State var transitionFrame: CGRect? = nil

  var body: some View {
    HStack(alignment: .top) {
      if model.editingSnippet == nil && model.newSnippetPresented == false {
        Spacer()
        VStack {
          Spacer().onAppear {
            withAnimation(.easeOut(duration: 0.33)) {
              transitionFrame = nil
            }
          }

          SnippetsListView(model: model)
            .frame(maxWidth: transitionFrame == nil ? 560 : nil)
            .frame(minWidth: transitionFrame?.width, maxWidth: transitionFrame?.width, minHeight: transitionFrame?.height, maxHeight: transitionFrame?.height)
            .background(
              .regularMaterial,
              in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }

        Spacer()
      }
    }
    .padding([.leading, .trailing, .top], 5) // to match quick actions
    .padding(.bottom, 20)
    .ignoresSafeArea(.all)
  }
}

class PassThroughContainerView: UIView {
  var shouldPassThrough: (() -> Bool)?
  weak var hostingView: UIView?

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hitView = super.hitTest(point, with: event)

    // If we should pass through...
    if shouldPassThrough?() == true {
      // ...and we hit this container or the hosting view, then pass through (reject the hitTest)
      if hitView == self || hitView == hostingView {
        return nil
      }
    }

    return hitView
  }
}

class SnippetsViewController: UIHostingController<SwiftUISnippetsView>, UIGestureRecognizerDelegate{
  var model: SearchModel!
  var tapGestureRecogninzer: UITapGestureRecognizer!
  var pendingOpenScratch: Bool = false
  var hostingView: UIView?

  override func loadView() {
    super.loadView()

    let container = PassThroughContainerView(frame: .zero)
    container.backgroundColor = .clear
    container.shouldPassThrough = { [weak self] in
      self?.model?.editingSnippet != nil || self?.model?.newSnippetPresented == true
    }

    let hostingView = self.view!
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    hostingView.backgroundColor = .clear

    self.hostingView = hostingView
    container.hostingView = hostingView
    container.addSubview(hostingView)
    NSLayoutConstraint.activate([
      hostingView.topAnchor.constraint(equalTo: container.topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
    ])

    self.view = container
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    // Add tap gesture recognizer to dismiss snippets (tapping outside the list)
    let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(_onTap(_:)))
    tapRecognizer.delegate = self
    self.view.addGestureRecognizer(tapRecognizer)
    self.tapGestureRecogninzer = tapRecognizer
  }

  public static func create(context: (any SnippetContext)?, transitionFrame: CGRect?) throws -> SnippetsViewController {
    let model = try SearchModel()
    model.snippetContext = context
    let rootView = SwiftUISnippetsView(model: model, transitionFrame: transitionFrame)
    let ctrl = SnippetsViewController(rootView: rootView)
    ctrl.model = model
    model.rootCtrl = ctrl
    return ctrl
  }
  
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    self.model.inputView?.becomeFirstResponder()
    if pendingOpenScratch {
      pendingOpenScratch = false
      self.model.openScratch()
    }
  }
  
  @objc func _onTap(_ recognizer: UITapGestureRecognizer) {
    if model.editingSnippet == nil && model.newSnippetPresented == false {
      model.close()
    }
  }
  
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    // Accept touches on passthrough or hosting view (empty areas)
    touch.view == self.view || touch.view == hostingView
  }

}

