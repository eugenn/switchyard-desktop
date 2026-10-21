import Testing
@testable import SwitchyardDesktopKit

@Test func onlyCodexIsSelectable() {
    let selectable = Provider.allCases.filter(\.isSelectable)
    #expect(selectable == [.codex])
}

@Test func codexUsesOpenAIBaseURLAndResponsesFormat() {
    // The subscription endpoint: a forwarded ChatGPT credential is not an API key.
    #expect(Provider.codex.defaultUpstreamBaseURL == "http://127.0.0.1:4101/v1")
    #expect(Provider.codex.wireFormat == "openai_responses")
    #expect(Provider.codex.codexWireAPI == "responses")
}
