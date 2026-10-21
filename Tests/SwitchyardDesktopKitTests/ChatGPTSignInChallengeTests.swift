import Foundation
import Testing
@testable import SwitchyardDesktopKit

private let sampleChallenge = """
Sign in with ChatGPT using device code:
1) Visit https://auth.openai.com/codex/device
2) Enter code: ABCD-1234
Device codes are a common phishing target. Never share this code.

"""

@Test func signInChallengeSurvivesEveryPossiblePipeSplit() throws {
    let bytes = Data(sampleChallenge.utf8)
    for index in 0...bytes.count {
        var output = ChatGPTSignInOutput()
        output.append(bytes.prefix(index))
        output.append(bytes.dropFirst(index))
        let challenge = try #require(ChatGPTSignInChallenge(message: output.message))
        #expect(challenge.url.absoluteString == "https://auth.openai.com/codex/device")
        #expect(challenge.code == "ABCD-1234")
    }
}

@Test func signInChallengeWaitsForTheWholeCodeAndRejectsUnexpectedDestinations() {
    let incomplete = "1) Visit https://auth.openai.com/codex/device\n2) Enter code: ABCD"
    #expect(ChatGPTSignInChallenge(message: incomplete) == nil)
    #expect(ChatGPTSignInChallenge(message: "Checking LiteLLM's ChatGPT session…") == nil)
    for url in ["http://auth.openai.com/codex/device", "https://auth.openai.com.example.org/codex/device",
                "https://example.org/codex/device", "https://auth.openai.com/other",
                "https://user@auth.openai.com/codex/device", "https://auth.openai.com/codex/device?next=example.org"] {
        #expect(ChatGPTSignInChallenge(message: sampleChallenge.replacingOccurrences(
            of: "https://auth.openai.com/codex/device", with: url)) == nil)
    }
}

@Test func signInOutputPreservesUTF8AndBoundsMemory() {
    var output = ChatGPTSignInOutput()
    let text = "Проверка…"
    for byte in text.utf8 { output.append(Data([byte])) }
    #expect(output.message == text)
    output.append(Data(repeating: 65, count: ChatGPTSignInOutput.limit * 2))
    #expect(output.message.utf8.count == ChatGPTSignInOutput.limit)
    output.append(Data("ignored".utf8))
    #expect(!output.message.contains("ignored"))
}
