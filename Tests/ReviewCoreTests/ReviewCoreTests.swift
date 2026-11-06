import Foundation
import Testing

@testable import ReviewCore

private let me = "sy"
private let base = Date(timeIntervalSince1970: 1_800_000_000)

private func actor(_ login: String, bot: Bool = false) -> [String: Any] {
    ["login": login, "__typename": bot ? "Bot" : "User"]
}

private func comment(_ id: String, by author: [String: Any], at offset: TimeInterval) -> [String: Any] {
    ["id": id, "createdAt": iso(offset), "author": author]
}

private func review(
    _ id: String,
    by author: [String: Any],
    state: String,
    at offset: TimeInterval,
    body: String = "",
    commit: String = "head"
) -> [String: Any] {
    ["id": id, "state": state, "body": body, "submittedAt": iso(offset), "author": author, "commit": ["oid": commit]]
}

private func iso(_ offset: TimeInterval) -> String {
    ISO8601DateFormatter().string(from: base.addingTimeInterval(offset))
}

private func node(
    number: Int = 1,
    author: String = "alice",
    branch: String = "feature",
    createdAt: TimeInterval = 0,
    updatedAt: TimeInterval = 0,
    pushedAt: TimeInterval = 0,
    reviews: [[String: Any]] = [],
    threads: [[[String: Any]]] = [],
    comments: [[String: Any]] = [],
    requested: [String] = [],
    ci: String? = nil,
    decision: String? = nil
) throws -> PullRequestNode {
    let json: [String: Any] = [
        "number": number,
        "title": "PR \(number)",
        "url": "https://github.com/org/repo/pull/\(number)",
        "isDraft": false,
        "createdAt": iso(createdAt),
        "updatedAt": iso(updatedAt),
        "headRefOid": "head",
        "headRefName": branch,
        "additions": 0,
        "deletions": 0,
        "reviewDecision": decision as Any,
        "author": actor(author),
        "repository": ["nameWithOwner": "org/repo"],
        "reviews": ["nodes": reviews],
        "reviewThreads": ["nodes": threads.map { ["comments": ["nodes": $0]] }],
        "comments": ["nodes": comments],
        "reviewRequests": ["nodes": requested.map { ["requestedReviewer": ["login": $0]] }],
        "commits": ["nodes": [["commit": ["committedDate": iso(pushedAt), "statusCheckRollup": ci.map { ["state": $0] } as Any]]]],
    ]
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PullRequestNode.self, from: JSONSerialization.data(withJSONObject: json))
}

private func map(_ node: PullRequestNode) -> PullRequest {
    QueueMapper(me: me, botAccounts: []).pullRequest(from: node)
}

private func section(_ node: PullRequestNode) -> QueueSection {
    QueueSection.of(map(node))
}

@Suite struct WhoseTurnTests {
    @Test func notInvolvedAndNotBlockedNeedsReview() throws {
        let pr = try node(comments: [comment("c1", by: actor("bob"), at: 10)])
        #expect(map(pr).involvement == .none)
        #expect(section(pr) == .needsReview)
    }

    @Test func someoneElsesChangeRequestWaitsForTheAuthor() throws {
        let blocked = try node(reviews: [review("r1", by: actor("bob"), state: "CHANGES_REQUESTED", at: 10)])
        let pushed = try node(pushedAt: 20, reviews: [review("r1", by: actor("bob"), state: "CHANGES_REQUESTED", at: 10)])
        let replied = try node(
            reviews: [review("r1", by: actor("bob"), state: "CHANGES_REQUESTED", at: 10)],
            comments: [comment("c1", by: actor("alice"), at: 20)]
        )
        #expect(section(blocked) == .waitingOnAuthor)
        #expect(section(pushed) == .needsReview)
        #expect(section(replied) == .needsReview)
    }

    @Test func myApprovalKeepsItInApprovedAndFlagsLaterChanges() throws {
        let same = try node(reviews: [review("r1", by: actor(me), state: "APPROVED", at: 10)])
        let changed = try node(pushedAt: 20, reviews: [review("r1", by: actor(me), state: "APPROVED", at: 10, commit: "old")])
        #expect(section(same) == .approved)
        #expect(!map(same).isChangedSinceMyApproval)
        #expect(section(changed) == .approved)
        #expect(map(changed).isChangedSinceMyApproval)
    }

