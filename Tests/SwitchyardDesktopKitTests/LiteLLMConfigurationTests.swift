import Foundation
import Testing
@testable import SwitchyardDesktopKit

@MainActor
@Test func liteLLMConfigurationUsesAssignedModelsAndEscapesIdentifiers() throws {
    let data = try LiteLLMProcessManager.configuration(models: ["model\"\nname", "fast", "fast"])
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let models = try #require(object["model_list"] as? [[String: Any]])
    #expect(models.count == 2)
    #expect(models.compactMap { $0["model_name"] as? String }.contains("model\"\nname"))
    let fast = try #require(models.first { ($0["model_name"] as? String) == "fast" })
    #expect((fast["litellm_params"] as? [String: String])?["model"] == "chatgpt/fast")
}

@Test func bundledLiteLLMDoesNotReceiveForwardedCodexCredentials() throws {
    var profile = RoutingProfile(algorithm: .stageRouter)
    profile.tiers[0].modelID = "fast"
    profile.tiers[1].modelID = "capable"
    let local = try SwitchyardConfigWriter.render(profile: profile)
    #expect(local.contains("forward_auth = false"))
    profile.upstreamBaseURL = "https://chatgpt.com/backend-api/codex"
    let direct = try SwitchyardConfigWriter.render(profile: profile)
    #expect(direct.contains("forward_auth = true"))
}
