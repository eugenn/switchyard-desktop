import Testing
@testable import SwitchyardDesktopKit

@Test func builtInCodexCatalogIsNonEmpty() {
    #expect(ModelCatalog.builtIn(for: .codex).entries.count >= 2)
}

@Test func addAppendsCustomEntry() {
    var catalog = ModelCatalog(builtIn: ["a"])
    catalog.add("custom-model")
    #expect(catalog.entries == ["a", "custom-model"])
}

@Test func addIgnoresBlanksAndDuplicates() {
    var catalog = ModelCatalog(builtIn: ["a"])
    catalog.add("   ")
    catalog.add("b")
    catalog.add("b")
    catalog.add("a")
    #expect(catalog.entries == ["a", "b"])
}

@Test func addTrimsSurroundingWhitespace() {
    var catalog = ModelCatalog(builtIn: [])
    catalog.add("  spaced-model \n")
    #expect(catalog.entries == ["spaced-model"])
}

@Test func removeDropsCustomEntry() {
    var catalog = ModelCatalog(builtIn: ["a"])
    catalog.add("b")
    catalog.remove("b")
    #expect(catalog.entries == ["a"])
}

@Test func removeHidesBuiltInAndReAddRestoresIt() {
    var catalog = ModelCatalog(builtIn: ["a", "b"])
    catalog.remove("a")
    #expect(catalog.entries == ["b"])

    catalog.add("a")
    #expect(catalog.entries == ["a", "b"])
}

@Test func removingUnknownIdIsANoOp() {
    var catalog = ModelCatalog(builtIn: ["a"])
    catalog.remove("nope")
    #expect(catalog.entries == ["a"])
}