    @Test func myChangeRequestWaitsUntilTheAuthorPushesOrReplies() throws {
        let waiting = try node(reviews: [review("r1", by: actor(me), state: "CHANGES_REQUESTED", at: 10)])
        let pushed = try node(pushedAt: 20, reviews: [review("r1", by: actor(me), state: "CHANGES_REQUESTED", at: 10)])
        let replied = try node(
            reviews: [review("r1", by: actor(me), state: "CHANGES_REQUESTED", at: 10)],
            threads: [[comment("t1", by: actor(me), at: 10), comment("t2", by: actor("alice"), at: 20)]]
        )
        #expect(map(waiting).involvement == .requestedChanges)
        #expect(section(waiting) == .waitingOnAuthor)
        #expect(map(pushed).involvement == .authorResponded)
        #expect(section(pushed) == .needsReview)
        #expect(map(replied).involvement == .authorResponded)
    }

    @Test func myCommentWaitsUntilTheAuthorResponds() throws {
        let waiting = try node(comments: [comment("c1", by: actor(me), at: 10)])
        let answered = try node(comments: [comment("c1", by: actor(me), at: 10), comment("c2", by: actor("alice"), at: 20)])
        #expect(map(waiting).involvement == .commented)
        #expect(section(waiting) == .waitingOnAuthor)
        #expect(map(answered).involvement == .authorResponded)
        #expect(section(answered) == .needsReview)
    }

    @Test func onlyTheAuthorCanHandTheTurnBack() throws {
        let pr = try node(comments: [comment("c1", by: actor(me), at: 10), comment("c2", by: actor("bob"), at: 20), comment("c3", by: actor("cursor"), at: 30)])
        #expect(section(pr) == .waitingOnAuthor)
    }

    @Test func aRequestByNameWinsEvenAfterApproving() throws {
        let pr = try node(reviews: [review("r1", by: actor(me), state: "APPROVED", at: 10)], requested: [me])
        #expect(map(pr).involvement == .requested)
        #expect(section(pr) == .needsReview)
    }

    @Test func aDismissedApprovalNoLongerCounts() throws {
        let pr = try node(reviews: [review("r1", by: actor(me), state: "APPROVED", at: 10), review("r2", by: actor(me), state: "DISMISSED", at: 20)])
        #expect(map(pr).involvement != .approved)
    }
}

@Suite struct MappingTests {
    @Test func countsReviewerCommentsOnly() throws {
        let onlyAuthorAndBots = try node(
            threads: [[comment("t1", by: actor("cursor"), at: 1), comment("t2", by: actor("alice"), at: 2)]],
            comments: [comment("c1", by: actor("linear-code", bot: true), at: 0)]
        )
        let changeRequestWithText = try node(
            reviews: [review("r1", by: actor("anthony"), state: "CHANGES_REQUESTED", at: 1, body: "Bump is risky")],
            comments: [comment("c1", by: actor("alice"), at: 2)]
        )
        let emptyReviewWithInlineComment = try node(
            reviews: [review("r1", by: actor("bob"), state: "COMMENTED", at: 1)],
            threads: [[comment("t1", by: actor("bob"), at: 1)]]
        )
        #expect(map(onlyAuthorAndBots).comments.count == 0)
        #expect(map(changeRequestWithText).comments.count == 1)
        #expect(map(changeRequestWithText).comments.countByPerson == ["anthony": 1])
        #expect(map(emptyReviewWithInlineComment).comments.count == 1)
    }

    @Test func newCommentsAreFromOthersAfterMyLastAction() throws {
        let pr = map(try node(comments: [
            comment("c1", by: actor("bob"), at: 5),
            comment("c2", by: actor(me), at: 10),
            comment("c3", by: actor("bob"), at: 20),
            comment("c4", by: actor("alice"), at: 25),
        ]))
        #expect(pr.comments.count == 3)
        #expect(pr.comments.newSinceMyLastAction == 1)
        #expect(pr.comments.latestAt == base.addingTimeInterval(20))
    }

    @Test func mapsCIRollup() throws {
        #expect(map(try node(ci: "ERROR")).ci == .failing)
        #expect(map(try node(ci: "EXPECTED")).ci == .pending)
        #expect(map(try node(ci: nil)).ci == .none)
    }

    @Test func reviewStatusFollowsTheRepositoryRule() throws {
        let approvedByBob = [review("r1", by: actor("bob"), state: "APPROVED", at: 1)]
        #expect(map(try node(reviews: approvedByBob, decision: "APPROVED")).reviewStatus == .approved)
        #expect(map(try node(reviews: approvedByBob, decision: "REVIEW_REQUIRED")).reviewStatus == .partlyApproved)
        #expect(map(try node(reviews: approvedByBob)).reviewStatus == .approved)
        #expect(map(try node(decision: "REVIEW_REQUIRED")).reviewStatus == .none)
        let blocked = approvedByBob + [review("r2", by: actor("carol"), state: "CHANGES_REQUESTED", at: 2)]
        #expect(map(try node(reviews: blocked, decision: "CHANGES_REQUESTED")).reviewStatus == .changesRequested)
    }

