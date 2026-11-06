import Foundation

public enum CardDetail: String, CaseIterable, Codable, Identifiable, Sendable {
    case reviewStatus
    case comments
    case ci
    case waiting
    case size

    public var id: Self { self }
}

public enum QueueSort: String, CaseIterable, Codable, Identifiable, Sendable {
    case mostUrgent
    case latestComment
    case recentlyUpdated
    case newestOpened
    case oldestOpened

    public var id: Self { self }
}

public enum ApprovedPlacement: String, CaseIterable, Codable, Identifiable, Sendable {
    case bottom
    case hide

    public var id: Self { self }
}

public struct HiddenPullRequest: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: URL

    public init(_ pullRequest: PullRequest) {
        id = pullRequest.id
        title = pullRequest.title
        url = pullRequest.url
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let refreshChoices = [2, 5, 10, 15, 30, 60]
    public static let idleLimitChoices = [7, 14, 30, 60, 90]

    public var teams: Set<String> = []
    public var repositories: Set<String> = []
    public var refreshMinutes = 10
    public var idleLimitDays: Int? = 30
    public var cardDetails = Set(CardDetail.allCases)
    public var sort = QueueSort.mostUrgent
    public var approvedPlacement = ApprovedPlacement.bottom
    public var branchFilter: String?
    public var authorTeams: Set<String> = []
    public var botAccounts: Set<String> = []
    public var onlyInvolvingMe = false
    public var notificationTopics = Set(NotificationTopic.allCases)
    public var hiddenPullRequests: [HiddenPullRequest] = []
    public var collapsedSections: Set<QueueSection> = [.waitingOnAuthor, .approved]

    public init() {}

    public func idleCutoff(now: Date) -> Date? {
        idleLimitDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
    }

    public init(from decoder: Decoder) throws {
        let defaults = AppSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        teams = try container.decodeIfPresent(Set<String>.self, forKey: .teams) ?? defaults.teams
        repositories = try container.decodeIfPresent(Set<String>.self, forKey: .repositories) ?? defaults.repositories
        refreshMinutes = try container.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? defaults.refreshMinutes
        idleLimitDays = container.contains(.idleLimitDays)
            ? try container.decode(Int?.self, forKey: .idleLimitDays)
            : defaults.idleLimitDays
        cardDetails = try Self.decodeKnown(CardDetail.self, forKey: .cardDetails, in: container) ?? defaults.cardDetails
        sort = try container.decodeIfPresent(QueueSort.self, forKey: .sort) ?? defaults.sort
        approvedPlacement = try container.decodeIfPresent(ApprovedPlacement.self, forKey: .approvedPlacement) ?? defaults.approvedPlacement
        branchFilter = try container.decodeIfPresent(String.self, forKey: .branchFilter)
        authorTeams = try container.decodeIfPresent(Set<String>.self, forKey: .authorTeams) ?? defaults.authorTeams
        botAccounts = try container.decodeIfPresent(Set<String>.self, forKey: .botAccounts) ?? defaults.botAccounts
        onlyInvolvingMe = try container.decodeIfPresent(Bool.self, forKey: .onlyInvolvingMe) ?? defaults.onlyInvolvingMe
        notificationTopics = try Self.decodeKnown(NotificationTopic.self, forKey: .notificationTopics, in: container) ?? defaults.notificationTopics
        hiddenPullRequests =
            try container.decodeIfPresent([HiddenPullRequest].self, forKey: .hiddenPullRequests) ?? defaults.hiddenPullRequests
        collapsedSections =
            try container.decodeIfPresent(Set<QueueSection>.self, forKey: .collapsedSections) ?? defaults.collapsedSections
    }

    // Options removed in a later version are dropped instead of failing the whole settings load.
    private static func decodeKnown<Option: RawRepresentable<String>, Key: CodingKey>(
        _ type: Option.Type,
        forKey key: Key,
        in container: KeyedDecodingContainer<Key>
    ) throws -> Set<Option>? {
        try container.decodeIfPresent([String].self, forKey: key).map { Set($0.compactMap(Option.init(rawValue:))) }
    }
}
