import Foundation

public enum Involvement: String, Codable, Sendable {
    case none
    case requested
    case authorResponded
    case commented
    case requestedChanges
    case approved
}

public enum ReviewStatus: String, Codable, Sendable {
    case none
    case partlyApproved
    case approved
    case changesRequested
}

public enum CIStatus: String, Codable, Sendable {
    case none
    case pending
    case passing
    case failing
}

public struct CommentSummary: Hashable, Codable, Sendable {
    public let count: Int
    public let newSinceMyLastAction: Int
    public let latestAt: Date?
    public let countByPerson: [String: Int]
}

public struct PullRequest: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let repository: String
    public let number: Int
    public let title: String
    public let url: URL
    public let author: String
    public let branch: String
    public let additions: Int
    public let deletions: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let involvement: Involvement
    public let isWaitingOnAuthor: Bool
    public let isChangedSinceMyApproval: Bool
    public let comments: CommentSummary
    public let ci: CIStatus
    public let reviewStatus: ReviewStatus
    public let approvedBy: [String]
    public let changesRequestedBy: [String]

    public var isInvolvingMe: Bool { involvement != .none }

    public var isCoveredByOthers: Bool {
        reviewStatus == .approved && involvement != .requested && involvement != .authorResponded
    }
}

public enum NotificationTopic: String, CaseIterable, Codable, Identifiable, Sendable {
    case myPullRequests
    case yourTurn

    public var id: Self { self }
}

public struct Activity: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case approved
        case changesRequested
        case commented
        case replied
        case pushed
    }

    public let id: String
    public let pullRequestID: String
    public let actor: String
    public let kind: Kind
    public let createdAt: Date

    var topic: NotificationTopic {
        switch kind {
        case .replied, .pushed: .yourTurn
        case .approved, .changesRequested, .commented: .myPullRequests
        }
    }
}

public struct QueueSnapshot: Sendable {
    public let me: String
    public let reviewQueue: [PullRequest]
    public let myPullRequests: [PullRequest]
    public let activities: [Activity]
    public let warnings: [String]

    public var allPullRequests: [PullRequest] { reviewQueue + myPullRequests }
}

public func compactAge(of date: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    switch seconds {
    case ..<60: return "just now"
    case ..<3600: return "\(seconds / 60)m ago"
    case ..<86_400: return "\(seconds / 3600)h ago"
    default: return "\(seconds / 86_400)d ago"
    }
}
