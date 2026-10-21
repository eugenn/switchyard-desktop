import Testing
@testable import SwitchyardDesktopKit

@Suite("Model glow")
struct ModelGlowTests {
    private func level(
        share: Double = 0.4, hasTraffic: Bool = true, isActive: Bool = false,
        isSelected: Bool = false, isFocused: Bool = true
    ) -> Double {
        ModelGlowLayer.level(
            share: share, hasTraffic: hasTraffic, isActive: isActive,
            isSelected: isSelected, isFocused: isFocused
        )
    }

    @Test("A model that served nothing gives no light")
    func idleIsDark() {
        #expect(level(share: 0, hasTraffic: false) == 0)
        #expect(level(hasTraffic: false, isActive: true) == 0)
    }

    @Test("More traffic and the active model glow brighter")
    func brightness() {
        #expect(level(share: 0.6) > level(share: 0.1))
        #expect(level(isActive: true) > level())
        #expect(level(isSelected: true) > level())
    }

    @Test("Exploring another model quiets the halo and it never exceeds 1")
    func focusAndCeiling() {
        #expect(level(isFocused: false) < level())
        #expect(level(share: 1, isActive: true, isSelected: true) <= 1)
    }

    @Test("Tubes thicken with traffic at the router and an idle one stays thin")
    func tubeRadius() {
        let busy = RequestFlowView.tubeRadius(share: 0.7, hasTraffic: true)
        let quiet = RequestFlowView.tubeRadius(share: 0.05, hasTraffic: true)
        let idle = RequestFlowView.tubeRadius(share: 0, hasTraffic: false)
        #expect(busy > quiet)
        #expect(quiet > idle)
        #expect(idle > 0)
    }
}
