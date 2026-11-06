import RepoSync
import ReviewCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: QueueModel
    let repoSync: RepoSyncModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            RepositorySettingsView(model: model)
                .tabItem { Label("Repositories", systemImage: "folder") }
            HiddenSettingsView(model: model)
                .tabItem { Label("Hidden", systemImage: "eye.slash") }
            LocalRepositoriesSettingsView(repoSync: repoSync)
                .tabItem { Label("Local Repos", systemImage: "arrow.down.circle") }
        }
        .frame(width: 620, height: 480)
    }
}

private struct LocalRepositoriesSettingsView: View {
    @Bindable var repoSync: RepoSyncModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Folder:")
                Text(repoSync.settings.folder ?? "Not chosen")
                    .foregroundStyle(repoSync.settings.folder == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…", action: repoSync.chooseFolder)
                if repoSync.settings.folder != nil {
                    Button("Stop pulling") { repoSync.settings.folder = nil }
                }
            }
            HStack {
                Text("Only repos from GitHub organization:")
                TextField("any", text: organizationBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Spacer()
            }
            HStack {
                Picker("Pull every", selection: $repoSync.settings.intervalMinutes) {
                    ForEach(RepoSyncSettings.intervalChoices, id: \.self) { minutes in
                        Text("\(minutes) minutes").tag(minutes)
                    }
                }
                .fixedSize()
                Spacer()
                Button(repoSync.isSyncing ? "Pulling…" : "Pull now") { Task { await repoSync.syncNow() } }
                    .disabled(repoSync.settings.folder == nil || repoSync.isSyncing)
            }
            Text("On main, only fast-forwards. On another branch, your branch is untouched and main is moved forward for later. Local commits on main or conflicting uncommitted changes are never overwritten.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage = repoSync.errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            List(repoSync.repositories) { repository in
                HStack(alignment: .top) {
                    Toggle("", isOn: includedBinding(repository)).labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repository.name)
                        Text(repository.gitHubName ?? repository.remoteURL ?? "No origin remote")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    outcomeView(for: repository)
                }
            }
        }
        .padding(16)
        .task { await repoSync.rescan() }
    }

    @ViewBuilder private func outcomeView(for repository: LocalRepository) -> some View {
        if repoSync.syncingIDs.contains(repository.id) {
            ProgressView().controlSize(.small)
        } else if let outcome = repoSync.outcomes[repository.id] {
            let (text, color) = describe(outcome)
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 260, alignment: .trailing)
        }
    }

    private func describe(_ outcome: SyncOutcome) -> (String, Color) {
        switch outcome {
        case let .updated(branch, commits): ("Pulled \(commits) new commit\(commits == 1 ? "" : "s") into \(branch)", .green)
        case let .upToDate(branch): ("\(branch) is up to date", .secondary)
        case .fetchedOnly: ("Fetched (no local main branch)", .secondary)
        case .noRemote: ("No origin remote, nothing to pull", .secondary)
        case let .skipped(reason): (reason, .orange)
        case let .failed(message): (message, .red)
        }
    }

    private var organizationBinding: Binding<String> {
        Binding(
            get: { repoSync.settings.organization ?? "" },
            set: { text in
                let organization = text.trimmingCharacters(in: .whitespaces)
                repoSync.settings.organization = organization.isEmpty ? nil : organization
            }
        )
    }

    private func includedBinding(_ repository: LocalRepository) -> Binding<Bool> {
        Binding(
            get: { !repoSync.settings.excludedRepositories.contains(repository.name) },
            set: { isIncluded in
                if isIncluded {
                    repoSync.settings.excludedRepositories.remove(repository.name)
                } else {
                    repoSync.settings.excludedRepositories.insert(repository.name)
                }
            }
        )
    }
}

private struct GeneralSettingsView: View {
    @Bindable var model: QueueModel
    @ViewState private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @ViewState private var loginItemError: String?
    @ViewState private var areNotificationsAllowed = true
    @ViewState private var botAccountsText = ""

