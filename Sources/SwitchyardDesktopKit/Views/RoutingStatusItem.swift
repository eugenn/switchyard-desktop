import AppKit

@MainActor
package final class RoutingStatusItem: NSObject, RoutingStatusDisplaying {
    private var item: NSStatusItem?
    private var contextMenu: NSMenu?
    package var onOpen: (() -> Void)?
    package var onControls: (() -> Void)?
    package var onStatistics: (() -> Void)?
    package var onStop: (() -> Void)?
    package var onRevealLogs: (() -> Void)?
    package var onQuit: (() -> Void)?

    package func update(_ presentation: RoutingStatusPresentation) {
        guard presentation.isVisible else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            contextMenu = nil
            return
        }
        if item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }
        let symbol = presentation.needsAttention
            ? "exclamationmark.arrow.triangle.2.circlepath"
            : "arrow.triangle.branch"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: presentation.title)
        image?.isTemplate = true
        item?.button?.image = image
        item?.button?.toolTip = "switchyard-desktop: \(presentation.title)"
        item?.button?.target = self
        item?.button?.action = #selector(statusItemClicked)
        item?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let menu = NSMenu()
        menu.autoenablesItems = false
        let status = NSMenuItem(title: presentation.title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        add("Open statistics", action: #selector(openStatistics), to: menu)
        add("Routing config", action: #selector(openControls), to: menu)
        add("Stop routing", action: #selector(stopRouting), to: menu, enabled: presentation.canStop)
        menu.addItem(.separator())
        add("Reveal logs in Finder", action: #selector(revealLogs), to: menu)
        menu.addItem(.separator())
        add("Quit switchyard-desktop...", action: #selector(quit), to: menu)
        contextMenu = menu
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu, enabled: Bool = true) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.isEnabled = enabled
        menu.addItem(entry)
    }

    @objc private func statusItemClicked() {
        handleClick(eventType: NSApp.currentEvent?.type)
    }

    package func handleClick(eventType: NSEvent.EventType?) {
        guard eventType == .rightMouseUp else {
            onOpen?()
            return
        }
        guard let item, let contextMenu else { return }
        item.menu = contextMenu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openControls() { onControls?() }
    @objc private func openStatistics() { onStatistics?() }
    @objc private func stopRouting() { onStop?() }
    @objc private func revealLogs() { onRevealLogs?() }
    @objc private func quit() { onQuit?() }
}