    @Test func reviewerStandingUsesLatestDecision() throws {
        let pr = map(try node(reviews: [
            review("r1", by: actor("bob"), state: "CHANGES_REQUESTED", at: 1),
            review("r2", by: actor("bob"), state: "APPROVED", at: 2),
            review("r3", by: actor("carol"), state: "CHANGES_REQUESTED", at: 3),
        ]))
        #expect(pr.approvedBy == ["bob"])
        #expect(pr.changesRequestedBy == ["carol"])
    }

    @Test func activityOnMyPullRequestSkipsBotsAndMe() throws {
        let activities = QueueMapper(me: me, botAccounts: []).activitiesOnMyPullRequest(
            try node(
                author: me,
                reviews: [
                    review("r1", by: actor("bob"), state: "APPROVED", at: 1),
                    review("r2", by: actor("cursor"), state: "COMMENTED", at: 2),
                    review("r3", by: actor(me), state: "COMMENTED", at: 3),
                ],
                comments: [comment("c1", by: actor("carol"), at: 4)]
            )
        )
        #expect(activities.map(\.id) == ["r1", "c1"])
        #expect(activities.map(\.kind) == [.approved, .commented])
    }

    @Test func configuredBotAccountsAreSkipped() throws {
        let pr = try node(author: me, comments: [comment("c1", by: actor("Deploy-Bot"), at: 1), comment("c2", by: actor("carol"), at: 2)])
        let activities = QueueMapper(me: me, botAccounts: ["deploy-bot"]).activitiesOnMyPullRequest(pr)
        #expect(activities.map(\.id) == ["c2"])
    }

    @Test func yourTurnActivityCoversRepliesAndPushes() throws {
        let pr = try node(
            pushedAt: 30,
            reviews: [review("r1", by: actor(me), state: "CHANGES_REQUESTED", at: 10)],
            comments: [comment("c1", by: actor("alice"), at: 20), comment("c2", by: actor("bob"), at: 25)]
        )
        let mapper = QueueMapper(me: me, botAccounts: [])
        let activities = mapper.yourTurnActivities(in: pr)
        #expect(activities.map(\.kind) == [.replied, .pushed])
        #expect(activities.map(\.id) == ["c1", "org/repo#1@head"])
        #expect(mapper.yourTurnActivities(in: try node(comments: [comment("c1", by: actor("alice"), at: 20)])).isEmpty)
    }
}

@Suite struct QueueTests {
    private func sections(
        _ queue: QueueSnapshot,
        sort: QueueSort = .mostUrgent,
        approvedPlacement: ApprovedPlacement = .bottom,
        hidden: [PullRequest] = [],
        branchFilter: String? = nil,
        onlyInvolvingMe: Bool = false
    ) -> [QueueSection: [PullRequest]] {
        var settings = AppSettings()
        settings.sort = sort
        settings.approvedPlacement = approvedPlacement
        settings.hiddenPullRequests = hidden.map(HiddenPullRequest.init)
        settings.branchFilter = branchFilter
        settings.onlyInvolvingMe = onlyInvolvingMe
        return queue.sections(using: settings)
    }

    private func snapshot(_ reviewNodes: [PullRequestNode], mine: [PullRequestNode] = []) -> QueueSnapshot {
        QueueMapper(me: me, botAccounts: []).snapshot(reviewNodes: reviewNodes, myNodes: mine, warnings: [])
    }

    @Test func mostUrgentPutsRequestsThenAnswersThenOldestThenApprovedByOthers() throws {
        let approvedByBob = [review("r", by: actor("bob"), state: "APPROVED", at: 1)]
        let queue = snapshot([
            try node(number: 1, createdAt: 0),
            try node(number: 2, createdAt: 50, requested: [me]),
            try node(number: 3, createdAt: 40, comments: [comment("c1", by: actor(me), at: 10), comment("c2", by: actor("alice"), at: 20)]),
            try node(number: 4, createdAt: -10),
            try node(number: 5, createdAt: -20, reviews: approvedByBob),
            try node(number: 6, createdAt: 60, reviews: approvedByBob, comments: [comment("c3", by: actor(me), at: 10), comment("c4", by: actor("alice"), at: 20)]),
        ])
        #expect(sections(queue)[.needsReview]?.map(\.number) == [2, 3, 6, 4, 1, 5])
        #expect(sections(queue, approvedPlacement: .hide)[.needsReview]?.map(\.number) == [2, 3, 6, 4, 1])
    }