    var body: some View {
        Form {
            Picker("Check for updates", selection: $model.settings.refreshMinutes) {
                ForEach(AppSettings.refreshChoices, id: \.self) { minutes in
                    Text("Every \(minutes) minutes").tag(minutes)
                }
            }
            Picker("Skip pull requests idle for more than", selection: $model.settings.idleLimitDays) {
                ForEach(AppSettings.idleLimitChoices, id: \.self) { days in
                    Text("\(days) days").tag(Int?.some(days))
                }
                Text("Never skip").tag(Int?.none)
            }
            Picker("Pull requests already approved by others", selection: $model.settings.approvedPlacement) {
                ForEach(ApprovedPlacement.allCases) { Text($0.title).tag($0) }
            }
            TextField("Only show pull requests whose branch contains", text: branchFilterBinding, prompt: Text("any branch"))
            Section {
                if model.teams.isEmpty {
                    Text(model.teamsError ?? "Loading your teams…").foregroundStyle(.secondary)
                }
                ForEach(model.teams) { team in
                    Toggle(team.id, isOn: $model.settings.authorTeams.contains(team.id))
                }
            } header: {
                Text("Only show pull requests opened by members of")
            } footer: {
                Text("Tick none to show pull requests from anyone. Your own pull requests always show.")
            }
            Section {
                TextField("Also treat these accounts as bots", text: $botAccountsText, prompt: Text("none"))
                    .onSubmit(saveBotAccounts)
            } footer: {
                Text("GitHub usernames, separated by commas. Press Return to save. Their pull requests, reviews and comments are left out.")
            }
            Section("Show on each card") {
                ForEach(CardDetail.allCases) { detail in
                    Toggle(detail.title, isOn: $model.settings.cardDetails.contains(detail))
                }
            }
            Section {
                ForEach(NotificationTopic.allCases) { topic in
                    Toggle(topic.title, isOn: $model.settings.notificationTopics.contains(topic))
                }
            } header: {
                Text("Notify me about")
            } footer: {
                if !areNotificationsAllowed {
                    Text("Notifications are turned off for PR Review Bar in System Settings › Notifications.")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, isOn in setOpensAtLogin(isOn) }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
                if let me = model.snapshot?.me {
                    LabeledContent("GitHub account", value: me)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: saveBotAccounts)
        .task {
            botAccountsText = model.settings.botAccounts.sorted().joined(separator: ", ")
            areNotificationsAllowed = await model.notifier.isAuthorized()
            if model.teams.isEmpty { await model.loadTeams() }
        }
    }

    private var branchFilterBinding: Binding<String> {
        Binding(
            get: { model.settings.branchFilter ?? "" },
            set: { text in
                let filter = text.trimmingCharacters(in: .whitespaces)
                model.settings.branchFilter = filter.isEmpty ? nil : filter
            }
        )
    }

    private func saveBotAccounts() {
        model.settings.botAccounts = Set(botAccountsText.split { $0 == "," || $0.isWhitespace }.map { $0.lowercased() })
    }

    private func setOpensAtLogin(_ isOn: Bool) {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            opensAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct RepositorySettingsView: View {
    @Bindable var model: QueueModel
    @ViewState private var filter = ""

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            List {
                Section("Your teams") {
                    if model.teams.isEmpty && model.teamsError == nil {
                        ProgressView().controlSize(.small)
                    }
                    ForEach(model.teams) { team in
                        Toggle(isOn: teamBinding(team)) {
                            VStack(alignment: .leading) {
                                Text(team.name)
                                Text(team.organization).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(width: 210)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let teamsError = model.teamsError {
                    Label(teamsError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                }
                HStack {
                    TextField("Filter repositories", text: $filter).textFieldStyle(.roundedBorder)
                    Text("Watching \(model.settings.repositories.count)").font(.caption).foregroundStyle(.secondary)
                }
                List {
                    if selectedTeams.isEmpty {
                        Text("Pick a team on the left to see its repositories.").foregroundStyle(.secondary)
                    }
                    ForEach(selectedTeams) { team in
                        Section {
                            ForEach(repositories(of: team), id: \.self) { repository in
                                Toggle(repository, isOn: $model.settings.repositories.contains(repository))
                            }
                        } header: {
                            HStack {
                                Text(team.name)
                                Spacer()
                                Button("All") { model.settings.repositories.formUnion(repositories(of: team)) }
                                Button("None") { model.settings.repositories.subtract(repositories(of: team)) }
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
            .padding(12)
        }
        .task { await model.loadTeams() }
    }

    private var selectedTeams: [Team] {
        model.teams.filter { model.settings.teams.contains($0.id) }
    }

    private func repositories(of team: Team) -> [String] {
        let all = model.repositoriesByTeam[team.id] ?? []
        guard !filter.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    private func teamBinding(_ team: Team) -> Binding<Bool> {
        Binding(
            get: { model.settings.teams.contains(team.id) },
            set: { isSelected in Task { await model.setTeam(team, isSelected: isSelected) } }
        )
    }
}

private struct HiddenSettingsView: View {
    let model: QueueModel

    var body: some View {
        List {
            if model.settings.hiddenPullRequests.isEmpty {
                Text("No hidden pull requests. Hide one from its card or its right-click menu.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.settings.hiddenPullRequests) { hidden in
                HStack {
                    VStack(alignment: .leading) {
                        Link(hidden.title, destination: hidden.url)
                        Text(hidden.id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show again") { model.unhide(hidden.id) }
                }
            }
        }
        .padding(12)
    }
}
