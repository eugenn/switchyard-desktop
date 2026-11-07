import Foundation

package struct JevClassifierConfiguration: Codable, Equatable, Sendable {
    package static let endpoint = "https://api.typesafe.ai/v1/systemone"
    package static let apiKeyEnvironmentVariable = "TYPESAFE_API_KEY"

    package var modelID = "jev-latest"
    package var cutoff = 0.6
    package var instructions = ""
}
