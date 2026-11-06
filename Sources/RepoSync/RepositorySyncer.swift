import Foundation

public enum SyncOutcome: Equatable, Sendable {
    case updated(branch: String, commits: Int)
    case upToDate(branch: String)
    case fetchedOnly
    case noRemote
    case skipped(String)
    case failed(String)

    public var needsAttention: Bool {
        switch self {
        case .skipped, .failed: true
        case .updated, .upToDate, .fetchedOnly, .noRemote: false
        }
    }
}

public enum RepositorySyncer {
    public static func syncAll(
        _ repositories: [LocalRepository],
        maxConcurrent: Int = 6,
        onResult: @escaping @Sendable (LocalRepository, SyncOutcome) async -> Void
    ) async {
        await withTaskGroup(of: (LocalRepository, SyncOutcome).self) { group in
            var pending = repositories.makeIterator()
            for _ in 0..<maxConcurrent {
                guard let repository = pending.next() else { break }
                group.addTask { (repository, await sync(repository)) }
            }
            for await (repository, outcome) in group {
                await onResult(repository, outcome)
                if let next = pending.next() {
                    group.addTask { (next, await sync(next)) }
                }
            }
        }
    }

    public static func sync(_ repository: LocalRepository) async -> SyncOutcome {
        guard repository.remoteURL != nil else { return .noRemote }
        do {
            return try await update(repository.path)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // Moves only the default branch, and only forward: merged with --ff-only when checked out, else updated as a ref.
    // Git itself refuses a non-fast-forward, a branch checked out in another worktree, and changes that would be overwritten.
    private static func update(_ directory: URL) async throws -> SyncOutcome {
        // Without reflogs, a stale log folder from a deleted branch such as feat/x/y cannot block fetching a new branch feat/x.
        let fetch = try await Git.run(["-c", "core.logAllRefUpdates=false", "fetch", "--prune", "--quiet", "origin"], in: directory)
        guard fetch.succeeded else { return .failed(fetch.firstErrorLine) }
        guard let branch = try await defaultBranch(in: directory) else { return .fetchedOnly }
        let localRef = "refs/heads/\(branch)"
        let remoteRef = "refs/remotes/origin/\(branch)"
        guard let before = try await revision(localRef, in: directory) else { return .fetchedOnly }

        let head = try await Git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory)
        let isOnBranch = head.succeeded && head.trimmedOutput == branch
        let update = isOnBranch
            ? try await Git.run(["merge", "--ff-only", "--quiet", remoteRef], in: directory)
            : try await Git.run(["fetch", ".", "\(remoteRef):\(localRef)"], in: directory)
        guard update.succeeded else { return .skipped(reason(for: update, branch: branch)) }

        guard let after = try await revision(localRef, in: directory), after != before else { return .upToDate(branch: branch) }
        let count = try await Git.run(["rev-list", "--count", "\(before)..\(after)"], in: directory)
        return .updated(branch: branch, commits: Int(count.trimmedOutput) ?? 0)
    }

    private static func defaultBranch(in directory: URL) async throws -> String? {
        let head = try await Git.run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: directory)
        if head.succeeded, head.trimmedOutput.hasPrefix("origin/") {
            return String(head.trimmedOutput.dropFirst("origin/".count))
        }
        for candidate in ["main", "master"] where try await revision("refs/remotes/origin/\(candidate)", in: directory) != nil {
            return candidate
        }
        return nil
    }

    private static func revision(_ ref: String, in directory: URL) async throws -> String? {
        let result = try await Git.run(["rev-parse", "--verify", "--quiet", ref], in: directory)
        return result.succeeded ? result.trimmedOutput : nil
    }

    private static func reason(for result: GitOutput, branch: String) -> String {
        let message = result.errorOutput
        if message.contains("non-fast-forward") || message.contains("Not possible to fast-forward") || message.contains("diverg") {
            return "Local \(branch) has commits that are not on origin, so it was left as is"
        }
        if message.contains("would be overwritten") {
            return "Your uncommitted changes touch files the update changes, so \(branch) was left as is"
        }
        if message.contains("checked out at") {
            return "\(branch) is checked out in another worktree, so it was left as is"
        }
        return result.firstErrorLine
    }
}
