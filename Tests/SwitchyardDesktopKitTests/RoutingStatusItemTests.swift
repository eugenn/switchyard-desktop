import AppKit
import Testing
@testable import SwitchyardDesktopKit

@MainActor
@Test func primaryStatusItemClickUsesTheDefaultDestinationInsteadOfExplicitControls() {
    let statusItem = RoutingStatusItem()
    var openCount = 0
    var controlsCount = 0
    statusItem.onOpen = { openCount += 1 }
    statusItem.onControls = { controlsCount += 1 }

    statusItem.handleClick(eventType: .leftMouseUp)

    #expect(openCount == 1)
    #expect(controlsCount == 0)
}
