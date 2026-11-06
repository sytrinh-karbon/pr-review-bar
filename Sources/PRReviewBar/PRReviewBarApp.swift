import ReviewCore
import SwiftUI

@main
struct PRReviewBarApp: App {
    @ViewState private var model = QueueModel()
    @ViewState private var repoSync = RepoSyncModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model, repoSync: repoSync)
        } label: {
            Image(systemName: "arrow.triangle.pull")
            if model.needsReviewCount > 0 {
                Text("\(model.needsReviewCount)")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model, repoSync: repoSync)
        }
    }
}

extension QueueSection {
    var title: String {
        switch self {
        case .needsReview: "Needs your review"
        case .waitingOnAuthor: "Waiting on author"
        case .approved: "Approved by you"
        case .mine: "Your pull requests"
        }
    }

    var emptyMessage: String {
        switch self {
        case .needsReview: "Nothing is waiting for you."
        case .waitingOnAuthor: "No pull requests are waiting on their authors."
        case .approved: "You have not approved any open pull requests."
        case .mine: "You have no open pull requests."
        }
    }
}

extension CardDetail {
    var title: String {
        switch self {
        case .reviewStatus: "Review status (colored stripe on the left)"
        case .comments: "Human comments (bots left out)"
        case .ci: "CI status"
        case .waiting: "Waiting time (opened and last updated)"
        case .size: "Size (lines added and removed)"
        }
    }
}

extension QueueSort {
    var title: String {
        switch self {
        case .mostUrgent: "Most urgent"
        case .latestComment: "Latest comment"
        case .recentlyUpdated: "Recently updated"
        case .newestOpened: "Newest opened"
        case .oldestOpened: "Oldest opened"
        }
    }
}

extension ApprovedPlacement {
    var title: String {
        switch self {
        case .bottom: "Move to the bottom"
        case .hide: "Hide them"
        }
    }
}

extension NotificationTopic {
    var title: String {
        switch self {
        case .myPullRequests: "Reviews and comments on my pull requests"
        case .yourTurn: "It's my turn again: the author pushed or replied after my review or comment"
        }
    }
}

extension Binding {
    func contains<Element: Hashable & Sendable>(_ element: Element) -> Binding<Bool> where Value == Set<Element> {
        Binding<Bool>(
            get: { wrappedValue.contains(element) },
            set: { isIncluded in
                if isIncluded {
                    wrappedValue.insert(element)
                } else {
                    wrappedValue.remove(element)
                }
            }
        )
    }
}
