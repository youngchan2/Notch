import AppKit
import SwiftUI

/// Resolve the user's accent again when macOS updates colors or appearance.
struct SystemAccentReader: NSViewRepresentable {
    var onChange: (NSColor) -> Void

    func makeNSView(context: Context) -> AccentObservingView {
        let view = AccentObservingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: AccentObservingView, context: Context) {
        view.onChange = onChange
    }

    final class AccentObservingView: NSView {
        var onChange: ((NSColor) -> Void)?
        private var colorObserver: NSObjectProtocol?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            colorObserver = NotificationCenter.default.addObserver(
                forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.reportAccent() }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { if let colorObserver { NotificationCenter.default.removeObserver(colorObserver) } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportAccent()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            reportAccent()
        }

        private func reportAccent() {
            guard window != nil else { return }
            var color = NSColor.controlAccentColor
            effectiveAppearance.performAsCurrentDrawingAppearance {
                color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor
            }
            DispatchQueue.main.async { [weak self] in self?.onChange?(color) }
        }
    }
}
