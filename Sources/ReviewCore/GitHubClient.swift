import Foundation

public enum GitHubError: LocalizedError, Equatable {
    case cliNotFound
    case notSignedIn
    case requestFailed(status: Int, message: String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound: "GitHub CLI (gh) not found. Install it with: brew install gh"
        case .notSignedIn: "GitHub CLI is not signed in. Run in Terminal: gh auth login"
        case let .requestFailed(status, message): "GitHub request failed (\(status)): \(message)"
        case let .queryFailed(message): "GitHub query failed: \(message)"
        }
    }
}

public struct Team: Codable, Hashable, Identifiable, Sendable {
    public let organization: String
    public let slug: String
    public let name: String

    public var id: String { "\(organization)/\(slug)" }
}

struct RepositoryName: Hashable {
    let owner: String
    let name: String

    init?(_ fullName: String) {
        guard let match = fullName.wholeMatch(of: /([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)/) else { return nil }
        owner = String(match.1)
        name = String(match.2)
    }

    var graphQLArguments: String { "owner: \"\(owner)\", name: \"\(name)\"" }
}

struct ListedEntry {
    let repository: RepositoryName
    let pullRequest: ListedPullRequest
}

public actor GitHubClient {
    private static let cliPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    private static let apiURL = URL(string: "https://api.github.com")!
    private static let repositoryBatchSize = 30
    private static let detailBatchSize = 20
    private static let concurrentRequests = 4
    private static let serverErrors: Set<Int> = [502, 503, 504]
    private static let myPullRequestsQuery = "is:pr is:open author:@me draft:false archived:false"

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private var token: String?
    private var viewer: String?

    public init() {}

    public func teams() async throws -> [Team] {
        struct Response: Decodable {
            struct Organization: Decodable {
                let login: String
            }

            let slug: String
            let name: String
            let organization: Organization
        }
        let teams: [Response] = try await restList("user/teams")
        return teams.map { Team(organization: $0.organization.login, slug: $0.slug, name: $0.name) }.sorted { $0.id < $1.id }
    }

    public func repositories(of team: Team) async throws -> [String] {
        struct Response: Decodable {
            let fullName: String
            let archived: Bool

            enum CodingKeys: String, CodingKey {
                case fullName = "full_name"
                case archived
            }
        }
        let repositories: [Response] = try await restList("orgs/\(team.organization)/teams/\(team.slug)/repos")
        return repositories.filter { !$0.archived }.map(\.fullName).sorted()
    }

    public func snapshot(
        watching repositories: Set<String>,
        updatedSince cutoff: Date?,
        authorTeams: Set<String>,
        botAccounts: Set<String>
    ) async throws -> QueueSnapshot {
        let me = try await viewerLogin()
        let mapper = QueueMapper(me: me, botAccounts: botAccounts)
        let (myNodes, myWarnings) = try await myPullRequests()
        let allowedAuthors = authorTeams.isEmpty ? nil : try await members(of: authorTeams)
        let (listed, listWarnings) = try await openPullRequests(in: repositories.sorted().compactMap(RepositoryName.init))
        let reviewable = listed.filter { entry in
            let pullRequest = entry.pullRequest
            guard let author = pullRequest.author?.login else { return false }
            return !pullRequest.isDraft && mapper.isHuman(pullRequest.author) && author != me
                && cutoff.map { pullRequest.updatedAt >= $0 } ?? true
                && allowedAuthors.map { $0.contains(author) } ?? true
        }
        let (reviewNodes, detailWarnings) = try await details(of: reviewable)
        return mapper.snapshot(reviewNodes: reviewNodes, myNodes: myNodes, warnings: myWarnings + listWarnings + detailWarnings)
    }

    private func members(of teams: Set<String>) async throws -> Set<String> {
        struct Member: Decodable {
            let login: String
        }
        var logins: Set<String> = []
        for team in teams.sorted() {
            let parts = team.split(separator: "/")
            guard parts.count == 2 else { continue }
            let members: [Member] = try await restList("orgs/\(parts[0])/teams/\(parts[1])/members")
            logins.formUnion(members.map(\.login))
        }
        return logins
    }

    private func viewerLogin() async throws -> String {
        if let viewer { return viewer }
        struct Response: Decodable {
            struct Viewer: Decodable {
                let login: String
            }

            let viewer: Viewer
        }
        let (response, _): (Response, [String]) = try await graphQL("query { viewer { login } }")
        viewer = response.viewer.login
        return response.viewer.login
    }

    private func myPullRequests() async throws -> ([PullRequestNode], [String]) {
        struct Response: Decodable {
            let search: Connection<PullRequestNode>
        }
        let query = """
            query { search(query: "\(Self.myPullRequestsQuery)", type: ISSUE, first: 50) { nodes { ...Full } } }
            \(PullRequestNode.fragment)
            """
        let (response, warnings): (Response, [String]) = try await graphQL(query)
        return (response.search.nodes, warnings)
    }

    private func openPullRequests(in repositories: [RepositoryName]) async throws -> ([ListedEntry], [String]) {
        struct Repository: Decodable {
            let pullRequests: Connection<ListedPullRequest>
        }
        var listed: [ListedEntry] = []
        var warnings: [String] = []
        for batch in repositories.chunked(into: Self.repositoryBatchSize) {
            let aliases = batch.enumerated().map { index, repository in
                "r\(index): repository(\(repository.graphQLArguments)) { pullRequests(states: OPEN, first: 100) { nodes { number isDraft updatedAt author { login __typename } } } }"
            }
            let (response, batchWarnings): ([String: Repository?], [String]) = try await graphQL("query {\n\(aliases.joined(separator: "\n"))\n}")
            warnings += batchWarnings
            for (index, repository) in batch.enumerated() {
                let pullRequests = response["r\(index)"]??.pullRequests.nodes ?? []
                listed += pullRequests.map { ListedEntry(repository: repository, pullRequest: $0) }
            }
        }
        return (listed, warnings)
    }

    private func details(of listed: [ListedEntry]) async throws -> ([PullRequestNode], [String]) {
        var batches = listed.chunked(into: Self.detailBatchSize).makeIterator()
        return try await withThrowingTaskGroup(of: ([PullRequestNode], [String]).self) { group in
            for _ in 0..<Self.concurrentRequests {
                guard let batch = batches.next() else { break }
                group.addTask { try await self.detailBatch(batch) }
            }
            var nodes: [PullRequestNode] = []
            var warnings: [String] = []
            while let (batchNodes, batchWarnings) = try await group.next() {
                nodes += batchNodes
                warnings += batchWarnings
                if let batch = batches.next() {
                    group.addTask { try await self.detailBatch(batch) }
                }
            }
            return (nodes, warnings)
        }
    }

    private func detailBatch(_ batch: [ListedEntry]) async throws -> ([PullRequestNode], [String]) {
        struct Repository: Decodable {
            let pullRequest: PullRequestNode?
        }
        let aliases = batch.enumerated().map { index, entry in
            "p\(index): repository(\(entry.repository.graphQLArguments)) { pullRequest(number: \(entry.pullRequest.number)) { ...Full } }"
        }
        let query = "query {\n\(aliases.joined(separator: "\n"))\n}\n\(PullRequestNode.fragment)"
        let (response, warnings): ([String: Repository?], [String]) = try await graphQL(query)
        return (batch.indices.compactMap { response["p\($0)"]??.pullRequest }, warnings)
    }

    private func graphQL<Response: Decodable>(_ query: String) async throws -> (Response, [String]) {
        var request = URLRequest(url: Self.apiURL.appending(path: "graphql"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(["query": query])
        let (data, _) = try await send(request)
        let envelope = try decoder.decode(GraphQLEnvelope<Response>.self, from: data)
        let messages = envelope.errors?.map(\.message) ?? []
        guard let response = envelope.data else { throw GitHubError.queryFailed(messages.joined(separator: "; ")) }
        return (response, messages)
    }

    private func restList<Element: Decodable>(_ path: String) async throws -> [Element] {
        var next = URL(string: "\(path)?per_page=100", relativeTo: Self.apiURL)
        var elements: [Element] = []
        while let url = next {
            let (data, response) = try await send(URLRequest(url: url))
            elements += try decoder.decode([Element].self, from: data)
            next = Self.nextPage(in: response)
        }
        return elements
    }

    private func send(_ request: URLRequest, isRetry: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue("Bearer \(try await authToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GitHubError.requestFailed(status: 0, message: "No HTTP response")
        }
        if response.statusCode == 401 {
            token = nil
            throw GitHubError.notSignedIn
        }
        if Self.serverErrors.contains(response.statusCode) {
            guard isRetry else { return try await send(request, isRetry: true) }
            throw GitHubError.requestFailed(status: response.statusCode, message: "GitHub is busy or timed out. It will try again on the next refresh.")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubError.requestFailed(status: response.statusCode, message: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return (data, response)
    }

    private func authToken() async throws -> String {
        if let token { return token }
        guard let cli = Self.cliPaths.first(where: FileManager.default.isExecutableFile(atPath:)) else { throw GitHubError.cliNotFound }
        let loaded = try await Task.detached { try Self.readToken(using: cli) }.value
        token = loaded
        return loaded
    }

    private static func readToken(using cli: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: cli)
        process.arguments = ["auth", "token"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !token.isEmpty else { throw GitHubError.notSignedIn }
        return token
    }

    private static func nextPage(in response: HTTPURLResponse) -> URL? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") where part.contains("rel=\"next\"") {
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">") else { continue }
            return URL(string: String(part[part.index(after: start)..<end]))
        }
        return nil
    }
}

private struct GraphQLEnvelope<Response: Decodable>: Decodable {
    struct Message: Decodable {
        let message: String
    }

    let data: Response?
    let errors: [Message]?
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
