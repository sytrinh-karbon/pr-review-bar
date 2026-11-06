import Foundation

public struct RepoSyncSettings: Codable, Equatable, Sendable {
    public static let intervalChoices = [5, 10, 15, 30, 60]

    public var folder: String?
    public var organization: String?
    public var intervalMinutes = 15
    public var excludedRepositories: Set<String> = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let defaults = RepoSyncSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
        organization = try container.decodeIfPresent(String.self, forKey: .organization)
        intervalMinutes = try container.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? defaults.intervalMinutes
        excludedRepositories =
            try container.decodeIfPresent(Set<String>.self, forKey: .excludedRepositories) ?? defaults.excludedRepositories
    }
}
