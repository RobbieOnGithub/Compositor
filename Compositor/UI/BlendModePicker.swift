import SwiftUI
import AppKit

struct BlendModePicker: NSViewRepresentable {
    let session: EditorSession
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: LayerBlendMode.allCases.map(\.rawValue))
        button.menu?.delegate = context.coordinator
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.setAccessibilityLabel("Blend mode")
        // Match the SwiftUI controls where the newer AppKit API is available. The
        // pop-up still needs to build and render on the app's macOS 15 minimum.
        if #available(macOS 26.0, *) {
            button.borderShape = .capsule
        } else {
            button.bezelStyle = .rounded
        }
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        button.isEnabled = session.canEditAppearance
        if !context.coordinator.tracking {
            button.selectItem(withTitle: (session.activeLayer?.blendMode ?? .normal).rawValue)
        }
    }
    static func dismantleNSView(_ button: NSPopUpButton, coordinator: Coordinator) {
        if coordinator.tracking { coordinator.session.previewBlendMode(nil, for: nil) }
        button.menu?.delegate = nil
    }
    final class Coordinator: NSObject, NSMenuDelegate {
        let session: EditorSession
        var tracking = false
        private var layerID: UUID?
        private var highlightedMode: LayerBlendMode?
        init(session: EditorSession) { self.session = session }
        func menuWillOpen(_ menu: NSMenu) {
            tracking = true
            layerID = session.activeLayerID
            highlightedMode = nil
        }
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            let mode = item.flatMap { LayerBlendMode(rawValue: $0.title) }
            if let mode { highlightedMode = mode }
            session.previewBlendMode(mode, for: layerID)
        }
        func menuDidClose(_ menu: NSMenu) {
            tracking = false
            session.previewBlendMode(nil, for: nil)
        }
        @objc func choose(_ button: NSPopUpButton) {
            guard session.activeLayerID == layerID,
                  let mode = highlightedMode ?? button.selectedItem.flatMap({ LayerBlendMode(rawValue: $0.title) }) else { return }
            session.setLayerBlendMode(mode)
            button.selectItem(withTitle: mode.rawValue)
            highlightedMode = nil
            session.refreshCanvasPreview?()
        }
    }
}
