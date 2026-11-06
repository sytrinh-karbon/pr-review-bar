import ReviewCore
import SwiftUI

struct PullRequestCard: View {
    private static let stripeWidth: CGFloat = 4
    private static let cornerRadius: CGFloat = 8

    let pullRequest: PullRequest
    let details: Set<CardDetail>
    let onHide: () -> Void

    @ViewState private var isHovered = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(pullRequest.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Button(action: onHide) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .help("Hide this pull request")
            }
            Text("\(pullRequest.repository) #\(pullRequest.number) · \(pullRequest.author)")
                .font(.caption)
                .foregroundStyle(.secondary)
            badges
            detailRow
        }
        .padding(8)
        .padding(.leading, showsReviewStatus ? Self.stripeWidth : 0)
        .background(RoundedRectangle(cornerRadius: Self.cornerRadius).fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        .overlay(alignment: .leading) {
            if showsReviewStatus {
                UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius, bottomLeadingRadius: Self.cornerRadius)
                    .fill(reviewStatus.color)
                    .frame(width: Self.stripeWidth)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(.quaternary))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { openURL(pullRequest.url) }
        .contextMenu {
            Button("Open in Browser") { openURL(pullRequest.url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pullRequest.url.absoluteString, forType: .string)
            }
            Divider()
            Button("Hide", action: onHide)
        }
    }

    private var showsReviewStatus: Bool { details.contains(.reviewStatus) }

    @ViewBuilder private var badges: some View {
        let labels = badgeLabels
        if !labels.isEmpty {
            HStack(spacing: 6) {
                ForEach(labels, id: \.text) { label in
                    Text(label.text)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(label.color.opacity(0.18)))
                        .foregroundStyle(label.color)
                }
            }
        }
    }

    private var badgeLabels: [(text: String, color: Color)] {
        var labels: [(text: String, color: Color)] = []
        if showsReviewStatus { labels.append((reviewStatus.text, reviewStatus.color)) }
        if let involvement = involvementText { labels.append((involvement, .blue)) }
        return labels
    }

    private var involvementText: String? {
        switch pullRequest.involvement {
        case .none: nil
        case .requested: "Requested from you"
        case .authorResponded: "Author responded to you"
        case .commented: "You commented"
        case .requestedChanges: "You requested changes"
        case .approved: pullRequest.isChangedSinceMyApproval ? "Changed since you approved" : "You approved"
        }
    }

    private var commenters: String {
        let people = pullRequest.comments.countByPerson.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard !people.isEmpty else { return "No comments from reviewers" }
        return "Comments from reviewers: " + people.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    private var reviewStatus: (text: String, color: Color) {
        let approvers = pullRequest.approvedBy.joined(separator: ", ")
        switch pullRequest.reviewStatus {
        case .none: return ("Not approved yet", .gray)
        case .partlyApproved: return ("Approved by \(approvers), more needed", .orange)
        case .approved: return (approvers.isEmpty ? "Approved" : "Approved by \(approvers)", .green)
        case .changesRequested: return ("Changes requested by \(pullRequest.changesRequestedBy.joined(separator: ", "))", .red)
        }
    }

    @ViewBuilder private var detailRow: some View {
        let shown = details.subtracting([.reviewStatus])
        if !shown.isEmpty {
            HStack(spacing: 12) {
                if shown.contains(.comments) {
                    HStack(spacing: 3) {
                        Label("\(pullRequest.comments.count)", systemImage: "bubble.left")
                        if pullRequest.comments.newSinceMyLastAction > 0 {
                            Text("· \(pullRequest.comments.newSinceMyLastAction) new").foregroundStyle(.blue)
                        }
                    }
                    .help(commenters)
                }
                if shown.contains(.ci), let ci = ciLabel {
                    Label("CI \(ci.text)", systemImage: ci.symbol).foregroundStyle(ci.color)
                }
                if shown.contains(.waiting) {
                    Label(
                        "Opened \(compactAge(of: pullRequest.createdAt, now: .now)) · updated \(compactAge(of: pullRequest.updatedAt, now: .now))",
                        systemImage: "clock"
                    )
                }
                if shown.contains(.size) {
                    HStack(spacing: 4) {
                        Text("+\(pullRequest.additions)").foregroundStyle(.green)
                        Text("−\(pullRequest.deletions)").foregroundStyle(.red)
                    }
                    .monospacedDigit()
                    .help("\(pullRequest.additions) lines added, \(pullRequest.deletions) lines removed")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var ciLabel: (text: String, symbol: String, color: Color)? {
        switch pullRequest.ci {
        case .none: nil
        case .pending: ("running", "circle.dotted", .orange)
        case .passing: ("passing", "checkmark.circle.fill", .green)
        case .failing: ("failing", "xmark.circle.fill", .red)
        }
    }
}
