import AppKit
import Observation
import RepoSync

@MainActor
@Observable
final class RepoSyncModel {
    private static let settingsKey = "repoSyncSettings"

    var settings: RepoSyncSettings {
        didSet {
            guard settings != oldValue else { return }
            save(settings)
            if settings.folder != oldValue.folder {
                outcomes = [:]
                repositories = []
            }
            if settings.organization != oldValue.organization { Task { await rescan() } }
            if settings.intervalMinutes != oldValue.intervalMinutes || settings.folder != oldValue.folder { startTimer() }
        }
    }
    private(set) var repositories: [LocalRepository] = []
    private(set) var outcomes: [String: SyncOutcome] = [:]
    private(set) var syncingIDs: Set<String> = []
    private(set) var lastSynced: Date?
    private(set) var errorMessage: String?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var isSyncQueued = false

    init() {
        do {
            settings = try Self.loadSettings(from: .standard)
        } catch {
            settings = RepoSyncSettings()
            errorMessage = "Saved sync settings could not be read, so defaults are in use."
        }
        startTimer()
    }

    var isSyncing: Bool { !syncingIDs.isEmpty }

    var includedRepositories: [LocalRepository] {
        repositories.filter { !settings.excludedRepositories.contains($0.name) }
    }

    var attentionCount: Int {
        includedRepositories.filter { outcomes[$0.id]?.needsAttention == true }.count
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds your company's repositories"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.folder = url.path
    }

    func rescan() async {
        guard let folder = settings.folder else {
            repositories = []
            return
        }
        do {
            let found = try await LocalRepository.discover(in: URL(filePath: folder))
            repositories = settings.organization.map { organization in found.filter { $0.belongs(to: organization) } } ?? found
            errorMessage = nil
        } catch {
            errorMessage = "Could not read \(folder): \(error.localizedDescription)"
        }
    }

    func syncNow() async {
        guard !isRunning else {
            isSyncQueued = true
            return
        }
        isRunning = true
        repeat {
            isSyncQueued = false
            await syncOnce()
        } while isSyncQueued
        isRunning = false
    }

    private func syncOnce() async {
        guard settings.folder != nil else { return }
        await rescan()
        let targets = includedRepositories
        guard !targets.isEmpty else { return }
        syncingIDs = Set(targets.map(\.id))
        await RepositorySyncer.syncAll(targets) { [weak self] repository, outcome in
            await self?.record(outcome, for: repository)
        }
        lastSynced = .now
    }

    private func record(_ outcome: SyncOutcome, for repository: LocalRepository) {
        outcomes[repository.id] = outcome
        syncingIDs.remove(repository.id)
    }

    private func startTimer() {
        timerTask?.cancel()
        guard settings.folder != nil else { return }
        let interval = Duration.seconds(settings.intervalMinutes * 60)
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func save(_ settings: RepoSyncSettings) {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: Self.settingsKey)
        } catch {
            errorMessage = "Could not save sync settings: \(error.localizedDescription)"
        }
    }

    private static func loadSettings(from defaults: UserDefaults) throws -> RepoSyncSettings {
        guard let data = defaults.data(forKey: settingsKey) else { return RepoSyncSettings() }
        return try JSONDecoder().decode(RepoSyncSettings.self, from: data)
    }
}
