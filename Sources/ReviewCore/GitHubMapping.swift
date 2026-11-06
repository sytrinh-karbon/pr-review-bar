import Foundation

struct Connection<Node: Decodable>: Decodable {
    let nodes: [Node]
}

extension Connection: Sendable where Node: Sendable {}

struct GitHubActor: Decodable {
    let login: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case login
        case type = "__typename"
    }
}

struct ListedPullRequest: Decodable {
    let number: Int
    let isDraft: Bool
    let updatedAt: Date
    let author: GitHubActor?
}

struct PullRequestNode: Decodable {
    struct Repository: Decodable {
        let nameWithOwner: String
    }

    struct Review: Decodable {
        struct Commit: Decodable {
            let oid: String
        }

        let id: String
        let state: String
        let body: String
        let submittedAt: Date?
        let author: GitHubActor?
        let commit: Commit?
    }

    struct Thread: Decodable {
        let comments: Connection<Comment>
    }

    struct Comment: Decodable {
        let id: String
        let createdAt: Date
        let author: GitHubActor?
    }

    struct ReviewRequest: Decodable {
        struct Reviewer: Decodable {
            let login: String?
        }

        let requestedReviewer: Reviewer?
    }

    struct CommitEntry: Decodable {
        struct Commit: Decodable {
            struct Rollup: Decodable {
                let state: String
            }

            let committedDate: Date
            let statusCheckRollup: Rollup?
        }

        let commit: Commit
    }

    let number: Int
    let title: String
    let url: URL
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    let headRefOid: String
    let headRefName: String
    let additions: Int
    let deletions: Int
    let reviewDecision: String?
    let author: GitHubActor?
    let repository: Repository
    let reviews: Connection<Review>
    let reviewThreads: Connection<Thread>
    let comments: Connection<Comment>
    let reviewRequests: Connection<ReviewRequest>
    let commits: Connection<CommitEntry>

    static let fragment = """
        fragment Full on PullRequest {
          number title url isDraft createdAt updatedAt headRefOid headRefName reviewDecision additions deletions
          author { login __typename }
          repository { nameWithOwner }
          reviews(last: 50) { nodes { id state body submittedAt author { login __typename } commit { oid } } }
          reviewThreads(last: 50) { nodes { comments(first: 30) { nodes { id createdAt author { login __typename } } } } }
          comments(last: 100) { nodes { id createdAt author { login __typename } } }
          reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } } } }
          commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state } } } }
        }
        """
}

