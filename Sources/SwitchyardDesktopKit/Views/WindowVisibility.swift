import AppKit
import SwiftUI

private struct RoutingWindowVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

package enum RoutingWindowVisibility {
    package static func isVisible(
        windowIsVisible: Bool, isMiniaturized: Bool, isOccluded: Bool, appIsHidden: Bool
    ) -> Bool {
        windowIsVisible && !isMiniaturized && !isOccluded && !appIsHidden
    }
}

extension EnvironmentValues {
    package var routingWindowVisible: Bool {
        get { self[RoutingWindowVisibleKey.self] }
        set { self[RoutingWindowVisibleKey.self] = newValue }
    }
}

package struct WindowVisibilityModifier: ViewModifier {
    @State private var isVisible = false
    let onChange: (Bool) -> Void

    package func body(content: Content) -> some View {
        content
            .environment(\.routingWindowVisible, isVisible)
            .background {
                WindowVisibilityObserver { isVisible = $0 }
                    .frame(width: 0, height: 0)
            }
            .onChange(of: isVisible, initial: true) { _, visible in
                onChange(visible)
            }
    }
}

extension View {
    package func observeRoutingWindowVisibility(onChange: @escaping (Bool) -> Void = { _ in }) -> some View {
        modifier(WindowVisibilityModifier(onChange: onChange))
    }
}

private struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        view.stopObserving()
    }

    @MainActor
    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification, NSApplication.didHideNotification,
                         NSApplication.didUnhideNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.queueVisibilityUpdate() }
                })
            }
            queueVisibilityUpdate()
        }

        private func queueVisibilityUpdate() {
            DispatchQueue.main.async { [weak self] in self?.updateVisibility() }
        }

        private func updateVisibility() {
            guard let window else { onChange?(false); return }
            onChange?(RoutingWindowVisibility.isVisible(
                windowIsVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized,
                isOccluded: !window.occlusionState.contains(.visible),
                appIsHidden: NSApp.isHidden
            ))
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }

        isolated deinit {
            stopObserving()
        }
    }
}