    @Test func sortOptionsOrderWithinEachPart() throws {
        let queue = snapshot([
            try node(number: 1, createdAt: 0, updatedAt: 300, comments: [comment("c1", by: actor("bob"), at: 100)]),
            try node(number: 2, createdAt: 10, updatedAt: 100, comments: [comment("c2", by: actor("bob"), at: 300)]),
            try node(number: 3, createdAt: -10, updatedAt: 200, comments: [comment("c3", by: actor("alice"), at: 400)]),
        ])
        func order(_ sort: QueueSort) -> [Int]? { sections(queue, sort: sort)[.needsReview]?.map(\.number) }
        #expect(order(.latestComment) == [2, 1, 3])
        #expect(order(.recentlyUpdated) == [1, 3, 2])
        #expect(order(.newestOpened) == [2, 1, 3])
        #expect(order(.oldestOpened) == [3, 1, 2])
    }

    @Test func involvingMeKeepsOnlyMyPullRequestsAndOnesIAmIn() throws {
        let queue = snapshot(
            [try node(number: 1), try node(number: 2, requested: [me]), try node(number: 3, comments: [comment("c1", by: actor(me), at: 10)])],
            mine: [try node(number: 4, author: me)]
        )
        let result = sections(queue, onlyInvolvingMe: true)
        #expect(result[.needsReview]?.map(\.number) == [2])
        #expect(result[.waitingOnAuthor]?.map(\.number) == [3])
        #expect(result[.mine]?.map(\.number) == [4])
    }

    @Test func hiddenPullRequestsAreLeftOut() throws {
        let queue = snapshot([try node(number: 1), try node(number: 2)], mine: [try node(number: 3, author: me)])
        let result = sections(queue, hidden: queue.reviewQueue.filter { $0.number == 1 } + queue.myPullRequests)
        #expect(result[.needsReview]?.map(\.number) == [2])
        #expect(result[.mine]?.isEmpty == true)
    }

    @Test func branchFilterKeepsMatchingReviewPullRequestsOnly() throws {
        let queue = snapshot(
            [try node(number: 1, branch: "PAY-2368-add-sync"), try node(number: 2, branch: "pla-12-fix")],
            mine: [try node(number: 3, author: me, branch: "my-branch")]
        )
        let result = sections(queue, branchFilter: "pay")
        #expect(result[.needsReview]?.map(\.number) == [1])
        #expect(result[.mine]?.map(\.number) == [3])
    }

    @Test func notificationsGroupNewActivityPerPullRequest() throws {
        let mine = try node(
            number: 7,
            author: me,
            reviews: [review("old", by: actor("bob"), state: "APPROVED", at: 1), review("r1", by: actor("bob"), state: "COMMENTED", at: 100)],
            comments: [comment("c1", by: actor("bob"), at: 101), comment("c2", by: actor("carol"), at: 102)]
        )
        let notes = snapshot([], mine: [mine]).notifications(
            since: base.addingTimeInterval(50),
            excluding: [],
            topics: Set(NotificationTopic.allCases),
            hiding: []
        )
        #expect(notes.count == 1)
        #expect(notes.first?.summary == "bob left 2 comments · carol commented")
        #expect(notes.first?.activityIDs == ["r1", "c1", "c2"])
    }

    @Test func notificationsRespectTopicsAndAlreadyNotified() throws {
        let mine = try node(number: 7, author: me, comments: [comment("c1", by: actor("bob"), at: 100)])
        let other = try node(number: 8, pushedAt: 110, comments: [comment("c2", by: actor(me), at: 90), comment("c3", by: actor("alice"), at: 100)])
        let queue = snapshot([other], mine: [mine])
        let yourTurn = queue.notifications(since: base, excluding: [], topics: [.yourTurn], hiding: [])
        #expect(yourTurn.map(\.summary) == ["alice replied · alice pushed new commits"])
        #expect(queue.notifications(since: base, excluding: ["c1"], topics: [.myPullRequests], hiding: []).isEmpty)
        #expect(queue.notifications(since: base, excluding: [], topics: Set(NotificationTopic.allCases), hiding: ["org/repo#8"]).count == 1)
    }

    @Test func compactAgeUsesLargestUnit() {
        #expect(compactAge(of: base, now: base.addingTimeInterval(30)) == "just now")
        #expect(compactAge(of: base, now: base.addingTimeInterval(125)) == "2m ago")
        #expect(compactAge(of: base, now: base.addingTimeInterval(7200)) == "2h ago")
        #expect(compactAge(of: base, now: base.addingTimeInterval(3 * 86_400)) == "3d ago")
    }

    @Test func settingsDecodeWithMissingAndRetiredOptions() throws {
        let saved = #"{"refreshMinutes": 5, "notificationTopics": ["myPullRequests", "repliesToMe"], "cardDetails": ["ci", "gone"]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(saved.utf8))
        #expect(settings.refreshMinutes == 5)
        #expect(settings.notificationTopics == [.myPullRequests])
        #expect(settings.cardDetails == [.ci])
        #expect(settings.authorTeams.isEmpty)
    }
}
