import RepoSync
import ReviewCore
import SwiftUI

struct MenuView: View {
    let model: QueueModel
    let repoSync: RepoSyncModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.settings.repositories.isEmpty {
                        Button("Choose repositories to watch…", action: showSettings)
                            .buttonStyle(.link)
                    }
                    ForEach(QueueSection.allCases) { section in
                        QueueSectionView(
                            section: section,
                            pullRequests: model.sections[section] ?? [],
                            isCollapsed: model.settings.collapsedSections.contains(section),
                            cardDetails: model.settings.cardDetails,
                            onToggle: { model.toggle(section) },
                            onHide: model.hide
                        )
                    }
                }
                .padding(12)
            }
            .frame(height: 480)
        }
        .frame(width: 420)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pull request reviews").font(.headline)
                status
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)
            .help("Refresh now")
            Button {
                model.settings.onlyInvolvingMe.toggle()
            } label: {
                Image(systemName: model.settings.onlyInvolvingMe ? "person.crop.circle.fill" : "person.crop.circle")
            }
            .help(model.settings.onlyInvolvingMe ? "Showing only pull requests involving you" : "Show only pull requests involving you")
            Menu {
                Picker("Sort by", selection: sortBinding) {
                    ForEach(QueueSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort by: \(model.settings.sort.title)")
            Menu {
                Button("Pull Local Repositories Now") { Task { await repoSync.syncNow() } }
                    .disabled(repoSync.settings.folder == nil || repoSync.isSyncing)
                Button("Settings…", action: showSettings)
                Divider()
                Button("Quit PR Review Bar") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(12)
    }

    @ViewBuilder private var status: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Group {
                if model.isRefreshing {
                    Text("Updating…")
                } else if let lastUpdated = model.lastUpdated {
                    Text("Updated \(compactAge(of: lastUpdated, now: context.date)) · every \(model.settings.refreshMinutes)m")
                } else {
                    Text("Not updated yet")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            repoSyncStatus(now: context.date)
        }
        if let errorMessage = model.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(model.snapshot?.warnings ?? [], id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func repoSyncStatus(now: Date) -> some View {
        if repoSync.settings.folder != nil {
            HStack(spacing: 4) {
                if repoSync.isSyncing {
                    Text("Pulling local repos… \(repoSync.syncingIDs.count) left")
                } else if let lastSynced = repoSync.lastSynced {
                    Text("Local repos pulled \(compactAge(of: lastSynced, now: now)) · every \(repoSync.settings.intervalMinutes)m")
                } else {
                    Text("Local repos not pulled yet")
                }
                if repoSync.attentionCount > 0 {
                    Button("· \(repoSync.attentionCount) need attention", action: showSettings)
                        .buttonStyle(.link)
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let errorMessage = repoSync.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sortBinding: Binding<QueueSort> {
        Binding(get: { model.settings.sort }, set: { model.settings.sort = $0 })
    }

    private func showSettings() {
        openSettings()
        NSApp.activate()
    }
}

private struct QueueSectionView: View {
    let section: QueueSection
    let pullRequests: [PullRequest]
    let isCollapsed: Bool
    let cardDetails: Set<CardDetail>
    let onToggle: () -> Void
    let onHide: (PullRequest) -> Void

    private var firstCoveredID: String? { pullRequests.first(where: \.isCoveredByOthers)?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text(section.title).font(.subheadline.weight(.semibold))
                    Text("\(pullRequests.count)").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                if pullRequests.isEmpty {
                    Text(section.emptyMessage).font(.caption).foregroundStyle(.secondary).padding(.leading, 18)
                }
                ForEach(pullRequests) { pullRequest in
                    if section == .needsReview, pullRequest.id == firstCoveredID {
                        Text("Already approved by others")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    PullRequestCard(pullRequest: pullRequest, details: cardDetails, onHide: { onHide(pullRequest) })
                }
            }
        }
    }
}
