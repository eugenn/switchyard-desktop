import Testing
@testable import SwitchyardDesktopKit

@Suite("Routing window visibility")
struct WindowVisibilityTests {
    @Test("Only an exposed, unminimized app window stays active")
    func visibilityConditions() {
        #expect(RoutingWindowVisibility.isVisible(
            windowIsVisible: true, isMiniaturized: false, isOccluded: false, appIsHidden: false
        ))
        #expect(!RoutingWindowVisibility.isVisible(
            windowIsVisible: false, isMiniaturized: false, isOccluded: false, appIsHidden: false
        ))
        #expect(!RoutingWindowVisibility.isVisible(
            windowIsVisible: true, isMiniaturized: true, isOccluded: false, appIsHidden: false
        ))
        #expect(!RoutingWindowVisibility.isVisible(
            windowIsVisible: true, isMiniaturized: false, isOccluded: true, appIsHidden: false
        ))
        #expect(!RoutingWindowVisibility.isVisible(
            windowIsVisible: true, isMiniaturized: false, isOccluded: false, appIsHidden: true
        ))
    }
}
