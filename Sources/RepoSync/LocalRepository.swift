import Foundation

public struct LocalRepository: Identifiable, Hashable, Sendable {
    public let name: String
    public let path: URL
    public let remoteURL: String?

    public var id: String { path.path }
    public var gitHubName: String? { remoteURL.flatMap(Self.gitHubName(fromRemote:)) }

    public func belongs(to organization: String) -> Bool {
        gitHubName?.split(separator: "/").first?.caseInsensitiveCompare(organization) == .orderedSame
    }

    // Linked worktrees have a `.git` file instead of a folder and share refs with their main clone, so only main clones are listed.
    public static func discover(in folder: URL) async throws -> [LocalRepository] {
        let children = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var repositories: [LocalRepository] = []
        for child in children where isMainClone(child) {
            let remote = try await Git.run(["config", "--get", "remote.origin.url"], in: child)
            repositories.append(LocalRepository(name: child.lastPathComponent, path: child, remoteURL: remote.succeeded ? remote.trimmedOutput : nil))
        }
        return repositories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func gitHubName(fromRemote url: String) -> String? {
        guard let match = url.firstMatch(of: /github\.com[:\/]([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+?)(?:\.git)?\/?$/) else { return nil }
        return "\(match.1)/\(match.2)"
    }

    private static func isMainClone(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.appending(path: ".git").path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