struct QueueMapper {
    private static let knownBots: Set<String> = [
        "cursor", "dependabot", "renovate", "github-actions", "copilot", "linear", "vercel", "codecov", "sonarcloud",
    ]
    private static let decisiveStates: Set<String> = ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]
    private static let submittedStates: Set<String> = ["APPROVED", "CHANGES_REQUESTED", "COMMENTED"]

    private struct Remark {
        let id: String
        let actor: String
        let createdAt: Date
    }

    let me: String
    let botAccounts: Set<String>

    func isHuman(_ actor: GitHubActor?) -> Bool {
        guard let actor else { return false }
        let login = actor.login.lowercased()
        return actor.type != "Bot" && !login.hasSuffix("[bot]") && !Self.knownBots.contains(login) && !botAccounts.contains(login)
    }

    func snapshot(reviewNodes: [PullRequestNode], myNodes: [PullRequestNode], warnings: [String]) -> QueueSnapshot {
        QueueSnapshot(
            me: me,
            reviewQueue: reviewNodes.map(pullRequest(from:)),
            myPullRequests: myNodes.map(pullRequest(from:)),
            activities: myNodes.flatMap(activitiesOnMyPullRequest) + reviewNodes.flatMap(yourTurnActivities(in:)),
            warnings: warnings
        )
    }

    func pullRequest(from node: PullRequestNode) -> PullRequest {
        let author = node.author?.login ?? "ghost"
        let decisions = latestDecisionByReviewer(node)
        let approvedBy = decisions.filter { $0.value.state == "APPROVED" && $0.key != me }.keys.sorted()
        let changesRequestedBy = decisions.filter { $0.value.state == "CHANGES_REQUESTED" && $0.key != me }.keys.sorted()
        let myLastActionAt = lastActionTime(in: node)
        let involvement = involvement(in: node, decision: decisions[me], lastActionAt: myLastActionAt)
        let reviewerRemarks = remarks(in: node).filter { $0.actor != author }
        return PullRequest(
            id: Self.pullRequestID(node),
            repository: node.repository.nameWithOwner,
            number: node.number,
            title: node.title,
            url: node.url,
            author: author,
            branch: node.headRefName,
            additions: node.additions,
            deletions: node.deletions,
            createdAt: node.createdAt,
            updatedAt: node.updatedAt,
            involvement: involvement,
            isWaitingOnAuthor: isWaitingOnAuthor(node, involvement: involvement, decisions: decisions),
            isChangedSinceMyApproval: involvement == .approved && decisions[me]?.commit?.oid != node.headRefOid,
            comments: CommentSummary(
                count: reviewerRemarks.count,
                newSinceMyLastAction: myLastActionAt.map { since in reviewerRemarks.filter { $0.actor != me && $0.createdAt > since }.count } ?? 0,
                latestAt: reviewerRemarks.map(\.createdAt).max(),
                countByPerson: Dictionary(reviewerRemarks.map { ($0.actor, 1) }, uniquingKeysWith: +)
            ),
            ci: Self.ciStatus(node.commits.nodes.first?.commit.statusCheckRollup?.state),
            reviewStatus: Self.reviewStatus(decision: node.reviewDecision, approvedBy: approvedBy, changesRequestedBy: changesRequestedBy),
            approvedBy: approvedBy,
            changesRequestedBy: changesRequestedBy
        )
    }

    // A review request by name wins: it is a direct ask, even after you approved.
    func involvement(in node: PullRequestNode, decision: PullRequestNode.Review?, lastActionAt: Date?) -> Involvement {
        if node.reviewRequests.nodes.contains(where: { $0.requestedReviewer?.login == me }) { return .requested }
        if decision?.state == "APPROVED" { return .approved }
        guard let lastActionAt else { return .none }
        if authorRespondedAfter(lastActionAt, in: node) { return .authorResponded }
        return decision?.state == "CHANGES_REQUESTED" ? .requestedChanges : .commented
    }

    // A change request blocks the PR for every reviewer until the author pushes or replies, so it is the author's turn.
    func isWaitingOnAuthor(_ node: PullRequestNode, involvement: Involvement, decisions: [String: PullRequestNode.Review]) -> Bool {
        switch involvement {
        case .commented, .requestedChanges:
            return true
        case .requested, .authorResponded, .approved:
            return false
        case .none:
            let standingRequest = decisions
                .filter { $0.key != me && $0.value.state == "CHANGES_REQUESTED" }
                .compactMap(\.value.submittedAt)
                .max()
            return standingRequest.map { !authorRespondedAfter($0, in: node) } ?? false
        }
    }

    // GitHub sets reviewDecision only when branch protection requires reviews; without that rule one approval is enough.
    static func reviewStatus(decision: String?, approvedBy: [String], changesRequestedBy: [String]) -> ReviewStatus {
        if !changesRequestedBy.isEmpty { return .changesRequested }
        if decision == "APPROVED" || (decision == nil && !approvedBy.isEmpty) { return .approved }
        return approvedBy.isEmpty ? .none : .partlyApproved
    }

    static func ciStatus(_ state: String?) -> CIStatus {
        switch state {
        case "SUCCESS": .passing
        case "FAILURE", "ERROR": .failing
        case "PENDING", "EXPECTED": .pending
        default: .none
        }
    }

    // A reply to a review thread is itself submitted as a review, so reviews plus conversation comments cover all feedback.
    func activitiesOnMyPullRequest(_ node: PullRequestNode) -> [Activity] {
        let id = Self.pullRequestID(node)
        let reviews: [Activity] = node.reviews.nodes.compactMap { review in
            guard isHuman(review.author), let actor = review.author?.login, actor != me, let submittedAt = review.submittedAt else { return nil }
            let kind: Activity.Kind
            switch review.state {
            case "APPROVED": kind = .approved
            case "CHANGES_REQUESTED": kind = .changesRequested
            case "COMMENTED": kind = .commented
            default: return nil
            }
            return Activity(id: review.id, pullRequestID: id, actor: actor, kind: kind, createdAt: submittedAt)
        }
        let comments = node.comments.nodes.compactMap { comment -> Activity? in
            guard isHuman(comment.author), let actor = comment.author?.login, actor != me else { return nil }
            return Activity(id: comment.id, pullRequestID: id, actor: actor, kind: .commented, createdAt: comment.createdAt)
        }
        return reviews + comments
    }

    func yourTurnActivities(in node: PullRequestNode) -> [Activity] {
        guard let author = node.author?.login, let since = lastActionTime(in: node) else { return [] }
        let decision = latestDecisionByReviewer(node)[me]
        guard involvement(in: node, decision: decision, lastActionAt: since) == .authorResponded else { return [] }
        let id = Self.pullRequestID(node)
        let replies = remarks(in: node)
            .filter { $0.actor == author && $0.createdAt > since }
            .map { Activity(id: $0.id, pullRequestID: id, actor: author, kind: .replied, createdAt: $0.createdAt) }
        guard let pushedAt = node.commits.nodes.first?.commit.committedDate, pushedAt > since else { return replies }
        return replies + [Activity(id: "\(id)@\(node.headRefOid)", pullRequestID: id, actor: author, kind: .pushed, createdAt: pushedAt)]
    }

    private static func pullRequestID(_ node: PullRequestNode) -> String {
        "\(node.repository.nameWithOwner)#\(node.number)"
    }

    private func authorRespondedAfter(_ date: Date, in node: PullRequestNode) -> Bool {
        if let pushedAt = node.commits.nodes.first?.commit.committedDate, pushedAt > date { return true }
        guard let author = node.author?.login else { return false }
        return remarks(in: node).contains { $0.actor == author && $0.createdAt > date }
    }

    private func lastActionTime(in node: PullRequestNode) -> Date? {
        let reviews = node.reviews.nodes
            .filter { $0.author?.login == me && (Self.submittedStates.contains($0.state) || $0.state == "DISMISSED") }
            .compactMap(\.submittedAt)
        let comments = (node.comments.nodes + node.reviewThreads.nodes.flatMap(\.comments.nodes))
            .filter { $0.author?.login == me }
            .map(\.createdAt)
        return (reviews + comments).max()
    }

    // Comments by people, plus the summary text of a review; a review's inline comments arrive through the threads.
    private func remarks(in node: PullRequestNode) -> [Remark] {
        let comments = (node.comments.nodes + node.reviewThreads.nodes.flatMap(\.comments.nodes)).compactMap { comment -> Remark? in
            guard isHuman(comment.author), let actor = comment.author?.login else { return nil }
            return Remark(id: comment.id, actor: actor, createdAt: comment.createdAt)
        }
        let reviewTexts = node.reviews.nodes.compactMap { review -> Remark? in
            guard isHuman(review.author), let actor = review.author?.login, let submittedAt = review.submittedAt,
                Self.submittedStates.contains(review.state), !review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return Remark(id: review.id, actor: actor, createdAt: submittedAt)
        }
        return comments + reviewTexts
    }

    private func latestDecisionByReviewer(_ node: PullRequestNode) -> [String: PullRequestNode.Review] {
        var decisions: [String: PullRequestNode.Review] = [:]
        for review in node.reviews.nodes where Self.decisiveStates.contains(review.state) && isHuman(review.author) {
            if let login = review.author?.login { decisions[login] = review }
        }
        return decisions.filter { $0.value.state != "DISMISSED" }
    }
}
