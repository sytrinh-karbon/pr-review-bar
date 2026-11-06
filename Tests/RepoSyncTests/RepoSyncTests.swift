import Foundation
import Testing

@testable import RepoSync

private struct Sandbox {
    let root: URL
    let origin: URL
    let teammate: URL
    let workspace: URL

    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "reposync-\(UUID().uuidString)")
        origin = root.appending(path: "origin.git")
        teammate = root.appending(path: "teammate")
        workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try await git(["init", "--bare", "--quiet", "-b", "main", origin.path], in: root)
        try await git(["clone", "--quiet", origin.path, teammate.path], in: root)
        try await commit("a.txt", "one", in: teammate)
        try await git(["push", "--quiet", "-u", "origin", "main"], in: teammate)
    }

    func clone(_ name: String) async throws -> LocalRepository {
        let path = workspace.appending(path: name)
        try await git(["clone", "--quiet", origin.path, path.path], in: root)
        return LocalRepository(name: name, path: path, remoteURL: origin.path)
    }

    func push(_ file: String, _ content: String) async throws {
        try await commit(file, content, in: teammate)
        try await git(["push", "--quiet"], in: teammate)
    }

    func commit(_ file: String, _ content: String, in directory: URL) async throws {
        try content.write(to: directory.appending(path: file), atomically: true, encoding: .utf8)
        try await git(["add", file], in: directory)
        try await git(["commit", "--quiet", "-m", "Change \(file)"], in: directory)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL) async throws -> String {
        let isolation = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]
        let result = try await Git.run(isolation + arguments, in: directory)
        #expect(result.succeeded, "git \(arguments.joined(separator: " ")): \(result.errorOutput)")
        return result.trimmedOutput
    }

    func read(_ file: String, in repository: LocalRepository) throws -> String {
        try String(contentsOf: repository.path.appending(path: file), encoding: .utf8)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite struct SyncTests {
    @Test func fastForwardsTheCheckedOutDefaultBranch() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.cleanUp() }
        let local = try await sandbox.clone("app")
        try await sandbox.push("a.txt", "two")

        #expect(await RepositorySyncer.sync(local) == .updated(branch: "main", commits: 1))
        #expect(try sandbox.read("a.txt", in: local) == "two")
        #expect(await RepositorySyncer.sync(local) == .upToDate(branch: "main"))
    }

    @Test func movesMainWithoutTouchingTheFeatureBranch() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.cleanUp() }
        let local = try await sandbox.clone("app")
        try await sandbox.git(["checkout", "--quiet", "-b", "feature"], in: local.path)
        try "work in progress".write(to: local.path.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try await sandbox.push("b.txt", "new")
        try await sandbox.push("b.txt", "newer")

        #expect(await RepositorySyncer.sync(local) == .updated(branch: "main", commits: 2))
        #expect(try await sandbox.git(["symbolic-ref", "--short", "HEAD"], in: local.path) == "feature")
        #expect(try sandbox.read("a.txt", in: local) == "work in progress")
        #expect(!FileManager.default.fileExists(atPath: local.path.appending(path: "b.txt").path))
        let main = try await sandbox.git(["rev-parse", "main"], in: local.path)
        #expect(try await sandbox.git(["rev-parse", "origin/main"], in: local.path) == main)
    }

    @Test func keepsUncommittedChangesThatConflict() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.cleanUp() }
        let local = try await sandbox.clone("app")
        try "my edit".write(to: local.path.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try await sandbox.push("a.txt", "their edit")

        let outcome = await RepositorySyncer.sync(local)
        #expect(outcome == .skipped("Your uncommitted changes touch files the update changes, so main was left as is"))
        #expect(try sandbox.read("a.txt", in: local) == "my edit")
    }

    @Test func leavesADivergedMainAlone() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.cleanUp() }
        let local = try await sandbox.clone("app")
        try await sandbox.commit("local.txt", "mine", in: local.path)
        let localMain = try await sandbox.git(["rev-parse", "main"], in: local.path)
        try await sandbox.git(["checkout", "--quiet", "-b", "feature"], in: local.path)
        try await sandbox.push("a.txt", "two")

        #expect(await RepositorySyncer.sync(local) == .skipped("Local main has commits that are not on origin, so it was left as is"))
        #expect(try await sandbox.git(["rev-parse", "main"], in: local.path) == localMain)
    }

    @Test func fetchesABranchWhoseNameClashesWithAStaleLogFolder() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.cleanUp() }
        let local = try await sandbox.clone("app")
        let staleLogs = local.path.appending(path: ".git/logs/refs/remotes/origin/feature")
        try FileManager.default.createDirectory(at: staleLogs, withIntermediateDirectories: true)
        try "stale".write(to: staleLogs.appending(path: "old"), atomically: true, encoding: .utf8)
        try await sandbox.git(["push", "--quiet", "origin", "main:refs/heads/feature"], in: sandbox.teammate)
        try await sandbox.push("a.txt", "two")

        #expect(await RepositorySyncer.sync(local) == .updated(branch: "main", commits: 1))
        #expect(try await sandbox.git(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/feature"], in: local.path) != "")
    }

    @Test func syncsEveryRepositoryAndReportsEach() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.cleanUp() }
        let first = try await sandbox.clone("first")
        let second = try await sandbox.clone("second")
        try await sandbox.push("a.txt", "two")

        let results = Results()
        await RepositorySyncer.syncAll([first, second], maxConcurrent: 1) { repository, outcome in
            await results.record(repository.name, outcome)
        }
        #expect(await results.all == ["first": .updated(branch: "main", commits: 1), "second": .updated(branch: "main", commits: 1)])
    }

    @Test func discoversMainClonesOnly() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.cleanUp() }
        let local = try await sandbox.clone("app")
        try await sandbox.git(["worktree", "add", "--quiet", "-b", "wt", sandbox.workspace.appending(path: "app-wt").path], in: local.path)
        try FileManager.default.createDirectory(at: sandbox.workspace.appending(path: "notes"), withIntermediateDirectories: true)

        let found = try await LocalRepository.discover(in: sandbox.workspace)
        #expect(found.map(\.name) == ["app"])
        #expect(found.first?.remoteURL == sandbox.origin.path)
    }

    @Test func readsGitHubNamesFromRemotes() {
        #expect(LocalRepository.gitHubName(fromRemote: "git@github.com:acme/widgets.git") == "acme/widgets")
        #expect(LocalRepository.gitHubName(fromRemote: "https://github.com/acme/widgets") == "acme/widgets")
        #expect(LocalRepository.gitHubName(fromRemote: "ssh://git@github.com/acme/widgets.app.git") == "acme/widgets.app")
        #expect(LocalRepository.gitHubName(fromRemote: "https://gitlab.com/acme/x.git") == nil)
    }

    @Test func matchesTheOrganizationIgnoringCase() {
        let path = URL(filePath: "/tmp/app")
        #expect(LocalRepository(name: "app", path: path, remoteURL: "git@github.com:Acme/app.git").belongs(to: "acme"))
        #expect(!LocalRepository(name: "app", path: path, remoteURL: "git@github.com:someone/app.git").belongs(to: "acme"))
        #expect(!LocalRepository(name: "app", path: path, remoteURL: nil).belongs(to: "acme"))
    }
}

private actor Results {
    var all: [String: SyncOutcome] = [:]

    func record(_ name: String, _ outcome: SyncOutcome) {
        all[name] = outcome
    }
}
