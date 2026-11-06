import Foundation

public enum QueueSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case needsReview
    case waitingOnAuthor
    case approved
    case mine

    public var id: Self { self }

    static func of(_ pullRequest: PullRequest) -> QueueSection {
        if pullRequest.involvement == .approved { return .approved }
        return pullRequest.isWaitingOnAuthor ? .waitingOnAuthor : .needsReview
    }
}

public struct ActivityNotification: Equatable, Sendable {
    public let pullRequest: PullRequest
    public let summary: String
    public let activityIDs: [String]
}

extension QueueSnapshot {
    // Review requests from you stay on top; PRs others already approved sink below the rest, or are dropped.
    public func sections(using settings: AppSettings) -> [QueueSection: [PullRequest]] {
        let hidden = Set(settings.hiddenPullRequests.map(\.id))
        let sort = settings.sort
        let visibleQueue = reviewQueue.filter { pullRequest in
            !hidden.contains(pullRequest.id)
                && (!settings.onlyInvolvingMe || pullRequest.isInvolvingMe)
                && settings.branchFilter.map { pullRequest.branch.localizedCaseInsensitiveContains($0) } ?? true
        }
        var sections = Dictionary(grouping: visibleQueue, by: QueueSection.of).mapValues { Self.sorted($0, by: sort, isReviewQueue: false) }
        let needsReview = visibleQueue.filter { QueueSection.of($0) == .needsReview }
        let open = needsReview.filter { !$0.isCoveredByOthers }
        let covered = settings.approvedPlacement == .hide ? [] : needsReview.filter(\.isCoveredByOthers)
        sections[.needsReview] = Self.sorted(open, by: sort, isReviewQueue: true) + Self.sorted(covered, by: sort, isReviewQueue: true)
        sections[.mine] = Self.sorted(myPullRequests.filter { !hidden.contains($0.id) }, by: sort, isReviewQueue: false)
        return sections
    }

    public func notifications(
        since: Date,
        excluding notified: Set<String>,
        topics: Set<NotificationTopic>,
        hiding hidden: Set<String>
    ) -> [ActivityNotification] {
        let pullRequests = Dictionary(allPullRequests.map { ($0.id, $0) }) { first, _ in first }
        let fresh = activities
            .filter { $0.createdAt > since && !notified.contains($0.id) && topics.contains($0.topic) && !hidden.contains($0.pullRequestID) }
            .sorted { $0.createdAt < $1.createdAt }
        let byPullRequest = Dictionary(grouping: fresh, by: \.pullRequestID)
        return byPullRequest.keys.sorted().compactMap { id in
            guard let pullRequest = pullRequests[id], let activities = byPullRequest[id] else { return nil }
            return ActivityNotification(
                pullRequest: pullRequest,
                summary: Self.summary(of: activities),
                activityIDs: activities.map(\.id)
            )
        }
    }

    private static func sorted(_ pullRequests: [PullRequest], by sort: QueueSort, isReviewQueue: Bool) -> [PullRequest] {
        pullRequests.sorted { lhs, rhs in
            let lhsIsRequested = lhs.involvement == .requested
            let rhsIsRequested = rhs.involvement == .requested
            if isReviewQueue, lhsIsRequested != rhsIsRequested { return lhsIsRequested }
            switch sort {
            case .mostUrgent:
                return isReviewQueue ? isMoreUrgent(lhs, rhs) : lhs.updatedAt > rhs.updatedAt
            case .latestComment:
                return (lhs.comments.latestAt ?? .distantPast) > (rhs.comments.latestAt ?? .distantPast)
            case .recentlyUpdated:
                return lhs.updatedAt > rhs.updatedAt
            case .newestOpened:
                return lhs.createdAt > rhs.createdAt
            case .oldestOpened:
                return lhs.createdAt < rhs.createdAt
            }
        }
    }

    private static func isMoreUrgent(_ lhs: PullRequest, _ rhs: PullRequest) -> Bool {
        let lhsResponded = lhs.involvement == .authorResponded
        let rhsResponded = rhs.involvement == .authorResponded
        if lhsResponded != rhsResponded { return lhsResponded }
        return lhs.createdAt < rhs.createdAt
    }

    private static func summary(of activities: [Activity]) -> String {
        struct Key: Hashable {
            let actor: String
            let kind: Activity.Kind
        }
        var order: [Key] = []
        var counts: [Key: Int] = [:]
        for activity in activities {
            let key = Key(actor: activity.actor, kind: activity.kind)
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        return order.map { phrase(actor: $0.actor, kind: $0.kind, count: counts[$0] ?? 1) }.joined(separator: " · ")
    }

    private static func phrase(actor: String, kind: Activity.Kind, count: Int) -> String {
        switch kind {
        case .approved: "\(actor) approved"
        case .changesRequested: "\(actor) requested changes"
        case .commented: count == 1 ? "\(actor) commented" : "\(actor) left \(count) comments"
        case .replied: count == 1 ? "\(actor) replied" : "\(actor) replied \(count) times"
        case .pushed: "\(actor) pushed new commits"
        }
    }
}
