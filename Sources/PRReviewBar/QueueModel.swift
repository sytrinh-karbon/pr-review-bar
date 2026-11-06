import AppKit
import Observation
import ReviewCore

@MainActor
@Observable
final class QueueModel {
    private enum StorageKey {
        static let settings = "settings"
        static let lastActivityCheck = "lastActivityCheck"
        static let notifiedActivityIDs = "notifiedActivityIDs"
    }

    private static let clockSkewAllowance: TimeInterval = 300
    private static let maxNotificationsPerRefresh = 5
    private static let rememberedActivityIDs = 1000

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            save(settings)
            if settings.refreshMinutes != oldValue.refreshMinutes { startPolling() }
            if settings.repositories != oldValue.repositories || settings.idleLimitDays != oldValue.idleLimitDays
                || settings.authorTeams != oldValue.authorTeams || settings.botAccounts != oldValue.botAccounts
            {
                Task { await refresh() }
            }
        }
    }
    private(set) var snapshot: QueueSnapshot?
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private(set) var teams: [Team] = []
    private(set) var repositoriesByTeam: [String: [String]] = [:]
    private(set) var teamsError: String?

    @ObservationIgnored private let client = GitHubClient()
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshQueued = false
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init() {
        do {
            settings = try Self.loadSettings(from: .standard)
        } catch {
            settings = AppSettings()
            errorMessage = "Saved settings could not be read, so defaults are in use."
        }
        startPolling()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task {
            do {
                try await notifier.requestAuthorization()
            } catch {
                errorMessage = "Notifications unavailable: \(error.localizedDescription)"
            }
        }
    }

    var sections: [QueueSection: [PullRequest]] {
        snapshot?.sections(using: settings) ?? [:]
    }

    var needsReviewCount: Int { sections[.needsReview]?.filter { !$0.isCoveredByOthers }.count ?? 0 }

    private var hiddenIDs: Set<String> { Set(settings.hiddenPullRequests.map(\.id)) }

    func refresh() async {
        guard !isRefreshing else {
            isRefreshQueued = true
            return
        }
        isRefreshing = true
        repeat {
            isRefreshQueued = false
            await fetch()
        } while isRefreshQueued
        isRefreshing = false
    }

    func hide(_ pullRequest: PullRequest) {
        settings.hiddenPullRequests.append(HiddenPullRequest(pullRequest))
    }

    func unhide(_ id: String) {
        settings.hiddenPullRequests.removeAll { $0.id == id }
    }

    func toggle(_ section: QueueSection) {
        if settings.collapsedSections.contains(section) {
            settings.collapsedSections.remove(section)
        } else {
            settings.collapsedSections.insert(section)
        }
    }

    func loadTeams() async {
        do {
            teams = try await client.teams()
            teamsError = nil
            for team in teams where settings.teams.contains(team.id) && repositoriesByTeam[team.id] == nil {
                try await loadRepositories(of: team)
            }
        } catch {
            teamsError = error.localizedDescription
        }
    }

    func setTeam(_ team: Team, isSelected: Bool) async {
        if isSelected {
            settings.teams.insert(team.id)
            do {
                try await loadRepositories(of: team)
            } catch {
                teamsError = error.localizedDescription
            }
            return
        }
        settings.teams.remove(team.id)
        let stillCovered = Set(settings.teams.flatMap { repositoriesByTeam[$0] ?? [] })
        let onlyInTeam = Set(repositoriesByTeam[team.id] ?? []).subtracting(stillCovered)
        settings.repositories.subtract(onlyInTeam)
    }

    private func loadRepositories(of team: Team) async throws {
        repositoriesByTeam[team.id] = try await client.repositories(of: team)
    }

    private func startPolling() {
        pollTask?.cancel()
        let interval = Duration.seconds(settings.refreshMinutes * 60)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func fetch() async {
        let checkStartedAt = Date.now
        do {
            let snapshot = try await client.snapshot(
                watching: settings.repositories,
                updatedSince: settings.idleCutoff(now: checkStartedAt),
                authorTeams: settings.authorTeams,
                botAccounts: settings.botAccounts
            )
            await notifyAboutActivity(in: snapshot, checkStartedAt: checkStartedAt)
            if snapshot.warnings.isEmpty { pruneHidden(keeping: snapshot) }
            self.snapshot = snapshot
            lastUpdated = .now
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func notifyAboutActivity(in snapshot: QueueSnapshot, checkStartedAt: Date) async {
        let lastCheck = defaults.object(forKey: StorageKey.lastActivityCheck) as? Date ?? checkStartedAt
        var notified = defaults.stringArray(forKey: StorageKey.notifiedActivityIDs) ?? []
        let notifications = snapshot.notifications(
            since: lastCheck.addingTimeInterval(-Self.clockSkewAllowance),
            excluding: Set(notified),
            topics: settings.notificationTopics,
            hiding: hiddenIDs
        )
        for notification in notifications.prefix(Self.maxNotificationsPerRefresh) {
            do {
                try await notifier.post(notification)
            } catch {
                errorMessage = "Could not show a notification: \(error.localizedDescription)"
            }
        }
        notified += notifications.flatMap(\.activityIDs)
        defaults.set(Array(notified.suffix(Self.rememberedActivityIDs)), forKey: StorageKey.notifiedActivityIDs)
        defaults.set(checkStartedAt, forKey: StorageKey.lastActivityCheck)
    }

    private func pruneHidden(keeping snapshot: QueueSnapshot) {
        let openIDs = Set(snapshot.allPullRequests.map(\.id))
        settings.hiddenPullRequests.removeAll { !openIDs.contains($0.id) }
    }

    private func save(_ settings: AppSettings) {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: StorageKey.settings)
        } catch {
            errorMessage = "Could not save settings: \(error.localizedDescription)"
        }
    }

    private static func loadSettings(from defaults: UserDefaults) throws -> AppSettings {
        guard let data = defaults.data(forKey: StorageKey.settings) else { return AppSettings() }
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }
}
